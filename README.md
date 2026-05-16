# XZ/LZMA2 RTL Codec IP

ASIC-oriented XZ/LZMA2 codec IP scaffold with AXI-Stream data ports and an
AXI-Lite control/status plane.

## Current v0.1 Scope

Implemented now:

- Standard `.xz` container encoder for a single Stream and one LZMA2 Block.
- LZMA2 uncompressed-chunk encoder path (`0x01/0x02` chunks plus `0x00` EOS).
- Decoder for the same LZMA2 uncompressed subset, with explicit errors for
  compressed LZMA2 chunks and unsupported filters.
- Check support for None, CRC32, and CRC64.
- AXI-Lite register shell and half-duplex top-level mux.
- Smoke test proving RTL encoder output round-trips through Python `lzma`.

Not implemented yet:

- HC4 match finder.
- FAST/greedy parser.
- LZMA range encoder/decoder and probability RAM.
- Real compression ratio characterization.
- Full common `.xz` decode coverage for compressed LZMA2 streams.

The v0.1 path is intentionally useful: it creates valid `.xz` files and fixes
the integration contract before the compression engine is inserted.

## Layout

- `rtl/xz_codec_top.sv`: top-level IP wrapper.
- `rtl/xz_axi_lite_regs.sv`: control/status registers.
- `rtl/xz_lzma2_uncompressed_encoder.sv`: `.xz` + LZMA2 uncompressed encoder.
- `rtl/xz_lzma2_uncompressed_decoder.sv`: matching decoder subset.
- `rtl/xz_codec_pkg.sv`: constants, CRC helpers, VLI helpers.
- `tb/tb_xz_encoder.sv`: encoder smoke testbench.
- `scripts/run_smoke.py`: compile/simulate/round-trip check.
- `scripts/xz_uncompressed_model.py`: Python golden model for this subset.
- `docs/REGISTER_MAP.md`: AXI-Lite map.
- `docs/MICROARCHITECTURE.md`: implementation notes and next steps.

## Quick Start

```sh
python3 scripts/run_smoke.py
```

Expected final line:

```text
smoke ok: encoded=<n> decoded=<n>
```

You can also generate a model `.xz` stream:

```sh
python3 scripts/xz_uncompressed_model.py input.bin output.xz --verify
```

## C Model and Compression Ratio

The RTL-equivalent C model is:

```sh
make cmodel
build/cmodel/xz_uncompressed_model input.bin output.xz
```

The standalone C model CLI accepts the same knobs intended for the compressed
core:

```sh
build/cmodel/xz_uncompressed_model \
  --dict-kib 64 \
  --lc 3 --lp 0 --pb 2 \
  --nice-len 64 \
  --depth 16 \
  --check 1 \
  input.bin output.xz
```

In the current standalone C model these knobs are validated, reported, and used
for LZMA2 dictionary-property emission; `nice_len` and `depth` are wired into the
configuration interface for the upcoming HC4/range-coder implementation.

There is also a liblzma-backed compressed C model:

```sh
make cmodel-liblzma
build/cmodel/xz_liblzma_model \
  --dict-kib 64 \
  --lc 3 --lp 0 --pb 2 \
  --nice-len 64 \
  --depth 16 \
  input.bin output.xz
```

This path calls real liblzma LZMA2 encoding with `LZMA_MF_HC4` and
`LZMA_MODE_FAST`, so it exercises the upstream HC4/range-coder algorithm through
the same local C model configuration interface. By default it includes headers
from `ref_code/xz/src/liblzma/api` and links with `-llzma`; override
`LZMA_CFLAGS` and `LZMA_LIBS` if you build liblzma from `ref_code`.

The standalone RTL-friendly compressed C model is:

```sh
make cmodel-rtl
build/cmodel/xz_rtl_model \
  --dict-kib 64 \
  --lc 3 --lp 0 --pb 2 \
  --nice-len 64 \
  --depth 16 \
  input.bin output.xz
```

This model doesn't link against liblzma. It contains a local probability RAM,
bit-serial range encoder, literal path, normal-match path, HC4-style hash-chain
match finder, greedy parser, LZMA2 chunk packetizer, incompressible fallback,
and `.xz` container/check generation. It intentionally omits rep-match and
optimum parsing for now, so it is the first RTL mapping baseline rather than a
compression-ratio upper bound. The current compressed range path is enabled
for the default `pb=2` setting; `--disable-matches` remains available for
literal-path isolation when debugging.

It prints:

```text
input_bytes=<n> output_bytes=<n> ratio=<output/input> overhead_bytes=<n>
```

For a quick round-trip check against Python `lzma`:

```sh
make smoke
make cmodel-test
```

To measure the v0.1 RTL-equivalent ratio on your own file:

