#!/usr/bin/env python3
"""Functional gate for the current C model.

This validates the internal RTL-equivalent uncompressed C model before any
benchmarking is allowed. The compressed LZMA2 C model is intentionally reported
as pending until the range-coder/HC4 implementation lands.
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


def compressed_reference(data: bytes) -> bytes:
    filters = [
        {
            "id": lzma.FILTER_LZMA2,
            "dict_size": 256 * 1024,
            "lc": 3,
            "lp": 0,
            "pb": 2,
            "mode": lzma.MODE_FAST,
            "nice_len": 32,
            "mf": lzma.MF_HC4,
            "depth": 16,
        }
    ]
    return lzma.compress(data, format=lzma.FORMAT_XZ, check=lzma.CHECK_CRC32, filters=filters)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cmodel", type=Path, default=Path("build/cmodel/xz_uncompressed_model"))
    parser.add_argument("--out-dir", type=Path, default=Path("build/cmodel/func"))
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
        start = time.perf_counter()
        encoded = compressed_reference(data)
        elapsed = time.perf_counter() - start
        if lzma.decompress(encoded) != data:
            raise SystemExit(f"compressed reference mismatch: {name}")
        xz_path = args.out_dir / f"{name}.compressed_ref.xz"
        xz_path.write_bytes(encoded)
        ratio = 0.0 if len(data) == 0 else len(encoded) / len(data)
        mbps = 0.0 if elapsed <= 0 else len(data) / elapsed / (1024 * 1024)
        print(
            f"PASS_COMPRESSED_REF {name}: input_bytes={len(data)} output_bytes={len(encoded)} "
            f"ratio={ratio:.6f} enc_MBps={mbps:.2f}"
        )
        compressed_passed += 1

    print(f"functional_pass={passed}/{len(cases)}")
    print(f"compressed_reference_pass={compressed_passed}/{len(cases)}")
    print("compressed_lzma2_cmodel_status=PYTHON_LZMA_REFERENCE_PASS_STANDALONE_C_PENDING")


if __name__ == "__main__":
    main()
