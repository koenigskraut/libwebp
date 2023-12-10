const std = @import("std");
const build_options = @import("build_options");
const webp = struct {
    usingnamespace @import("common_sse2.zig");
    usingnamespace @import("intrinsics.zig");
    usingnamespace @import("lossless.zig");
    usingnamespace @import("lossless_common.zig");
    usingnamespace @import("../utils/utils.zig");
    usingnamespace @import("../webp/format_constants.zig");
};

const __m128i = webp.__m128i;

//------------------------------------------------------------------------------
// Predictor Transform

inline fn ClampedAddSubtractFull_SSE2(c0: u32, c1: u32, c2: u32) u32 {
    const zero = webp._mm_setzero_si128();
    const C0 = webp._mm_unpacklo_epi8(webp._mm_cvtsi32_si128(@bitCast(c0)), zero);
    const C1 = webp._mm_unpacklo_epi8(webp._mm_cvtsi32_si128(@bitCast(c1)), zero);
    const C2 = webp._mm_unpacklo_epi8(webp._mm_cvtsi32_si128(@bitCast(c2)), zero);
    const V1 = webp._mm_add_epi16(C0, C1);
    const V2 = webp._mm_sub_epi16(V1, C2);
    const b = webp._mm_packus_epi16(V2, V2);
    return @bitCast(webp._mm_cvtsi128_si32(b));
}

inline fn ClampedAddSubtractHalf_SSE2(c0: u32, c1: u32, c2: u32) u32 {
    const zero = webp._mm_setzero_si128();
    const C0 = webp._mm_unpacklo_epi8(webp._mm_cvtsi32_si128(@bitCast(c0)), zero);
    const C1 = webp._mm_unpacklo_epi8(webp._mm_cvtsi32_si128(@bitCast(c1)), zero);
    const B0 = webp._mm_unpacklo_epi8(webp._mm_cvtsi32_si128(@bitCast(c2)), zero);
    const avg = webp._mm_add_epi16(C1, C0);
    const A0 = webp._mm_srli_epi16(avg, 1);
    const A1 = webp._mm_sub_epi16(A0, B0);
    const BgtA = webp._mm_cmpgt_epi16(B0, A0);
    const A2 = webp._mm_sub_epi16(A1, BgtA);
    const A3 = webp._mm_srai_epi16(A2, 1);
    const A4 = webp._mm_add_epi16(A0, A3);
    const A5 = webp._mm_packus_epi16(A4, A4);
    return @bitCast(webp._mm_cvtsi128_si32(A5));
}

inline fn Select_SSE2(a: u32, b: u32, c: u32) u32 {
    const zero = webp._mm_setzero_si128();
    const A0 = webp._mm_cvtsi32_si128(@bitCast(a));
    const B0 = webp._mm_cvtsi32_si128(@bitCast(b));
    const C0 = webp._mm_cvtsi32_si128(@bitCast(c));
    const AC0 = webp._mm_subs_epu8(A0, C0);
    const CA0 = webp._mm_subs_epu8(C0, A0);
    const BC0 = webp._mm_subs_epu8(B0, C0);
    const CB0 = webp._mm_subs_epu8(C0, B0);
    const AC = webp._mm_or_si128(AC0, CA0);
    const BC = webp._mm_or_si128(BC0, CB0);
    const pa = webp._mm_unpacklo_epi8(AC, zero); // |a - c|
    const pb = webp._mm_unpacklo_epi8(BC, zero); // |b - c|
    const diff = webp._mm_sub_epi16(pb, pa);
    {
        var out: [8]i16 = undefined;
        webp._mm_storeu_si128(@ptrCast(&out), diff);
        const pa_minus_pb = out[0] +% out[1] +% out[2] +% out[3];
        return if (pa_minus_pb <= 0) a else b;
    }
}

inline fn Average2_m128i(a0: *const __m128i, a1: *const __m128i, avg: *__m128i) void {
    // (a + b) >> 1 = ((a + b + 1) >> 1) - ((a ^ b) & 1)
    const ones = webp._mm_set1_epi8(1);
    const avg1 = webp._mm_avg_epu8(a0.*, a1.*);
    const one = webp._mm_and_si128(webp._mm_xor_si128(a0.*, a1.*), ones);
    avg.* = webp._mm_sub_epi8(avg1, one);
}

inline fn Average2_uint32_SSE2(a0: u32, a1: u32, avg: *__m128i) void {
    // (a + b) >> 1 = ((a + b + 1) >> 1) - ((a ^ b) & 1)
    const ones = webp._mm_set1_epi8(1);
    const A0 = webp._mm_cvtsi32_si128(@bitCast(a0));
    const A1 = webp._mm_cvtsi32_si128(@bitCast(a1));
    const avg1 = webp._mm_avg_epu8(A0, A1);
    const one = webp._mm_and_si128(webp._mm_xor_si128(A0, A1), ones);
    avg.* = webp._mm_sub_epi8(avg1, one);
}

inline fn Average2_uint32_16_SSE2(a0: u32, a1: u32) __m128i {
    const zero = webp._mm_setzero_si128();
    const A0 = webp._mm_unpacklo_epi8(webp._mm_cvtsi32_si128(@bitCast(a0)), zero);
    const A1 = webp._mm_unpacklo_epi8(webp._mm_cvtsi32_si128(@bitCast(a1)), zero);
    const sum = webp._mm_add_epi16(A1, A0);
    return webp._mm_srli_epi16(sum, 1);
}

