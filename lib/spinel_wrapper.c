#include <ruby.h>
#include "sp_runtime.h"

// Forward declarations of Spinel types and functions from spinel_logic.c
typedef struct sp_SpinelLogic_s sp_SpinelLogic;
typedef struct sp_IntArray_s sp_IntArray;
typedef struct sp_FloatArray_s sp_FloatArray;
typedef struct sp_StrIntHash_s sp_StrIntHash;

// Including the generated code directly to avoid complex linking
#include "spinel_logic.c"

static VALUE rb_cSpinelDetector;

typedef struct {
    sp_SpinelLogic *logic;
} spinel_wrapper_t;

static void spinel_wrapper_free(void *ptr) {
    // Spinel uses its own GC, but since we're in a standalone-ish mode,
    // we don't have a global sweep here. However, for a long-lived object
    // in the Rinha, it's fine as long as we don't leak per request.
    free(ptr);
}

static size_t spinel_wrapper_memsize(const void *ptr) {
    return sizeof(spinel_wrapper_t);
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
    wrapper->logic = NULL;
    return obj;
}

static VALUE spinel_init(VALUE self, VALUE labels_arr, VALUE mcc_risk_hash, VALUE norm_data) {
    spinel_wrapper_t *wrapper;
    TypedData_Get_Struct(self, spinel_wrapper_t, &spinel_wrapper_type, wrapper);

    // Initialize Spinel runtime
    // sp_gc_heap initialization is handled by first sp_gc_alloc
    
    // Convert Ruby labels (Array of Int) to sp_IntArray
    sp_IntArray *sp_labels = sp_IntArray_new();
    long len = RARRAY_LEN(labels_arr);
    for (long i = 0; i < len; i++) {
        sp_IntArray_push(sp_labels, NUM2LL(rb_ary_entry(labels_arr, i)));
    }

    // Convert Ruby mcc_risk (Hash String -> Float) to sp_StrIntHash (Int = Float * 1000)
    sp_StrIntHash *sp_mcc_risk = sp_StrIntHash_new();
    VALUE keys = rb_funcall(mcc_risk_hash, rb_intern("keys"), 0);
    long keys_len = RARRAY_LEN(keys);
    for (long i = 0; i < keys_len; i++) {
        VALUE k = rb_ary_entry(keys, i);
        VALUE v = rb_hash_aref(mcc_risk_hash, k);
        const char *k_str = StringValueCStr(k);
        // Spinel's sp_StrIntHash_set expects a Spinel string (with metadata)
        // But for literal-like strings it might work with raw chars if we're careful.
        // Actually sp_runtime.h has sp_str_dup_external
        sp_StrIntHash_set(sp_mcc_risk, sp_str_dup_external(k_str), (mrb_int)(NUM2DBL(v) * 1000.0));
    }

    // norm_data: [max_amount, max_inst, avg_ratio_limit, max_min, max_km, max_tx, max_m_avg]
    wrapper->logic = sp_SpinelLogic_new(
        sp_labels, 
        sp_mcc_risk,
        NUM2DBL(rb_ary_entry(norm_data, 0)),
        NUM2DBL(rb_ary_entry(norm_data, 1)),
        NUM2DBL(rb_ary_entry(norm_data, 2)),
        NUM2DBL(rb_ary_entry(norm_data, 3)),
        NUM2DBL(rb_ary_entry(norm_data, 4)),
        NUM2DBL(rb_ary_entry(norm_data, 5)),
        NUM2DBL(rb_ary_entry(norm_data, 6))
    );

    return self;
}

static VALUE spinel_build_vector(VALUE self, VALUE args) {
    spinel_wrapper_t *wrapper;
    TypedData_Get_Struct(self, spinel_wrapper_t, &spinel_wrapper_type, wrapper);

    // args: [amount, inst, cust_avg, hour, wday, last_tx_mins, last_tx_km, km_home, tx_c, is_online, card_present, known_merch, mcc, m_avg]
    sp_FloatArray *v = sp_SpinelLogic_build_vector(
        wrapper->logic,
        NUM2DBL(rb_ary_entry(args, 0)),
        NUM2DBL(rb_ary_entry(args, 1)),
        NUM2DBL(rb_ary_entry(args, 2)),
        FIX2INT(rb_ary_entry(args, 3)),
        FIX2INT(rb_ary_entry(args, 4)),
        NUM2DBL(rb_ary_entry(args, 5)),
        NUM2DBL(rb_ary_entry(args, 6)),
        NUM2DBL(rb_ary_entry(args, 7)),
        NUM2DBL(rb_ary_entry(args, 8)),
        RTEST(rb_ary_entry(args, 9)),
        RTEST(rb_ary_entry(args, 10)),
        RTEST(rb_ary_entry(args, 11)),
        StringValueCStr(rb_ary_entry(args, 12)),
        NUM2DBL(rb_ary_entry(args, 13))
    );

    // Convert sp_FloatArray to Ruby Array
    int len = sp_FloatArray_length(v);
    VALUE res = rb_ary_new2(len);
    for (int i = 0; i < len; i++) {
        rb_ary_push(res, DBL2NUM(sp_FloatArray_get(v, i)));
    }
    
    // We should ideally tell Spinel to collect v if it was local, 
    // but here we just rely on its own GC or the fact that it's small.
    return res;
}

static VALUE spinel_calculate_score(VALUE self, VALUE indices_arr) {
    spinel_wrapper_t *wrapper;
    TypedData_Get_Struct(self, spinel_wrapper_t, &spinel_wrapper_type, wrapper);

    sp_IntArray *sp_indices = sp_IntArray_new();
    long len = RARRAY_LEN(indices_arr);
    for (long i = 0; i < len; i++) {
        sp_IntArray_push(sp_indices, NUM2LL(rb_ary_entry(indices_arr, i)));
    }

    mrb_float score = sp_SpinelLogic_calculate_score(wrapper->logic, sp_indices);
    return DBL2NUM(score);
}

void Init_spinel_detector(void) {
    rb_cSpinelDetector = rb_define_class("SpinelDetector", rb_cObject);
    rb_define_alloc_func(rb_cSpinelDetector, spinel_alloc);
    rb_define_method(rb_cSpinelDetector, "initialize", spinel_init, 3);
    rb_define_method(rb_cSpinelDetector, "build_vector", spinel_build_vector, 1);
    rb_define_method(rb_cSpinelDetector, "calculate_score", spinel_calculate_score, 1);
}
