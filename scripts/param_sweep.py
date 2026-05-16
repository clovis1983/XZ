#!/usr/bin/env python3
"""Sweep LZMA2 parameters on the generated benchmark corpus.

The default sweep stays in the hardware-friendly design space:
FAST mode + HC4 match finder. BT4/NORMAL can be enabled explicitly as a
compression-ratio upper-bound reference.
"""

from __future__ import annotations

import argparse
import csv
import json
import lzma
import shutil
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Params:
    mode_name: str
    mf_name: str
    dict_kib: int
    lc: int
    lp: int
    pb: int
    nice_len: int
    depth: int

    def label(self) -> str:
        return (
            f"{self.mode_name}_{self.mf_name}_dict{self.dict_kib}KiB_"
            f"lc{self.lc}_lp{self.lp}_pb{self.pb}_nice{self.nice_len}_depth{self.depth}"
        )


def xz_baseline(data: bytes) -> bytes:
    xz = shutil.which("xz")
    if xz:
        proc = subprocess.run(
            [xz, "-9e", "--check=crc32", "-c"],
            input=data,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        )
        return proc.stdout
    return lzma.compress(
        data,
        format=lzma.FORMAT_XZ,
        check=lzma.CHECK_CRC32,
        preset=9 | lzma.PRESET_EXTREME,
    )


def mode_value(name: str) -> int:
    return lzma.MODE_FAST if name == "fast" else lzma.MODE_NORMAL


def mf_value(name: str) -> int:
    return {
        "hc3": lzma.MF_HC3,
        "hc4": lzma.MF_HC4,
        "bt4": lzma.MF_BT4,
    }[name]


def compress_with_params(data: bytes, params: Params) -> bytes:
    filters = [
        {
            "id": lzma.FILTER_LZMA2,
            "dict_size": params.dict_kib * 1024,
            "lc": params.lc,
            "lp": params.lp,
            "pb": params.pb,
            "mode": mode_value(params.mode_name),
            "nice_len": params.nice_len,
            "mf": mf_value(params.mf_name),
            "depth": params.depth,
        }
    ]
    return lzma.compress(data, format=lzma.FORMAT_XZ, check=lzma.CHECK_CRC32, filters=filters)


def parse_int_list(text: str) -> list[int]:
    return [int(x.strip(), 0) for x in text.split(",") if x.strip()]


def build_param_list(args: argparse.Namespace) -> list[Params]:
    lzma_props = [(3, 0, 2), (4, 0, 0), (2, 0, 2)]
    modes = ["fast"]
    mfs = ["hc4"]
    if args.include_upper_bound:
        modes.append("normal")
        mfs.append("bt4")

    params: list[Params] = []
    for mode in modes:
        for mf in mfs:
            if mode == "fast" and mf == "bt4":
                continue
            if mode == "normal" and mf != "bt4":
                continue
            for dict_kib in parse_int_list(args.dict_kib):
                for lc, lp, pb in lzma_props:
                    for nice in parse_int_list(args.nice_len):
                        for depth in parse_int_list(args.depth):
                            if lc + lp <= 4:
                                params.append(Params(mode, mf, dict_kib, lc, lp, pb, nice, depth))
    return params


def mbps(byte_count: int, seconds: float) -> float:
    return 0.0 if seconds <= 0 else byte_count / seconds / (1024 * 1024)


