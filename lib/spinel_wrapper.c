#include <ruby.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define SPINEL_DIMS 14
#define SPINEL_K 5
#define INDEX_MAGIC "RB26IDX1"

static VALUE rb_cSpinelDetector;

typedef struct {
    float *vectors;
    unsigned char *labels;
    uint32_t count;

    double max_amount;
    double max_installments;
    double amount_vs_avg_ratio;
    double max_minutes;
    double max_km;
    double max_tx_count_24h;
    double max_merchant_avg;

    double inv_max_amount;
    double inv_max_installments;
    double inv_amount_vs_avg_ratio;
    double inv_max_minutes;
    double inv_max_km;
    double inv_max_tx_count_24h;
    double inv_max_merchant_avg;
} spinel_wrapper_t;

static double clamp01(double value) {
    if (value < 0.0) return 0.0;
    if (value > 1.0) return 1.0;
    return value;
}

static double inv_or_one(double value) {
    return 1.0 / (value > 0.0 ? value : 1.0);
}

static void spinel_wrapper_free(void *ptr) {
    spinel_wrapper_t *wrapper = (spinel_wrapper_t *)ptr;
    if (!wrapper) return;
    if (wrapper->vectors) xfree(wrapper->vectors);
    if (wrapper->labels) xfree(wrapper->labels);
    xfree(wrapper);
}

static size_t spinel_wrapper_memsize(const void *ptr) {
    const spinel_wrapper_t *wrapper = (const spinel_wrapper_t *)ptr;
    if (!wrapper) return 0;
    return sizeof(spinel_wrapper_t) +
           ((size_t)wrapper->count * SPINEL_DIMS * sizeof(float)) +
           ((size_t)wrapper->count * sizeof(unsigned char));
}

static const rb_data_type_t spinel_wrapper_type = {
    "SpinelDetector",
    {NULL, spinel_wrapper_free, spinel_wrapper_memsize,},
    NULL, NULL,
    RUBY_TYPED_FREE_IMMEDIATELY,
};

static VALUE spinel_alloc(VALUE klass) {
    spinel_wrapper_t *wrapper;
    VALUE obj = TypedData_Make_Struct(klass, spinel_wrapper_t, &spinel_wrapper_type, wrapper);
    memset(wrapper, 0, sizeof(*wrapper));
    return obj;
}

static void read_exact(FILE *file, void *dst, size_t size, const char *path) {
    if (fread(dst, 1, size, file) != size) {
        fclose(file);
        rb_raise(rb_eRuntimeError, "short read while loading %s", path);
    }
}

static void spinel_load_index(spinel_wrapper_t *wrapper, const char *path) {
    FILE *file = fopen(path, "rb");
    if (!file) rb_sys_fail(path);

    char magic[8];
    read_exact(file, magic, sizeof(magic), path);
    if (memcmp(magic, INDEX_MAGIC, sizeof(magic)) != 0) {
        fclose(file);
        rb_raise(rb_eArgError, "invalid border index magic in %s", path);
    }

    uint32_t count = 0;
    read_exact(file, &count, sizeof(count), path);
    if (count == 0) {
        fclose(file);
        rb_raise(rb_eArgError, "empty border index in %s", path);
    }

    wrapper->vectors = ALLOC_N(float, (size_t)count * SPINEL_DIMS);
    wrapper->labels = ALLOC_N(unsigned char, count);
    wrapper->count = count;

    for (uint32_t i = 0; i < count; i++) {
        read_exact(file, &wrapper->vectors[(size_t)i * SPINEL_DIMS],
                   SPINEL_DIMS * sizeof(float), path);
        read_exact(file, &wrapper->labels[i], sizeof(unsigned char), path);
    }

    fclose(file);
}

static VALUE spinel_init(VALUE self, VALUE index_path, VALUE _mcc_risk_hash, VALUE norm_data) {
    spinel_wrapper_t *wrapper;
    TypedData_Get_Struct(self, spinel_wrapper_t, &spinel_wrapper_type, wrapper);

    spinel_load_index(wrapper, StringValueCStr(index_path));

    wrapper->max_amount = NUM2DBL(rb_ary_entry(norm_data, 0));
    wrapper->max_installments = NUM2DBL(rb_ary_entry(norm_data, 1));
    wrapper->amount_vs_avg_ratio = NUM2DBL(rb_ary_entry(norm_data, 2));
    wrapper->max_minutes = NUM2DBL(rb_ary_entry(norm_data, 3));
    wrapper->max_km = NUM2DBL(rb_ary_entry(norm_data, 4));
    wrapper->max_tx_count_24h = NUM2DBL(rb_ary_entry(norm_data, 5));
    wrapper->max_merchant_avg = NUM2DBL(rb_ary_entry(norm_data, 6));

    wrapper->inv_max_amount = inv_or_one(wrapper->max_amount);
    wrapper->inv_max_installments = inv_or_one(wrapper->max_installments);
    wrapper->inv_amount_vs_avg_ratio = inv_or_one(wrapper->amount_vs_avg_ratio);
    wrapper->inv_max_minutes = inv_or_one(wrapper->max_minutes);
    wrapper->inv_max_km = inv_or_one(wrapper->max_km);
    wrapper->inv_max_tx_count_24h = inv_or_one(wrapper->max_tx_count_24h);
    wrapper->inv_max_merchant_avg = inv_or_one(wrapper->max_merchant_avg);

    return self;
}

