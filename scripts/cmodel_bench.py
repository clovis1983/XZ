#!/usr/bin/env python3
"""Benchmark C model output against best-available XZ baseline."""

from __future__ import annotations

import argparse
import csv
import gzip
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


def gzip_version() -> str:
    gz = shutil.which("gzip")
    if not gz:
        return "python gzip module (gzip CLI not found)"
    try:
        completed = subprocess.run([gz, "--version"], check=False, text=True, capture_output=True)
        text = (completed.stdout or completed.stderr).strip().splitlines()
        if text:
            return text[0]
    except Exception:
        return "gzip CLI present but version query failed"
    return "gzip CLI present but version query failed"


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


def gzip_encode(input_path: Path, output_path: Path) -> tuple[str, float]:
    gz = shutil.which("gzip")
    data = input_path.read_bytes()
    start = time.perf_counter()
    if gz:
        encoded = subprocess.check_output([gz, "-9", "-c", str(input_path)])
        output_path.write_bytes(encoded)
        tool = "gzip -9"
    else:
        encoded = gzip.compress(data, compresslevel=9)
        output_path.write_bytes(encoded)
        tool = "python gzip compresslevel=9"
    elapsed = time.perf_counter() - start
    if gzip.decompress(output_path.read_bytes()) != data:
        raise SystemExit(f"gzip decode mismatch: {input_path}")
    return tool, elapsed


def cmodel_encode_uncompressed(
    cmodel: Path,
    input_path: Path,
    output_path: Path,
    chunk_size: int,
    args: argparse.Namespace,
) -> float:
    start = time.perf_counter()
    run(
        [
            str(cmodel),
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
            "--chunk-size",
            str(chunk_size),
            str(input_path),
            str(output_path),
        ]
    )
    elapsed = time.perf_counter() - start
    if lzma.decompress(output_path.read_bytes()) != input_path.read_bytes():
        raise SystemExit(f"cmodel decode mismatch: {input_path}")
    return elapsed


def common_cmodel_args(args: argparse.Namespace) -> list[str]:
    return [
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
    ]


def cmodel_encode_compressed(input_path: Path, output_path: Path, args: argparse.Namespace) -> tuple[str, float]:
    if args.compressed_backend in ("liblzma", "rtl"):
        exe = args.compressed_cmodel if args.compressed_backend == "liblzma" else args.rtl_cmodel
        cmd = [str(exe), *common_cmodel_args(args)]
        if args.compressed_backend == "rtl":
            cmd += ["--chunk-size", str(args.chunk_size)]
        cmd += [str(input_path), str(output_path)]
        start = time.perf_counter()
        run(cmd)
        elapsed = time.perf_counter() - start
        if lzma.decompress(output_path.read_bytes()) != input_path.read_bytes():
            raise SystemExit(f"{args.compressed_backend} cmodel decode mismatch: {input_path}")
        if args.compressed_backend == "liblzma":
            desc = (
                "standalone C liblzma LZMA2 HC4 range "
                f"dict={args.dict_kib}KiB lc={args.lc} lp={args.lp} pb={args.pb} "
                f"nice={args.nice_len} depth={args.depth}"
            )
        else:
            desc = (
                "standalone RTL-friendly C LZMA2 HC4 greedy range "
                f"dict={args.dict_kib}KiB lc={args.lc} lp={args.lp} pb={args.pb} "
                f"nice={args.nice_len} depth={args.depth} chunk={args.chunk_size}"
            )
        return desc, elapsed

    data = input_path.read_bytes()
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
    start = time.perf_counter()
    encoded = lzma.compress(data, format=lzma.FORMAT_XZ, check=lzma.CHECK_CRC32, filters=filters)
    output_path.write_bytes(encoded)
    elapsed = time.perf_counter() - start
    if lzma.decompress(encoded) != data:
        raise SystemExit(f"compressed cmodel proxy decode mismatch: {input_path}")
    desc = (
        "python-lzma LZMA2 HC4 fast "
        f"dict={args.dict_kib}KiB lc={args.lc} lp={args.lp} pb={args.pb} "
        f"nice={args.nice_len} depth={args.depth}"
    )
    return desc, elapsed


def decode_time(path: Path) -> float:
    data = path.read_bytes()
    start = time.perf_counter()
    lzma.decompress(data)
    return time.perf_counter() - start


def gzip_decode_time(path: Path) -> float:
    data = path.read_bytes()
    start = time.perf_counter()
    gzip.decompress(data)
    return time.perf_counter() - start


def mbps(byte_count: int, seconds: float) -> float:
    if seconds <= 0:
        return 0.0
    return byte_count / seconds / (1024 * 1024)


