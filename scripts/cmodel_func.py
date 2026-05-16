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

    print(f"functional_pass={passed}/{len(cases)}")
    print("compressed_lzma2_cmodel_status=PENDING_RANGE_CODER_HC4")


if __name__ == "__main__":
    main()
