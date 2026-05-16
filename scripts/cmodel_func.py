#!/usr/bin/env python3
"""Functional gate for the current C model.

This validates the internal RTL-equivalent uncompressed C model before any
benchmarking is allowed. It can also validate the compressed LZMA2 backend used
by the benchmark flow.
"""

from __future__ import annotations

import argparse
import lzma
import random
import subprocess
import time
from pathlib import Path


def run(cmd: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, check=True, text=True, capture_output=True)


def make_cases(out_dir: Path) -> list[tuple[str, bytes, int]]:
    rng = random.Random(0xC0DE_585A)
    return [
        ("empty", b"", 65536),
        ("small", b"XZ RTL C model smoke\n" * 3, 65536),
        ("repeat", (b"ABCD" * 4096) + (b"\x00" * 2048), 65536),
        ("random", bytes(rng.randrange(0, 256) for _ in range(8192)), 65536),
        ("cross_64k", bytes((i * 13 + (i >> 6)) & 0xFF for i in range(70000)), 65536),
        ("dict_wrap", (b"0123456789abcdef" * 8192) + (b"wrap" * 4096), 16384),
        ("crc64", bytes((128 + ((i // 17) % 11) - 5) & 0xFF for i in range(32768)), 4096),
        ("fallback_like_noise", bytes(rng.randrange(0, 256) for _ in range(90000)), 65536),
    ]


def compressed_reference(data: bytes, args: argparse.Namespace) -> bytes:
    filters = [
        {
            "id": lzma.FILTER_LZMA2,
            "dict_size": args.dict_kib * 1024,
            "lc": args.lc,
            "lp": args.lp,
            "pb": args.pb,
            "mode": lzma.MODE_FAST,
            "nice_len": args.nice_len,
            "mf": lzma.MF_HC4,
            "depth": args.depth,
        }
    ]
    return lzma.compress(data, format=lzma.FORMAT_XZ, check=lzma.CHECK_CRC32, filters=filters)


def compressed_cmodel(input_path: Path, output_path: Path, args: argparse.Namespace) -> tuple[str, bytes, float]:
    if args.compressed_backend == "python":
        data = input_path.read_bytes()
        start = time.perf_counter()
        encoded = compressed_reference(data, args)
        elapsed = time.perf_counter() - start
        output_path.write_bytes(encoded)
        return "PYTHON_LZMA_REFERENCE", encoded, elapsed

    exe = args.compressed_cmodel if args.compressed_backend == "liblzma" else args.rtl_cmodel
    cmd = [
        str(exe),
        "--check",
        "1",
        "--dict-kib",
        str(args.dict_kib),
        "--lc",
        str(args.lc),
        "--lp",
        str(args.lp),
        "--pb",
        str(args.pb),
        "--nice-len",
        str(args.nice_len),
        "--depth",
        str(args.depth),
        str(input_path),
        str(output_path),
    ]
    start = time.perf_counter()
    run(cmd)
    elapsed = time.perf_counter() - start
    if args.compressed_backend == "liblzma":
        return "STANDALONE_C_LIBLZMA_HC4_RANGE", output_path.read_bytes(), elapsed
    return "STANDALONE_C_RTL_FRIENDLY_HC4_RANGE", output_path.read_bytes(), elapsed


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cmodel", type=Path, default=Path("build/cmodel/xz_uncompressed_model"))
    parser.add_argument("--compressed-cmodel", type=Path, default=Path("build/cmodel/xz_liblzma_model"))
    parser.add_argument("--rtl-cmodel", type=Path, default=Path("build/cmodel/xz_rtl_model"))
    parser.add_argument("--compressed-backend", choices=["python", "liblzma", "rtl"], default="python")
    parser.add_argument("--out-dir", type=Path, default=Path("build/cmodel/func"))
    parser.add_argument("--dict-kib", type=int, default=256)
    parser.add_argument("--lc", type=int, default=4)
    parser.add_argument("--lp", type=int, default=0)
    parser.add_argument("--pb", type=int, default=0)
    parser.add_argument("--nice-len", type=int, default=64)
    parser.add_argument("--depth", type=int, default=16)
    args = parser.parse_args()

    args.out_dir.mkdir(parents=True, exist_ok=True)
    cases = make_cases(args.out_dir)
    passed = 0

    for name, data, chunk_size in cases:
        check = "4" if name == "crc64" else "1"
        input_path = args.out_dir / f"{name}.bin"
        xz_path = args.out_dir / f"{name}.xz"
        input_path.write_bytes(data)

        result = run(
            [
                str(args.cmodel),
                "--check",
                check,
                "--dict-kib",
                str(args.dict_kib),
                "--lc",
                str(args.lc),
                "--lp",
                str(args.lp),
                "--pb",
                str(args.pb),
                "--nice-len",
                str(args.nice_len),
                "--depth",
                str(args.depth),
                "--chunk-size",
                str(chunk_size),
                str(input_path),
                str(xz_path),
            ]
        )
        decoded = lzma.decompress(xz_path.read_bytes())
        if decoded != data:
            raise SystemExit(f"decode mismatch: {name}")

        print(f"PASS {name}: {result.stdout.strip()}")
        passed += 1

    compressed_passed = 0
    for name, data, _chunk_size in cases:
        input_path = args.out_dir / f"{name}.bin"
        xz_path = args.out_dir / f"{name}.compressed_{args.compressed_backend}.xz"
        backend_name, encoded, elapsed = compressed_cmodel(input_path, xz_path, args)
        if lzma.decompress(encoded) != data:
            raise SystemExit(f"compressed backend mismatch: {name}")
        ratio = 0.0 if len(data) == 0 else len(encoded) / len(data)
        mbps = 0.0 if elapsed <= 0 else len(data) / elapsed / (1024 * 1024)
        print(
            f"PASS_COMPRESSED_{args.compressed_backend.upper()} {name}: "
            f"input_bytes={len(data)} output_bytes={len(encoded)} ratio={ratio:.6f} "
            f"enc_MBps={mbps:.2f} backend={backend_name}"
        )
        compressed_passed += 1

    print(f"functional_pass={passed}/{len(cases)}")
    print(f"compressed_backend_pass={compressed_passed}/{len(cases)}")
    print(f"compressed_lzma2_cmodel_status={args.compressed_backend.upper()}_PASS")


if __name__ == "__main__":
    main()