inline fn Average2_SSE2(a0: u32, a1: u32) u32 {
    var output: __m128i = undefined;
    Average2_uint32_SSE2(a0, a1, &output);
    return @bitCast(webp._mm_cvtsi128_si32(output));
}

inline fn Average3_SSE2(a0: u32, a1: u32, a2: u32) u32 {
    const zero = webp._mm_setzero_si128();
    const avg1 = Average2_uint32_16_SSE2(a0, a2);
    const A1 = webp._mm_unpacklo_epi8(webp._mm_cvtsi32_si128(@bitCast(a1)), zero);
    const sum = webp._mm_add_epi16(avg1, A1);
    const avg2 = webp._mm_srli_epi16(sum, 1);
    const A2 = webp._mm_packus_epi16(avg2, avg2);
    return @bitCast(webp._mm_cvtsi128_si32(A2));
}

inline fn Average4_SSE2(a0: u32, a1: u32, a2: u32, a3: u32) u32 {
    const avg1 = Average2_uint32_16_SSE2(a0, a1);
    const avg2 = Average2_uint32_16_SSE2(a2, a3);
    const sum = webp._mm_add_epi16(avg2, avg1);
    const avg3 = webp._mm_srli_epi16(sum, 1);
    const A0 = webp._mm_packus_epi16(avg3, avg3);
    return @bitCast(webp._mm_cvtsi128_si32(A0));
}

fn Predictor5_SSE2(left: [*c]const u32, top: [*c]const u32) callconv(.C) u32 {
    const pred = Average3_SSE2(left[0], top[0], top[1]);
    return pred;
}

fn Predictor6_SSE2(left: [*c]const u32, top: [*c]const u32) callconv(.C) u32 {
    const pred = Average2_SSE2(left[0], (top - 1)[0]);
    return pred;
}

fn Predictor7_SSE2(left: [*c]const u32, top: [*c]const u32) callconv(.C) u32 {
    const pred = Average2_SSE2(left[0], top[0]);
    return pred;
}

fn Predictor8_SSE2(left: [*c]const u32, top: [*c]const u32) callconv(.C) u32 {
    const pred = Average2_SSE2((top - 1)[0], top[0]);
    _ = left;
    return pred;
}

fn Predictor9_SSE2(left: [*c]const u32, top: [*c]const u32) callconv(.C) u32 {
    const pred = Average2_SSE2(top[0], top[1]);
    _ = left;
    return pred;
}

fn Predictor10_SSE2(left: [*c]const u32, top: [*c]const u32) callconv(.C) u32 {
    const pred = Average4_SSE2(left[0], (top - 1)[0], top[0], top[1]);
    return pred;
}

fn Predictor11_SSE2(left: [*c]const u32, top: [*c]const u32) callconv(.C) u32 {
    const pred = Select_SSE2(top[0], left[0], (top - 1)[0]);
    return pred;
}

fn Predictor12_SSE2(left: [*c]const u32, top: [*c]const u32) callconv(.C) u32 {
    const pred = ClampedAddSubtractFull_SSE2(left[0], top[0], (top - 1)[0]);
    return pred;
}

fn Predictor13_SSE2(left: [*c]const u32, top: [*c]const u32) callconv(.C) u32 {
    const pred = ClampedAddSubtractHalf_SSE2(left[0], top[0], (top - 1)[0]);
    return pred;
}

// Batch versions of those functions.

// Predictor0: ARGB_BLACK.
fn PredictorAdd0_SSE2(in: [*c]const u32, upper: [*c]const u32, num_pixels: c_int, out: [*c]u32) callconv(.C) void {
    _ = upper;
    const black = webp._mm_set1_epi32(@bitCast(@as(u32, webp.ARGB_BLACK)));
    var i: usize = 0;
    while (i + 4 <= num_pixels) : (i += 4) {
        const src = webp._mm_loadu_si128(@ptrCast(in[i..]));
        const res = webp._mm_add_epi8(src, black);
        webp._mm_storeu_si128(@ptrCast(out[i..]), res);
    }
    if (i != num_pixels) {
        webp.VP8LPredictorsAdd_C[0].?(in[i..], null, num_pixels - @as(c_int, @intCast(i)), out[i..]);
    }
}

// Predictor1: left.
fn PredictorAdd1_SSE2(in: [*c]const u32, upper: [*c]const u32, num_pixels: c_int, out: [*c]u32) callconv(.C) void {
    var prev = webp._mm_set1_epi32(@bitCast((out - 1)[0]));
    var i: usize = 0;
    while (i + 4 <= num_pixels) : (i += 4) {
        // a | b | c | d
        const src = webp._mm_loadu_si128(@ptrCast(in[i..]));
        // 0 | a | b | c
        const shift0 = webp._mm_slli_si128(src, 4);
        // a | a + b | b + c | c + d
        const sum0 = webp._mm_add_epi8(src, shift0);
        // 0 | 0 | a | a + b
        const shift1 = webp._mm_slli_si128(sum0, 8);
        // a | a + b | a + b + c | a + b + c + d
        const sum1 = webp._mm_add_epi8(sum0, shift1);
        const res = webp._mm_add_epi8(sum1, prev);
        webp._mm_storeu_si128(@ptrCast(out[i..]), res);
        // replicate prev output on the four lanes
        prev = webp._mm_shuffle_epi32(res, (3 << 0) | (3 << 2) | (3 << 4) | (3 << 6));
    }
    if (i != num_pixels) {
        webp.VP8LPredictorsAdd_C[1].?(in[i..], upper[i..], num_pixels - @as(c_int, @intCast(i)), out[i..]);
    }
}

