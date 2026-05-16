#include <errno.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum {
    XZ_CHECK_NONE = 0,
    XZ_CHECK_CRC32 = 1,
    XZ_CHECK_CRC64 = 4,
};

typedef struct {
    uint32_t dict_kib;
    uint8_t dict_prop;
    uint32_t lc;
    uint32_t lp;
    uint32_t pb;
    uint32_t nice_len;
    uint32_t depth;
    uint32_t chunk_size;
    int check_type;
} xz_lzma2_cfg_t;

static uint32_t crc32_update(uint32_t crc, uint8_t data)
{
    crc ^= data;
    for (int i = 0; i < 8; ++i)
        crc = (crc & 1U) ? ((crc >> 1) ^ 0xEDB88320U) : (crc >> 1);
    return crc;
}

static uint32_t crc32_bytes(const uint8_t *data, uint64_t len)
{
    uint32_t crc = 0xFFFFFFFFU;
    for (uint64_t i = 0; i < len; ++i)
        crc = crc32_update(crc, data[i]);
    return ~crc;
}

static uint64_t crc64_bytes(const uint8_t *data, uint64_t len)
{
    uint64_t crc = UINT64_C(0xFFFFFFFFFFFFFFFF);
    for (uint64_t i = 0; i < len; ++i) {
        crc ^= data[i];
        for (int bit = 0; bit < 8; ++bit)
            crc = (crc & 1U) ? ((crc >> 1) ^ UINT64_C(0xC96C5795D7870F42)) : (crc >> 1);
    }
    return ~crc;
}

static void put_le32(uint8_t out[4], uint32_t value)
{
    out[0] = (uint8_t)value;
    out[1] = (uint8_t)(value >> 8);
    out[2] = (uint8_t)(value >> 16);
    out[3] = (uint8_t)(value >> 24);
}

static void put_le64(uint8_t out[8], uint64_t value)
{
    for (int i = 0; i < 8; ++i)
        out[i] = (uint8_t)(value >> (i * 8));
}

static int write_bytes(FILE *f, const uint8_t *data, size_t len)
{
    return fwrite(data, 1, len, f) == len ? 0 : -1;
}

static int write_byte(FILE *f, uint8_t byte)
{
    return fputc(byte, f) == EOF ? -1 : 0;
}

static unsigned vli_len(uint64_t value)
{
    unsigned len = 1;
    while (value >= 0x80U) {
        value >>= 7;
        ++len;
    }
    return len;
}

static int write_vli(FILE *f, uint64_t value, uint32_t *crc)
{
    do {
        uint8_t byte = (uint8_t)(value & 0x7FU);
        value >>= 7;
        if (value != 0)
            byte |= 0x80U;
        if (write_byte(f, byte) != 0)
            return -1;
        if (crc != NULL)
            *crc = crc32_update(*crc, byte);
    } while (value != 0);
    return 0;
}

static uint32_t stream_flags_crc(int check_type)
{
    uint8_t flags[2] = {0x00, (uint8_t)check_type};
    return crc32_bytes(flags, sizeof(flags));
}

static uint32_t block_header_crc(uint8_t dict_prop)
{
    uint8_t header[8] = {0x02, 0x00, 0x21, 0x01, dict_prop, 0x00, 0x00, 0x00};
    return crc32_bytes(header, sizeof(header));
}

static uint32_t footer_crc(uint32_t backward_size, int check_type)
{
    uint8_t footer_fields[6];
    put_le32(footer_fields, backward_size);
    footer_fields[4] = 0x00;
    footer_fields[5] = (uint8_t)check_type;
    return crc32_bytes(footer_fields, sizeof(footer_fields));
}

static int check_size(int check_type)
{
    switch (check_type) {
    case XZ_CHECK_NONE:
        return 0;
    case XZ_CHECK_CRC32:
        return 4;
    case XZ_CHECK_CRC64:
        return 8;
    default:
        return -1;
    }
}

static uint8_t dict_prop_from_kib(uint32_t dict_kib)
{
    switch (dict_kib) {
    case 64:
        return 8;
    case 256:
        return 12;
    case 1024:
        return 16;
    default:
        return 0xFF;
    }
}

