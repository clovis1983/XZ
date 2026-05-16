# Microarchitecture Notes

## v0.1 Data Path

The current implementation establishes the codec shell and a standards-compliant
baseline path:

```text
AXI-Stream in
  -> chunk buffer
  -> LZMA2 uncompressed packet writer/parser
  -> XZ container writer/parser
  -> Check/Index/Footer CRC logic
  -> AXI-Stream out
```

The encoder emits:

1. XZ Stream Header.
2. One Block Header with one LZMA2 filter.
3. LZMA2 uncompressed chunks.
4. LZMA2 EOS marker.
5. Block padding and Check.
6. Index and Stream Footer.

The decoder accepts the same subset and rejects unsupported compressed LZMA2
packets instead of producing ambiguous output.

## ASIC Mapping

- `chunk_mem` is the only large v0.1 storage. Map it to an SRAM macro for ASIC.
- CRC32/CRC64 are byte-serial combinational update functions with sequential
  accumulation. They can be unrolled if a wider AXI-Stream packer is added.
- The top level is half-duplex. Encoder/decoder memories and probability RAMs
  should be shared once the range coder lands.

## Planned Compression Engine Insertion

The HC4/range-coder implementation should replace only the LZMA2 payload stage:

```text
chunk buffer
  -> HC4 match finder
  -> FAST/greedy parser
  -> range encoder + probability RAM
  -> LZMA2 compressed chunk writer
```

Required RTL blocks:

- Rolling 2/3/4-byte hash and hash-chain table.
- Dictionary SRAM with wrap-aware compare window.
- Candidate walker bounded by `search_depth`.
- Greedy parser selecting literal, rep match, or normal match.
- Bit-serial range encoder/decoder, one probability decision per cycle.
- Probability RAM initialized from `lc/lp/pb` and state reset events.

## RTL-Friendly C Model Baseline

`cmodel/xz_rtl_model.c` is the current software shape for the compressed RTL
core. It is self-contained and does not call liblzma. The model emits standard
`.xz` streams using:

- local LZMA probability arrays for `is_match`, `is_rep`, literal coders,
  length coders, distance slots, special distances, and alignment bits;
- a bit-serial range encoder with explicit normalize, bit, direct-bit,
  bittree, reverse-bittree, and flush operations;
- an HC4-style hash-chain match finder with runtime `dict_kib`,
  `nice_len`, and `depth` bounds;
- a greedy parser that emits literals or normal matches;
- LZMA2 compressed chunk headers with property reset, plus uncompressed
  fallback when a chunk is incompressible;
- the same XZ Stream/Header/Block/Index/Footer and CRC32/CRC64 code path used
  by the uncompressed C model.

The first RTL coding target should map this model block-for-block. Rep-match
coding and optimum parsing remain deliberate compression-ratio improvements
after this baseline is stable.

## Characterization Defaults

Use these initial sweep points:

| Parameter | Values |
| --- | --- |
| Dictionary | 64 KiB, 256 KiB, 1 MiB |
| `nice_len` | 16, 32, 64 |
| `search_depth` | 4, 8, 16, 32 |
| `lc/lp/pb` | default 3/0/2 plus 4/0/0 for source text |

Benchmark data should include source trees, ELF/firmware images, logs/JSON,
NPU intermediate tensors, NPU weights, random data, and already-compressed data.

## Acceptance Gates

- Encoder output decompresses with XZ Utils/liblzma or Python `lzma`.
- Decoder output matches golden for supported streams and errors clearly on
  unsupported filters/compressed packets.
- Encoder and decoder counters report input bytes, output bytes, and active
  cycles for bit/cycle calculations.
- HC4/range-coder milestone reaches `0.5~1 bit/cycle` on sustained streams
  with no AXI backpressure.
