# XZ/LZMA2 RTL Codec IP Handoff

## Current Status

Repository: `https://github.com/clovis1983/XZ`

The project is in the transition from compressed decoder core bring-up to
top-level compressed decode integration.

Completed:

- `.xz` container RTL shell with AXI-Stream data plane and AXI-Lite control plane.
- Uncompressed LZMA2 RTL encoder/decoder path, including Stream Header/Footer,
  Block Header, Index, CRC32/CRC64, and smoke tests.
- RTL-friendly C model with compressed LZMA2 encode/decode.
- C model dictionary evaluation for `4/16/64 KiB`.
- Decision: RTL default uses a `4 KiB` memory macro; datapath remains `16 KiB`
  capable.
- Centralized RTL memory shell for dictionary, HC4 head/prev, and probability RAM.
- Initial RTL shared-core units:
  - range bit encode/decode combinational step
  - probability RAM controller
  - memory-top simulation coverage
- Debug-stage corpus simulation using the smallest generated benchmark file.
- Compressed decoder core directed bring-up:
  - probability RAM initialization and updates
  - raw LZMA2 compressed chunk header parsing
  - range decoder init/normalize
  - literal, normal match, short rep, long rep, special distance, direct-bit
    distance error, truncate, bad control, and bad property directed coverage
- Top-level compressed decode selection through `cfg0[19]`, with default
  uncompressed decode behavior unchanged.
- Top-level raw LZMA2 file-driven compressed decode directed target.

Not completed yet:

- Full `.xz` container compressed RTL decoder path.
- Full compressed RTL encoder path.
- HC4 match finder RTL.
- LZMA symbol encoder FSMs.
- Top-level `.xz` compressed stream parser integration.

## Important Files

Core RTL:

- `rtl/xz_codec_top.sv`: current top-level wrapper.
- `rtl/xz_codec_pkg.sv`: constants, CRC helpers, dict id helpers.
- `rtl/xz_codec_mem_top.sv`: centralized memory wrapper.
- `rtl/xz_lzma2_compressed_core.sv`: raw LZMA2 compressed decoder core.
- `rtl/xz_range_bit.sv`: one probability-decision range encode/decode step.
- `rtl/xz_prob_ram_ctrl.sv`: probability RAM init and read-modify-write update.
- `rtl/xz_lzma2_uncompressed_encoder.sv`: working uncompressed LZMA2 encoder.
- `rtl/xz_lzma2_uncompressed_decoder.sv`: working uncompressed LZMA2 decoder.

C models and scripts:

- `cmodel/xz_rtl_model.c`: RTL-friendly compressed C model, encode/decode.
- `scripts/cmodel_func.py`: C model functional gate.
- `scripts/cmodel_bench.py`: C model benchmark vs `xz -9e` and gzip.
- `scripts/pre_rtl_dict_report.py`: dictionary capacity report for `4/16/64 KiB`.
- `scripts/run_corpus_sim.py`: RTL file-driven corpus simulation.
- `scripts/gen_bench_corpus.py`: deterministic five-file benchmark corpus.

Testbenches:

- `tb/tb_lzma_core_units.sv`: range/prob/memory unit tests.
- `tb/tb_xz_encoder.sv`, `tb/tb_xz_decoder.sv`: smoke tests.
- `tb/tb_xz_encoder_file.sv`, `tb/tb_xz_decoder_file.sv`: file-driven corpus tests.

## Configuration Decisions

Dictionary:

- C model supports `--dict-kib 4`, `16`, `64`, `256`, `1024`.
- RTL baseline uses:
  - `dict_size_id=0`: 4 KiB, LZMA2 dict property `0`
  - `dict_size_id=1`: 16 KiB, LZMA2 dict property `4`
  - `dict_size_id=2/3`: 16 KiB aliases
- RTL default reset uses `dict_size_id=0`.
- RTL datapath should keep 14-bit dictionary addressing so it can support 16 KiB.
- 4 KiB macro mode uses low 12 address bits through `dict_mask=16'h0FFF`.

Default compression parameters:

```text
dict = 4 KiB for RTL default
lc/lp/pb = 3/0/2
nice_len = 64
depth = 16
check = CRC32
chunk_size = 65536
```

Latest pre-RTL dictionary totals:

```text
4 KiB:  total rtl/xz factor = 1.106760, estimated memory bits = 251730
16 KiB: total rtl/xz factor = 1.087041, estimated memory bits = 743250
64 KiB: total rtl/xz factor = 1.090219, estimated memory bits = 2709330
```

## Commands

Fast RTL shared-core unit test:

```sh
make rtl-core-units
```

Compressed core directed test:

```sh
make rtl-compressed-core
```

Top-level raw LZMA2 compressed directed test:

```sh
make rtl-compressed-top
```

Debug-stage corpus simulation, currently only the smallest generated benchmark
file:

```sh
make corpus-sim
```

Full five-file corpus simulation:

```sh
make corpus-sim-all
```

Existing RTL smoke:

```sh
make smoke
```

C model gate with RTL-friendly compressed backend:

```sh
make cmodel-gate-rtl
```

Dictionary report:

```sh
make pre-rtl-dict-report
```

Expected local verification state at handoff:

```text
make rtl-core-units  PASS
make rtl-compressed-core PASS
make rtl-compressed-top  PASS
make corpus-sim      PASS, runs prog_b only
make smoke           PASS
make cmodel-gate-rtl PASS
```

## Current Simulation Boundary

`make corpus-sim` and `make corpus-sim-all` currently exercise the working
uncompressed RTL container path on generated corpus files. This is intentional
for debug-stage regression speed and container stability.

`make corpus-sim` and `make corpus-sim-all` do not yet exercise the compressed
decoder path. Use `make rtl-compressed-core` and `make rtl-compressed-top` for
compressed decoder directed coverage.

`xz_lzma2_compressed_core.sv` currently accepts raw LZMA2 compressed chunks, not
a full `.xz` container stream. In `xz_codec_top`, set `cfg0[19]` with decode mode
to route AXI-Stream input to the compressed core. Leave `cfg0[19]` clear for the
existing uncompressed `.xz` decoder path.

## Recommended Next Steps

1. Extend top-level compressed decode from raw LZMA2 chunks to `.xz` Block
   parsing, CRC/check verification, Index/Footer, and final stream accounting.
2. Add broader file-driven compressed decoder cases once `.xz` container support
   exists.
3. Add remaining compressed decoder stress cases:
   - rep1/rep2/rep3 rotation
   - dictionary wrap
   - large direct distances that remain valid
   - multi-chunk property reset/state retention
4. Only after decoder works, start encoder path:
   - range encoder byte output FSM
   - literal encode
   - HC4 match finder
   - rep/normal match parser
   - incompressible fallback

## Notes For New Conversation

- Do not commit `ref_code/`; it is intentionally ignored and should stay local.
- The local machine does not have synthesis tools; focus on Icarus/VVP simulation.
- For debug speed, use `make corpus-sim`; use `make corpus-sim-all` only when a
  broader regression is needed.
- Existing Icarus warnings about constant selects and `unique case` are known
  and currently non-fatal.
- The user wants module boundaries to stay clean and all large memories under a
  top-level memory wrapper for MBIST and hard macro replacement.