const PredictorBody = fn (in: [*c]const u32, upper: [*c]const u32, num_pixels: c_int, out: [*c]u32) callconv(.C) void;

// Macro that adds 32-bit integers from IN using mod 256 arithmetic
// per 8 bit channel.
fn GeneratePredictor1(comptime x: usize, comptime upper_offset: usize) PredictorBody {
    return struct {
        fn _(in: [*c]const u32, upper: [*c]const u32, num_pixels: c_int, out: [*c]u32) callconv(.C) void {
            var i: usize = 0;
            while (i + 4 <= num_pixels) : (i += 4) {
                const src = webp._mm_loadu_si128(@ptrCast(in[i..]));
                const other = webp._mm_loadu_si128(@ptrCast(upper[i +% upper_offset ..]));
                const res = webp._mm_add_epi8(src, other);
                webp._mm_storeu_si128(@ptrCast(out[i..]), res);
            }
            if (i != num_pixels) {
                webp.VP8LPredictorsAdd_C[x].?(in[i..], upper[i..], num_pixels - @as(c_int, @intCast(i)), out[i..]);
            }
        }
    }._;
}

// Predictor2: Top.
const PredictorAdd2_SSE2 = GeneratePredictor1(2, 0);
// Predictor3: Top-right.
const PredictorAdd3_SSE2 = GeneratePredictor1(3, 1);
// Predictor4: Top-left.
const PredictorAdd4_SSE2 = GeneratePredictor1(4, @bitCast(@as(isize, -1)));

// Due to averages with integers, values cannot be accumulated in parallel for
// predictors 5 to 7.
const PredictorAdd5_SSE2 = webp.GeneratePredictorAdd(Predictor5_SSE2);
const PredictorAdd6_SSE2 = webp.GeneratePredictorAdd(Predictor6_SSE2);
const PredictorAdd7_SSE2 = webp.GeneratePredictorAdd(Predictor7_SSE2);

fn GeneratePredictor2(comptime x: usize, comptime upper_offset: usize) PredictorBody {
    return struct {
        fn _(in: [*c]const u32, upper: [*c]const u32, num_pixels: c_int, out: [*c]u32) callconv(.C) void {
            var i: usize = 0;
            while (i + 4 <= num_pixels) : (i += 4) {
                const Tother = webp._mm_loadu_si128(@ptrCast(upper[i +% upper_offset ..]));
                const T = webp._mm_loadu_si128(@ptrCast(upper[i..]));
                const src = webp._mm_loadu_si128(@ptrCast(in[i..]));
                var avg: __m128i, var res: __m128i = .{ undefined, undefined };
                Average2_m128i(&T, &Tother, &avg);
                res = webp._mm_add_epi8(avg, src);
                webp._mm_storeu_si128(@ptrCast(out[i..]), res);
            }
            if (i != num_pixels) {
                webp.VP8LPredictorsAdd_C[x].?(in[i..], upper[i..], num_pixels - @as(c_int, @intCast(i)), out[i..]);
            }
        }
    }._;
}

// Predictor8: average TL T.
const PredictorAdd8_SSE2 = GeneratePredictor2(8, @bitCast(@as(isize, -1)));
// Predictor9: average T TR.
const PredictorAdd9_SSE2 = GeneratePredictor2(9, 1);

// Predictor10: average of (average of (L,TL), average of (T, TR)).
inline fn doPred10(L: __m128i, TL: __m128i, avgTTR: __m128i, src: __m128i, out: [*c]u32) __m128i {
    var avgLTL: __m128i, var avg: __m128i = .{ undefined, undefined };
    Average2_m128i(&L, &TL, &avgLTL);
    Average2_m128i(&avgTTR, &avgLTL, &avg);
    const tmp_L = webp._mm_add_epi8(avg, src);
    out[0] = @bitCast(webp._mm_cvtsi128_si32(tmp_L));
    return tmp_L;
}

inline fn doPred10Shift(TL: __m128i, avgTTR: __m128i, src: __m128i) struct { __m128i, __m128i, __m128i } {
    // Rotate the pre-computed values for the next iteration.
    return .{
        webp._mm_srli_si128(TL, 4),
        webp._mm_srli_si128(avgTTR, 4),
        webp._mm_srli_si128(src, 4),
    };
}

