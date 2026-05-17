#!/usr/bin/env python3
"""Generate tiny raw LZMA2 and .xz directed streams for RTL decoder tests."""

from __future__ import annotations

import binascii
from pathlib import Path


def crc32(data: bytes) -> int:
    return binascii.crc32(data) & 0xFFFFFFFF


def le32(value: int) -> bytes:
    return value.to_bytes(4, "little")


def vli(value: int) -> bytes:
    out = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        if value:
            out.append(byte | 0x80)
        else:
            out.append(byte)
            return bytes(out)


def stream_header(check_type: int = 1) -> bytes:
    flags = bytes([0x00, check_type])
    return bytes.fromhex("fd 37 7a 58 5a 00") + flags + le32(crc32(flags))


def block_header(dict_prop: int = 0) -> bytes:
    body = bytes([0x02, 0x00, 0x21, 0x01, dict_prop & 0x3F, 0x00, 0x00, 0x00])
    return body + le32(crc32(body))


def stream_footer(index_size: int, check_type: int = 1) -> bytes:
    backward_size = (index_size // 4) - 1
    flags = bytes([0x00, check_type])
    body = le32(backward_size) + flags
    return le32(crc32(body)) + body + bytes([0x59, 0x5A])


def xz_stream(lzma2_payload: bytes, decoded: bytes, *, corrupt_check=False,
              corrupt_padding=False, truncate=False) -> bytes:
    block = bytearray()
    block += block_header()
    block += lzma2_payload
    block += b"\x00"
    while len(block) % 4:
        block.append(0x01 if corrupt_padding and len(block) % 4 == 3 else 0x00)

    check = bytearray(le32(crc32(decoded)))
    if corrupt_check:
        check[0] ^= 0x01
    block += check

    unpadded_size = len(block_header()) + len(lzma2_payload) + 1 + 4
    index_body = bytes([0x00]) + vli(1) + vli(unpadded_size) + vli(len(decoded))
    while len(index_body) % 4:
        index_body += b"\x00"
    index = index_body + le32(crc32(index_body))

    data = stream_header() + bytes(block) + index + stream_footer(len(index))
    return data[:-3] if truncate else data


def main() -> None:
    out_dir = Path("build/compressed_directed")
    out_dir.mkdir(parents=True, exist_ok=True)

    # Raw LZMA2 compressed chunk:
    #   header: reset props, unpacked_len=4, compressed_len=8, prop=0x5d
    #   payload: range-coded literals A/B followed by a normal match dist=2 len=2
    abab = bytes.fromhex("e0 00 03 00 07 5d 00 20 90 9c 04 00 00 00")
    (out_dir / "raw_lzma2_abab.bin").write_bytes(abab)
    (out_dir / "raw_lzma2_abab.expected.bin").write_bytes(b"ABAB")
    (out_dir / "xz_lzma2_abab.xz").write_bytes(xz_stream(abab, b"ABAB"))

    # RTL-friendly C-model style chunk for a longer literal/match mix:
    #   decoded: ABABABABABABABAB
    #   symbols: A, B, then a length-14 match at distance 2
    abab16 = bytes.fromhex("e0 00 0f 00 07 5d 00 20 90 a6 02 00 00 00")
    (out_dir / "raw_lzma2_abab16_rtl.bin").write_bytes(abab16)
    (out_dir / "raw_lzma2_abab16_rtl.expected.bin").write_bytes(b"ABABABABABABABAB")
    (out_dir / "xz_lzma2_abab16_rtl.xz").write_bytes(
        xz_stream(abab16, b"ABABABABABABABAB")
    )

    (out_dir / "xz_lzma2_bad_crc.xz").write_bytes(
        xz_stream(abab, b"ABAB", corrupt_check=True)
    )
    (out_dir / "xz_lzma2_bad_padding.xz").write_bytes(
        xz_stream(abab, b"ABAB", corrupt_padding=True)
    )
    (out_dir / "xz_lzma2_truncated.xz").write_bytes(
        xz_stream(abab, b"ABAB", truncate=True)
    )

    # Same container shape with an invalid property byte; expected to terminate
    # with XZ_ERR_CONFIG after header parsing and before payload consumption.
    bad_prop = bytes.fromhex("e0 00 00 00 04 ff 00 00 00 00 00")
    (out_dir / "raw_lzma2_bad_prop.bin").write_bytes(bad_prop)

    print(f"compressed directed fixtures: {out_dir}")


if __name__ == "__main__":
    main()