static uint32_t dict_kib_from_prop(uint8_t dict_prop)
{
    switch (dict_prop) {
    case 8:
        return 64;
    case 12:
        return 256;
    case 16:
        return 1024;
    default:
        return 0;
    }
}

static int validate_cfg(const xz_lzma2_cfg_t *cfg)
{
    if (check_size(cfg->check_type) < 0)
        return -1;
    if (cfg->dict_prop > 40)
        return -1;
    if (cfg->dict_kib == 0)
        return -1;
    if (cfg->lc > 4 || cfg->lp > 4 || cfg->lc + cfg->lp > 4)
        return -1;
    if (cfg->pb > 4)
        return -1;
    if (cfg->nice_len == 0 || cfg->nice_len > 273)
        return -1;
    if (cfg->depth == 0)
        return -1;
    if (cfg->chunk_size == 0 || cfg->chunk_size > 65536)
        return -1;
    return 0;
}

static int write_stream_header(FILE *out, int check_type)
{
    static const uint8_t magic[6] = {0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00};
    uint8_t crc[4];
    uint8_t flags[2] = {0x00, (uint8_t)check_type};
    put_le32(crc, stream_flags_crc(check_type));

    return write_bytes(out, magic, sizeof(magic)) ||
           write_bytes(out, flags, sizeof(flags)) ||
           write_bytes(out, crc, sizeof(crc));
}

static int write_block_header(FILE *out, uint8_t dict_prop)
{
    uint8_t header[8] = {0x02, 0x00, 0x21, 0x01, dict_prop, 0x00, 0x00, 0x00};
    uint8_t crc[4];
    put_le32(crc, block_header_crc(dict_prop));
    return write_bytes(out, header, sizeof(header)) || write_bytes(out, crc, sizeof(crc));
}

static int write_lzma2_uncompressed(FILE *out, const uint8_t *data, uint64_t len,
                                    uint32_t chunk_size, uint64_t *compressed_size)
{
    uint64_t pos = 0;
    int first = 1;
    *compressed_size = 0;

    while (pos < len) {
        uint32_t this_chunk = chunk_size;
        if (this_chunk > len - pos)
            this_chunk = (uint32_t)(len - pos);

        uint16_t minus_one = (uint16_t)(this_chunk - 1);
        if (write_byte(out, first ? 0x01 : 0x02) ||
            write_byte(out, (uint8_t)(minus_one >> 8)) ||
            write_byte(out, (uint8_t)minus_one) ||
            write_bytes(out, data + pos, this_chunk))
            return -1;

        *compressed_size += 3U + this_chunk;
        pos += this_chunk;
        first = 0;
    }

    if (write_byte(out, 0x00) != 0)
        return -1;
    *compressed_size += 1;
    return 0;
}

static int write_check(FILE *out, const uint8_t *data, uint64_t len, int check_type)
{
    uint8_t bytes[8];

    if (check_type == XZ_CHECK_NONE)
        return 0;
    if (check_type == XZ_CHECK_CRC32) {
        put_le32(bytes, crc32_bytes(data, len));
        return write_bytes(out, bytes, 4);
    }
    if (check_type == XZ_CHECK_CRC64) {
        put_le64(bytes, crc64_bytes(data, len));
        return write_bytes(out, bytes, 8);
    }
    return -1;
}

static int write_index(FILE *out, uint64_t unpadded_size, uint64_t uncompressed_size,
                       unsigned *index_size)
{
    uint32_t crc = 0xFFFFFFFFU;
    unsigned body_len = 2 + vli_len(unpadded_size) + vli_len(uncompressed_size);
    unsigned pad_len = (4U - (body_len & 3U)) & 3U;
    uint8_t crc_bytes[4];

    if (write_byte(out, 0x00) || write_byte(out, 0x01))
        return -1;
    crc = crc32_update(crc, 0x00);
    crc = crc32_update(crc, 0x01);

    if (write_vli(out, unpadded_size, &crc) || write_vli(out, uncompressed_size, &crc))
        return -1;

    for (unsigned i = 0; i < pad_len; ++i) {
        if (write_byte(out, 0x00))
            return -1;
        crc = crc32_update(crc, 0x00);
    }

    put_le32(crc_bytes, ~crc);
    if (write_bytes(out, crc_bytes, sizeof(crc_bytes)))
        return -1;

    *index_size = body_len + pad_len + 4;
    return 0;
}