fn PredictorAdd10_SSE2(in: [*c]const u32, upper: [*c]const u32, num_pixels: c_int, out: [*c]u32) callconv(.C) void {
    var L = webp._mm_cvtsi32_si128(@bitCast((out - 1)[0]));
    var i: usize = 0;
    while (i + 4 <= num_pixels) : (i += 4) {
        var src = webp._mm_loadu_si128(@ptrCast(in[i..]));
        var TL = webp._mm_loadu_si128(@ptrCast(upper + i - 1));
        const T = webp._mm_loadu_si128(@ptrCast(upper[i..]));
        const TR = webp._mm_loadu_si128(@ptrCast(upper[i + 1 ..]));
        var avgTTR: __m128i = undefined;
        Average2_m128i(&T, &TR, &avgTTR);
        L = doPred10(L, TL, avgTTR, src, out[i + 0 ..]);
        TL, avgTTR, src = doPred10Shift(TL, avgTTR, src);
        L = doPred10(L, TL, avgTTR, src, out[i + 1 ..]);
        TL, avgTTR, src = doPred10Shift(TL, avgTTR, src);
        L = doPred10(L, TL, avgTTR, src, out[i + 2 ..]);
        TL, avgTTR, src = doPred10Shift(TL, avgTTR, src);
        L = doPred10(L, TL, avgTTR, src, out[i + 3 ..]);
    }
    if (i != num_pixels) {
        webp.VP8LPredictorsAdd_C[10].?(in[i..], upper[i..], num_pixels - @as(c_int, @intCast(i)), out[i..]);
    }
}

// Predictor11: select.
inline fn doPred11(L: __m128i, T: __m128i, TL: __m128i, pa: __m128i, src: __m128i, out: [*c]u32) __m128i {
    const L_lo = webp._mm_unpacklo_epi32(L, T);
    const TL_lo = webp._mm_unpacklo_epi32(TL, T);
    const pb = webp._mm_sad_epu8(L_lo, TL_lo); // pb = sum |L-TL|
    const mask = webp._mm_cmpgt_epi32(pb, pa);
    const A = webp._mm_and_si128(mask, L);
    const B = webp._mm_andnot_si128(mask, T);
    const pred = webp._mm_or_si128(A, B); // pred = (pa > b)? L : T
    const tmp_L = webp._mm_add_epi8(src, pred);
    out[0] = @bitCast(webp._mm_cvtsi128_si32(tmp_L));
    return tmp_L;
}

inline fn doPred11Shift(T: __m128i, TL: __m128i, src: __m128i, pa: __m128i) struct { __m128i, __m128i, __m128i, __m128i } {
    // Shift the pre-computed value for the next iteration.
    return .{
        webp._mm_srli_si128(T, 4),
        webp._mm_srli_si128(TL, 4),
        webp._mm_srli_si128(src, 4),
        webp._mm_srli_si128(pa, 4),
    };
}

fn PredictorAdd11_SSE2(in: [*c]const u32, upper: [*c]const u32, num_pixels: c_int, out: [*c]u32) callconv(.C) void {
    var pa: __m128i = undefined;
    var L = webp._mm_cvtsi32_si128(@bitCast((out - 1)[0]));
    var i: usize = 0;
    while (i + 4 <= num_pixels) : (i += 4) {
        var T = webp._mm_loadu_si128(@ptrCast(upper[i..]));
        var TL = webp._mm_loadu_si128(@ptrCast(upper + i - 1));
        var src = webp._mm_loadu_si128(@ptrCast(in[i..]));
        {
            // We can unpack with any value on the upper 32 bits, provided it's the
            // same on both operands (so that their sum of abs diff is zero). Here we
            // use T.
            const T_lo = webp._mm_unpacklo_epi32(T, T);
            const TL_lo = webp._mm_unpacklo_epi32(TL, T);
            const T_hi = webp._mm_unpackhi_epi32(T, T);
            const TL_hi = webp._mm_unpackhi_epi32(TL, T);
            const s_lo = webp._mm_sad_epu8(T_lo, TL_lo);
            const s_hi = webp._mm_sad_epu8(T_hi, TL_hi);
            pa = webp._mm_packs_epi32(s_lo, s_hi); // pa = sum |T-TL|
        }
        L = doPred11(L, T, TL, pa, src, out[i + 0 ..]);
        T, TL, src, pa = doPred11Shift(T, TL, src, pa);
        L = doPred11(L, T, TL, pa, src, out[i + 1 ..]);
        T, TL, src, pa = doPred11Shift(T, TL, src, pa);
        L = doPred11(L, T, TL, pa, src, out[i + 2 ..]);
        T, TL, src, pa = doPred11Shift(T, TL, src, pa);
        L = doPred11(L, T, TL, pa, src, out[i + 3 ..]);
    }
    if (i != num_pixels) {
        webp.VP8LPredictorsAdd_C[11].?(in[i..], upper[i..], num_pixels - @as(c_int, @intCast(i)), out[i..]);
    }
}

// Predictor12: ClampedAddSubtractFull.
inline fn doPred12(L: __m128i, diff: __m128i, src: __m128i, out: [*c]u32) __m128i {
    const all = webp._mm_add_epi16(L, diff);
    const alls = webp._mm_packus_epi16(all, all);
    const res = webp._mm_add_epi8(src, alls);
    out[0] = @bitCast(webp._mm_cvtsi128_si32(res));
    return webp._mm_unpacklo_epi8(res, .{ 0, 0 });
}