def write_markdown(summary_rows: list[dict[str, str]], path: Path) -> None:
    headers = [
        "rank",
        "label",
        "total_factor",
        "avg_factor",
        "total_bytes",
        "enc_MBps",
        "prog_a",
        "prog_b",
        "npu_a",
        "npu_b",
        "npu_c",
    ]
    lines = [
        "# LZMA2 Parameter Sweep",
        "",
        "| " + " | ".join(headers) + " |",
        "| " + " | ".join(["---"] * len(headers)) + " |",
    ]
    for row in summary_rows:
        lines.append("| " + " | ".join(row[h] for h in headers) + " |")
    path.write_text("\n".join(lines) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, default=Path("build/bench_corpus/manifest.json"))
    parser.add_argument("--out-dir", type=Path, default=Path("build/cmodel/reports"))
    parser.add_argument("--dict-kib", default="64,256,1024")
    parser.add_argument("--nice-len", default="16,32,64")
    parser.add_argument("--depth", default="4,8,16,32")
    parser.add_argument("--top", type=int, default=20)
    parser.add_argument("--include-upper-bound", action="store_true")
    args = parser.parse_args()

    args.out_dir.mkdir(parents=True, exist_ok=True)
    manifest = json.loads(args.manifest.read_text())
    files = [(item["name"], Path(item["path"]).read_bytes()) for item in manifest["files"]]

    baseline_sizes: dict[str, int] = {}
    for name, data in files:
        baseline = xz_baseline(data)
        if lzma.decompress(baseline) != data:
            raise SystemExit(f"baseline decode mismatch: {name}")
        baseline_sizes[name] = len(baseline)

    detail_rows: list[dict[str, str]] = []
    summary: list[tuple[float, int, float, Params, dict[str, float]]] = []
    params_list = build_param_list(args)
    print(f"sweeping {len(params_list)} parameter sets over {len(files)} files")

    for index, params in enumerate(params_list, 1):
        total_bytes = 0
        total_baseline = 0
        total_input = 0
        total_time = 0.0
        factors: dict[str, float] = {}

        for name, data in files:
            start = time.perf_counter()
            encoded = compress_with_params(data, params)
            elapsed = time.perf_counter() - start
            if lzma.decompress(encoded) != data:
                raise SystemExit(f"decode mismatch: {params.label()} {name}")

            size = len(encoded)
            baseline = baseline_sizes[name]
            factor = size / baseline if baseline else 0.0
            factors[name] = factor
            total_bytes += size
            total_baseline += baseline
            total_input += len(data)
            total_time += elapsed

            detail_rows.append(
                {
                    "label": params.label(),
                    "mode": params.mode_name,
                    "mf": params.mf_name,
                    "dict_kib": str(params.dict_kib),
                    "lc": str(params.lc),
                    "lp": str(params.lp),
                    "pb": str(params.pb),
                    "nice_len": str(params.nice_len),
                    "depth": str(params.depth),
                    "file": name,
                    "bytes": str(size),
                    "baseline_bytes": str(baseline),
                    "factor": f"{factor:.6f}",
                    "enc_MBps": f"{mbps(len(data), elapsed):.2f}",
                }
            )

        total_factor = total_bytes / total_baseline if total_baseline else 0.0
        avg_factor = sum(factors.values()) / len(factors)
        enc_rate = mbps(total_input, total_time)
        summary.append((total_factor, total_bytes, enc_rate, params, factors))
        if index % 20 == 0 or index == len(params_list):
            print(f"completed {index}/{len(params_list)}")

    summary.sort(key=lambda item: (item[0], item[1]))
    detail_path = args.out_dir / "param_sweep_detail.csv"
    summary_path = args.out_dir / "param_sweep_summary.csv"
    md_path = args.out_dir / "param_sweep_top.md"

    with detail_path.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=list(detail_rows[0].keys()))
        writer.writeheader()
        writer.writerows(detail_rows)

    summary_rows: list[dict[str, str]] = []
    for rank, (total_factor, total_bytes, enc_rate, params, factors) in enumerate(summary[: args.top], 1):
        row = {
            "rank": str(rank),
            "label": params.label(),
            "total_factor": f"{total_factor:.6f}",
            "avg_factor": f"{sum(factors.values()) / len(factors):.6f}",
            "total_bytes": str(total_bytes),
            "enc_MBps": f"{enc_rate:.2f}",
        }
        for name, _data in files:
            row[name] = f"{factors[name]:.4f}"
        summary_rows.append(row)

    with summary_path.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=list(summary_rows[0].keys()))
        writer.writeheader()
        writer.writerows(summary_rows)
    write_markdown(summary_rows, md_path)

    print(f"detail: {detail_path}")
    print(f"summary: {summary_path}")
    print(f"markdown: {md_path}")
    best = summary_rows[0]
    print(f"best: {best['label']} total_factor={best['total_factor']} enc_MBps={best['enc_MBps']}")


if __name__ == "__main__":
    main()
