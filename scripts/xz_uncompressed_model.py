#!/usr/bin/env python3
"""Small golden model for the v0.1 RTL XZ/LZMA2 uncompressed path."""

from __future__ import annotations

import argparse
import binascii
import lzma
from pathlib import Path

CHECK_NONE = 0
CHECK_CRC32 = 1
CHECK_CRC64 = 4

CRC64_POLY = 0xC96C5795D7870F42


def crc32(data: bytes) -> int:
    return binascii.crc32(data) & 0xFFFFFFFF


def crc64_xz(data: bytes) -> int:
    crc = 0xFFFFFFFFFFFFFFFF
    for byte in data:
        crc ^= byte
        for _ in range(8):
            if crc & 1:
                crc = (crc >> 1) ^ CRC64_POLY
            else:
                crc >>= 1
            crc &= 0xFFFFFFFFFFFFFFFF
    return crc ^ 0xFFFFFFFFFFFFFFFF


def le32(value: int) -> bytes:
    return value.to_bytes(4, "little")


def le64(value: int) -> bytes:
    return value.to_bytes(8, "little")


def encode_vli(value: int) -> bytes:
    out = bytearray()
    while value >= 0x80:
        out.append((value & 0x7F) | 0x80)
        value >>= 7
    out.append(value)
    return bytes(out)


def check_bytes(data: bytes, check_type: int) -> bytes:
    if check_type == CHECK_NONE:
        return b""
    if check_type == CHECK_CRC32:
        return le32(crc32(data))
    if check_type == CHECK_CRC64:
        return le64(crc64_xz(data))
    raise ValueError(f"unsupported check type {check_type}")


def lzma2_uncompressed(data: bytes, chunk_size: int = 65536) -> bytes:
    if not 1 <= chunk_size <= 65536:
        raise ValueError("chunk_size must be in [1, 65536]")

    out = bytearray()
    pos = 0
    first = True
    while pos < len(data):
        chunk = data[pos : pos + chunk_size]
        size_minus_one = len(chunk) - 1
        out.append(0x01 if first else 0x02)
        out.extend(size_minus_one.to_bytes(2, "big"))
        out.extend(chunk)
        first = False
        pos += len(chunk)
    out.append(0x00)
    return bytes(out)


def build_xz(data: bytes, check_type: int = CHECK_CRC32, dict_prop: int = 12, chunk_size: int = 65536) -> bytes:
    stream_flags = bytes([0x00, check_type])
    stream_header = b"\xFD7zXZ\x00" + stream_flags + le32(crc32(stream_flags))

    block_prefix = bytes([0x02, 0x00, 0x21, 0x01, dict_prop, 0x00, 0x00, 0x00])
    block_header = block_prefix + le32(crc32(block_prefix))

    compressed = lzma2_uncompressed(data, chunk_size)
    padding = b"\x00" * ((4 - ((len(block_header) + len(compressed)) & 3)) & 3)
    check = check_bytes(data, check_type)

    unpadded_size = len(block_header) + len(compressed) + len(check)
    index_body = b"\x00" + encode_vli(1) + encode_vli(unpadded_size) + encode_vli(len(data))
    index_padding = b"\x00" * ((4 - (len(index_body) & 3)) & 3)
    index_without_crc = index_body + index_padding
    index = index_without_crc + le32(crc32(index_without_crc))

    backward_size = len(index) // 4 - 1
    footer_fields = le32(backward_size) + stream_flags
    stream_footer = le32(crc32(footer_fields)) + footer_fields + b"YZ"

    return stream_header + block_header + compressed + padding + check + index + stream_footer


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--check", type=int, default=CHECK_CRC32, choices=[CHECK_NONE, CHECK_CRC32, CHECK_CRC64])
    parser.add_argument("--dict-prop", type=int, default=12)
    parser.add_argument("--chunk-size", type=int, default=65536)
    parser.add_argument("--verify", action="store_true")
    args = parser.parse_args()

    data = args.input.read_bytes()
    encoded = build_xz(data, args.check, args.dict_prop, args.chunk_size)
    args.output.write_bytes(encoded)

    if args.verify:
        decoded = lzma.decompress(encoded)
        if decoded != data:
            raise SystemExit("verification failed")

    print(f"wrote {args.output} input={len(data)} output={len(encoded)}")


if __name__ == "__main__":
    main()