fn PredictorAdd12_SSE2(in: [*c]const u32, upper: [*c]const u32, num_pixels: c_int, out: [*c]u32) callconv(.C) void {
    const zero = webp._mm_setzero_si128();
    const L8 = webp._mm_cvtsi32_si128(@bitCast((out - 1)[0]));
    var L = webp._mm_unpacklo_epi8(L8, zero);
    var i: usize = 0;
    while (i + 4 <= num_pixels) : (i += 4) {
        // Load 4 pixels at a time.
        var src = webp._mm_loadu_si128(@ptrCast(in[i..]));
        const T = webp._mm_loadu_si128(@ptrCast(upper[i..]));
        const T_lo = webp._mm_unpacklo_epi8(T, zero);
        const T_hi = webp._mm_unpackhi_epi8(T, zero);
        const TL = webp._mm_loadu_si128(@ptrCast(upper + i - 1));
        const TL_lo = webp._mm_unpacklo_epi8(TL, zero);
        const TL_hi = webp._mm_unpackhi_epi8(TL, zero);
        var diff_lo = webp._mm_sub_epi16(T_lo, TL_lo);
        var diff_hi = webp._mm_sub_epi16(T_hi, TL_hi);
        L = doPred12(L, diff_lo, src, out[i + 0 ..]);
        {
            diff_lo = webp._mm_srli_si128(diff_lo, 8);
            src = webp._mm_srli_si128(src, 4);
        }
        L = doPred12(L, diff_lo, src, out[i + 1 ..]);
        {
            src = webp._mm_srli_si128(src, 4);
        }
        L = doPred12(L, diff_hi, src, out[i + 2 ..]);
        {
            diff_hi = webp._mm_srli_si128(diff_hi, 8);
            src = webp._mm_srli_si128(src, 4);
        }
        L = doPred12(L, diff_hi, src, out[i + 3 ..]);
    }
    if (i != num_pixels) {
        webp.VP8LPredictorsAdd_C[12].?(in[i..], upper[i..], num_pixels - @as(c_int, @intCast(i)), out[i..]);
    }
}

// Due to averages with integers, values cannot be accumulated in parallel for
// predictors 13.
const PredictorAdd13_SSE2 = webp.GeneratePredictorAdd(Predictor13_SSE2);

//------------------------------------------------------------------------------
// Subtract-Green Transform

fn AddGreenToBlueAndRed_SSE2(src: [*c]const u32, num_pixels: c_int, dst: [*c]u32) callconv(.C) void {
    var i: usize = 0;
    while (i + 4 <= num_pixels) : (i += 4) {
        const in = webp._mm_loadu_si128(@ptrCast(src[i..])); // argb
        const A = webp._mm_srli_epi16(in, 8); // 0 a 0 g
        const B = webp._mm_shufflelo_epi16(A, webp._mm_shuffle(.{ 2, 2, 0, 0 }));
        const C = webp._mm_shufflehi_epi16(B, webp._mm_shuffle(.{ 2, 2, 0, 0 })); // 0g0g
        const out = webp._mm_add_epi8(in, C);
        webp._mm_storeu_si128(@ptrCast(dst[i..]), out);
    }
    // fallthrough and finish off with plain-C
    if (i != num_pixels) {
        webp.VP8LAddGreenToBlueAndRed_C(src[i..], num_pixels - @as(c_int, @intCast(i)), dst[i..]);
    }
}

//------------------------------------------------------------------------------
// Color Transform

fn TransformColorInverse_SSE2(m: *const webp.VP8LMultipliers, src: [*c]const u32, num_pixels: c_int, dst: [*c]u32) callconv(.C) void {
    // sign-extended multiplying constants, pre-shifted by 5.
    const S = struct {
        inline fn cst(m_: *const webp.VP8LMultipliers, comptime name: []const u8) u16 {
            const field = @as(i16, @field(m_, name)) << 8; // sign-extend
            return @bitCast(field >> 5);
        }
        inline fn mkCst16(hi: u32, lo: u32) __m128i {
            const a = hi << 16;
            const b = lo & 0xffff;
            return webp._mm_set1_epi32(@bitCast(a | b));
        }
    };

    const mults_rb = S.mkCst16(S.cst(m, "green_to_red_"), S.cst(m, "green_to_blue_"));
    const mults_b2 = S.mkCst16(S.cst(m, "red_to_blue_"), 0);

    const mask_ag = webp._mm_set1_epi32(@bitCast(@as(u32, 0xff00ff00))); // alpha-green masks
    var i: usize = 0;
    while (i + 4 <= num_pixels) : (i += 4) {
        const in = webp._mm_loadu_si128(@ptrCast(src[i..])); // argb
        const A = webp._mm_and_si128(in, mask_ag); // a   0   g   0
        const B = webp._mm_shufflelo_epi16(A, webp._mm_shuffle(.{ 2, 2, 0, 0 }));
        const C = webp._mm_shufflehi_epi16(B, webp._mm_shuffle(.{ 2, 2, 0, 0 })); // g0g0
        const D = webp._mm_mulhi_epi16(C, mults_rb); // x dr  x db1
        const E = webp._mm_add_epi8(in, D); // x r'  x   b'
        const F = webp._mm_slli_epi16(E, 8); // r' 0   b' 0
        const G = webp._mm_mulhi_epi16(F, mults_b2); // x db2  0  0
        const H = webp._mm_srli_epi32(G, 8); // 0  x db2  0
        const I = webp._mm_add_epi8(H, F); // r' x  b'' 0
        const J = webp._mm_srli_epi16(I, 8); // 0  r'  0  b''
        const out = webp._mm_or_si128(J, A);
        webp._mm_storeu_si128(@ptrCast(dst[i..]), out);
    }
    // Fall-back to C-version for left-overs.
    if (i != num_pixels) {
        webp.VP8LTransformColorInverse_C(m, src[i..], num_pixels - @as(c_int, @intCast(i)), dst[i..]);
    }
}

