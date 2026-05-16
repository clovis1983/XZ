#!/usr/bin/env python3
"""Benchmark C model output against best-available XZ baseline."""

from __future__ import annotations

import argparse
import csv
import json
import lzma
import shutil
import subprocess
import time
from pathlib import Path


def run(cmd: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, check=True, text=True, capture_output=True)


def xz_version() -> tuple[str, bool]:
    xz = shutil.which("xz")
    if not xz:
        return "python-lzma preset=9|EXTREME (xz CLI not found)", False
    try:
        out = run([xz, "--version"]).stdout.strip().replace("\n", " | ")
    except Exception:
        return "xz CLI present but version query failed", False
    return out, "5.8.3" in out


def baseline_encode(input_path: Path, output_path: Path) -> tuple[str, float]:
    xz = shutil.which("xz")
    data = input_path.read_bytes()
    start = time.perf_counter()
    if xz:
        encoded = subprocess.check_output([xz, "-9e", "--check=crc32", "-c", str(input_path)])
        output_path.write_bytes(encoded)
        tool = "xz -9e --check=crc32"
    else:
        encoded = lzma.compress(
            data,
            format=lzma.FORMAT_XZ,
            check=lzma.CHECK_CRC32,
            preset=9 | lzma.PRESET_EXTREME,
        )
        output_path.write_bytes(encoded)
        tool = "python lzma preset=9|EXTREME check=CRC32"
    elapsed = time.perf_counter() - start
    if lzma.decompress(output_path.read_bytes()) != data:
        raise SystemExit(f"baseline decode mismatch: {input_path}")
    return tool, elapsed


def cmodel_encode_uncompressed(cmodel: Path, input_path: Path, output_path: Path, chunk_size: int) -> float:
    start = time.perf_counter()
    run([str(cmodel), "--check", "1", "--chunk-size", str(chunk_size), str(input_path), str(output_path)])
    elapsed = time.perf_counter() - start
    if lzma.decompress(output_path.read_bytes()) != input_path.read_bytes():
        raise SystemExit(f"cmodel decode mismatch: {input_path}")
    return elapsed


def cmodel_encode_compressed(input_path: Path, output_path: Path) -> tuple[str, float]:
    data = input_path.read_bytes()
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
    start = time.perf_counter()
    encoded = lzma.compress(data, format=lzma.FORMAT_XZ, check=lzma.CHECK_CRC32, filters=filters)
    output_path.write_bytes(encoded)
    elapsed = time.perf_counter() - start
    if lzma.decompress(encoded) != data:
        raise SystemExit(f"compressed cmodel proxy decode mismatch: {input_path}")
    desc = "python-lzma LZMA2 HC4 fast dict=256KiB lc=3 lp=0 pb=2 nice=32 depth=16"
    return desc, elapsed


def decode_time(path: Path) -> float:
    data = path.read_bytes()
    start = time.perf_counter()
    lzma.decompress(data)
    return time.perf_counter() - start


def mbps(byte_count: int, seconds: float) -> float:
    if seconds <= 0:
        return 0.0
    return byte_count / seconds / (1024 * 1024)


