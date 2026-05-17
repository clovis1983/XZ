#!/usr/bin/env python3
"""Compare area-sensitive RTL C model dictionary choices before RTL coding."""

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


def mbps(byte_count: int, seconds: float) -> float:
    return 0.0 if seconds <= 0 else byte_count / seconds / (1024 * 1024)


def xz_baseline(input_path: Path, output_path: Path) -> tuple[str, float]:
    xz = shutil.which("xz")
    data = input_path.read_bytes()
    start = time.perf_counter()
    if xz:
        encoded = subprocess.check_output([xz, "-9e", "--check=crc32", "-c", str(input_path)])
        tool = "xz -9e --check=crc32"
    else:
        encoded = lzma.compress(
            data,
            format=lzma.FORMAT_XZ,
            check=lzma.CHECK_CRC32,
            preset=9 | lzma.PRESET_EXTREME,
        )
        tool = "python lzma preset=9|EXTREME check=CRC32"
    output_path.write_bytes(encoded)
    elapsed = time.perf_counter() - start
    if lzma.decompress(encoded) != data:
        raise SystemExit(f"xz baseline decode mismatch: {input_path}")
    return tool, elapsed


def rtl_encode(
    rtl_cmodel: Path,
    input_path: Path,
    output_path: Path,
    dict_kib: int,
    args: argparse.Namespace,
) -> float:
    cmd = [
        str(rtl_cmodel),
        "--mode",
        "encode",
        "--check",
        "1",
        "--dict-kib",
        str(dict_kib),
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
        str(args.chunk_size),
        str(input_path),
        str(output_path),
    ]
    start = time.perf_counter()
    run(cmd)
    return time.perf_counter() - start


def rtl_decode(rtl_cmodel: Path, input_path: Path, output_path: Path) -> float:
    start = time.perf_counter()
    run([str(rtl_cmodel), "--mode", "decode", str(input_path), str(output_path)])
    return time.perf_counter() - start


def prob_entries(lc: int, lp: int) -> int:
    literal = 0x300 << (lc + lp)
    fixed = 12 * 16 + 12 * 4 + 12 * 16 + 4 * 64 + (1 << 7) - 14 + 16
    len_probs = 2 * (2 + 16 * 8 + 16 * 8 + 256)
    return literal + fixed + len_probs


def memory_bits(dict_kib: int, lc: int, lp: int) -> dict[str, int]:
    dict_bytes = dict_kib * 1024
    position_width = 16
    hash_entries = 1
    while hash_entries < dict_bytes:
        hash_entries <<= 1
    return {
        "dict_bits": dict_bytes * 8,
        "hc4_prev_bits": dict_bytes * position_width,
        "hc4_head_bits": hash_entries * position_width,
        "prob_bits": prob_entries(lc, lp) * 11,
        "position_width": position_width,
        "hash_entries": hash_entries,
    }