def write_markdown(
    rows: list[dict[str, str]],
    path: Path,
    xz_ver: str,
    is_583: bool,
    gz_ver: str,
    args: argparse.Namespace,
) -> None:
    headers = [
        "name",
        "category",
        "input_bytes",
        "cmodel_bytes",
        "xz_bytes",
        "gzip_bytes",
        "uncompressed_xz_bytes",
        "cmodel_mode",
        "cmodel_to_xz",
        "cmodel_to_gzip",
        "cmodel_enc_MBps",
        "cmodel_dec_MBps",
        "xz_enc_MBps",
        "xz_dec_MBps",
        "gzip_enc_MBps",
        "gzip_dec_MBps",
    ]
    lines = [
        "# C Model Benchmark Report",
        "",
        f"- baseline_version: `{xz_ver}`",
        f"- baseline_is_xz_5_8_3: `{is_583}`",
        f"- gzip_version: `{gz_ver}`",
        "- gzip_reference_params: `gzip -9`",
        "- compressed_mode_note: `backend may be python reference, liblzma reference, or standalone RTL-friendly C model`",
        f"- compressed_backend: `{args.compressed_backend}`",
        "- compressed_reference_params: "
        f"`LZMA2 HC4 fast dict={args.dict_kib}KiB lc={args.lc} lp={args.lp} "
        f"pb={args.pb} nice={args.nice_len} depth={args.depth} check=CRC32`",
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
    parser.add_argument("--compressed-cmodel", type=Path, default=Path("build/cmodel/xz_liblzma_model"))
    parser.add_argument("--rtl-cmodel", type=Path, default=Path("build/cmodel/xz_rtl_model"))
    parser.add_argument("--compressed-backend", choices=["python", "liblzma", "rtl"], default="python")
    parser.add_argument("--out-dir", type=Path, default=Path("build/cmodel/reports"))
    parser.add_argument("--chunk-size", type=int, default=65536)
    parser.add_argument("--mode", choices=["uncompressed", "compressed"], default="uncompressed")
    parser.add_argument("--dict-kib", type=int, default=256)
    parser.add_argument("--lc", type=int, default=4)
    parser.add_argument("--lp", type=int, default=0)
    parser.add_argument("--pb", type=int, default=0)
    parser.add_argument("--nice-len", type=int, default=64)
    parser.add_argument("--depth", type=int, default=16)
    args = parser.parse_args()

    args.out_dir.mkdir(parents=True, exist_ok=True)
    encoded_dir = args.out_dir / "encoded"
    encoded_dir.mkdir(exist_ok=True)

    manifest = json.loads(args.manifest.read_text())
    version, is_583 = xz_version()
    gz_version = gzip_version()
    rows: list[dict[str, str]] = []

    for item in manifest["files"]:
        name = item["name"]
        input_path = Path(item["path"])
        input_bytes = input_path.stat().st_size
        cmodel_xz = encoded_dir / f"{name}.cmodel.xz"
        uncompressed_xz = encoded_dir / f"{name}.uncompressed.xz"
        baseline_xz = encoded_dir / f"{name}.bestxz.xz"
        baseline_gz = encoded_dir / f"{name}.gzip.gz"

        unc_enc = cmodel_encode_uncompressed(args.cmodel, input_path, uncompressed_xz, args.chunk_size, args)
        if args.mode == "compressed":
            cmodel_tool, c_enc = cmodel_encode_compressed(input_path, cmodel_xz, args)
        else:
            cmodel_tool = "standalone C model LZMA2 uncompressed chunks"
            cmodel_xz.write_bytes(uncompressed_xz.read_bytes())
            c_enc = unc_enc
        c_dec = decode_time(cmodel_xz)
        baseline_tool, xz_enc = baseline_encode(input_path, baseline_xz)
        xz_dec = decode_time(baseline_xz)
        gzip_tool, gz_enc = gzip_encode(input_path, baseline_gz)
        gz_dec = gzip_decode_time(baseline_gz)

        c_bytes = cmodel_xz.stat().st_size
        xz_bytes = baseline_xz.stat().st_size
        gz_bytes = baseline_gz.stat().st_size
        xz_factor = c_bytes / xz_bytes if xz_bytes else 0.0
        gz_factor = c_bytes / gz_bytes if gz_bytes else 0.0

        row = {
            "name": name,
            "category": item["category"],
            "input_bytes": str(input_bytes),
            "cmodel_bytes": str(c_bytes),
            "xz_bytes": str(xz_bytes),
            "gzip_bytes": str(gz_bytes),
            "uncompressed_xz_bytes": str(uncompressed_xz.stat().st_size),
            "cmodel_mode": args.mode,
            "cmodel_to_xz": f"{xz_factor:.4f}",
            "cmodel_to_gzip": f"{gz_factor:.4f}",
            "cmodel_enc_MBps": f"{mbps(input_bytes, c_enc):.2f}",
            "cmodel_dec_MBps": f"{mbps(input_bytes, c_dec):.2f}",
            "xz_enc_MBps": f"{mbps(input_bytes, xz_enc):.2f}",
            "xz_dec_MBps": f"{mbps(input_bytes, xz_dec):.2f}",
            "gzip_enc_MBps": f"{mbps(input_bytes, gz_enc):.2f}",
            "gzip_dec_MBps": f"{mbps(input_bytes, gz_dec):.2f}",
            "baseline_tool": baseline_tool,
            "gzip_tool": gzip_tool,
            "cmodel_tool": cmodel_tool,
        }
        rows.append(row)
        print(
            f"{name}: input={input_bytes} cmodel={c_bytes} xz={xz_bytes} gzip={gz_bytes} "
            f"c/xz={xz_factor:.4f} c/gzip={gz_factor:.4f} "
            f"c_enc={row['cmodel_enc_MBps']}MB/s xz_enc={row['xz_enc_MBps']}MB/s "
            f"gzip_enc={row['gzip_enc_MBps']}MB/s"
        )

    csv_path = args.out_dir / "cmodel_bench.csv"
    md_path = args.out_dir / "cmodel_bench.md"
    fieldnames = list(rows[0].keys()) if rows else []
    with csv_path.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)
    write_markdown(rows, md_path, version, is_583, gz_version, args)

    print(f"csv: {csv_path}")
    print(f"markdown: {md_path}")
    print(f"baseline_version: {version}")
    print(f"baseline_is_xz_5_8_3: {is_583}")
    print(f"gzip_version: {gz_version}")


if __name__ == "__main__":
    main()