static int write_footer(FILE *out, unsigned index_size, int check_type)
{
    uint32_t backward_size = (index_size >> 2) - 1;
    uint8_t bytes[12];

    put_le32(&bytes[0], footer_crc(backward_size, check_type));
    put_le32(&bytes[4], backward_size);
    bytes[8] = 0x00;
    bytes[9] = (uint8_t)check_type;
    bytes[10] = 0x59;
    bytes[11] = 0x5A;

    return write_bytes(out, bytes, sizeof(bytes));
}

static uint8_t *read_file(const char *path, uint64_t *len)
{
    FILE *f = fopen(path, "rb");
    uint8_t *data = NULL;
    long size;

    if (f == NULL)
        return NULL;

    if (fseek(f, 0, SEEK_END) != 0)
        goto fail;
    size = ftell(f);
    if (size < 0)
        goto fail;
    if (fseek(f, 0, SEEK_SET) != 0)
        goto fail;

    data = malloc(size == 0 ? 1U : (size_t)size);
    if (data == NULL)
        goto fail;

    if (fread(data, 1, (size_t)size, f) != (size_t)size)
        goto fail;

    fclose(f);
    *len = (uint64_t)size;
    return data;

fail:
    free(data);
    fclose(f);
    return NULL;
}

static int parse_u32(const char *text, uint32_t *value)
{
    char *end = NULL;
    unsigned long parsed;

    errno = 0;
    parsed = strtoul(text, &end, 0);
    if (errno != 0 || end == text || *end != '\0' || parsed > UINT32_MAX)
        return -1;
    *value = (uint32_t)parsed;
    return 0;
}

static void usage(const char *argv0)
{
    fprintf(stderr,
            "usage: %s [options] <input> <output.xz>\n"
            "options:\n"
            "  --check 0|1|4       XZ check type: none/crc32/crc64 (default 1)\n"
            "  --dict-kib N        Dictionary size in KiB: 64, 256, or 1024 (default 64)\n"
            "  --dict-prop N       Raw LZMA2 dict property, kept for RTL compatibility\n"
            "  --lc N              Literal context bits, lc+lp<=4 (default 3)\n"
            "  --lp N              Literal position bits, lc+lp<=4 (default 0)\n"
            "  --pb N              Position bits, <=4 (default 2)\n"
            "  --nice-len N        Match nice length for future HC4 parser (default 64)\n"
            "  --depth N           Match search depth for future HC4 parser (default 16)\n"
            "  --chunk-size N      LZMA2 chunk size, <=65536 (default 65536)\n",
            argv0);
}

