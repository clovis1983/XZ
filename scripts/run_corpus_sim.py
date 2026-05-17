#!/usr/bin/env python3
"""Run RTL container encode/decode simulation on the benchmark corpus."""

from __future__ import annotations

import argparse
import json
import lzma
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def run(cmd: list[str]) -> None:
    print("+", " ".join(cmd))
    subprocess.run(cmd, cwd=ROOT, check=True)


def build_sims(out_dir: Path) -> tuple[Path, Path]:
    enc_sim = out_dir / "xz_encoder_file.vvp"
    dec_sim = out_dir / "xz_decoder_file.vvp"
    run(
        [
            "iverilog",
            "-g2012",
            "-s",
            "tb_xz_encoder_file",
            "-Wall",
            "-o",
            str(enc_sim),
            "rtl/xz_codec_pkg.sv",
            "rtl/xz_lzma2_uncompressed_encoder.sv",
            "tb/tb_xz_encoder_file.sv",
        ]
    )
    run(
        [
            "iverilog",
            "-g2012",
            "-s",
            "tb_xz_decoder_file",
            "-Wall",
            "-o",
            str(dec_sim),
            "rtl/xz_codec_pkg.sv",
            "rtl/xz_lzma2_uncompressed_decoder.sv",
            "tb/tb_xz_decoder_file.sv",
        ]
    )
    return enc_sim, dec_sim


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, default=Path("build/bench_corpus/manifest.json"))
    parser.add_argument("--out-dir", type=Path, default=Path("build/rtl_corpus"))
    args = parser.parse_args()

    args.out_dir.mkdir(parents=True, exist_ok=True)
    manifest = json.loads(args.manifest.read_text())
    enc_sim, dec_sim = build_sims(args.out_dir)

    for item in manifest["files"]:
        name = item["name"]
        input_path = Path(item["path"])
        xz_path = args.out_dir / f"{name}.rtl.xz"
        decoded_path = args.out_dir / f"{name}.rtl.decoded.bin"

        run(["vvp", str(enc_sim), f"+INPUT={input_path}", f"+OUTPUT={xz_path}"])
        decoded_by_python = lzma.decompress(xz_path.read_bytes())
        if decoded_by_python != input_path.read_bytes():
            raise SystemExit(f"python lzma mismatch after RTL encode: {name}")

        run(["vvp", str(dec_sim), f"+INPUT={xz_path}", f"+OUTPUT={decoded_path}"])
        if decoded_path.read_bytes() != input_path.read_bytes():
            raise SystemExit(f"RTL decode mismatch: {name}")

        print(
            f"CORPUS_SIM_PASS {name} input={input_path.stat().st_size} "
            f"xz={xz_path.stat().st_size}"
        )

    print("CORPUS_SIM_ALL_PASS")


if __name__ == "__main__":
    main()
