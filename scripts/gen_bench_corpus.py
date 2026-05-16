#!/usr/bin/env python3
"""Generate deterministic benchmark inputs for the C model gate."""

from __future__ import annotations

import argparse
import json
import random
import struct
from pathlib import Path


SEED = 0x585A_2026


def align(buf: bytearray, boundary: int, fill: int = 0) -> None:
    while len(buf) % boundary:
        buf.append(fill & 0xFF)


def words_to_bytes(words: list[int]) -> bytes:
    return b"".join(struct.pack("<I", w & 0xFFFFFFFF) for w in words)


def prog_a(rng: random.Random) -> bytes:
    buf = bytearray()
    buf += b"\x7fELF\x02\x01\x01\x00" + bytes(8)
    buf += struct.pack("<HHIQQQIHHHHHH", 2, 0xF3, 1, 0x80000000, 64, 0, 0, 64, 56, 5, 64, 6, 5)
    align(buf, 256)

    opcodes = [
        0x00000013, 0x00100093, 0x00208113, 0x00310193,
        0x00418213, 0x00520293, 0x00628313, 0x00730393,
        0x00008067, 0xFE010113, 0x00113C23, 0x00813823,
    ]
    for block in range(384):
        words = []
        for i in range(32):
            base = opcodes[(block + i) % len(opcodes)]
            if i in (7, 19):
                base ^= rng.randrange(0, 1 << 12) << 20
            words.append(base)
        buf += words_to_bytes(words)
        if block % 9 == 0:
            buf += bytes([0x13, 0x00, 0x00, 0x00]) * rng.randrange(2, 10)
    align(buf, 4096, 0)

    constants = [0, 1, 2, 4, 8, 16, 32, 64, 255, 1024, 4096, 0xDEADBEEF]
    for i in range(8192):
        value = constants[(i * 7) % len(constants)]
        if i % 37 == 0:
            value ^= rng.randrange(0, 1 << 16)
        buf += struct.pack("<I", value)
    return bytes(buf)


def prog_b(rng: random.Random) -> bytes:
    buf = bytearray()
    sections = [b".text", b".rodata", b".data", b".bss", b".symtab", b".strtab"]
    for idx, name in enumerate(sections):
        buf += name.ljust(16, b"\x00")
        buf += struct.pack("<IIII", idx, len(buf), 0x1000 + idx * 0x210, 0x100 + idx * 7)
    align(buf, 512)

    templates = [
        b"init_runtime", b"dispatch_kernel", b"copy_tensor", b"matmul_tile",
        b"relu_activation", b"dma_submit", b"flush_cache", b"return_status",
    ]
    for i in range(7000):
        if i % 13 == 0:
            buf += templates[i % len(templates)] + b"\x00"
        elif i % 17 == 0:
            buf += bytes(rng.randrange(0, 256) for _ in range(11))
        else:
            buf += bytes([(i * 31) & 0xFF, (i >> 1) & 0xFF, 0x00, 0x00])
    align(buf, 4096, 0xCC)

    for i in range(22000):
        if i % 64 < 48:
            buf.append((i * 5 + (i >> 4)) & 0xFF)
        else:
            buf.append(rng.randrange(0, 256))
    return bytes(buf)


def npu_a(rng: random.Random) -> bytes:
    buf = bytearray()
    channels = 48
    height = 64
    width = 64
    for c in range(channels):
        bias = rng.randrange(-8, 9)
        for y in range(height):
            for x in range(width):
                tile = ((x // 8) + (y // 8) + c) & 7
                value = 128 + bias + tile * 3 + rng.randrange(-2, 3)
                if (x + y + c) % 29 == 0:
                    value = 128
                buf.append(value & 0xFF)
    return bytes(buf)


def npu_b(rng: random.Random) -> bytes:
    buf = bytearray()
    for tensor in range(18):
        base = rng.randrange(-200, 201)
        for i in range(8192):
            smooth = base + ((i // 64) % 17) - 8
            if i % 31 == 0:
                smooth += rng.randrange(-16, 17)
            if i % 257 == 0:
                smooth = 0
            buf += struct.pack("<h", max(-32768, min(32767, smooth)))
        align(buf, 256)
    return bytes(buf)


def npu_c(rng: random.Random) -> bytes:
    buf = bytearray()
    for block in range(128):
        if block % 4 == 0:
            mask = bytearray()
            for i in range(1024):
                mask.append(0x00 if i % 7 else 0xFF)
            buf += mask
        elif block % 4 == 1:
            for i in range(512):
                scale = 0x3C00 + ((i + block) % 23)  # fp16-like values near 1.0
                buf += struct.pack("<H", scale)
        elif block % 4 == 2:
            pattern = bytes((128 + ((i // 16) % 9) - 4) & 0xFF for i in range(2048))
            buf += pattern
        else:
            buf += bytes(rng.randrange(0, 256) for _ in range(1536))
        align(buf, 128)
    return bytes(buf)


GENERATORS = [
    ("prog_a", "software_program", "ELF/firmware style repeated code and constants", prog_a),
    ("prog_b", "software_program", "compiled package style sections and symbols", prog_b),
    ("npu_a", "npu_intermediate", "int8 activation tensor with tiled locality", npu_a),
    ("npu_b", "npu_intermediate", "int16/fp16-like smooth intermediate parameters", npu_b),
    ("npu_c", "npu_intermediate", "mixed sparse masks, scales, bursts, and noise", npu_c),
]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out-dir", type=Path, default=Path("build/bench_corpus"))
    args = parser.parse_args()

    args.out_dir.mkdir(parents=True, exist_ok=True)
    rng = random.Random(SEED)
    manifest = {"seed": SEED, "files": []}

    for name, category, description, gen in GENERATORS:
        data = gen(rng)
        path = args.out_dir / f"{name}.bin"
        path.write_bytes(data)
        manifest["files"].append(
            {
                "name": name,
                "category": category,
                "description": description,
                "path": str(path),
                "bytes": len(data),
            }
        )
        print(f"{name}: {len(data)} bytes -> {path}")

    manifest_path = args.out_dir / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"manifest: {manifest_path}")


if __name__ == "__main__":
    main()
