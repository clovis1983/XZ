# XZ/LZMA2 RTL Design Specification

## 1. Design Goal and Current Scope

This project implements an XZ/LZMA2 codec RTL IP with AXI-Stream data ports and
an AXI-Lite control/status plane. The current RTL has two functional decode
paths:

- Uncompressed `.xz` container encoder/decoder path.
- Early compressed `.xz` decoder path for directed bring-up.

The design is simulation-first at this stage. Icarus/VVP functional pass is the
main gate; synthesis/DC/VCS are not assumed to be available locally.

Current compressed decode support is intentionally limited but real:

- `xz_lzma2_compressed_core` decodes raw LZMA2 compressed chunks.
- `xz_lzma2_compressed_decoder` wraps that core with a minimal `.xz` container
  parser/checker.
- `xz_codec_top` selects the compressed `.xz` decoder when decode mode is set
  and `cfg0[19]` is `1`.

Broader compressed decoder stress coverage and the compressed encoder/HC4 path
are still future work.

## 2. Top-Level Architecture

```text
AXI-Lite control/status
        |
        v
  xz_codec_top
    | mode=encode
    +--> xz_lzma2_uncompressed_encoder
    |
    | mode=decode, cfg0[19]=0
    +--> xz_lzma2_uncompressed_decoder
    |
    | mode=decode, cfg0[19]=1
    +--> xz_lzma2_compressed_decoder
            |
            +--> xz_lzma2_compressed_core
                    |
                    +--> xz_codec_mem_top
                    +--> xz_prob_ram_ctrl
                    +--> xz_range_bit_decode_step
```

The top level is half-duplex. Only one of encoder, uncompressed decoder, or
compressed decoder is selected for a transaction.

## 3. Control and Status Interface

AXI-Lite registers are implemented in `xz_axi_lite_regs`.

Important controls:

- `REG_CTRL[0]`: `start_pulse`
- `REG_CTRL[1]`: `mode_decode`
  - `0`: encode
  - `1`: decode
- `REG_CTRL[2]`: `soft_reset_pulse`
- `REG_CTRL[3]`: `irq_enable`
- `REG_CFG0[3:0]`: check type
- `REG_CFG0[5:4]`: dictionary size id
- `REG_CFG0[10:8]`: `lc`
- `REG_CFG0[14:12]`: `lp`
- `REG_CFG0[18:16]`: `pb`
- `REG_CFG0[19]`: compressed LZMA2 decode select
  - `0`: decode with uncompressed `.xz` decoder
  - `1`: decode with compressed `.xz` decoder wrapper
- `REG_CFG1[7:0]`: `nice_len`
- `REG_CFG1[15:8]`: `search_depth`
- `REG_CFG1[31:16]`: block size in KiB

Status:

- `REG_STATUS`: busy, done, error code.
- `REG_BYTES_IN0/1`: selected core input byte count.
- `REG_BYTES_OUT0/1`: selected core output byte count.
- `REG_CYCLES0/1`: selected core active cycle count.

Default reset configuration:

```text
check = CRC32
dict_size_id = 0
lc/lp/pb = 3/0/2
nice_len = 64
search_depth = 16
block_size = 64 KiB
compressed decode select = 0
```

## 4. Module Responsibilities

### `xz_codec_top`

Top-level integration wrapper.

Responsibilities:

- Instantiate AXI-Lite register block.
- Select encoder/uncompressed decoder/compressed decoder.
- Route AXI-Stream input/output ready/valid/data/last.
- Multiplex `busy/done/error/bytes_in/bytes_out/active_cycles`.
- Generate `m_axis_tuser = {error_present, error_code[6:0]}`.
- Generate interrupt when enabled and selected core is done or has error.

Selection rules:

- Encode: `mode_decode == 0`.
- Uncompressed decode: `mode_decode == 1 && cfg_compressed_lzma2 == 0`.
- Compressed decode: `mode_decode == 1 && cfg_compressed_lzma2 == 1`.

### `xz_lzma2_uncompressed_encoder`

