#include <errno.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

enum {
    XZ_CHECK_NONE = 0,
    XZ_CHECK_CRC32 = 1,
    XZ_CHECK_CRC64 = 4,

    LZMA_STATES = 12,
    LZMA_LIT_STATES = 7,
    LZMA_POS_STATES_MAX = 16,
    LZMA_LITERAL_CODER_SIZE = 0x300,
    LZMA_MATCH_LEN_MIN = 2,
    LZMA_MATCH_LEN_MAX = 273,
    LZMA_LEN_LOW_BITS = 3,
    LZMA_LEN_MID_BITS = 3,
    LZMA_LEN_HIGH_BITS = 8,
    LZMA_LEN_LOW_SYMBOLS = 1 << LZMA_LEN_LOW_BITS,
    LZMA_LEN_MID_SYMBOLS = 1 << LZMA_LEN_MID_BITS,
    LZMA_DIST_STATES = 4,
    LZMA_DIST_SLOT_BITS = 6,
    LZMA_DIST_SLOTS = 1 << LZMA_DIST_SLOT_BITS,
    LZMA_DIST_MODEL_START = 4,
    LZMA_DIST_MODEL_END = 14,
    LZMA_FULL_DISTANCES = 1 << (LZMA_DIST_MODEL_END / 2),
    LZMA_ALIGN_BITS = 4,
    LZMA_ALIGN_SIZE = 1 << LZMA_ALIGN_BITS,
    RC_BIT_MODEL_TOTAL_BITS = 11,
    RC_BIT_MODEL_TOTAL = 1 << RC_BIT_MODEL_TOTAL_BITS,
    RC_MOVE_BITS = 5,
    RC_TOP_VALUE = 1 << 24,
};

typedef uint16_t prob_t;

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
    int force_uncompressed;
    int enable_matches;
} xz_cfg_t;

typedef struct {
    uint8_t *data;
    size_t len;
    size_t cap;
} vec_t;

typedef struct {
    uint64_t low;
    uint64_t cache_size;
    uint32_t range;
    uint8_t cache;
    uint64_t bit_events;
    vec_t *out;
} rc_t;

typedef struct {
    prob_t choice;
    prob_t choice2;
    prob_t low[LZMA_POS_STATES_MAX][1 << LZMA_LEN_LOW_BITS];
    prob_t mid[LZMA_POS_STATES_MAX][1 << LZMA_LEN_MID_BITS];
    prob_t high[1 << LZMA_LEN_HIGH_BITS];
} len_probs_t;

typedef struct {
    uint32_t lc;
    uint32_t lp;
    uint32_t pb;
    uint32_t pos_mask;
    uint32_t literal_mask;
    uint32_t state;
    uint32_t reps[4];
    uint64_t literals;
    uint64_t matches;
    uint64_t match_bytes;
    uint64_t rc_bits;
    prob_t is_match[LZMA_STATES][LZMA_POS_STATES_MAX];
    prob_t is_rep[LZMA_STATES];
    prob_t is_rep0[LZMA_STATES];
    prob_t is_rep1[LZMA_STATES];
    prob_t is_rep2[LZMA_STATES];
    prob_t is_rep0_long[LZMA_STATES][LZMA_POS_STATES_MAX];
    prob_t dist_slot[LZMA_DIST_STATES][LZMA_DIST_SLOTS];
    prob_t dist_special[LZMA_FULL_DISTANCES - LZMA_DIST_MODEL_END];
    prob_t dist_align[LZMA_ALIGN_SIZE];
    len_probs_t match_len;
    len_probs_t rep_len;
    prob_t *literal;
} lzma_enc_t;

typedef struct {
    uint32_t len;
    uint32_t dist;
} match_t;

typedef struct {
    uint32_t dict_size;
    uint32_t depth;
    uint32_t nice_len;
    uint32_t hash_size;
    uint32_t hash_mask;
    uint32_t *head;
    uint32_t *prev;
    uint64_t probes;
} hc4_t;

typedef struct {
    uint64_t compressed_chunks;
    uint64_t uncompressed_chunks;
    uint64_t literals;
    uint64_t matches;
    uint64_t match_bytes;
    uint64_t rc_bits;
    uint64_t hc4_probes;
} rtl_stats_t;