static void build_query(spinel_wrapper_t *wrapper, VALUE args, float q[SPINEL_DIMS]) {
    double amount = NUM2DBL(rb_ary_entry(args, 0));
    double installments = NUM2DBL(rb_ary_entry(args, 1));
    double customer_avg = NUM2DBL(rb_ary_entry(args, 2));
    int hour = FIX2INT(rb_ary_entry(args, 3));
    int wday = FIX2INT(rb_ary_entry(args, 4));
    double last_minutes = NUM2DBL(rb_ary_entry(args, 5));
    double last_km = NUM2DBL(rb_ary_entry(args, 6));
    double km_home = NUM2DBL(rb_ary_entry(args, 7));
    double tx_count = NUM2DBL(rb_ary_entry(args, 8));
    int is_online = RTEST(rb_ary_entry(args, 9));
    int card_present = RTEST(rb_ary_entry(args, 10));
    int known_merchant = RTEST(rb_ary_entry(args, 11));
    double mcc_risk = NUM2DBL(rb_ary_entry(args, 12));
    double merchant_avg = NUM2DBL(rb_ary_entry(args, 13));

    double amount_vs_avg = customer_avg > 0.0
        ? (amount / customer_avg) * wrapper->inv_amount_vs_avg_ratio
        : 1.0;

    q[0] = (float)clamp01(amount * wrapper->inv_max_amount);
    q[1] = (float)clamp01(installments * wrapper->inv_max_installments);
    q[2] = (float)clamp01(amount_vs_avg);
    q[3] = (float)((double)hour / 23.0);
    q[4] = (float)((double)wday / 6.0);

    if (last_minutes >= 0.0) {
        q[5] = (float)clamp01(last_minutes * wrapper->inv_max_minutes);
        q[6] = (float)clamp01(last_km * wrapper->inv_max_km);
    } else {
        q[5] = -1.0f;
        q[6] = -1.0f;
    }

    q[7] = (float)clamp01(km_home * wrapper->inv_max_km);
    q[8] = (float)clamp01(tx_count * wrapper->inv_max_tx_count_24h);
    q[9] = is_online ? 1.0f : 0.0f;
    q[10] = card_present ? 1.0f : 0.0f;
    q[11] = known_merchant ? 0.0f : 1.0f;
    q[12] = (float)mcc_risk;
    q[13] = (float)clamp01(merchant_avg * wrapper->inv_max_merchant_avg);
}

static double spinel_knn_score(spinel_wrapper_t *wrapper, const float q[SPINEL_DIMS]) {
    float best_dist[SPINEL_K] = {1e30f, 1e30f, 1e30f, 1e30f, 1e30f};
    unsigned char best_label[SPINEL_K] = {0, 0, 0, 0, 0};

    for (uint32_t i = 0; i < wrapper->count; i++) {
        const float *v = &wrapper->vectors[(size_t)i * SPINEL_DIMS];
        float dist = 0.0f;

        for (int d = 0; d < SPINEL_DIMS; d++) {
            float diff = q[d] - v[d];
            dist += diff * diff;
        }

        if (dist < best_dist[SPINEL_K - 1]) {
            int pos = SPINEL_K - 1;
            while (pos > 0 && dist < best_dist[pos - 1]) {
                best_dist[pos] = best_dist[pos - 1];
                best_label[pos] = best_label[pos - 1];
                pos--;
            }
            best_dist[pos] = dist;
            best_label[pos] = wrapper->labels[i];
        }
    }

    int frauds = 0;
    for (int i = 0; i < SPINEL_K; i++) frauds += best_label[i];
    return (double)frauds / (double)SPINEL_K;
}

static VALUE spinel_score_args(VALUE self, VALUE args) {
    spinel_wrapper_t *wrapper;
    TypedData_Get_Struct(self, spinel_wrapper_t, &spinel_wrapper_type, wrapper);

    float query[SPINEL_DIMS];
    build_query(wrapper, args, query);

    return DBL2NUM(spinel_knn_score(wrapper, query));
}

void Init_spinel_detector(void) {
    rb_cSpinelDetector = rb_define_class("SpinelDetector", rb_cObject);
    rb_define_alloc_func(rb_cSpinelDetector, spinel_alloc);
    rb_define_method(rb_cSpinelDetector, "initialize", spinel_init, 3);
    rb_define_method(rb_cSpinelDetector, "score_args", spinel_score_args, 1);
}
