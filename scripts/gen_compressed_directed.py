#!/usr/bin/env python3
"""Generate tiny raw LZMA2 directed streams for RTL compressed decoder tests."""

from __future__ import annotations

from pathlib import Path


def main() -> None:
    out_dir = Path("build/compressed_directed")
    out_dir.mkdir(parents=True, exist_ok=True)

    # Raw LZMA2 compressed chunk:
    #   header: reset props, unpacked_len=4, compressed_len=8, prop=0x5d
    #   payload: range-coded literals A/B followed by a normal match dist=2 len=2
    abab = bytes.fromhex("e0 00 03 00 07 5d 00 20 90 9c 04 00 00 00")
    (out_dir / "raw_lzma2_abab.bin").write_bytes(abab)
    (out_dir / "raw_lzma2_abab.expected.bin").write_bytes(b"ABAB")

    # Same container shape with an invalid property byte; expected to terminate
    # with XZ_ERR_CONFIG after header parsing and before payload consumption.
    bad_prop = bytes.fromhex("e0 00 00 00 04 ff 00 00 00 00 00")
    (out_dir / "raw_lzma2_bad_prop.bin").write_bytes(bad_prop)

    print(f"compressed directed fixtures: {out_dir}")


if __name__ == "__main__":
    main()