static int vec_reserve(vec_t *v, size_t need)
{
    if (need <= v->cap)
        return 0;
    size_t cap = v->cap == 0 ? 256U : v->cap;
    while (cap < need)
        cap *= 2U;
    uint8_t *p = realloc(v->data, cap);
    if (p == NULL)
        return -1;
    v->data = p;
    v->cap = cap;
    return 0;
}

static int vec_push(vec_t *v, uint8_t b)
{
    if (vec_reserve(v, v->len + 1U) != 0)
        return -1;
    v->data[v->len++] = b;
    return 0;
}

static int vec_write(vec_t *v, const uint8_t *data, size_t len)
{
    if (vec_reserve(v, v->len + len) != 0)
        return -1;
    memcpy(v->data + v->len, data, len);
    v->len += len;
    return 0;
}

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

static int vec_put_le32(vec_t *v, uint32_t value)
{
    uint8_t bytes[4];
    put_le32(bytes, value);
    return vec_write(v, bytes, sizeof(bytes));
}

static int vec_put_le64(vec_t *v, uint64_t value)
{
    uint8_t bytes[8];
    put_le64(bytes, value);
    return vec_write(v, bytes, sizeof(bytes));
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

static int vec_write_vli(vec_t *v, uint64_t value, uint32_t *crc)
{
    do {
        uint8_t byte = (uint8_t)(value & 0x7FU);
        value >>= 7;
        if (value != 0)
            byte |= 0x80U;
        if (vec_push(v, byte) != 0)
            return -1;
        if (crc != NULL)
            *crc = crc32_update(*crc, byte);
    } while (value != 0);
    return 0;
}

static int check_size(int check_type)
{
    if (check_type == XZ_CHECK_NONE)
        return 0;
    if (check_type == XZ_CHECK_CRC32)
        return 4;
    if (check_type == XZ_CHECK_CRC64)
        return 8;
    return -1;
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

static void prob_reset(prob_t *p)
{
    *p = RC_BIT_MODEL_TOTAL / 2;
}

static void prob_reset_array(prob_t *p, size_t n)
{
    for (size_t i = 0; i < n; ++i)
        prob_reset(&p[i]);
}

static void len_probs_reset(len_probs_t *lp)
{
    prob_reset(&lp->choice);
    prob_reset(&lp->choice2);
    prob_reset_array(&lp->low[0][0], LZMA_POS_STATES_MAX * (1 << LZMA_LEN_LOW_BITS));
    prob_reset_array(&lp->mid[0][0], LZMA_POS_STATES_MAX * (1 << LZMA_LEN_MID_BITS));
    prob_reset_array(lp->high, 1 << LZMA_LEN_HIGH_BITS);
}

static void rc_reset(rc_t *rc, vec_t *out)
{
    rc->low = 0;
    rc->cache_size = 1;
    rc->range = UINT32_MAX;
    rc->cache = 0;
    rc->bit_events = 0;
    rc->out = out;
}

static int rc_shift_low(rc_t *rc)
{
    if ((uint32_t)rc->low < 0xFF000000U || (uint32_t)(rc->low >> 32) != 0) {
        do {
            if (vec_push(rc->out, (uint8_t)(rc->cache + (uint8_t)(rc->low >> 32))) != 0)
                return -1;
            rc->cache = 0xFF;
        } while (--rc->cache_size != 0);
        rc->cache = (uint8_t)((rc->low >> 24) & 0xFFU);
    }

    ++rc->cache_size;
    rc->low = (rc->low & 0x00FFFFFFU) << 8;
    return 0;
}

static int rc_normalize(rc_t *rc)
{
    if (rc->range < RC_TOP_VALUE) {
        if (rc_shift_low(rc) != 0)
            return -1;
        rc->range <<= 8;
    }
    return 0;
}

static int rc_bit(rc_t *rc, prob_t *prob, uint32_t bit)
{
    if (rc_normalize(rc) != 0)
        return -1;

    uint32_t p = *prob;
    uint32_t bound = (rc->range >> RC_BIT_MODEL_TOTAL_BITS) * p;
    if (bit == 0) {
        rc->range = bound;
        p += (RC_BIT_MODEL_TOTAL - p) >> RC_MOVE_BITS;
    } else {
        rc->low += bound;
        rc->range -= bound;
        p -= p >> RC_MOVE_BITS;
    }
    *prob = (prob_t)p;
    ++rc->bit_events;
    return 0;
}

static int rc_direct(rc_t *rc, uint32_t value, uint32_t bit_count)
{
    while (bit_count != 0) {
        if (rc_normalize(rc) != 0)
            return -1;
        rc->range >>= 1;
        if (((value >> --bit_count) & 1U) != 0)
            rc->low += rc->range;
        ++rc->bit_events;
    }
    return 0;
}

static int rc_bittree(rc_t *rc, prob_t *probs, uint32_t bit_count, uint32_t symbol)
{
    uint32_t model = 1;
    while (bit_count != 0) {
        uint32_t bit = (symbol >> --bit_count) & 1U;
        if (rc_bit(rc, &probs[model], bit) != 0)
            return -1;
        model = (model << 1) + bit;
    }
    return 0;
}

static int rc_bittree_reverse(rc_t *rc, prob_t *probs, uint32_t bit_count, uint32_t symbol)
{
    uint32_t model = 1;
    while (bit_count != 0) {
        uint32_t bit = symbol & 1U;
        symbol >>= 1;
        if (rc_bit(rc, &probs[model], bit) != 0)
            return -1;
        model = (model << 1) + bit;
        --bit_count;
    }
    return 0;
}

static int rc_bittree_reverse_offset(rc_t *rc, prob_t *probs, int32_t offset,
                                     uint32_t bit_count, uint32_t symbol)
{
    uint32_t model = 1;
    while (bit_count != 0) {
        uint32_t bit = symbol & 1U;
        symbol >>= 1;
        if (rc_bit(rc, &probs[offset + (int32_t)model], bit) != 0)
            return -1;
        model = (model << 1) + bit;
        --bit_count;
    }
    return 0;
}

static int rc_flush(rc_t *rc)
{
    if (rc_normalize(rc) != 0)
        return -1;
    for (int i = 0; i < 5; ++i) {
        if (rc_shift_low(rc) != 0)
            return -1;
    }
    return 0;
}

static uint32_t literal_mask_calc(uint32_t lc, uint32_t lp)
{
    return ((0x100U << lp) - (0x100U >> lc));
}

static prob_t *literal_subcoder(lzma_enc_t *e, uint32_t pos, uint8_t prev_byte)
{
    uint32_t idx = ((((pos << 8) + prev_byte) & e->literal_mask) << e->lc);
    return e->literal + 3U * idx;
}

static void update_literal(uint32_t *state)
{
    if (*state <= 3)
        *state = 0;
    else if (*state <= 9)
        *state -= 3;
    else
        *state -= 6;
}

static void update_match(uint32_t *state)
{
    *state = *state < LZMA_LIT_STATES ? 7 : 10;
}

static uint32_t get_dist_state(uint32_t len)
{
    return len < LZMA_DIST_STATES + LZMA_MATCH_LEN_MIN
               ? len - LZMA_MATCH_LEN_MIN
               : LZMA_DIST_STATES - 1;
}

static uint32_t get_dist_slot(uint32_t dist)
{
    if (dist <= 4)
        return dist;
    uint32_t i = 31U;
    while (((dist >> i) & 1U) == 0)
        --i;
    return i + i + ((dist >> (i - 1)) & 1U);
}

static int lzma_init(lzma_enc_t *e, const xz_cfg_t *cfg)
{
    memset(e, 0, sizeof(*e));
    e->lc = cfg->lc;
    e->lp = cfg->lp;
    e->pb = cfg->pb;
    e->pos_mask = (1U << cfg->pb) - 1U;
    e->literal_mask = literal_mask_calc(cfg->lc, cfg->lp);
    e->reps[0] = e->reps[1] = e->reps[2] = e->reps[3] = 0;

    size_t literal_count = (size_t)LZMA_LITERAL_CODER_SIZE << (cfg->lc + cfg->lp);
    e->literal = malloc(literal_count * sizeof(e->literal[0]));
    if (e->literal == NULL)
        return -1;

    prob_reset_array(&e->is_match[0][0], LZMA_STATES * LZMA_POS_STATES_MAX);
    prob_reset_array(e->is_rep, LZMA_STATES);
    prob_reset_array(e->is_rep0, LZMA_STATES);
    prob_reset_array(e->is_rep1, LZMA_STATES);
    prob_reset_array(e->is_rep2, LZMA_STATES);
    prob_reset_array(&e->is_rep0_long[0][0], LZMA_STATES * LZMA_POS_STATES_MAX);
    prob_reset_array(&e->dist_slot[0][0], LZMA_DIST_STATES * LZMA_DIST_SLOTS);
    prob_reset_array(e->dist_special, LZMA_FULL_DISTANCES - LZMA_DIST_MODEL_END);
    prob_reset_array(e->dist_align, LZMA_ALIGN_SIZE);
    prob_reset_array(e->literal, literal_count);
    len_probs_reset(&e->match_len);
    len_probs_reset(&e->rep_len);
    return 0;
}

static void lzma_free(lzma_enc_t *e)
{
    free(e->literal);
    e->literal = NULL;
}

static int lzma_literal(lzma_enc_t *e, rc_t *rc, const uint8_t *data, uint32_t pos)
{
    uint32_t pos_state = pos & e->pos_mask;
    uint8_t prev = pos == 0 ? 0 : data[pos - 1];
    uint8_t cur = data[pos];
    prob_t *sub = literal_subcoder(e, pos, prev);

    if (rc_bit(rc, &e->is_match[e->state][pos_state], 0) != 0)
        return -1;

    if (e->state < LZMA_LIT_STATES) {
        if (rc_bittree(rc, sub, 8, cur) != 0)
            return -1;
    } else {
        uint32_t match_byte = 0;
        if ((uint64_t)pos > (uint64_t)e->reps[0])
            match_byte = data[pos - e->reps[0] - 1U];
        uint32_t offset = 0x100;
        uint32_t symbol = (uint32_t)cur + 0x100;
        do {
            match_byte <<= 1;
            uint32_t match_bit = match_byte & offset;
            uint32_t sub_idx = offset + match_bit + (symbol >> 8);
            uint32_t bit = (symbol >> 7) & 1U;
            if (rc_bit(rc, &sub[sub_idx], bit) != 0)
                return -1;
            symbol <<= 1;
            offset &= ~(match_byte ^ symbol);
        } while (symbol < 0x10000U);
    }

    update_literal(&e->state);
    ++e->literals;
    return 0;
}

static int lzma_len(lzma_enc_t *e, rc_t *rc, len_probs_t *lp, uint32_t pos_state, uint32_t len)
{
    (void)e;
    len -= LZMA_MATCH_LEN_MIN;
    if (len < LZMA_LEN_LOW_SYMBOLS) {
        return rc_bit(rc, &lp->choice, 0) ||
               rc_bittree(rc, lp->low[pos_state], LZMA_LEN_LOW_BITS, len);
    }

    len -= LZMA_LEN_LOW_SYMBOLS;
    if (rc_bit(rc, &lp->choice, 1) != 0)
        return -1;
    if (len < LZMA_LEN_MID_SYMBOLS) {
        return rc_bit(rc, &lp->choice2, 0) ||
               rc_bittree(rc, lp->mid[pos_state], LZMA_LEN_MID_BITS, len);
    }

    len -= LZMA_LEN_MID_SYMBOLS;
    return rc_bit(rc, &lp->choice2, 1) ||
           rc_bittree(rc, lp->high, LZMA_LEN_HIGH_BITS, len);
}

static int lzma_match(lzma_enc_t *e, rc_t *rc, uint32_t pos, uint32_t len, uint32_t distance)
{
    uint32_t pos_state = pos & e->pos_mask;
    uint32_t dist = distance - 1U;

    if (rc_bit(rc, &e->is_match[e->state][pos_state], 1) != 0 ||
        rc_bit(rc, &e->is_rep[e->state], 0) != 0)
        return -1;

    update_match(&e->state);
    if (lzma_len(e, rc, &e->match_len, pos_state, len) != 0)
        return -1;

    uint32_t dist_slot = get_dist_slot(dist);
    uint32_t dist_state = get_dist_state(len);
    if (rc_bittree(rc, e->dist_slot[dist_state], LZMA_DIST_SLOT_BITS, dist_slot) != 0)
        return -1;

    if (dist_slot >= LZMA_DIST_MODEL_START) {
        uint32_t footer_bits = (dist_slot >> 1) - 1U;
        uint32_t base = (2U | (dist_slot & 1U)) << footer_bits;
        uint32_t dist_reduced = dist - base;
        if (dist_slot < LZMA_DIST_MODEL_END) {
            if (rc_bittree_reverse_offset(rc, e->dist_special,
                                          (int32_t)base - (int32_t)dist_slot - 1,
                                          footer_bits, dist_reduced) != 0)
                return -1;
        } else {
            if (rc_direct(rc, dist_reduced >> LZMA_ALIGN_BITS,
                          footer_bits - LZMA_ALIGN_BITS) != 0 ||
                rc_bittree_reverse(rc, e->dist_align, LZMA_ALIGN_BITS,
                                   dist_reduced & (LZMA_ALIGN_SIZE - 1U)) != 0)
                return -1;
        }
    }

    e->reps[3] = e->reps[2];
    e->reps[2] = e->reps[1];
    e->reps[1] = e->reps[0];
    e->reps[0] = dist;
    ++e->matches;
    e->match_bytes += len;
    return 0;
}

static uint32_t hc4_hash(const uint8_t *data, uint32_t remaining, uint32_t mask)
{
    uint32_t h = 0;
    for (uint32_t i = 0; i < 4 && i < remaining; ++i)
        h = (h * 257U) ^ data[i];
    return h & mask;
}

static int hc4_init(hc4_t *hc, uint32_t dict_size, uint32_t depth, uint32_t nice_len)
{
    memset(hc, 0, sizeof(*hc));
    hc->dict_size = dict_size;
    hc->depth = depth;
    hc->nice_len = nice_len;
    hc->hash_size = 1U;
    while (hc->hash_size < dict_size)
        hc->hash_size <<= 1;
    hc->hash_mask = hc->hash_size - 1U;
    hc->head = calloc(hc->hash_size, sizeof(hc->head[0]));
    hc->prev = calloc(dict_size, sizeof(hc->prev[0]));
    return hc->head == NULL || hc->prev == NULL ? -1 : 0;
}

static void hc4_free(hc4_t *hc)
{
    free(hc->head);
    free(hc->prev);
}

static uint32_t hc4_insert(hc4_t *hc, const uint8_t *data, uint32_t len, uint32_t pos)
{
    if (pos + 4U > len)
        return 0;
    uint32_t h = hc4_hash(data + pos, len - pos, hc->hash_mask);
    uint32_t prev = hc->head[h];
    hc->prev[pos % hc->dict_size] = prev;
    hc->head[h] = pos + 1U;
    return prev;
}

static match_t hc4_find_and_insert(hc4_t *hc, const uint8_t *data, uint32_t len, uint32_t pos)
{
    match_t best = {0, 0};
    uint32_t prev = hc4_insert(hc, data, len, pos);
    uint32_t max_len = len - pos;
    if (max_len > LZMA_MATCH_LEN_MAX)
        max_len = LZMA_MATCH_LEN_MAX;
    if (max_len > hc->nice_len)
        max_len = hc->nice_len;

    for (uint32_t d = 0; prev != 0 && d < hc->depth; ++d) {
        uint32_t cand = prev - 1U;
        if (cand >= pos)
            break;
        uint32_t dist = pos - cand;
        if (dist == 0 || dist > hc->dict_size)
            break;
        ++hc->probes;

        uint32_t n = 0;
        while (n < max_len && data[cand + n] == data[pos + n])
            ++n;
        if (n >= 4 && n > best.len) {
            best.len = n;
            best.dist = dist;
            if (n >= hc->nice_len)
                break;
        }
        prev = hc->prev[cand % hc->dict_size];
    }
    return best;
}

static int lzma_encode_chunk(const uint8_t *data, uint32_t len, const xz_cfg_t *cfg,
                             vec_t *compressed, rtl_stats_t *stats)
{
    lzma_enc_t enc;
    hc4_t hc;
    rc_t rc;
    int rc_ok = -1;

    memset(compressed, 0, sizeof(*compressed));
    if (lzma_init(&enc, cfg) != 0)
        return -1;
    if (hc4_init(&hc, cfg->dict_kib * 1024U, cfg->depth, cfg->nice_len) != 0)
        goto out_enc;
    rc_reset(&rc, compressed);

    uint32_t pos = 0;
    while (pos < len) {
        match_t m = {0, 0};
        if (pos != 0)
            m = hc4_find_and_insert(&hc, data, len, pos);
        else
            (void)hc4_insert(&hc, data, len, pos);

        if (cfg->enable_matches && m.len >= 4) {
            if (lzma_match(&enc, &rc, pos, m.len, m.dist) != 0)
                goto out_hc;
            for (uint32_t i = 1; i < m.len && pos + i < len; ++i)
                (void)hc4_insert(&hc, data, len, pos + i);
            pos += m.len;
        } else {
            if (lzma_literal(&enc, &rc, data, pos) != 0)
                goto out_hc;
            ++pos;
        }
    }

    if (rc_flush(&rc) != 0)
        goto out_hc;

    stats->literals += enc.literals;
    stats->matches += enc.matches;
    stats->match_bytes += enc.match_bytes;
    stats->rc_bits += rc.bit_events;
    stats->hc4_probes += hc.probes;
    rc_ok = 0;

out_hc:
    hc4_free(&hc);
out_enc:
    lzma_free(&enc);
    if (rc_ok != 0) {
        free(compressed->data);
        memset(compressed, 0, sizeof(*compressed));
    }
    return rc_ok;
}

static uint8_t lclppb_prop(const xz_cfg_t *cfg)
{
    return (uint8_t)((cfg->pb * 5U + cfg->lp) * 9U + cfg->lc);
}

static int write_lzma2_uncompressed_chunk(vec_t *out, const uint8_t *data, uint32_t len,
                                          int dict_reset)
{
    uint16_t minus_one = (uint16_t)(len - 1U);
    return vec_push(out, dict_reset ? 0x01 : 0x02) ||
           vec_push(out, (uint8_t)(minus_one >> 8)) ||
           vec_push(out, (uint8_t)minus_one) ||
           vec_write(out, data, len);
}

static int write_lzma2_compressed_chunk(vec_t *out, const uint8_t *data, uint32_t len,
                                        const vec_t *compressed, const xz_cfg_t *cfg)
{
    (void)data;
    uint32_t us = len - 1U;
    uint32_t cs = (uint32_t)compressed->len - 1U;
    return vec_push(out, (uint8_t)(0xE0U + ((us >> 16) & 0x1FU))) ||
           vec_push(out, (uint8_t)(us >> 8)) ||
           vec_push(out, (uint8_t)us) ||
           vec_push(out, (uint8_t)(cs >> 8)) ||
           vec_push(out, (uint8_t)cs) ||
           vec_push(out, lclppb_prop(cfg)) ||
           vec_write(out, compressed->data, compressed->len);
}

static int encode_lzma2_payload(const uint8_t *data, uint64_t len, const xz_cfg_t *cfg,
                                vec_t *payload, rtl_stats_t *stats)
{
    uint64_t pos = 0;
    memset(payload, 0, sizeof(*payload));
    memset(stats, 0, sizeof(*stats));

    while (pos < len) {
        uint32_t chunk = cfg->chunk_size;
        if (chunk > len - pos)
            chunk = (uint32_t)(len - pos);

        vec_t compressed;
        int use_compressed = 0;
        if (!cfg->force_uncompressed &&
            lzma_encode_chunk(data + pos, chunk, cfg, &compressed, stats) == 0) {
            use_compressed = compressed.len < chunk && compressed.len <= 65536U;
        } else {
            memset(&compressed, 0, sizeof(compressed));
        }

        if (use_compressed) {
            if (write_lzma2_compressed_chunk(payload, data + pos, chunk, &compressed, cfg) != 0) {
                free(compressed.data);
                return -1;
            }
            ++stats->compressed_chunks;
        } else {
            if (write_lzma2_uncompressed_chunk(payload, data + pos, chunk, 1) != 0) {
                free(compressed.data);
                return -1;
            }
            ++stats->uncompressed_chunks;
        }
        free(compressed.data);
        pos += chunk;
    }

    return vec_push(payload, 0x00);
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
    uint8_t fields[6];
    put_le32(fields, backward_size);
    fields[4] = 0x00;
    fields[5] = (uint8_t)check_type;
    return crc32_bytes(fields, sizeof(fields));
}

static int write_stream_header(vec_t *out, int check_type)
{
    static const uint8_t magic[6] = {0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00};
    uint8_t flags[2] = {0x00, (uint8_t)check_type};
    return vec_write(out, magic, sizeof(magic)) ||
           vec_write(out, flags, sizeof(flags)) ||
           vec_put_le32(out, stream_flags_crc(check_type));
}

static int write_block_header(vec_t *out, uint8_t dict_prop)
{
    uint8_t header[8] = {0x02, 0x00, 0x21, 0x01, dict_prop, 0x00, 0x00, 0x00};
    return vec_write(out, header, sizeof(header)) ||
           vec_put_le32(out, block_header_crc(dict_prop));
}

static int write_check(vec_t *out, const uint8_t *data, uint64_t len, int check_type)
{
    if (check_type == XZ_CHECK_NONE)
        return 0;
    if (check_type == XZ_CHECK_CRC32)
        return vec_put_le32(out, crc32_bytes(data, len));
    if (check_type == XZ_CHECK_CRC64)
        return vec_put_le64(out, crc64_bytes(data, len));
    return -1;
}

static int write_index(vec_t *out, uint64_t unpadded_size, uint64_t uncompressed_size,
                       unsigned *index_size)
{
    uint32_t crc = 0xFFFFFFFFU;
    unsigned body_len = 2U + vli_len(unpadded_size) + vli_len(uncompressed_size);
    unsigned pad_len = (4U - (body_len & 3U)) & 3U;

    if (vec_push(out, 0x00) || vec_push(out, 0x01))
        return -1;
    crc = crc32_update(crc, 0x00);
    crc = crc32_update(crc, 0x01);

    if (vec_write_vli(out, unpadded_size, &crc) ||
        vec_write_vli(out, uncompressed_size, &crc))
        return -1;

    for (unsigned i = 0; i < pad_len; ++i) {
        if (vec_push(out, 0x00))
            return -1;
        crc = crc32_update(crc, 0x00);
    }

    if (vec_put_le32(out, ~crc) != 0)
        return -1;
    *index_size = body_len + pad_len + 4U;
    return 0;
}

static int write_footer(vec_t *out, unsigned index_size, int check_type)
{
    uint32_t backward_size = (index_size >> 2) - 1U;
    return vec_put_le32(out, footer_crc(backward_size, check_type)) ||
           vec_put_le32(out, backward_size) ||
           vec_push(out, 0x00) ||
           vec_push(out, (uint8_t)check_type) ||
           vec_push(out, 0x59) ||
           vec_push(out, 0x5A);
}

static int encode_xz(const uint8_t *input, uint64_t input_len, const xz_cfg_t *cfg,
                     vec_t *out, rtl_stats_t *stats)
{
    vec_t payload;
    int csize = check_size(cfg->check_type);
    unsigned index_size = 0;

    if (csize < 0)
        return -1;
    memset(out, 0, sizeof(*out));
    if (encode_lzma2_payload(input, input_len, cfg, &payload, stats) != 0)
        return -1;

    uint64_t block_pad = (4U - ((12U + payload.len) & 3U)) & 3U;
    uint64_t unpadded_size = 12U + payload.len + (uint64_t)csize;

    if (write_stream_header(out, cfg->check_type) ||
        write_block_header(out, cfg->dict_prop) ||
        vec_write(out, payload.data, payload.len))
        goto fail;
    for (uint64_t i = 0; i < block_pad; ++i)
        if (vec_push(out, 0x00))
            goto fail;
    if (write_check(out, input, input_len, cfg->check_type) ||
        write_index(out, unpadded_size, input_len, &index_size) ||
        write_footer(out, index_size, cfg->check_type))
        goto fail;

    free(payload.data);
    return 0;

fail:
    free(payload.data);
    free(out->data);
    memset(out, 0, sizeof(*out));
    return -1;
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

static int validate_cfg(const xz_cfg_t *cfg)
{
    if (check_size(cfg->check_type) < 0)
        return -1;
    if (cfg->dict_kib == 0 || cfg->dict_prop > 40)
        return -1;
    if (cfg->lc > 4 || cfg->lp > 4 || cfg->lc + cfg->lp > 4 || cfg->pb > 4)
        return -1;
    if (cfg->nice_len < 4 || cfg->nice_len > LZMA_MATCH_LEN_MAX)
        return -1;
    if (cfg->depth == 0)
        return -1;
    if (cfg->chunk_size == 0 || cfg->chunk_size > 65536)
        return -1;
    return 0;
}

static void usage(const char *argv0)
{
    fprintf(stderr,
            "usage: %s [options] <input> <output.xz>\n"
            "options:\n"
            "  --check 0|1|4       XZ check: none/crc32/crc64 (default 1)\n"
            "  --dict-kib N        Dictionary KiB: 64, 256, or 1024 (default 64)\n"
            "  --dict-prop N       Raw LZMA2 dictionary property\n"
            "  --lc N              Literal context bits, lc+lp<=4 (default 3)\n"
            "  --lp N              Literal position bits, lc+lp<=4 (default 0)\n"
            "  --pb N              Position bits, <=4 (default 2)\n"
            "  --nice-len N        HC4 greedy nice length, 4..273 (default 64)\n"
            "  --depth N           HC4 chain depth (default 16)\n"
            "  --chunk-size N      LZMA2 chunk size, <=65536 (default 65536)\n"
            "  --disable-matches   Emit literals only; keeps range path, disables match tokens\n"
            "  --force-uncompressed  Disable range-coded chunk emission\n",
            argv0);
}

int main(int argc, char **argv)
{
    xz_cfg_t cfg = {
        .dict_kib = 64,
        .dict_prop = 8,
        .lc = 3,
        .lp = 0,
        .pb = 2,
        .nice_len = 64,
        .depth = 16,
        .chunk_size = 65536,
        .check_type = XZ_CHECK_CRC32,
        .force_uncompressed = 0,
        .enable_matches = 1,
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
            if (parse_u32(argv[++i], &cfg.chunk_size) != 0) {
                usage(argv[0]);
                return 1;
            }
        } else if (strcmp(argv[i], "--force-uncompressed") == 0) {
            cfg.force_uncompressed = 1;
        } else if (strcmp(argv[i], "--enable-matches") == 0) {
            cfg.enable_matches = 1;
        } else if (strcmp(argv[i], "--disable-matches") == 0) {
            cfg.enable_matches = 0;
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

    uint64_t input_len = 0;
    uint8_t *input = read_file(input_path, &input_len);
    if (input == NULL) {
        fprintf(stderr, "failed to read %s\n", input_path);
        return 1;
    }

    vec_t output;
    rtl_stats_t stats;
    clock_t start = clock();
    int rc = encode_xz(input, input_len, &cfg, &output, &stats);
    double seconds = (double)(clock() - start) / (double)CLOCKS_PER_SEC;
    if (rc != 0) {
        fprintf(stderr, "encode failed\n");
        free(input);
        return 1;
    }

    if (write_file(output_path, output.data, output.len) != 0) {
        fprintf(stderr, "failed to write %s\n", output_path);
        free(output.data);
        free(input);
        return 1;
    }

    double ratio = input_len == 0 ? 0.0 : (double)output.len / (double)input_len;
    double mbps = seconds <= 0.0 ? 0.0 : (double)input_len / seconds / (1024.0 * 1024.0);
    printf("input_bytes=%" PRIu64 " output_bytes=%zu ratio=%.6f enc_MBps=%.2f "
           "dict_kib=%u dict_prop=%u lc=%u lp=%u pb=%u nice_len=%u depth=%u "
           "chunk_size=%u check=%d backend=rtl_friendly_hc4_range "
           "compressed_chunks=%" PRIu64 " uncompressed_chunks=%" PRIu64 " "
           "literals=%" PRIu64 " matches=%" PRIu64 " match_bytes=%" PRIu64 " "
           "rc_bits=%" PRIu64 " hc4_probes=%" PRIu64 "\n",
           input_len, output.len, ratio, mbps,
           cfg.dict_kib, cfg.dict_prop, cfg.lc, cfg.lp, cfg.pb, cfg.nice_len,
           cfg.depth, cfg.chunk_size, cfg.check_type, stats.compressed_chunks,
           stats.uncompressed_chunks, stats.literals, stats.matches, stats.match_bytes,
           stats.rc_bits, stats.hc4_probes);

    free(output.data);
    free(input);
    return 0;
}