//------------------------------------------------------------------------------
// Color-space conversion functions

fn ConvertBGRAToRGB_SSE2(src: [*c]const u32, num_pixels_: c_int, dst: [*c]u8) callconv(.C) void {
    var in: [*]align(1) const __m128i = @ptrCast(src);
    var out: [*]align(1) __m128i = @ptrCast(dst);
    var num_pixels = num_pixels_;

    while (num_pixels >= 32) {
        // Load the BGRA buffers.
        var in0 = webp._mm_loadu_si128(@ptrCast(in + 0));
        var in1 = webp._mm_loadu_si128(@ptrCast(in + 1));
        var in2 = webp._mm_loadu_si128(@ptrCast(in + 2));
        var in3 = webp._mm_loadu_si128(@ptrCast(in + 3));
        var in4 = webp._mm_loadu_si128(@ptrCast(in + 4));
        var in5 = webp._mm_loadu_si128(@ptrCast(in + 5));
        var in6 = webp._mm_loadu_si128(@ptrCast(in + 6));
        var in7 = webp._mm_loadu_si128(@ptrCast(in + 7));
        webp.VP8L32bToPlanar_SSE2(&in0, &in1, &in2, &in3);
        webp.VP8L32bToPlanar_SSE2(&in4, &in5, &in6, &in7);
        // At this points, in1/in5 contains red only, in2/in6 green only ...
        // Pack the colors in 24b RGB.
        webp.VP8PlanarTo24b_SSE2(&in1, &in5, &in2, &in6, &in3, &in7);
        webp._mm_storeu_si128(@ptrCast(out + 0), in1);
        webp._mm_storeu_si128(@ptrCast(out + 1), in5);
        webp._mm_storeu_si128(@ptrCast(out + 2), in2);
        webp._mm_storeu_si128(@ptrCast(out + 3), in6);
        webp._mm_storeu_si128(@ptrCast(out + 4), in3);
        webp._mm_storeu_si128(@ptrCast(out + 5), in7);
        in += 8;
        out += 6;
        num_pixels -= 32;
    }
    // left-overs
    if (num_pixels > 0) {
        webp.VP8LConvertBGRAToRGB_C(@ptrCast(@alignCast(in)), num_pixels, @ptrCast(out));
    }
}

fn ConvertBGRAToRGBA_SSE2(src: [*c]const u32, num_pixels_: c_int, dst: [*c]u8) callconv(.C) void {
    const red_blue_mask = webp._mm_set1_epi32(@bitCast(@as(u32, 0x00ff00ff)));
    var in: [*]align(1) const __m128i = @ptrCast(src);
    var out: [*]align(1) __m128i = @ptrCast(dst);
    var num_pixels = num_pixels_;
    while (num_pixels >= 8) {
        const A1 = webp._mm_loadu_si128(@ptrCast(in));
        in += 1;
        const A2 = webp._mm_loadu_si128(@ptrCast(in));
        in += 1;
        const B1 = webp._mm_and_si128(A1, red_blue_mask); // R 0 B 0
        const B2 = webp._mm_and_si128(A2, red_blue_mask); // R 0 B 0
        const C1 = webp._mm_andnot_si128(red_blue_mask, A1); // 0 G 0 A
        const C2 = webp._mm_andnot_si128(red_blue_mask, A2); // 0 G 0 A
        const D1 = webp._mm_shufflelo_epi16(B1, webp._mm_shuffle(.{ 2, 3, 0, 1 }));
        const D2 = webp._mm_shufflelo_epi16(B2, webp._mm_shuffle(.{ 2, 3, 0, 1 }));
        const E1 = webp._mm_shufflehi_epi16(D1, webp._mm_shuffle(.{ 2, 3, 0, 1 }));
        const E2 = webp._mm_shufflehi_epi16(D2, webp._mm_shuffle(.{ 2, 3, 0, 1 }));
        const F1 = webp._mm_or_si128(E1, C1);
        const F2 = webp._mm_or_si128(E2, C2);
        webp._mm_storeu_si128(@ptrCast(out), F1);
        out += 1;
        webp._mm_storeu_si128(@ptrCast(out), F2);
        out += 1;
        num_pixels -= 8;
    }
    // left-overs
    if (num_pixels > 0) {
        webp.VP8LConvertBGRAToRGBA_C(@ptrCast(@alignCast(in)), num_pixels, @ptrCast(out));
    }
}