def write_markdown(rows: list[dict[str, str]], path: Path, xz_ver: str, is_583: bool) -> None:
    headers = [
        "name",
        "category",
        "input_bytes",
        "cmodel_bytes",
        "xz_bytes",
        "uncompressed_xz_bytes",
        "cmodel_mode",
        "cmodel_to_xz",
        "cmodel_enc_MBps",
        "cmodel_dec_MBps",
        "xz_enc_MBps",
        "xz_dec_MBps",
    ]
    lines = [
        "# C Model Benchmark Report",
        "",
        f"- baseline_version: `{xz_ver}`",
        f"- baseline_is_xz_5_8_3: `{is_583}`",
        "- compressed_mode_note: `python-lzma custom LZMA2 is used as the compressed reference until the standalone C range-coder/HC4 model lands`",
        "- compressed_reference_params: `LZMA2 HC4 fast dict=256KiB lc=3 lp=0 pb=2 nice=32 depth=16 check=CRC32`",
        "",
        "| " + " | ".join(headers) + " |",
        "| " + " | ".join(["---"] * len(headers)) + " |",
    ]
    for row in rows:
        lines.append("| " + " | ".join(str(row[h]) for h in headers) + " |")
    path.write_text("\n".join(lines) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, default=Path("build/bench_corpus/manifest.json"))
    parser.add_argument("--cmodel", type=Path, default=Path("build/cmodel/xz_uncompressed_model"))
    parser.add_argument("--out-dir", type=Path, default=Path("build/cmodel/reports"))
    parser.add_argument("--chunk-size", type=int, default=65536)
    parser.add_argument("--mode", choices=["uncompressed", "compressed"], default="uncompressed")
    args = parser.parse_args()

    args.out_dir.mkdir(parents=True, exist_ok=True)
    encoded_dir = args.out_dir / "encoded"
    encoded_dir.mkdir(exist_ok=True)

    manifest = json.loads(args.manifest.read_text())
    version, is_583 = xz_version()
    rows: list[dict[str, str]] = []

    for item in manifest["files"]:
        name = item["name"]
        input_path = Path(item["path"])
        input_bytes = input_path.stat().st_size
        cmodel_xz = encoded_dir / f"{name}.cmodel.xz"
        uncompressed_xz = encoded_dir / f"{name}.uncompressed.xz"
        baseline_xz = encoded_dir / f"{name}.bestxz.xz"

        unc_enc = cmodel_encode_uncompressed(args.cmodel, input_path, uncompressed_xz, args.chunk_size)
        if args.mode == "compressed":
            cmodel_tool, c_enc = cmodel_encode_compressed(input_path, cmodel_xz)
        else:
            cmodel_tool = "standalone C model LZMA2 uncompressed chunks"
            cmodel_xz.write_bytes(uncompressed_xz.read_bytes())
            c_enc = unc_enc
        c_dec = decode_time(cmodel_xz)
        baseline_tool, xz_enc = baseline_encode(input_path, baseline_xz)
        xz_dec = decode_time(baseline_xz)

        c_bytes = cmodel_xz.stat().st_size
        xz_bytes = baseline_xz.stat().st_size
        factor = c_bytes / xz_bytes if xz_bytes else 0.0

        row = {
            "name": name,
            "category": item["category"],
            "input_bytes": str(input_bytes),
            "cmodel_bytes": str(c_bytes),
            "xz_bytes": str(xz_bytes),
            "uncompressed_xz_bytes": str(uncompressed_xz.stat().st_size),
            "cmodel_mode": args.mode,
            "cmodel_to_xz": f"{factor:.4f}",
            "cmodel_enc_MBps": f"{mbps(input_bytes, c_enc):.2f}",
            "cmodel_dec_MBps": f"{mbps(input_bytes, c_dec):.2f}",
            "xz_enc_MBps": f"{mbps(input_bytes, xz_enc):.2f}",
            "xz_dec_MBps": f"{mbps(input_bytes, xz_dec):.2f}",
            "baseline_tool": baseline_tool,
            "cmodel_tool": cmodel_tool,
        }
        rows.append(row)
        print(
            f"{name}: input={input_bytes} cmodel={c_bytes} xz={xz_bytes} "
            f"factor={factor:.4f} c_enc={row['cmodel_enc_MBps']}MB/s "
            f"xz_enc={row['xz_enc_MBps']}MB/s"
        )

    csv_path = args.out_dir / "cmodel_bench.csv"
    md_path = args.out_dir / "cmodel_bench.md"
    fieldnames = list(rows[0].keys()) if rows else []
    with csv_path.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)
    write_markdown(rows, md_path, version, is_583)

    print(f"csv: {csv_path}")
    print(f"markdown: {md_path}")
    print(f"baseline_version: {version}")
    print(f"baseline_is_xz_5_8_3: {is_583}")


if __name__ == "__main__":
    main()