Working `.xz` encoder for LZMA2 uncompressed chunks.

Responsibilities:

- Accept raw input bytes.
- Emit complete `.xz` stream:
  - Stream Header
  - Block Header
  - LZMA2 uncompressed chunks
  - LZMA2 EOS
  - block padding
  - Check
  - Index
  - Stream Footer
- Maintain CRC32/CRC64, sizes, and counters.

Storage:

- Uses an internal chunk buffer sized by `CHUNK_MAX_BYTES`.

### `xz_lzma2_uncompressed_decoder`

Working `.xz` decoder for the supported uncompressed LZMA2 subset.

Responsibilities:

- Parse Stream Header, Block Header, LZMA2 uncompressed chunks, Check, Index,
  and Footer.
- Verify magic, header CRC, block CRC, Check, Index CRC, Footer CRC, padding,
  and sizes.
- Emit raw payload bytes.
- Reject unsupported compressed LZMA2 packets with a clear error.

This path is the baseline for container parsing behavior.

### `xz_lzma2_compressed_decoder`

Compressed `.xz` container wrapper around the raw compressed core.

Responsibilities:

- Parse minimal `.xz` container:
  - Stream Header
  - Block Header
  - LZMA2 payload
  - LZMA2 EOS byte
  - block padding
  - Check
  - Index
  - Stream Footer
- Feed LZMA2 compressed chunk bytes to `xz_lzma2_compressed_core`.
- Compute Check over decoded output bytes, not over compressed payload.
- Check Index `unpadded_size` and `uncompressed_size`.
- Surface raw core errors through the wrapper.
- Keep `done/error_code` stable at completion.

Current boundaries:

- Directed `.xz` coverage exists for a tiny `ABAB` compressed stream.
- A 16-byte RTL-friendly C-model style `ABAB` stream covers a longer
  distance-2 match, output backpressure, and selected counter checks.
- Error coverage exists for bad CRC, bad block padding, and truncated stream.
- Broad multi-chunk and large-dictionary compressed streams are not complete.

### `xz_lzma2_compressed_core`

Raw LZMA2 compressed chunk decoder.

Responsibilities:

- Parse raw LZMA2 compressed chunk header:
  - control byte
  - unpacked length
  - compressed length
  - property byte
- Initialize probability RAM.
- Initialize range decoder from the first five payload bytes.
- Decode LZMA symbols:
  - literals
  - normal matches
  - short rep
  - long rep
  - length trees
  - distance slot
  - distance special
  - distance align
  - direct distance bits
- Maintain dictionary memory and emit decoded bytes.
- Report stable `done/error_code/bytes_in/bytes_out/active_cycles`.

Probability model address bases:

```text
is_match      = 0
is_rep        = 192
is_rep0       = 204
is_rep1       = 216
is_rep2       = 228
is_rep0_long  = 240
dist_slot     = 432
dist_special  = 688
dist_align    = 802
match_len     = 818
rep_len       = 1332
literal       = 2048
```

Current directed coverage includes literal-only, normal match, short rep, long
rep, special distance, direct distance error, truncation, bad control, and bad
property.

### `xz_codec_mem_top`

Centralized simulation memory wrapper.

Memories:

- Dictionary RAM.
- HC4 previous-position RAM.
- HC4 head RAM.
- Probability RAM.

Responsibilities:

- Provide one wrapper boundary for large memories.
- Keep dictionary/HC4/probability memories suitable for later SRAM macro and
  MBIST replacement.
- Use active macro sizing while keeping datapath address widths larger.

Dictionary policy:

- RTL baseline macro is 4 KiB.
- Datapath keeps 14-bit dictionary addressing for 16 KiB capability.
- Active dictionary mask is derived from `cfg_dict_size_id`.

### `xz_prob_ram_ctrl`

Probability RAM initialization and update controller.

Responsibilities:

- Initialize all probability entries to `1024`.
- Perform read-modify-write probability update for a decoded/encoded bit.
- Use LZMA probability update rule with total `2048` and move bits `5`.
- Provide old/new probability observability for unit tests.

### `xz_range_bit`