fn ConvertBGRAToRGBA4444_SSE2(src: [*c]const u32, num_pixels_: c_int, dst: [*c]u8) callconv(.C) void {
    const mask_0x0f = webp._mm_set1_epi8(0x0f);
    const mask_0xf0 = webp._mm_set1_epi8(@bitCast(@as(u8, 0xf0)));
    var in: [*]align(1) const __m128i = @ptrCast(src);
    var out: [*]align(1) __m128i = @ptrCast(dst);
    var num_pixels = num_pixels_;
    while (num_pixels >= 8) {
        const bgra0 = webp._mm_loadu_si128(@ptrCast(in)); // bgra0|bgra1|bgra2|bgra3
        in += 1;
        const bgra4 = webp._mm_loadu_si128(@ptrCast(in)); // bgra4|bgra5|bgra6|bgra7
        in += 1;
        const v0l = webp._mm_unpacklo_epi8(bgra0, bgra4); // b0b4g0g4r0r4a0a4...
        const v0h = webp._mm_unpackhi_epi8(bgra0, bgra4); // b2b6g2g6r2r6a2a6...
        const v1l = webp._mm_unpacklo_epi8(v0l, v0h); // b0b2b4b6g0g2g4g6...
        const v1h = webp._mm_unpackhi_epi8(v0l, v0h); // b1b3b5b7g1g3g5g7...
        const v2l = webp._mm_unpacklo_epi8(v1l, v1h); // b0...b7 | g0...g7
        const v2h = webp._mm_unpackhi_epi8(v1l, v1h); // r0...r7 | a0...a7
        const ga0 = webp._mm_unpackhi_epi64(v2l, v2h); // g0...g7 | a0...a7
        const rb0 = webp._mm_unpacklo_epi64(v2h, v2l); // r0...r7 | b0...b7
        const ga1 = webp._mm_srli_epi16(ga0, 4); // g0-|g1-|...|a6-|a7-
        const rb1 = webp._mm_and_si128(rb0, mask_0xf0); // -r0|-r1|...|-b6|-a7
        const ga2 = webp._mm_and_si128(ga1, mask_0x0f); // g0-|g1-|...|a6-|a7-
        const rgba0 = webp._mm_or_si128(ga2, rb1); // rg0..rg7 | ba0..ba7
        const rgba1 = webp._mm_srli_si128(rgba0, 8); // ba0..ba7 | 0
        const rgba = if (build_options.swap_16bit_csp)
            webp._mm_unpacklo_epi8(rgba1, rgba0) // barg0...barg7
        else
            webp._mm_unpacklo_epi8(rgba0, rgba1); // rgba0...rgba7
        webp._mm_storeu_si128(@ptrCast(out), rgba);
        out += 1;
        num_pixels -= 8;
    }
    // left-overs
    if (num_pixels > 0) {
        webp.VP8LConvertBGRAToRGBA4444_C(@ptrCast(@alignCast(in)), num_pixels, @ptrCast(out));
    }
}

fn ConvertBGRAToRGB565_SSE2(src: [*c]const u32, num_pixels_: c_int, dst: [*c]u8) callconv(.C) void {
    const mask_0xe0 = webp._mm_set1_epi8(@bitCast(@as(u8, 0xe0)));
    const mask_0xf8 = webp._mm_set1_epi8(@bitCast(@as(u8, 0xf8)));
    const mask_0x07 = webp._mm_set1_epi8(0x07);
    var in: [*]align(1) const __m128i = @ptrCast(src);
    var out: [*]align(1) __m128i = @ptrCast(dst);
    var num_pixels = num_pixels_;
    while (num_pixels >= 8) {
        const bgra0 = webp._mm_loadu_si128(@ptrCast(in)); // bgra0|bgra1|bgra2|bgra3
        in += 1;
        const bgra4 = webp._mm_loadu_si128(@ptrCast(in)); // bgra4|bgra5|bgra6|bgra7
        in += 1;
        const v0l = webp._mm_unpacklo_epi8(bgra0, bgra4); // b0b4g0g4r0r4a0a4...
        const v0h = webp._mm_unpackhi_epi8(bgra0, bgra4); // b2b6g2g6r2r6a2a6...
        const v1l = webp._mm_unpacklo_epi8(v0l, v0h); // b0b2b4b6g0g2g4g6...
        const v1h = webp._mm_unpackhi_epi8(v0l, v0h); // b1b3b5b7g1g3g5g7...
        const v2l = webp._mm_unpacklo_epi8(v1l, v1h); // b0...b7 | g0...g7
        const v2h = webp._mm_unpackhi_epi8(v1l, v1h); // r0...r7 | a0...a7
        const ga0 = webp._mm_unpackhi_epi64(v2l, v2h); // g0...g7 | a0...a7
        const rb0 = webp._mm_unpacklo_epi64(v2h, v2l); // r0...r7 | b0...b7
        const rb1 = webp._mm_and_si128(rb0, mask_0xf8); // -r0..-r7|-b0..-b7
        const g_lo1 = webp._mm_srli_epi16(ga0, 5);
        const g_lo2 = webp._mm_and_si128(g_lo1, mask_0x07); // g0-...g7-|xx (3b)
        const g_hi1 = webp._mm_slli_epi16(ga0, 3);
        const g_hi2 = webp._mm_and_si128(g_hi1, mask_0xe0); // -g0...-g7|xx (3b)
        const b0 = webp._mm_srli_si128(rb1, 8); // -b0...-b7|0
        const rg1 = webp._mm_or_si128(rb1, g_lo2); // gr0...gr7|xx
        const b1 = webp._mm_srli_epi16(b0, 3);
        const gb1 = webp._mm_or_si128(b1, g_hi2); // bg0...bg7|xx
        const rgba = if (build_options.swap_16bit_csp)
            webp._mm_unpacklo_epi8(gb1, rg1) // rggb0...rggb7
        else
            webp._mm_unpacklo_epi8(rg1, gb1); // bgrb0...bgrb7
        webp._mm_storeu_si128(@ptrCast(out), rgba);
        out += 1;
        num_pixels -= 8;
    }
    // left-overs
    if (num_pixels > 0) {
        webp.VP8LConvertBGRAToRGB565_C(@ptrCast(@alignCast(in)), num_pixels, @ptrCast(out));
    }
}