int main(int argc, char **argv)
{
    const char *input_path = NULL;
    const char *output_path = NULL;
    uint8_t *input = NULL;
    uint64_t input_len = 0;
    uint64_t compressed_size = 0;
    uint64_t unpadded_size = 0;
    uint64_t total_out = 0;
    unsigned index_size = 0;
    uint32_t tmp = 0;
    xz_lzma2_cfg_t cfg = {
        .dict_kib = 64,
        .dict_prop = 8,
        .lc = 3,
        .lp = 0,
        .pb = 2,
        .nice_len = 64,
        .depth = 16,
        .chunk_size = 65536,
        .check_type = XZ_CHECK_CRC32,
    };
    int csize = 0;
    FILE *out = NULL;
    int rc = 1;

    for (int i = 1; i < argc; ++i) {
        if (strcmp(argv[i], "--check") == 0 && i + 1 < argc) {
            if (parse_u32(argv[++i], &tmp) != 0) {
                usage(argv[0]);
                return 1;
            }
            cfg.check_type = (int)tmp;
        } else if (strcmp(argv[i], "--dict-kib") == 0 && i + 1 < argc) {
            if (parse_u32(argv[++i], &tmp) != 0) {
                usage(argv[0]);
                return 1;
            }
            cfg.dict_kib = tmp;
            cfg.dict_prop = dict_prop_from_kib(tmp);
            if (cfg.dict_prop == 0xFF) {
                usage(argv[0]);
                return 1;
            }
        } else if (strcmp(argv[i], "--dict-prop") == 0 && i + 1 < argc) {
            if (parse_u32(argv[++i], &tmp) != 0 || tmp > 40) {
                usage(argv[0]);
                return 1;
            }
            cfg.dict_prop = (uint8_t)tmp;
            cfg.dict_kib = dict_kib_from_prop(cfg.dict_prop);
            if (cfg.dict_kib == 0)
                cfg.dict_kib = (uint32_t)(2U | (tmp & 1U)) << ((tmp / 2U) + 1U);
        } else if (strcmp(argv[i], "--lc") == 0 && i + 1 < argc) {
            if (parse_u32(argv[++i], &cfg.lc) != 0) {
                usage(argv[0]);
                return 1;
            }
        } else if (strcmp(argv[i], "--lp") == 0 && i + 1 < argc) {
            if (parse_u32(argv[++i], &cfg.lp) != 0) {
                usage(argv[0]);
                return 1;
            }
        } else if (strcmp(argv[i], "--pb") == 0 && i + 1 < argc) {
            if (parse_u32(argv[++i], &cfg.pb) != 0) {
                usage(argv[0]);
                return 1;
            }
        } else if (strcmp(argv[i], "--nice-len") == 0 && i + 1 < argc) {
            if (parse_u32(argv[++i], &cfg.nice_len) != 0) {
                usage(argv[0]);
                return 1;
            }
        } else if (strcmp(argv[i], "--depth") == 0 && i + 1 < argc) {
            if (parse_u32(argv[++i], &cfg.depth) != 0) {
                usage(argv[0]);
                return 1;
            }
        } else if (strcmp(argv[i], "--chunk-size") == 0 && i + 1 < argc) {
            if (parse_u32(argv[++i], &tmp) != 0 || tmp == 0 || tmp > 65536) {
                usage(argv[0]);
                return 1;
            }
            cfg.chunk_size = tmp;
        } else if (input_path == NULL) {
            input_path = argv[i];
        } else if (output_path == NULL) {
            output_path = argv[i];
        } else {
            usage(argv[0]);
            return 1;
        }
    }

    csize = check_size(cfg.check_type);
    if (input_path == NULL || output_path == NULL || validate_cfg(&cfg) != 0) {
        usage(argv[0]);
        return 1;
    }

    input = read_file(input_path, &input_len);
    if (input == NULL) {
        fprintf(stderr, "failed to read %s\n", input_path);
        return 1;
    }

    out = fopen(output_path, "wb");
    if (out == NULL) {
        fprintf(stderr, "failed to open %s\n", output_path);
        goto out;
    }

    if (write_stream_header(out, cfg.check_type) ||
        write_block_header(out, cfg.dict_prop) ||
        write_lzma2_uncompressed(out, input, input_len, cfg.chunk_size, &compressed_size))
        goto out;

    for (unsigned i = 0; i < ((4U - ((12U + compressed_size) & 3U)) & 3U); ++i) {
        if (write_byte(out, 0x00))
            goto out;
    }

    if (write_check(out, input, input_len, cfg.check_type))
        goto out;

    unpadded_size = 12U + compressed_size + (uint64_t)csize;
    if (write_index(out, unpadded_size, input_len, &index_size) ||
        write_footer(out, index_size, cfg.check_type))
        goto out;

    if (fclose(out) != 0) {
        out = NULL;
        goto out;
    }
    out = NULL;

    total_out = 12U + unpadded_size + ((4U - ((12U + compressed_size) & 3U)) & 3U) +
                index_size + 12U;
    printf("input_bytes=%" PRIu64 " output_bytes=%" PRIu64 " ratio=%.6f overhead_bytes=%" PRIu64
           " dict_kib=%u dict_prop=%u lc=%u lp=%u pb=%u nice_len=%u depth=%u chunk_size=%u check=%d\n",
           input_len, total_out, input_len == 0 ? 0.0 : (double)total_out / (double)input_len,
           total_out >= input_len ? total_out - input_len : 0,
           cfg.dict_kib, cfg.dict_prop, cfg.lc, cfg.lp, cfg.pb, cfg.nice_len, cfg.depth,
           cfg.chunk_size, cfg.check_type);
    rc = 0;

out:
    if (out != NULL)
        fclose(out);
    free(input);
    return rc;
}
