# AXI-Lite Register Map

All registers are 32-bit little-endian. Address bits `[1:0]` are ignored.

| Offset | Name | Access | Description |
| --- | --- | --- | --- |
| `0x00` | `CTRL` | RW/pulse | bit0 `start`, bit1 `mode_decode`, bit2 `soft_reset`, bit3 `irq_enable` |
| `0x04` | `CFG0` | RW | bits `[3:0]` `check_type`, `[5:4]` `dict_size_id`, `[10:8]` `lc`, `[14:12]` `lp`, `[18:16]` `pb` |
| `0x08` | `CFG1` | RW | bits `[7:0]` `nice_len`, `[15:8]` `search_depth`, `[31:16]` `block_size_kib` |
| `0x0C` | `STATUS` | RO | bit1 `busy`, bit2 `done`, bits `[15:8]` `error_code` |
| `0x10` | `BYTES_IN_LO` | RO | input byte counter `[31:0]` |
| `0x14` | `BYTES_IN_HI` | RO | input byte counter `[63:32]` |
| `0x18` | `BYTES_OUT_LO` | RO | output byte counter `[31:0]` |
| `0x1C` | `BYTES_OUT_HI` | RO | output byte counter `[63:32]` |
| `0x20` | `CYCLES_LO` | RO | active cycle counter `[31:0]` |
| `0x24` | `CYCLES_HI` | RO | active cycle counter `[63:32]` |

## Defaults

- `mode_decode = 0` for encode mode.
- `check_type = 1` for CRC32.
- `dict_size_id = 0` for 64 KiB in v0.1 register reset.
- `lc=3`, `lp=0`, `pb=2`.
- `nice_len=32`, `search_depth=16`, `block_size_kib=64`.

## Dictionary IDs

| ID | Dictionary property | Dictionary size |
| --- | --- | --- |
| `0` | `8` | 64 KiB |
| `1` | `12` | 256 KiB |
| `2` | `16` | 1 MiB |
| `3` | `4` | 16 KiB |

## Error Codes

| Code | Meaning |
| --- | --- |
| `0x00` | No error |
| `0x01` | Bad XZ stream magic |
| `0x02` | Bad Stream Header CRC |
| `0x03` | Unsupported Check type |
| `0x04` | Unsupported filter or block header shape |
| `0x05` | Unsupported LZMA2 packet, including compressed chunks in v0.1 |
| `0x06` | CRC/index/footer mismatch |
| `0x07` | Bad padding |
| `0x08` | Truncated stream, reserved for future parser hardening |
| `0x09` | Invalid encoder configuration |