```sh
make ratio INPUT=/path/to/sample.bin
```

Important: v0.1 uses LZMA2 uncompressed chunks, so ratio is expected to be
larger than 1.0 except for unusual corner cases. This measures container/chunk
overhead and model/RTL alignment, not real HC4/range-coder compression.

## C Model Gate and Benchmark Corpus

The next-stage gate runs functionality before any performance reporting:

```sh
make cmodel-func
make bench-corpus
make cmodel-bench
```

or as one command:

```sh
make cmodel-gate
```

To compare the hardware-target compressed parameter set against the best XZ
baseline:

```sh
make cmodel-gate CMODEL_MODE=compressed
```

The same Python `lzma` compressed reference path is also available through an
explicit target:

```sh
make cmodel-gate-python
```

To force the compressed side to use the liblzma-backed C binary instead of the
Python reference:

```sh
make cmodel-gate-liblzma
```

To run the standalone RTL-friendly C model gate:

```sh
make cmodel-gate-rtl
```

Compressed mode defaults to Python `lzma` with an explicit LZMA2 filter that
matches the intended hardware subset: HC4, fast mode, configurable dictionary,
`lc/lp/pb`, `nice_len`, and `depth`. `make cmodel-gate-liblzma` switches that
path to the standalone C binary backed by liblzma, so the functional cases and
five-file benchmark both exercise a C executable using real HC4/range coding.
`make cmodel-gate-rtl` instead uses the self-contained RTL-friendly encoder.
All three compressed backends are driven from the same Makefile knobs:
`CMODEL_DICT_KIB`, `CMODEL_LC`, `CMODEL_LP`, `CMODEL_PB`,
`CMODEL_NICE_LEN`, and `CMODEL_DEPTH`; the RTL backend also receives
`CMODEL_CHUNK_SIZE` explicitly.

Parameter sweeps can be run on the same five-file corpus:

```sh
make param-sweep
```

The default sweep stays in the hardware-friendly space:

```text
mode=FAST, mf=HC4
dict=64/256/1024 KiB
lc/lp/pb=(3/0/2), (4/0/0), (2/0/2)
nice_len=16/32/64
depth=4/8/16/32
```

Results are written to:

```text
build/cmodel/reports/param_sweep_detail.csv
build/cmodel/reports/param_sweep_summary.csv
build/cmodel/reports/param_sweep_top.md
```

`make param-sweep-upper` additionally includes BT4/NORMAL as a compression-ratio
upper-bound reference; that setting is not the first RTL target.

`bench-corpus` deterministically generates five benchmark binaries:

- two software-program style files (`prog_a.bin`, `prog_b.bin`)
- three NPU intermediate-parameter style files (`npu_a.bin`, `npu_b.bin`, `npu_c.bin`)

Benchmark reports are written to:

```text
build/cmodel/reports/cmodel_bench.csv
build/cmodel/reports/cmodel_bench.md
```

The report compares the current C model output against `xz -9e --check=crc32`
when an `xz` CLI is available. If `xz` is not installed, it falls back to Python
`lzma` with `preset=9|PRESET_EXTREME` and marks the baseline as non-final. It
also reports a `gzip -9` reference with size and encode/decode throughput, plus
`cmodel_to_gzip` for quick comparison against a DEFLATE baseline.

## VCS and DC

Commercial-tool targets are included for validation on another machine:

```sh
make vcs
make vcs-run
```

`make vcs` compiles the encoder TB, decoder TB, and top-level syntax target.
`make vcs-run` runs the encoder first so `tb/out_hw.xz` exists, then runs the
decoder.

For Design Compiler:

```sh
make dc \
  DC_TARGET_LIBRARY=/path/to/typical.db \
  DC_LINK_LIBRARY="/path/to/typical.db" \
  DC_CLOCK_PERIOD_NS=2.0 \
  DC_CHUNK_MAX_BYTES=64
```

Reports and mapped outputs are written under `build/dc/`. Keep
`DC_CHUNK_MAX_BYTES` small for first generic synthesis because v0.1 still models
the chunk buffer as RTL storage; replace it with an SRAM macro before full-size
`65536` synthesis.

## Integration Notes

- Data width is 8-bit AXI-Stream in v0.1. The internal container/range-coder
  boundary is byte-oriented, so widening should be added with ingress/egress
  packers rather than touching codec state machines.
- `CHUNK_MAX_BYTES` defaults to 65536, matching the LZMA2 uncompressed chunk
  maximum. For simulation, override it to a smaller value.
- The encoder chunk buffer is modeled as a register array. ASIC integration
  should map this storage to a synchronous SRAM macro or replace it with a
  two-pass/chunk-size prefetch path.
