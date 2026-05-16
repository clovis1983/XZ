#include <errno.h>
#include <inttypes.h>
#include <lzma.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

typedef struct {
    uint32_t dict_kib;
    uint32_t lc;
    uint32_t lp;
    uint32_t pb;
    uint32_t nice_len;
    uint32_t depth;
    lzma_check check;
} xz_liblzma_cfg_t;

static uint8_t *read_file(const char *path, size_t *len)
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
    *len = (size_t)size;
    return data;

fail:
    free(data);
    fclose(f);
    return NULL;
}

static int write_file(const char *path, const uint8_t *data, size_t len)
{
    FILE *f = fopen(path, "wb");
    if (f == NULL)
        return -1;
    int rc = fwrite(data, 1, len, f) == len ? 0 : -1;
    if (fclose(f) != 0)
        rc = -1;
    return rc;
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

static int validate_cfg(const xz_liblzma_cfg_t *cfg)
{
    if (cfg->dict_kib == 0)
        return -1;
    if (cfg->lc > 4 || cfg->lp > 4 || cfg->lc + cfg->lp > 4)
        return -1;
    if (cfg->pb > 4)
        return -1;
    if (cfg->nice_len < 4 || cfg->nice_len > 273)
        return -1;
    if (cfg->depth == 0)
        return -1;
    if (!lzma_check_is_supported(cfg->check))
        return -1;
    return 0;
}

static const char *lzma_ret_name(lzma_ret ret)
{
    switch (ret) {
    case LZMA_OK:
        return "LZMA_OK";
    case LZMA_STREAM_END:
        return "LZMA_STREAM_END";
    case LZMA_NO_CHECK:
        return "LZMA_NO_CHECK";
    case LZMA_UNSUPPORTED_CHECK:
        return "LZMA_UNSUPPORTED_CHECK";
    case LZMA_GET_CHECK:
        return "LZMA_GET_CHECK";
    case LZMA_MEM_ERROR:
        return "LZMA_MEM_ERROR";
    case LZMA_MEMLIMIT_ERROR:
        return "LZMA_MEMLIMIT_ERROR";
    case LZMA_FORMAT_ERROR:
        return "LZMA_FORMAT_ERROR";
    case LZMA_OPTIONS_ERROR:
        return "LZMA_OPTIONS_ERROR";
    case LZMA_DATA_ERROR:
        return "LZMA_DATA_ERROR";
    case LZMA_BUF_ERROR:
        return "LZMA_BUF_ERROR";
    case LZMA_PROG_ERROR:
        return "LZMA_PROG_ERROR";
    default:
        return "LZMA_UNKNOWN";
    }
}

static int encode_lzma2_xz(const uint8_t *input, size_t input_len,
                           const xz_liblzma_cfg_t *cfg,
                           uint8_t **output, size_t *output_len)
{
    lzma_options_lzma opt;
    memset(&opt, 0, sizeof(opt));
    if (lzma_lzma_preset(&opt, 6) != false) {
        fprintf(stderr, "lzma_lzma_preset failed\n");
        return -1;
    }

    opt.dict_size = cfg->dict_kib * 1024U;
    opt.lc = cfg->lc;
    opt.lp = cfg->lp;
    opt.pb = cfg->pb;
    opt.mode = LZMA_MODE_FAST;
    opt.nice_len = cfg->nice_len;
    opt.mf = LZMA_MF_HC4;
    opt.depth = cfg->depth;

    lzma_filter filters[] = {
        { .id = LZMA_FILTER_LZMA2, .options = &opt },
        { .id = LZMA_VLI_UNKNOWN, .options = NULL },
    };

    uint64_t memusage = lzma_raw_encoder_memusage(filters);
    if (memusage == UINT64_MAX) {
        fprintf(stderr, "invalid raw encoder options\n");
        return -1;
    }

    size_t cap = input_len + input_len / 3U + 65536U;
    if (cap < 4096U)
        cap = 4096U;
    uint8_t *out = malloc(cap);
    if (out == NULL)
        return -1;

    lzma_stream strm = LZMA_STREAM_INIT;
    lzma_ret ret = lzma_stream_encoder(&strm, filters, cfg->check);
    if (ret != LZMA_OK) {
        fprintf(stderr, "lzma_stream_encoder: %s\n", lzma_ret_name(ret));
        free(out);
        return -1;
    }

    strm.next_in = input;
    strm.avail_in = input_len;
    strm.next_out = out;
    strm.avail_out = cap;

    while (1) {
        ret = lzma_code(&strm, LZMA_FINISH);
        if (ret == LZMA_STREAM_END)
            break;
        if (ret != LZMA_OK) {
            fprintf(stderr, "lzma_code: %s\n", lzma_ret_name(ret));
            lzma_end(&strm);
            free(out);
            return -1;
        }

        if (strm.avail_out == 0) {
            size_t used = cap;
            size_t new_cap = cap * 2U;
            uint8_t *new_out = realloc(out, new_cap);
            if (new_out == NULL) {
                lzma_end(&strm);
                free(out);
                return -1;
            }
            out = new_out;
            cap = new_cap;
            strm.next_out = out + used;
            strm.avail_out = cap - used;
        }
    }

    *output_len = cap - strm.avail_out;
    lzma_end(&strm);
    *output = out;
    return 0;
}

static void usage(const char *argv0)
{
    fprintf(stderr,
            "usage: %s [options] <input> <output.xz>\n"
            "options:\n"
            "  --check 0|1|4       XZ check type: none/crc32/crc64 (default 1)\n"
            "  --dict-kib N        Dictionary size in KiB (default 64)\n"
            "  --lc N              Literal context bits, lc+lp<=4 (default 3)\n"
            "  --lp N              Literal position bits, lc+lp<=4 (default 0)\n"
            "  --pb N              Position bits, <=4 (default 2)\n"
            "  --nice-len N        LZMA nice length (default 64)\n"
            "  --depth N           HC4 search depth (default 16)\n",
            argv0);
}

int main(int argc, char **argv)
{
    xz_liblzma_cfg_t cfg = {
        .dict_kib = 64,
        .lc = 3,
        .lp = 0,
        .pb = 2,
        .nice_len = 64,
        .depth = 16,
        .check = LZMA_CHECK_CRC32,
    };
    const char *input_path = NULL;
    const char *output_path = NULL;
    uint32_t tmp = 0;

    for (int i = 1; i < argc; ++i) {
        if (strcmp(argv[i], "--check") == 0 && i + 1 < argc) {
            if (parse_u32(argv[++i], &tmp) != 0) {
                usage(argv[0]);
                return 1;
            }
            cfg.check = (lzma_check)tmp;
        } else if (strcmp(argv[i], "--dict-kib") == 0 && i + 1 < argc) {
            if (parse_u32(argv[++i], &cfg.dict_kib) != 0) {
                usage(argv[0]);
                return 1;
            }
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
        } else if (input_path == NULL) {
            input_path = argv[i];
        } else if (output_path == NULL) {
            output_path = argv[i];
        } else {
            usage(argv[0]);
            return 1;
        }
    }

    if (input_path == NULL || output_path == NULL || validate_cfg(&cfg) != 0) {
        usage(argv[0]);
        return 1;
    }

    size_t input_len = 0;
    uint8_t *input = read_file(input_path, &input_len);
    if (input == NULL) {
        fprintf(stderr, "failed to read %s\n", input_path);
        return 1;
    }

    uint8_t *output = NULL;
    size_t output_len = 0;
    clock_t start = clock();
    int rc = encode_lzma2_xz(input, input_len, &cfg, &output, &output_len);
    double seconds = (double)(clock() - start) / (double)CLOCKS_PER_SEC;
    if (rc != 0) {
        free(input);
        return 1;
    }

    if (write_file(output_path, output, output_len) != 0) {
        fprintf(stderr, "failed to write %s\n", output_path);
        free(output);
        free(input);
        return 1;
    }

    double ratio = input_len == 0 ? 0.0 : (double)output_len / (double)input_len;
    double mbps = seconds <= 0.0 ? 0.0 : (double)input_len / seconds / (1024.0 * 1024.0);
    printf("input_bytes=%zu output_bytes=%zu ratio=%.6f enc_MBps=%.2f "
           "dict_kib=%u lc=%u lp=%u pb=%u nice_len=%u depth=%u check=%u backend=liblzma_hc4_range\n",
           input_len, output_len, ratio, mbps, cfg.dict_kib, cfg.lc, cfg.lp, cfg.pb,
           cfg.nice_len, cfg.depth, (unsigned)cfg.check);

    free(output);
    free(input);
    return 0;
}