fn ConvertBGRAToBGR_SSE2(src: [*c]const u32, num_pixels_: c_int, dst_: [*c]u8) callconv(.C) void {
    const mask_l = webp._mm_set_epi32(0, 0x00ffffff, 0, 0x00ffffff);
    const mask_h = webp._mm_set_epi32(0x00ffffff, 0, 0x00ffffff, 0);
    var in: [*]align(1) const __m128i = @ptrCast(src);
    var dst, var num_pixels = .{ dst_, num_pixels_ };
    const end: [*c]const u8 = webp.offsetPtr(dst, num_pixels * 3);
    // the last storel_epi64 below writes 8 bytes starting at offset 18
    while (dst + 26 <= end) {
        const bgra0 = webp._mm_loadu_si128(@ptrCast(in)); // bgra0|bgra1|bgra2|bgra3
        in += 1;
        const bgra4 = webp._mm_loadu_si128(@ptrCast(in)); // bgra4|bgra5|bgra6|bgra7
        in += 1;
        const a0l = webp._mm_and_si128(bgra0, mask_l); // bgr0|0|bgr0|0
        const a4l = webp._mm_and_si128(bgra4, mask_l); // bgr0|0|bgr0|0
        const a0h = webp._mm_and_si128(bgra0, mask_h); // 0|bgr0|0|bgr0
        const a4h = webp._mm_and_si128(bgra4, mask_h); // 0|bgr0|0|bgr0
        const b0h = webp._mm_srli_epi64(a0h, 8); // 000b|gr00|000b|gr00
        const b4h = webp._mm_srli_epi64(a4h, 8); // 000b|gr00|000b|gr00
        const c0 = webp._mm_or_si128(a0l, b0h); // rgbrgb00|rgbrgb00
        const c4 = webp._mm_or_si128(a4l, b4h); // rgbrgb00|rgbrgb00
        const c2 = webp._mm_srli_si128(c0, 8);
        const c6 = webp._mm_srli_si128(c4, 8);
        webp._mm_storel_epi64(@ptrCast(dst + 0), c0);
        webp._mm_storel_epi64(@ptrCast(dst + 6), c2);
        webp._mm_storel_epi64(@ptrCast(dst + 12), c4);
        webp._mm_storel_epi64(@ptrCast(dst + 18), c6);
        dst += 24;
        num_pixels -= 8;
    }
    // left-overs
    if (num_pixels > 0) {
        webp.VP8LConvertBGRAToBGR_C(@ptrCast(@alignCast(in)), num_pixels, dst);
    }
}

//------------------------------------------------------------------------------
// Entry point

pub fn VP8LDspInitSSE2() void {
    webp.VP8LPredictors[5] = &Predictor5_SSE2;
    webp.VP8LPredictors[6] = &Predictor6_SSE2;
    webp.VP8LPredictors[7] = &Predictor7_SSE2;
    webp.VP8LPredictors[8] = &Predictor8_SSE2;
    webp.VP8LPredictors[9] = &Predictor9_SSE2;
    webp.VP8LPredictors[10] = &Predictor10_SSE2;
    webp.VP8LPredictors[11] = &Predictor11_SSE2;
    webp.VP8LPredictors[12] = &Predictor12_SSE2;
    webp.VP8LPredictors[13] = &Predictor13_SSE2;

    webp.VP8LPredictorsAdd[0] = &PredictorAdd0_SSE2;
    webp.VP8LPredictorsAdd[1] = &PredictorAdd1_SSE2;
    webp.VP8LPredictorsAdd[2] = &PredictorAdd2_SSE2;
    webp.VP8LPredictorsAdd[3] = &PredictorAdd3_SSE2;
    webp.VP8LPredictorsAdd[4] = &PredictorAdd4_SSE2;
    webp.VP8LPredictorsAdd[5] = &PredictorAdd5_SSE2;
    webp.VP8LPredictorsAdd[6] = &PredictorAdd6_SSE2;
    webp.VP8LPredictorsAdd[7] = &PredictorAdd7_SSE2;
    webp.VP8LPredictorsAdd[8] = &PredictorAdd8_SSE2;
    webp.VP8LPredictorsAdd[9] = &PredictorAdd9_SSE2;
    webp.VP8LPredictorsAdd[10] = &PredictorAdd10_SSE2;
    webp.VP8LPredictorsAdd[11] = &PredictorAdd11_SSE2;
    webp.VP8LPredictorsAdd[12] = &PredictorAdd12_SSE2;
    webp.VP8LPredictorsAdd[13] = &PredictorAdd13_SSE2;

    webp.VP8LAddGreenToBlueAndRed = &AddGreenToBlueAndRed_SSE2;
    webp.VP8LTransformColorInverse = &TransformColorInverse_SSE2;

    webp.VP8LConvertBGRAToRGB = &ConvertBGRAToRGB_SSE2;
    webp.VP8LConvertBGRAToRGBA = &ConvertBGRAToRGBA_SSE2;
    webp.VP8LConvertBGRAToRGBA4444 = &ConvertBGRAToRGBA4444_SSE2;
    webp.VP8LConvertBGRAToRGB565 = &ConvertBGRAToRGB565_SSE2;
    webp.VP8LConvertBGRAToBGR = &ConvertBGRAToBGR_SSE2;
}