Combinational one-decision range coder step.

Modules:

- `xz_range_bit_encode_step`
- `xz_range_bit_decode_step`

Responsibilities:

- Compute `bound = (range >> 11) * prob`.
- Select bit branch.
- Produce updated range/code or range/low.
- Produce updated probability.

The compressed decoder currently uses the decode step.

### CRC Modules and Package

`xz_codec_pkg` contains:

- XZ constants.
- Error code constants.
- CRC32/CRC64 byte update functions.
- Stream/Header/Footer CRC helpers.
- dictionary size/property helpers.
- VLI helper functions.

`xz_crc32` and `xz_crc64` are small sequential byte-serial CRC modules; many
current datapaths use package functions directly.

## 5. Data and Counter Semantics

Common core interface convention:

- `start` is a pulse sampled in `IDLE`.
- `busy` is high during active non-terminal states.
- `done` is high when the selected transaction has reached terminal completion.
- `error_code == XZ_ERR_NONE` means success.
- Nonzero `error_code` means failure and should be stable when `done` is high.
- `bytes_in` counts accepted AXI-Stream input bytes for the selected core.
- `bytes_out` counts accepted AXI-Stream output bytes for the selected core.
- `active_cycles` increments while `busy` is high.

Important distinction:

- Raw compressed core `bytes_in` counts raw LZMA2 chunk bytes.
- Compressed `.xz` wrapper `bytes_in` counts full `.xz` container bytes accepted
  by the wrapper.
- Compressed `.xz` wrapper `bytes_out` counts decoded payload bytes.

## 6. Error Codes

Defined in `xz_codec_pkg`:

```text
00 XZ_ERR_NONE
01 XZ_ERR_BAD_MAGIC
02 XZ_ERR_BAD_HEADER_CRC
03 XZ_ERR_UNSUPPORTED_CHECK
04 XZ_ERR_UNSUPPORTED_FILTER
05 XZ_ERR_UNSUPPORTED_LZMA2
06 XZ_ERR_BAD_CRC
07 XZ_ERR_BAD_PADDING
08 XZ_ERR_TRUNCATED
09 XZ_ERR_CONFIG
```

Use existing error codes; do not add new error codes unless a new failure class
cannot be represented cleanly.

## 7. Verification Targets

Primary local gates:

```sh
make rtl-core-units
make rtl-compressed-core
make rtl-compressed-xz-top
make rtl-compressed-top
make smoke
make corpus-sim
git diff --check
```

Target meanings:

- `rtl-core-units`: memory, range bit, probability RAM unit checks.
- `rtl-compressed-core`: raw LZMA2 compressed core directed checks.
- `rtl-compressed-xz-top`: complete `.xz` compressed directed top checks.
- `rtl-compressed-top`: alias for the current compressed top-level gate.
- `smoke`: uncompressed encoder/decoder smoke and top compile.
- `corpus-sim`: smallest file-driven corpus case for existing uncompressed path.

Known Icarus warnings:

- constant select warnings in `always_*`
- `unique/unique0` ignored warnings
- `$fwrite` synthesis warnings in testbenches

These warnings are currently non-fatal.

## 8. Current Limitations and Next Work

Compressed decoder remaining work:

- Add broader `.xz` file-driven cases generated from the RTL C model.
- Add rep1/rep2/rep3 rotation directed cases.
- Add dictionary wrap and overlap copy stress cases.
- Add legal large direct-distance cases.
- Add multi-chunk LZMA2 property reset and state-retention cases.
- Add backpressure-directed cases for top-level compressed output.

Compressed encoder future work:

- Range encoder byte-output FSM.
- Literal encoder.
- HC4 match finder.
- FAST/greedy parser.
- Rep/normal match encoder.
- Incompressible fallback.

Memory/ASIC future work:

- Replace simulation arrays under `xz_codec_mem_top` with SRAM macros.
- Keep MBIST and hard macro replacement contained at the memory wrapper.
- Revisit performance after functional correctness: target sustained
  `0.5~1 bit/cycle` for compressed core milestones.