def write_markdown(rows: list[dict[str, str]], path: Path, args: argparse.Namespace) -> None:
    headers = [
        "name",
        "dict_kib",
        "input_bytes",
        "rtl_bytes",
        "xz_bytes",
        "rtl_to_xz",
        "rtl_enc_MBps",
        "rtl_dec_MBps",
        "dict_bits",
        "hc4_prev_bits",
        "hc4_head_bits",
        "prob_bits",
        "total_memory_bits",
    ]
    lines = [
        "# Pre-RTL Dictionary Report",
        "",
        f"- compared_dicts: `{','.join(str(x) + 'KiB' for x in args.dicts)}`",
        f"- fixed_params: `lc={args.lc} lp={args.lp} pb={args.pb} "
        f"nice_len={args.nice_len} depth={args.depth} chunk={args.chunk_size}`",
        "- rtl_address_assumption: `64KiB-capable datapath, 16-bit distance-minus-one/address path`",
        "",
        "| " + " | ".join(headers) + " |",
        "| " + " | ".join(["---"] * len(headers)) + " |",
    ]
    for row in rows:
        lines.append("| " + " | ".join(row[h] for h in headers) + " |")
    path.write_text("\n".join(lines) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, default=Path("build/bench_corpus/manifest.json"))
    parser.add_argument("--rtl-cmodel", type=Path, default=Path("build/cmodel/xz_rtl_model"))
    parser.add_argument("--out-dir", type=Path, default=Path("build/cmodel/reports"))
    parser.add_argument("--dict-kib", default="4,16,64")
    parser.add_argument("--lc", type=int, default=3)
    parser.add_argument("--lp", type=int, default=0)
    parser.add_argument("--pb", type=int, default=2)
    parser.add_argument("--nice-len", type=int, default=64)
    parser.add_argument("--depth", type=int, default=16)
    parser.add_argument("--chunk-size", type=int, default=65536)
    args = parser.parse_args()
    args.dicts = [int(x.strip(), 0) for x in args.dict_kib.split(",") if x.strip()]

    args.out_dir.mkdir(parents=True, exist_ok=True)
    encoded_dir = args.out_dir / "pre_rtl_dict_encoded"
    encoded_dir.mkdir(exist_ok=True)
    manifest = json.loads(args.manifest.read_text())

    rows: list[dict[str, str]] = []
    baseline_sizes: dict[str, int] = {}
    for item in manifest["files"]:
        name = item["name"]
        input_path = Path(item["path"])
        xz_path = encoded_dir / f"{name}.xz_best.xz"
        _tool, _elapsed = xz_baseline(input_path, xz_path)
        baseline_sizes[name] = xz_path.stat().st_size

    for dict_kib in args.dicts:
        mem = memory_bits(dict_kib, args.lc, args.lp)
        total_memory_bits = mem["dict_bits"] + mem["hc4_prev_bits"] + mem["hc4_head_bits"] + mem["prob_bits"]
        for item in manifest["files"]:
            name = item["name"]
            input_path = Path(item["path"])
            input_bytes = input_path.stat().st_size
            rtl_xz = encoded_dir / f"{name}.rtl_dict{dict_kib}.xz"
            rtl_out = encoded_dir / f"{name}.rtl_dict{dict_kib}.bin"
            enc_elapsed = rtl_encode(args.rtl_cmodel, input_path, rtl_xz, dict_kib, args)
            dec_elapsed = rtl_decode(args.rtl_cmodel, rtl_xz, rtl_out)
            if rtl_out.read_bytes() != input_path.read_bytes():
                raise SystemExit(f"rtl decode mismatch: {name} dict={dict_kib}")

            rtl_bytes = rtl_xz.stat().st_size
            xz_bytes = baseline_sizes[name]
            row = {
                "name": name,
                "dict_kib": str(dict_kib),
                "input_bytes": str(input_bytes),
                "rtl_bytes": str(rtl_bytes),
                "xz_bytes": str(xz_bytes),
                "rtl_to_xz": f"{rtl_bytes / xz_bytes:.4f}",
                "rtl_enc_MBps": f"{mbps(input_bytes, enc_elapsed):.2f}",
                "rtl_dec_MBps": f"{mbps(input_bytes, dec_elapsed):.2f}",
                "dict_bits": str(mem["dict_bits"]),
                "hc4_prev_bits": str(mem["hc4_prev_bits"]),
                "hc4_head_bits": str(mem["hc4_head_bits"]),
                "prob_bits": str(mem["prob_bits"]),
                "total_memory_bits": str(total_memory_bits),
            }
            rows.append(row)
            print(
                f"{name} dict={dict_kib}KiB rtl={rtl_bytes} xz={xz_bytes} "
                f"factor={row['rtl_to_xz']} enc={row['rtl_enc_MBps']}MB/s "
                f"dec={row['rtl_dec_MBps']}MB/s mem_bits={total_memory_bits}"
            )

    csv_path = args.out_dir / "pre_rtl_dict_report.csv"
    md_path = args.out_dir / "pre_rtl_dict_report.md"
    with csv_path.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)
    write_markdown(rows, md_path, args)
    print(f"csv: {csv_path}")
    print(f"markdown: {md_path}")


if __name__ == "__main__":
    main()
