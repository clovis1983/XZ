#!/usr/bin/env python3
"""Build and run the RTL smoke test, then verify the generated .xz stream."""

from __future__ import annotations

import lzma
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def run(cmd: list[str]) -> None:
    print("+", " ".join(cmd))
    subprocess.run(cmd, cwd=ROOT, check=True)


def main() -> None:
    tb_dir = ROOT / "tb"
    tb_dir.mkdir(exist_ok=True)

    run(
        [
            "iverilog",
            "-g2012",
            "-s",
            "tb_xz_encoder",
            "-Wall",
            "-o",
            "tb/xz_encoder_smoke.vvp",
            "rtl/xz_codec_pkg.sv",
            "rtl/xz_lzma2_uncompressed_encoder.sv",
            "tb/tb_xz_encoder.sv",
        ]
    )
    run(["vvp", "tb/xz_encoder_smoke.vvp"])

    encoded = (ROOT / "tb/out_hw.xz").read_bytes()
    expected = (ROOT / "tb/out_input.bin").read_bytes()
    decoded = lzma.decompress(encoded)
    if decoded != expected:
        raise SystemExit("RTL encoder .xz output did not round-trip through Python lzma")

    run(
        [
            "iverilog",
            "-g2012",
            "-s",
            "tb_xz_decoder",
            "-Wall",
            "-o",
            "tb/xz_decoder_smoke.vvp",
            "rtl/xz_codec_pkg.sv",
            "rtl/xz_lzma2_uncompressed_decoder.sv",
            "tb/tb_xz_decoder.sv",
        ]
    )
    run(["vvp", "tb/xz_decoder_smoke.vvp"])
    rtl_decoded = (ROOT / "tb/out_decoded.bin").read_bytes()
    if rtl_decoded != expected:
        raise SystemExit("RTL decoder output did not match encoder input")

    run(
        [
            "iverilog",
            "-g2012",
            "-s",
            "xz_codec_top",
            "-P",
            "xz_codec_top.CHUNK_MAX_BYTES=64",
            "-Wall",
            "-o",
            "tb/xz_top_compile.vvp",
            "rtl/xz_codec_pkg.sv",
            "rtl/xz_crc32.sv",
            "rtl/xz_crc64.sv",
            "rtl/xz_codec_mem_top.sv",
            "rtl/xz_range_bit.sv",
            "rtl/xz_lzma2_compressed_core.sv",
            "rtl/xz_lzma2_uncompressed_encoder.sv",
            "rtl/xz_lzma2_uncompressed_decoder.sv",
            "rtl/xz_axi_lite_regs.sv",
            "rtl/xz_codec_top.sv",
        ]
    )

    print(f"smoke ok: encoded={len(encoded)} decoded={len(decoded)}")


if __name__ == "__main__":
    main()
