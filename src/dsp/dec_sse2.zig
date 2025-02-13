const std = @import("std");
const webp = struct {
    usingnamespace @import("common_sse2.zig");
    usingnamespace @import("intrinzic");
    usingnamespace @import("../utils/utils.zig");
};
const dec = @import("dec.zig");

const c_bool = webp.c_bool;
const __m128i = webp.__m128i;
const BPS = @import("dsp.zig").BPS;

//------------------------------------------------------------------------------
// Transforms (Paragraph 14.4)

fn Transform_SSE2(in: [*c]const i16, dst: [*c]u8, do_two: c_bool) callconv(.C) void {
    // This implementation makes use of 16-bit fixed point versions of two
    // multiply constants:
    //    K1 = sqrt(2) * cos (pi/8) ~= 85627 / 2^16
    //    K2 = sqrt(2) * sin (pi/8) ~= 35468 / 2^16
    //
    // To be able to use signed 16-bit integers, we use the following trick to
    // have constants within range:
    // - Associated constants are obtained by subtracting the 16-bit fixed point
    //   version of one:
    //      k = K - (1 << 16)  =>  K = k + (1 << 16)
    //      K1 = 85267  =>  k1 =  20091
    //      K2 = 35468  =>  k2 = -30068
    // - The multiplication of a variable by a constant become the sum of the
    //   variable and the multiplication of that variable by the associated
    //   constant:
    //      (x * K) >> 16 = (x * (k + (1 << 16))) >> 16 = ((x * k ) >> 16) + x
    const k1 = webp._mm_set1_epi16(20091);
    const k2 = webp._mm_set1_epi16(-30068);
    var T0: __m128i = undefined;
    var T1: __m128i = undefined;
    var T2: __m128i = undefined;
    var T3: __m128i = undefined;

    // Load and concatenate the transform coefficients (we'll do two transforms
    // in parallel). In the case of only one transform, the second half of the
    // vectors will just contain random value we'll never use nor store.
    var in0: __m128i = undefined;
    var in1: __m128i = undefined;
    var in2: __m128i = undefined;
    var in3: __m128i = undefined;
    {
        in0 = webp._mm_loadl_epi64(@ptrCast(in[0..]));
        in1 = webp._mm_loadl_epi64(@ptrCast(in[4..]));
        in2 = webp._mm_loadl_epi64(@ptrCast(in[8..]));
        in3 = webp._mm_loadl_epi64(@ptrCast(in[12..]));
        // a00 a10 a20 a30   x x x x
        // a01 a11 a21 a31   x x x x
        // a02 a12 a22 a32   x x x x
        // a03 a13 a23 a33   x x x x
        if (do_two != 0) {
            const inB0 = webp._mm_loadl_epi64(@ptrCast(in[16..]));
            const inB1 = webp._mm_loadl_epi64(@ptrCast(in[20..]));
            const inB2 = webp._mm_loadl_epi64(@ptrCast(in[24..]));
            const inB3 = webp._mm_loadl_epi64(@ptrCast(in[28..]));
            in0 = webp._mm_unpacklo_epi64(in0, inB0);
            in1 = webp._mm_unpacklo_epi64(in1, inB1);
            in2 = webp._mm_unpacklo_epi64(in2, inB2);
            in3 = webp._mm_unpacklo_epi64(in3, inB3);
            // a00 a10 a20 a30   b00 b10 b20 b30
            // a01 a11 a21 a31   b01 b11 b21 b31
            // a02 a12 a22 a32   b02 b12 b22 b32
            // a03 a13 a23 a33   b03 b13 b23 b33
        }
    }

    // Vertical pass and subsequent transpose.
    {
        // First pass, c and d calculations are longer because of the "trick"
        // multiplications.
        const a = webp._mm_add_epi16(in0, in2);
        const b = webp._mm_sub_epi16(in0, in2);
        // c = MUL(in1, K2) - MUL(in3, K1) = MUL(in1, k2) - MUL(in3, k1) + in1 - in3
        const c1 = webp._mm_mulhi_epi16(in1, k2);
        const c2 = webp._mm_mulhi_epi16(in3, k1);
        const c3 = webp._mm_sub_epi16(in1, in3);
        const c4 = webp._mm_sub_epi16(c1, c2);
        const c = webp._mm_add_epi16(c3, c4);
        // d = MUL(in1, K1) + MUL(in3, K2) = MUL(in1, k1) + MUL(in3, k2) + in1 + in3
        const d1 = webp._mm_mulhi_epi16(in1, k1);
        const d2 = webp._mm_mulhi_epi16(in3, k2);
        const d3 = webp._mm_add_epi16(in1, in3);
        const d4 = webp._mm_add_epi16(d1, d2);
        const d = webp._mm_add_epi16(d3, d4);

        // Second pass.
        const tmp0 = webp._mm_add_epi16(a, d);
        const tmp1 = webp._mm_add_epi16(b, c);
        const tmp2 = webp._mm_sub_epi16(b, c);
        const tmp3 = webp._mm_sub_epi16(a, d);

        // Transpose the two 4x4.
        webp.VP8Transpose_2_4x4_16b(&tmp0, &tmp1, &tmp2, &tmp3, &T0, &T1, &T2, &T3);
    }

    // Horizontal pass and subsequent transpose.
    {
        // First pass, c and d calculations are longer because of the "trick"
        // multiplications.
        const four = webp._mm_set1_epi16(4);
        const dc = webp._mm_add_epi16(T0, four);
        const a = webp._mm_add_epi16(dc, T2);
        const b = webp._mm_sub_epi16(dc, T2);
        // c = MUL(T1, K2) - MUL(T3, K1) = MUL(T1, k2) - MUL(T3, k1) + T1 - T3
        const c1 = webp._mm_mulhi_epi16(T1, k2);
        const c2 = webp._mm_mulhi_epi16(T3, k1);
        const c3 = webp._mm_sub_epi16(T1, T3);
        const c4 = webp._mm_sub_epi16(c1, c2);
        const c = webp._mm_add_epi16(c3, c4);
        // d = MUL(T1, K1) + MUL(T3, K2) = MUL(T1, k1) + MUL(T3, k2) + T1 + T3
        const d1 = webp._mm_mulhi_epi16(T1, k1);
        const d2 = webp._mm_mulhi_epi16(T3, k2);
        const d3 = webp._mm_add_epi16(T1, T3);
        const d4 = webp._mm_add_epi16(d1, d2);
        const d = webp._mm_add_epi16(d3, d4);

        // Second pass.
        const tmp0 = webp._mm_add_epi16(a, d);
        const tmp1 = webp._mm_add_epi16(b, c);
        const tmp2 = webp._mm_sub_epi16(b, c);
        const tmp3 = webp._mm_sub_epi16(a, d);
        const shifted0 = webp._mm_srai_epi16(tmp0, 3);
        const shifted1 = webp._mm_srai_epi16(tmp1, 3);
        const shifted2 = webp._mm_srai_epi16(tmp2, 3);
        const shifted3 = webp._mm_srai_epi16(tmp3, 3);

        // Transpose the two 4x4.
        webp.VP8Transpose_2_4x4_16b(&shifted0, &shifted1, &shifted2, &shifted3, &T0, &T1, &T2, &T3);
    }

    // Add inverse transform to 'dst' and store.
    {
        const zero = webp._mm_setzero_si128();
        // Load the reference(s).
        var dst0: __m128i = undefined;
        var dst1: __m128i = undefined;
        var dst2: __m128i = undefined;
        var dst3: __m128i = undefined;
        if (do_two != 0) {
            // Load eight bytes/pixels per line.
            dst0 = webp._mm_loadl_epi64(@ptrCast(dst[0 * BPS ..]));
            dst1 = webp._mm_loadl_epi64(@ptrCast(dst[1 * BPS ..]));
            dst2 = webp._mm_loadl_epi64(@ptrCast(dst[2 * BPS ..]));
            dst3 = webp._mm_loadl_epi64(@ptrCast(dst[3 * BPS ..]));
        } else {
            // Load four bytes/pixels per line.
            dst0 = webp._mm_cvtsi32_si128(webp.WebPMemToInt32(dst[0 * BPS ..]));
            dst1 = webp._mm_cvtsi32_si128(webp.WebPMemToInt32(dst[1 * BPS ..]));
            dst2 = webp._mm_cvtsi32_si128(webp.WebPMemToInt32(dst[2 * BPS ..]));
            dst3 = webp._mm_cvtsi32_si128(webp.WebPMemToInt32(dst[3 * BPS ..]));
        }
        // Convert to 16b.
        dst0 = webp._mm_unpacklo_epi8(dst0, zero);
        dst1 = webp._mm_unpacklo_epi8(dst1, zero);
        dst2 = webp._mm_unpacklo_epi8(dst2, zero);
        dst3 = webp._mm_unpacklo_epi8(dst3, zero);
        // Add the inverse transform(s).
        dst0 = webp._mm_add_epi16(dst0, T0);
        dst1 = webp._mm_add_epi16(dst1, T1);
        dst2 = webp._mm_add_epi16(dst2, T2);
        dst3 = webp._mm_add_epi16(dst3, T3);
        // Unsigned saturate to 8b.
        dst0 = webp._mm_packus_epi16(dst0, dst0);
        dst1 = webp._mm_packus_epi16(dst1, dst1);
        dst2 = webp._mm_packus_epi16(dst2, dst2);
        dst3 = webp._mm_packus_epi16(dst3, dst3);
        // Store the results.
        if (do_two != 0) {
            // Store eight bytes/pixels per line.
            webp._mm_storel_epi64(@ptrCast(dst[0 * BPS ..]), dst0);
            webp._mm_storel_epi64(@ptrCast(dst[1 * BPS ..]), dst1);
            webp._mm_storel_epi64(@ptrCast(dst[2 * BPS ..]), dst2);
            webp._mm_storel_epi64(@ptrCast(dst[3 * BPS ..]), dst3);
        } else {
            // Store four bytes/pixels per line.
            webp.WebPInt32ToMem(dst[0 * BPS ..], webp._mm_cvtsi128_si32(dst0));
            webp.WebPInt32ToMem(dst[1 * BPS ..], webp._mm_cvtsi128_si32(dst1));
            webp.WebPInt32ToMem(dst[2 * BPS ..], webp._mm_cvtsi128_si32(dst2));
            webp.WebPInt32ToMem(dst[3 * BPS ..], webp._mm_cvtsi128_si32(dst3));
        }
    }
}

//------------------------------------------------------------------------------
// Loop Filter (Paragraph 15)

// Compute abs(p - q) = subs(p - q) OR subs(q - p)
inline fn MM_ABS(p: __m128i, q: __m128i) __m128i {
    return webp._mm_or_si128(webp._mm_subs_epu8(q, p), webp._mm_subs_epu8(p, q));
}

// Shift each byte of "x" by 3 bits while preserving by the sign bit.
inline fn SignedShift8b_SSE2(x: *__m128i) void {
    const zero = webp._mm_setzero_si128();
    const lo_0 = webp._mm_unpacklo_epi8(zero, x.*);
    const hi_0 = webp._mm_unpackhi_epi8(zero, x.*);
    const lo_1 = webp._mm_srai_epi16(lo_0, 3 + 8);
    const hi_1 = webp._mm_srai_epi16(hi_0, 3 + 8);
    x.* = webp._mm_packs_epi16(lo_1, hi_1);
}

inline fn FLIP_SIGN_BIT2(a: *__m128i, b: *__m128i) void {
    const sign_bit = webp._mm_set1_epi8(@bitCast(@as(u8, 0x80)));
    a.* = webp._mm_xor_si128(a.*, sign_bit);
    b.* = webp._mm_xor_si128(b.*, sign_bit);
}

inline fn FLIP_SIGN_BIT4(a: *__m128i, b: *__m128i, c: *__m128i, d: *__m128i) void {
    FLIP_SIGN_BIT2(a, b);
    FLIP_SIGN_BIT2(c, d);
}

// input/output is uint8_t
inline fn GetNotHEV_SSE2(p1: *const __m128i, p0: *const __m128i, q0: *const __m128i, q1: *const __m128i, hev_thresh: c_int, not_hev: *__m128i) void {
    const zero = webp._mm_setzero_si128();
    const t_1 = MM_ABS(p1.*, p0.*);
    const t_2 = MM_ABS(q1.*, q0.*);

    const h = webp._mm_set1_epi8(@truncate(hev_thresh));
    const t_max = webp._mm_max_epu8(t_1, t_2);

    const t_max_h = webp._mm_subs_epu8(t_max, h);
    not_hev.* = webp._mm_cmpeq_epi8(t_max_h, zero); // not_hev <= t1 && not_hev <= t2
}

// input pixels are int8_t
inline fn GetBaseDelta_SSE2(p1: *const __m128i, p0: *const __m128i, q0: *const __m128i, q1: *const __m128i, delta: *__m128i) void {
    // beware of addition order, for saturation!
    const p1_q1 = webp._mm_subs_epi8(p1.*, q1.*); // p1 - q1
    const q0_p0 = webp._mm_subs_epi8(q0.*, p0.*); // q0 - p0
    const s1 = webp._mm_adds_epi8(p1_q1, q0_p0); // p1 - q1 + 1 * (q0 - p0)
    const s2 = webp._mm_adds_epi8(q0_p0, s1); // p1 - q1 + 2 * (q0 - p0)
    const s3 = webp._mm_adds_epi8(q0_p0, s2); // p1 - q1 + 3 * (q0 - p0)
    delta.* = s3;
}

// input and output are int8_t
inline fn DoSimpleFilter_SSE2(p0: *__m128i, q0: *__m128i, fl: *const __m128i) void {
    const k3 = webp._mm_set1_epi8(3);
    const k4 = webp._mm_set1_epi8(4);
    var v3 = webp._mm_adds_epi8(fl.*, k3);
    var v4 = webp._mm_adds_epi8(fl.*, k4);

    SignedShift8b_SSE2(&v4); // v4 >> 3
    SignedShift8b_SSE2(&v3); // v3 >> 3
    q0.* = webp._mm_subs_epi8(q0.*, v4); // q0 -= v4
    p0.* = webp._mm_adds_epi8(p0.*, v3); // p0 += v3
}

// Updates values of 2 pixels at MB edge during complex filtering.
// Update operations:
// q = q - delta and p = p + delta; where delta = [(a_hi >> 7), (a_lo >> 7)]
// Pixels 'pi' and 'qi' are int8_t on input, uint8_t on output (sign flip).
inline fn Update2Pixels_SSE2(pi: *__m128i, qi: *__m128i, a0_lo: *const __m128i, a0_hi: *const __m128i) void {
    const a1_lo = webp._mm_srai_epi16(a0_lo.*, 7);
    const a1_hi = webp._mm_srai_epi16(a0_hi.*, 7);
    const delta = webp._mm_packs_epi16(a1_lo, a1_hi);
    pi.* = webp._mm_adds_epi8(pi.*, delta);
    qi.* = webp._mm_subs_epi8(qi.*, delta);
    FLIP_SIGN_BIT2(pi, qi);
}

// input pixels are uint8_t
inline fn NeedsFilter_SSE2(p1: *const __m128i, p0: *const __m128i, q0: *const __m128i, q1: *const __m128i, thresh: c_int, mask: *__m128i) void {
    const m_thresh = webp._mm_set1_epi8(@truncate(@as(i32, thresh)));
    const t1 = MM_ABS(p1.*, q1.*); // abs(p1 - q1)
    const kFE = webp._mm_set1_epi8(@bitCast(@as(u8, 0xFE)));
    const t2 = webp._mm_and_si128(t1, kFE); // set lsb of each byte to zero
    const t3 = webp._mm_srli_epi16(t2, 1); // abs(p1 - q1) / 2

    const t4 = MM_ABS(p0.*, q0.*); // abs(p0 - q0)
    const t5 = webp._mm_adds_epu8(t4, t4); // abs(p0 - q0) * 2
    const t6 = webp._mm_adds_epu8(t5, t3); // abs(p0-q0)*2 + abs(p1-q1)/2

    const t7 = webp._mm_subs_epu8(t6, m_thresh); // mask <= m_thresh
    mask.* = webp._mm_cmpeq_epi8(t7, webp._mm_setzero_si128());
}

//------------------------------------------------------------------------------
// Edge filtering functions

// Applies filter on 2 pixels (p0 and q0)
inline fn DoFilter2_SSE2(p1: *__m128i, p0: *__m128i, q0: *__m128i, q1: *__m128i, thresh: c_int) void {
    const sign_bit = webp._mm_set1_epi8(@bitCast(@as(u8, 0x80)));
    // convert p1/q1 to int8_t (for GetBaseDelta_SSE2)
    const p1s = webp._mm_xor_si128(p1.*, sign_bit);
    const q1s = webp._mm_xor_si128(q1.*, sign_bit);

    var mask: __m128i = undefined;
    var a: __m128i = undefined;
    NeedsFilter_SSE2(p1, p0, q0, q1, thresh, &mask);

    FLIP_SIGN_BIT2(p0, q0);
    GetBaseDelta_SSE2(&p1s, p0, q0, &q1s, &a);
    a = webp._mm_and_si128(a, mask); // mask filter values we don't care about
    DoSimpleFilter_SSE2(p0, q0, &a);
    FLIP_SIGN_BIT2(p0, q0);
}

// Applies filter on 4 pixels (p1, p0, q0 and q1)
inline fn DoFilter4_SSE2(p1: *__m128i, p0: *__m128i, q0: *__m128i, q1: *__m128i, mask: *const __m128i, hev_thresh: c_int) void {
    const zero = webp._mm_setzero_si128();
    const sign_bit = webp._mm_set1_epi8(@bitCast(@as(u8, 0x80)));
    const k64 = webp._mm_set1_epi8(64);
    const k3 = webp._mm_set1_epi8(3);
    const k4 = webp._mm_set1_epi8(4);

    var not_hev: __m128i = undefined;
    // compute hev mask
    GetNotHEV_SSE2(p1, p0, q0, q1, hev_thresh, &not_hev);

    // convert to signed values
    FLIP_SIGN_BIT4(p1, p0, q0, q1);

    var t1 = webp._mm_subs_epi8(p1.*, q1.*); // p1 - q1
    t1 = webp._mm_andnot_si128(not_hev, t1); // hev(p1 - q1)
    var t2 = webp._mm_subs_epi8(q0.*, p0.*); // q0 - p0
    t1 = webp._mm_adds_epi8(t1, t2); // hev(p1 - q1) + 1 * (q0 - p0)
    t1 = webp._mm_adds_epi8(t1, t2); // hev(p1 - q1) + 2 * (q0 - p0)
    t1 = webp._mm_adds_epi8(t1, t2); // hev(p1 - q1) + 3 * (q0 - p0)
    t1 = webp._mm_and_si128(t1, mask.*); // mask filter values we don't care about

    t2 = webp._mm_adds_epi8(t1, k3); // 3 * (q0 - p0) + hev(p1 - q1) + 3
    var t3 = webp._mm_adds_epi8(t1, k4); // 3 * (q0 - p0) + hev(p1 - q1) + 4
    SignedShift8b_SSE2(&t2); // (3 * (q0 - p0) + hev(p1 - q1) + 3) >> 3
    SignedShift8b_SSE2(&t3); // (3 * (q0 - p0) + hev(p1 - q1) + 4) >> 3
    p0.* = webp._mm_adds_epi8(p0.*, t2); // p0 += t2
    q0.* = webp._mm_subs_epi8(q0.*, t3); // q0 -= t3
    FLIP_SIGN_BIT2(p0, q0);

    // this is equivalent to signed (a + 1) >> 1 calculation
    t2 = webp._mm_add_epi8(t3, sign_bit);
    t3 = webp._mm_avg_epu8(t2, zero);
    t3 = webp._mm_sub_epi8(t3, k64);

    t3 = not_hev & t3; // if !hev
    q1.* = webp._mm_subs_epi8(q1.*, t3); // q1 -= t3
    p1.* = webp._mm_adds_epi8(p1.*, t3); // p1 += t3
    FLIP_SIGN_BIT2(p1, q1);
}

// Applies filter on 6 pixels (p2, p1, p0, q0, q1 and q2)
inline fn DoFilter6_SSE2(p2: *__m128i, p1: *__m128i, p0: *__m128i, q0: *__m128i, q1: *__m128i, q2: *__m128i, mask: *const __m128i, hev_thresh: c_int) void {
    const zero = webp._mm_setzero_si128();
    var a: __m128i, var not_hev: __m128i = .{ undefined, undefined };

    // compute hev mask
    GetNotHEV_SSE2(p1, p0, q0, q1, hev_thresh, &not_hev);

    FLIP_SIGN_BIT4(p1, p0, q0, q1);
    FLIP_SIGN_BIT2(p2, q2);
    GetBaseDelta_SSE2(p1, p0, q0, q1, &a);

    { // do simple filter on pixels with hev
        const m = webp._mm_andnot_si128(not_hev, mask.*);
        const f = webp._mm_and_si128(a, m);
        DoSimpleFilter_SSE2(p0, q0, &f);
    }

    { // do strong filter on pixels with not hev
        const k9 = webp._mm_set1_epi16(0x0900);
        const k63 = webp._mm_set1_epi16(63);

        const m = webp._mm_and_si128(not_hev, mask.*);
        const f = webp._mm_and_si128(a, m);

        const f_lo = webp._mm_unpacklo_epi8(zero, f);
        const f_hi = webp._mm_unpackhi_epi8(zero, f);

        const f9_lo = webp._mm_mulhi_epi16(f_lo, k9); // Filter (lo) * 9
        const f9_hi = webp._mm_mulhi_epi16(f_hi, k9); // Filter (hi) * 9

        const a2_lo = webp._mm_add_epi16(f9_lo, k63); // Filter * 9 + 63
        const a2_hi = webp._mm_add_epi16(f9_hi, k63); // Filter * 9 + 63

        const a1_lo = webp._mm_add_epi16(a2_lo, f9_lo); // Filter * 18 + 63
        const a1_hi = webp._mm_add_epi16(a2_hi, f9_hi); // Filter * 18 + 63

        const a0_lo = webp._mm_add_epi16(a1_lo, f9_lo); // Filter * 27 + 63
        const a0_hi = webp._mm_add_epi16(a1_hi, f9_hi); // Filter * 27 + 63

        Update2Pixels_SSE2(p2, q2, &a2_lo, &a2_hi);
        Update2Pixels_SSE2(p1, q1, &a1_lo, &a1_hi);
        Update2Pixels_SSE2(p0, q0, &a0_lo, &a0_hi);
    }
}

// reads 8 rows across a vertical edge.
inline fn Load8x4_SSE2(b: [*c]const u8, stride: c_int, p: *__m128i, q: *__m128i) void {
    // A0 = 63 62 61 60 23 22 21 20 43 42 41 40 03 02 01 00
    // A1 = 73 72 71 70 33 32 31 30 53 52 51 50 13 12 11 10
    const A0 = webp._mm_set_epi32(
        webp.WebPMemToInt32(webp.offsetPtr(b, 6 * stride)),
        webp.WebPMemToInt32(webp.offsetPtr(b, 2 * stride)),
        webp.WebPMemToInt32(webp.offsetPtr(b, 4 * stride)),
        webp.WebPMemToInt32(webp.offsetPtr(b, 0 * stride)),
    );
    const A1 = webp._mm_set_epi32(
        webp.WebPMemToInt32(webp.offsetPtr(b, 7 * stride)),
        webp.WebPMemToInt32(webp.offsetPtr(b, 3 * stride)),
        webp.WebPMemToInt32(webp.offsetPtr(b, 5 * stride)),
        webp.WebPMemToInt32(webp.offsetPtr(b, 1 * stride)),
    );

    // B0 = 53 43 52 42 51 41 50 40 13 03 12 02 11 01 10 00
    // B1 = 73 63 72 62 71 61 70 60 33 23 32 22 31 21 30 20
    const B0 = webp._mm_unpacklo_epi8(A0, A1);
    const B1 = webp._mm_unpackhi_epi8(A0, A1);

    // C0 = 33 23 13 03 32 22 12 02 31 21 11 01 30 20 10 00
    // C1 = 73 63 53 43 72 62 52 42 71 61 51 41 70 60 50 40
    const C0 = webp._mm_unpacklo_epi16(B0, B1);
    const C1 = webp._mm_unpackhi_epi16(B0, B1);

    // *p = 71 61 51 41 31 21 11 01 70 60 50 40 30 20 10 00
    // *q = 73 63 53 43 33 23 13 03 72 62 52 42 32 22 12 02
    p.* = webp._mm_unpacklo_epi32(C0, C1);
    q.* = webp._mm_unpackhi_epi32(C0, C1);
}

inline fn Load16x4_SSE2(r0: [*c]const u8, r8: [*c]const u8, stride: c_int, p1: *__m128i, p0: *__m128i, q0: *__m128i, q1: *__m128i) void {
    // Assume the pixels around the edge (|) are numbered as follows
    //                00 01 | 02 03
    //                10 11 | 12 13
    //                 ...  |  ...
    //                e0 e1 | e2 e3
    //                f0 f1 | f2 f3
    //
    // r0 is pointing to the 0th row (00)
    // r8 is pointing to the 8th row (80)

    // Load
    // p1 = 71 61 51 41 31 21 11 01 70 60 50 40 30 20 10 00
    // q0 = 73 63 53 43 33 23 13 03 72 62 52 42 32 22 12 02
    // p0 = f1 e1 d1 c1 b1 a1 91 81 f0 e0 d0 c0 b0 a0 90 80
    // q1 = f3 e3 d3 c3 b3 a3 93 83 f2 e2 d2 c2 b2 a2 92 82
    Load8x4_SSE2(r0, stride, p1, q0);
    Load8x4_SSE2(r8, stride, p0, q1);

    {
        // p1 = f0 e0 d0 c0 b0 a0 90 80 70 60 50 40 30 20 10 00
        // p0 = f1 e1 d1 c1 b1 a1 91 81 71 61 51 41 31 21 11 01
        // q0 = f2 e2 d2 c2 b2 a2 92 82 72 62 52 42 32 22 12 02
        // q1 = f3 e3 d3 c3 b3 a3 93 83 73 63 53 43 33 23 13 03
        const t1 = p1.*;
        const t2 = q0.*;
        p1.* = webp._mm_unpacklo_epi64(t1, p0.*);
        p0.* = webp._mm_unpackhi_epi64(t1, p0.*);
        q0.* = webp._mm_unpacklo_epi64(t2, q1.*);
        q1.* = webp._mm_unpackhi_epi64(t2, q1.*);
    }
}

inline fn Store4x4_SSE2(x: *__m128i, dst_: [*c]u8, stride: c_int) void {
    var i: u8, var dst = .{ 0, dst_ };
    while (i < 4) : ({
        i += 1;
        dst = webp.offsetPtr(dst, stride);
    }) {
        webp.WebPInt32ToMem(dst, webp._mm_cvtsi128_si32(x.*));
        x.* = webp._mm_srli_si128(x.*, 4);
    }
}

// Transpose back and store
inline fn Store16x4_SSE2(p1: *const __m128i, p0: *const __m128i, q0: *const __m128i, q1: *const __m128i, r0_: [*c]u8, r8_: [*c]u8, stride: c_int) void {
    var r0, var r8 = .{ r0_, r8_ };
    // p0 = 71 70 61 60 51 50 41 40 31 30 21 20 11 10 01 00
    // p1 = f1 f0 e1 e0 d1 d0 c1 c0 b1 b0 a1 a0 91 90 81 80
    var t1 = p0.*;
    var p0_s = webp._mm_unpacklo_epi8(p1.*, t1);
    var p1_s = webp._mm_unpackhi_epi8(p1.*, t1);

    // q0 = 73 72 63 62 53 52 43 42 33 32 23 22 13 12 03 02
    // q1 = f3 f2 e3 e2 d3 d2 c3 c2 b3 b2 a3 a2 93 92 83 82
    t1 = q0.*;
    var q0_s = webp._mm_unpacklo_epi8(t1, q1.*);
    var q1_s = webp._mm_unpackhi_epi8(t1, q1.*);

    // p0 = 33 32 31 30 23 22 21 20 13 12 11 10 03 02 01 00
    // q0 = 73 72 71 70 63 62 61 60 53 52 51 50 43 42 41 40
    t1 = p0_s;
    p0_s = webp._mm_unpacklo_epi16(t1, q0_s);
    q0_s = webp._mm_unpackhi_epi16(t1, q0_s);

    // p1 = b3 b2 b1 b0 a3 a2 a1 a0 93 92 91 90 83 82 81 80
    // q1 = f3 f2 f1 f0 e3 e2 e1 e0 d3 d2 d1 d0 c3 c2 c1 c0
    t1 = p1_s;
    p1_s = webp._mm_unpacklo_epi16(t1, q1_s);
    q1_s = webp._mm_unpackhi_epi16(t1, q1_s);

    Store4x4_SSE2(&p0_s, r0, stride);
    r0 = webp.offsetPtr(r0, 4 * stride);
    Store4x4_SSE2(&q0_s, r0, stride);

    Store4x4_SSE2(&p1_s, r8, stride);
    r8 = webp.offsetPtr(r8, 4 * stride);
    Store4x4_SSE2(&q1_s, r8, stride);
}

//------------------------------------------------------------------------------
// Simple In-loop filtering (Paragraph 15.2)

fn SimpleVFilter16_SSE2(p: [*c]u8, stride: c_int, thresh: c_int) callconv(.C) void {
    // Load
    var p1 = webp._mm_loadu_si128(webp.offsetPtr(p, -2 * stride));
    var p0 = webp._mm_loadu_si128(webp.offsetPtr(p, -stride));
    var q0 = webp._mm_loadu_si128(webp.offsetPtr(p, 0));
    var q1 = webp._mm_loadu_si128(webp.offsetPtr(p, stride));
    // var p1: __m128i = @bitCast(webp.offsetPtr(p, -2 * stride)[0..16].*);
    // var p0: __m128i = @bitCast(webp.offsetPtr(p, -stride)[0..16].*);
    // var q0: __m128i = @bitCast(webp.offsetPtr(p, 0)[0..16].*);
    // var q1: __m128i = @bitCast(webp.offsetPtr(p, stride)[0..16].*);

    DoFilter2_SSE2(&p1, &p0, &q0, &q1, thresh);

    // Store
    webp._mm_storeu_si128(webp.offsetPtr(p, -stride), p0);
    webp._mm_storeu_si128(webp.offsetPtr(p, 0), q0);
    // webp.offsetPtr(p, -stride)[0..16].* = @bitCast(p0);
    // webp.offsetPtr(p, 0)[0..16].* = @bitCast(q0);
}

fn SimpleHFilter16_SSE2(p_: [*c]u8, stride: c_int, thresh: c_int) callconv(.C) void {
    var p = p_;
    var p1: __m128i = undefined;
    var p0: __m128i = undefined;
    var q0: __m128i = undefined;
    var q1: __m128i = undefined;

    p -= 2; // beginning of p1

    Load16x4_SSE2(p, webp.offsetPtr(p, 8 * stride), stride, &p1, &p0, &q0, &q1);
    DoFilter2_SSE2(&p1, &p0, &q0, &q1, thresh);
    Store16x4_SSE2(&p1, &p0, &q0, &q1, p, webp.offsetPtr(p, 8 * stride), stride);
}

fn SimpleVFilter16i_SSE2(p_: [*c]u8, stride: c_int, thresh: c_int) callconv(.C) void {
    var p, var k: u8 = .{ p_, 3 };
    while (k > 0) : (k -= 1) {
        p = webp.offsetPtr(p, 4 * stride);
        SimpleVFilter16_SSE2(p, stride, thresh);
    }
}

fn SimpleHFilter16i_SSE2(p_: [*c]u8, stride: c_int, thresh: c_int) callconv(.C) void {
    var p, var k: u8 = .{ p_, 3 };
    while (k > 0) : (k -= 1) {
        p += 4;
        SimpleHFilter16_SSE2(p, stride, thresh);
    }
}

//------------------------------------------------------------------------------
// Complex In-loop filtering (Paragraph 15.3)

inline fn MAX_DIFF1(p3: __m128i, p2: __m128i, p1: __m128i, p0: __m128i) __m128i {
    var m = MM_ABS(p1, p0);
    m = webp._mm_max_epu8(m, MM_ABS(p3, p2));
    m = webp._mm_max_epu8(m, MM_ABS(p2, p1));
    return m;
}

inline fn MAX_DIFF2(p3: __m128i, p2: __m128i, p1: __m128i, p0: __m128i, m_: __m128i) __m128i {
    var m = webp._mm_max_epu8(m_, MM_ABS(p1, p0));
    m = webp._mm_max_epu8(m, MM_ABS(p3, p2));
    m = webp._mm_max_epu8(m, MM_ABS(p2, p1));
    return m;
}

inline fn LOAD_H_EDGES4(p: [*c]const u8, stride: c_int) struct { __m128i, __m128i, __m128i, __m128i } {
    return .{
        webp._mm_loadu_si128(webp.offsetPtr(p, 0 * stride)),
        webp._mm_loadu_si128(webp.offsetPtr(p, 1 * stride)),
        webp._mm_loadu_si128(webp.offsetPtr(p, 2 * stride)),
        webp._mm_loadu_si128(webp.offsetPtr(p, 3 * stride)),
    };
}

inline fn LOADUV_H_EDGE(u: [*c]const u8, v: [*c]const u8, stride: c_int) __m128i {
    const U: __m128i = webp._mm_loadl_epi64(@ptrCast(webp.offsetPtr(u, stride)));
    const V: __m128i = webp._mm_loadl_epi64(@ptrCast(webp.offsetPtr(v, stride)));
    return webp._mm_unpacklo_epi64(U, V);
}

inline fn LOADUV_H_EDGES4(u: [*c]const u8, v: [*c]const u8, stride: c_int) struct { __m128i, __m128i, __m128i, __m128i } {
    return .{
        LOADUV_H_EDGE(u, v, 0 * stride),
        LOADUV_H_EDGE(u, v, 1 * stride),
        LOADUV_H_EDGE(u, v, 2 * stride),
        LOADUV_H_EDGE(u, v, 3 * stride),
    };
}

inline fn STOREUV(p: __m128i, u: [*c]u8, v: [*c]u8, stride: c_int) void {
    webp._mm_storel_epi64(@ptrCast(webp.offsetPtr(u, stride)), p);
    webp._mm_storel_epi64(@ptrCast(webp.offsetPtr(v, stride)), webp._mm_srli_si128(p, 8));
}

inline fn ComplexMask_SSE2(p1: *const __m128i, p0: *const __m128i, q0: *const __m128i, q1: *const __m128i, thresh: c_int, ithresh: c_int, mask: *__m128i) void {
    const it = webp._mm_set1_epi8(@truncate(ithresh));
    const diff = webp._mm_subs_epu8(mask.*, it);
    const thresh_mask = webp._mm_cmpeq_epi8(diff, webp._mm_setzero_si128());
    var filter_mask: __m128i = undefined;
    NeedsFilter_SSE2(p1, p0, q0, q1, thresh, &filter_mask);
    mask.* = webp._mm_and_si128(thresh_mask, filter_mask);
}

// on macroblock edges
fn VFilter16_SSE2(p: [*c]u8, stride: c_int, thresh: c_int, ithresh: c_int, hev_thresh: c_int) callconv(.C) void {
    // Load p3, p2, p1, p0
    var t1, const p2, const p1, const p0 = LOAD_H_EDGES4(webp.offsetPtr(p, -4 * stride), stride);
    var mask = MAX_DIFF1(t1, p2, p1, p0);

    // Load q0, q1, q2, q3
    const q0, const q1, const q2, t1 = LOAD_H_EDGES4(p, stride);
    mask = MAX_DIFF2(t1, q2, q1, q0, mask);

    ComplexMask_SSE2(&p1, &p0, &q0, &q1, thresh, ithresh, &mask);
    DoFilter6_SSE2(&p2, &p1, &p0, &q0, &q1, &q2, &mask, hev_thresh);

    // Store
    webp.offsetPtr(p, -3 * stride)[0..16].* = @bitCast(p2);
    webp.offsetPtr(p, -2 * stride)[0..16].* = @bitCast(p1);
    webp.offsetPtr(p, -1 * stride)[0..16].* = @bitCast(p0);
    webp.offsetPtr(p, 0 * stride)[0..16].* = @bitCast(q0);
    webp.offsetPtr(p, 1 * stride)[0..16].* = @bitCast(q1);
    webp.offsetPtr(p, 2 * stride)[0..16].* = @bitCast(q2);
}

fn HFilter16_SSE2(p: [*c]u8, stride: c_int, thresh: c_int, ithresh: c_int, hev_thresh: c_int) callconv(.C) void {
    var p3: __m128i, var p2: __m128i, var p1: __m128i, var p0: __m128i, var q0: __m128i, var q1: __m128i, var q2: __m128i, var q3: __m128i = .{undefined} ** 8;

    const b = p - 4;
    Load16x4_SSE2(b, webp.offsetPtr(b, 8 * stride), stride, &p3, &p2, &p1, &p0);
    var mask = MAX_DIFF1(p3, p2, p1, p0);

    Load16x4_SSE2(p, webp.offsetPtr(p, 8 * stride), stride, &q0, &q1, &q2, &q3);
    mask = MAX_DIFF2(q3, q2, q1, q0, mask);

    ComplexMask_SSE2(&p1, &p0, &q0, &q1, thresh, ithresh, &mask);
    DoFilter6_SSE2(&p2, &p1, &p0, &q0, &q1, &q2, &mask, hev_thresh);

    Store16x4_SSE2(&p3, &p2, &p1, &p0, b, webp.offsetPtr(b, 8 * stride), stride);
    Store16x4_SSE2(&q0, &q1, &q2, &q3, p, webp.offsetPtr(p, 8 * stride), stride);
}

// on three inner edges
fn VFilter16i_SSE2(p_: [*c]u8, stride: c_int, thresh: c_int, ithresh: c_int, hev_thresh: c_int) callconv(.C) void {
    var p = p_;
    var p3, var p2, var p1, var p0 = LOAD_H_EDGES4(p, stride); // prologue

    var k: u8 = 3;
    while (k > 0) : (k -= 1) {
        const b = webp.offsetPtr(p, 2 * stride); // beginning of p1
        p = webp.offsetPtr(p, 4 * stride);

        var mask = MAX_DIFF1(p3, p2, p1, p0); // compute partial mask
        p3, p2, const tmp1, const tmp2 = LOAD_H_EDGES4(p, stride);
        mask = MAX_DIFF2(p3, p2, tmp1, tmp2, mask);

        // p3 and p2 are not just temporary variables here: they will be
        // re-used for next span. And q2/q3 will become p1/p0 accordingly.
        ComplexMask_SSE2(&p1, &p0, &p3, &p2, thresh, ithresh, &mask);
        DoFilter4_SSE2(&p1, &p0, &p3, &p2, &mask, hev_thresh);

        // Store
        webp.offsetPtr(b, 0 * stride)[0..16].* = @bitCast(p1);
        webp.offsetPtr(b, 1 * stride)[0..16].* = @bitCast(p0);
        webp.offsetPtr(b, 2 * stride)[0..16].* = @bitCast(p3);
        webp.offsetPtr(b, 3 * stride)[0..16].* = @bitCast(p2);

        // rotate samples
        p1 = tmp1;
        p0 = tmp2;
    }
}

fn HFilter16i_SSE2(p_: [*c]u8, stride: c_int, thresh: c_int, ithresh: c_int, hev_thresh: c_int) callconv(.C) void {
    var p = p_;
    var p3: __m128i, var p2: __m128i, var p1: __m128i, var p0: __m128i = .{undefined} ** 4; // loop invariants

    Load16x4_SSE2(p, webp.offsetPtr(p, 8 * stride), stride, &p3, &p2, &p1, &p0); // prologue

    var k: u8 = 3;
    while (k > 0) : (k -= 1) {
        var tmp1: __m128i, var tmp2: __m128i = .{ undefined, undefined };
        const b = p + 2; // beginning of p1

        p += 4; // beginning of q0 (and next span)

        var mask = MAX_DIFF1(p3, p2, p1, p0); // compute partial mask
        Load16x4_SSE2(p, webp.offsetPtr(p, 8 * stride), stride, &p3, &p2, &tmp1, &tmp2);
        mask = MAX_DIFF2(p3, p2, tmp1, tmp2, mask);

        ComplexMask_SSE2(&p1, &p0, &p3, &p2, thresh, ithresh, &mask);
        DoFilter4_SSE2(&p1, &p0, &p3, &p2, &mask, hev_thresh);

        Store16x4_SSE2(&p1, &p0, &p3, &p2, b, webp.offsetPtr(b, 8 * stride), stride);

        // rotate samples
        p1 = tmp1;
        p0 = tmp2;
    }
}

// 8-pixels wide variant, for chroma filtering
fn VFilter8_SSE2(u: [*c]u8, v: [*c]u8, stride: c_int, thresh: c_int, ithresh: c_int, hev_thresh: c_int) callconv(.C) void {
    // Load p3, p2, p1, p0
    var t1, const p2, const p1, const p0 = LOADUV_H_EDGES4(webp.offsetPtr(u, -4 * stride), webp.offsetPtr(v, -4 * stride), stride);
    var mask = MAX_DIFF1(t1, p2, p1, p0);

    // Load q0, q1, q2, q3
    const q0, const q1, const q2, t1 = LOADUV_H_EDGES4(u, v, stride);
    mask = MAX_DIFF2(t1, q2, q1, q0, mask);

    ComplexMask_SSE2(&p1, &p0, &q0, &q1, thresh, ithresh, &mask);
    DoFilter6_SSE2(&p2, &p1, &p0, &q0, &q1, &q2, &mask, hev_thresh);

    // Store
    STOREUV(p2, u, v, -3 * stride);
    STOREUV(p1, u, v, -2 * stride);
    STOREUV(p0, u, v, -1 * stride);
    STOREUV(q0, u, v, 0 * stride);
    STOREUV(q1, u, v, 1 * stride);
    STOREUV(q2, u, v, 2 * stride);
}

fn HFilter8_SSE2(u: [*c]u8, v: [*c]u8, stride: c_int, thresh: c_int, ithresh: c_int, hev_thresh: c_int) callconv(.C) void {
    var p3: __m128i, var p2: __m128i, var p1: __m128i, var p0: __m128i, var q0: __m128i, var q1: __m128i, var q2: __m128i, var q3: __m128i = .{undefined} ** 8;
    const tu = u - 4;
    const tv = v - 4;
    Load16x4_SSE2(tu, tv, stride, &p3, &p2, &p1, &p0);
    var mask = MAX_DIFF1(p3, p2, p1, p0);

    Load16x4_SSE2(u, v, stride, &q0, &q1, &q2, &q3);
    mask = MAX_DIFF2(q3, q2, q1, q0, mask);

    ComplexMask_SSE2(&p1, &p0, &q0, &q1, thresh, ithresh, &mask);
    DoFilter6_SSE2(&p2, &p1, &p0, &q0, &q1, &q2, &mask, hev_thresh);

    Store16x4_SSE2(&p3, &p2, &p1, &p0, tu, tv, stride);
    Store16x4_SSE2(&q0, &q1, &q2, &q3, u, v, stride);
}

fn VFilter8i_SSE2(u_: [*c]u8, v_: [*c]u8, stride: c_int, thresh: c_int, ithresh: c_int, hev_thresh: c_int) callconv(.C) void {
    var v = v_;
    var u = u_;

    // Load p3, p2, p1, p0
    var t2, var t1, var p1, var p0 = LOADUV_H_EDGES4(u, v, stride);
    var mask = MAX_DIFF1(t2, t1, p1, p0);

    u = webp.offsetPtr(u, 4 * stride);
    v = webp.offsetPtr(v, 4 * stride);

    // Load q0, q1, q2, q3
    var q0, var q1, t1, t2 = LOADUV_H_EDGES4(u, v, stride);
    mask = MAX_DIFF2(t2, t1, q1, q0, mask);

    ComplexMask_SSE2(&p1, &p0, &q0, &q1, thresh, ithresh, &mask);
    DoFilter4_SSE2(&p1, &p0, &q0, &q1, &mask, hev_thresh);

    // Store
    STOREUV(p1, u, v, -2 * stride);
    STOREUV(p0, u, v, -1 * stride);
    STOREUV(q0, u, v, 0 * stride);
    STOREUV(q1, u, v, 1 * stride);
}

fn HFilter8i_SSE2(u_: [*c]u8, v_: [*c]u8, stride: c_int, thresh: c_int, ithresh: c_int, hev_thresh: c_int) callconv(.C) void {
    var v, var u = .{ v_, u_ };
    var t1: __m128i, var t2: __m128i, var p1: __m128i, var p0: __m128i, var q0: __m128i, var q1: __m128i = .{undefined} ** 6;
    Load16x4_SSE2(u, v, stride, &t2, &t1, &p1, &p0); // p3, p2, p1, p0
    var mask = MAX_DIFF1(t2, t1, p1, p0);

    u += 4; // beginning of q0
    v += 4;
    Load16x4_SSE2(u, v, stride, &q0, &q1, &t1, &t2); // q0, q1, q2, q3
    mask = MAX_DIFF2(t2, t1, q1, q0, mask);

    ComplexMask_SSE2(&p1, &p0, &q0, &q1, thresh, ithresh, &mask);
    DoFilter4_SSE2(&p1, &p0, &q0, &q1, &mask, hev_thresh);

    u -= 2; // beginning of p1
    v -= 2;
    Store16x4_SSE2(&p1, &p0, &q0, &q1, u, v, stride);
}

//------------------------------------------------------------------------------
// 4x4 predictions

inline fn DST(dst: [*]u8, comptime x: usize, comptime y: usize) *u8 {
    return &dst[x + y * BPS];
}

inline fn AVG3(a: i32, b: i32, c: i32) u8 {
    return @truncate(@as(u32, @bitCast((a + 2 * b + c + 2) >> 2)));
}

// We use the following 8b-arithmetic tricks:
//     (a + 2 * b + c + 2) >> 2 = (AC + b + 1) >> 1
//   where: AC = (a + c) >> 1 = [(a + c + 1) >> 1] - [(a^c) & 1]
// and:
//     (a + 2 * b + c + 2) >> 2 = (AB + BC + 1) >> 1 - (ab|bc)&lsb
//   where: AC = (a + b + 1) >> 1,   BC = (b + c + 1) >> 1
//   and ab = a ^ b, bc = b ^ c, lsb = (AC^BC)&1

fn VE4_SSE2(dst: [*c]u8) callconv(.C) void { // vertical
    const one = webp._mm_set1_epi8(1);
    const ABCDEFGH = webp._mm_loadl_epi64(@ptrCast(dst - BPS - 1));
    const BCDEFGH0 = webp._mm_srli_si128(ABCDEFGH, 1);
    const CDEFGH00 = webp._mm_srli_si128(ABCDEFGH, 2);
    const a = webp._mm_avg_epu8(ABCDEFGH, CDEFGH00);
    const lsb = webp._mm_and_si128(webp._mm_xor_si128(ABCDEFGH, CDEFGH00), one);
    const b = webp._mm_subs_epu8(a, lsb);
    const avg = webp._mm_avg_epu8(b, BCDEFGH0);
    const vals = webp._mm_cvtsi128_si32(avg);
    for (0..4) |i| {
        webp.WebPInt32ToMem(dst + i * BPS, vals);
    }
}

fn LD4_SSE2(dst: [*c]u8) callconv(.C) void { // Down-Left
    const one = webp._mm_set1_epi8(1);
    const ABCDEFGH = webp._mm_loadl_epi64(@ptrCast(dst - BPS));
    const BCDEFGH0 = webp._mm_srli_si128(ABCDEFGH, 1);
    const CDEFGH00 = webp._mm_srli_si128(ABCDEFGH, 2);
    const CDEFGHH0 = webp._mm_insert_epi16(CDEFGH00, (dst - BPS)[7], 3);
    const avg1 = webp._mm_avg_epu8(ABCDEFGH, CDEFGHH0);
    const lsb = webp._mm_and_si128(webp._mm_xor_si128(ABCDEFGH, CDEFGHH0), one);
    const avg2 = webp._mm_subs_epu8(avg1, lsb);
    const abcdefg = webp._mm_avg_epu8(avg2, BCDEFGH0);
    webp.WebPInt32ToMem(dst + 0 * BPS, webp._mm_cvtsi128_si32(abcdefg));
    webp.WebPInt32ToMem(dst + 1 * BPS, webp._mm_cvtsi128_si32(webp._mm_srli_si128(abcdefg, 1)));
    webp.WebPInt32ToMem(dst + 2 * BPS, webp._mm_cvtsi128_si32(webp._mm_srli_si128(abcdefg, 2)));
    webp.WebPInt32ToMem(dst + 3 * BPS, webp._mm_cvtsi128_si32(webp._mm_srli_si128(abcdefg, 3)));
}

fn VR4_SSE2(dst: [*c]u8) callconv(.C) void { // Vertical-Right
    const one = webp._mm_set1_epi8(1);
    const I: i16 = (dst - 1 + 0 * BPS)[0];
    const J: i16 = (dst - 1 + 1 * BPS)[0];
    const K: i16 = (dst - 1 + 2 * BPS)[0];
    const X: i16 = (dst - 1 - BPS)[0];
    const XABCD = webp._mm_loadl_epi64(@ptrCast(dst - BPS - 1));
    const ABCD0 = webp._mm_srli_si128(XABCD, 1);
    const abcd = webp._mm_avg_epu8(XABCD, ABCD0);
    const _XABCD = webp._mm_slli_si128(XABCD, 1);
    const IXABCD = webp._mm_insert_epi16(_XABCD, (I | (X << 8)), 0);
    const avg1 = webp._mm_avg_epu8(IXABCD, ABCD0);
    const lsb = webp._mm_and_si128(webp._mm_xor_si128(IXABCD, ABCD0), one);
    const avg2 = webp._mm_subs_epu8(avg1, lsb);
    const efgh = webp._mm_avg_epu8(avg2, XABCD);
    webp.WebPInt32ToMem(dst + 0 * BPS, webp._mm_cvtsi128_si32(abcd));
    webp.WebPInt32ToMem(dst + 1 * BPS, webp._mm_cvtsi128_si32(efgh));
    webp.WebPInt32ToMem(dst + 2 * BPS, webp._mm_cvtsi128_si32(webp._mm_slli_si128(abcd, 1)));
    webp.WebPInt32ToMem(dst + 3 * BPS, webp._mm_cvtsi128_si32(webp._mm_slli_si128(efgh, 1)));

    // these two are hard to implement in SSE2, so we keep the C-version:
    DST(dst.?, 0, 2).* = AVG3(J, I, X);
    DST(dst.?, 0, 3).* = AVG3(K, J, I);
}

fn VL4_SSE2(dst: [*c]u8) callconv(.C) void { // Vertical-Left
    const one = webp._mm_set1_epi8(1);
    const ABCDEFGH = webp._mm_loadl_epi64(@ptrCast(dst - BPS));
    const BCDEFGH_ = webp._mm_srli_si128(ABCDEFGH, 1);
    const CDEFGH__ = webp._mm_srli_si128(ABCDEFGH, 2);
    const avg1 = webp._mm_avg_epu8(ABCDEFGH, BCDEFGH_);
    const avg2 = webp._mm_avg_epu8(CDEFGH__, BCDEFGH_);
    const avg3 = webp._mm_avg_epu8(avg1, avg2);
    const lsb1 = webp._mm_and_si128(webp._mm_xor_si128(avg1, avg2), one);
    const ab = webp._mm_xor_si128(ABCDEFGH, BCDEFGH_);
    const bc = webp._mm_xor_si128(CDEFGH__, BCDEFGH_);
    const abbc = webp._mm_or_si128(ab, bc);
    const lsb2 = webp._mm_and_si128(abbc, lsb1);
    const avg4 = webp._mm_subs_epu8(avg3, lsb2);
    const extra_out: u32 = @bitCast(webp._mm_cvtsi128_si32(webp._mm_srli_si128(avg4, 4)));
    webp.WebPInt32ToMem(dst + 0 * BPS, webp._mm_cvtsi128_si32(avg1));
    webp.WebPInt32ToMem(dst + 1 * BPS, webp._mm_cvtsi128_si32(avg4));
    webp.WebPInt32ToMem(dst + 2 * BPS, webp._mm_cvtsi128_si32(webp._mm_srli_si128(avg1, 1)));
    webp.WebPInt32ToMem(dst + 3 * BPS, webp._mm_cvtsi128_si32(webp._mm_srli_si128(avg4, 1)));

    // these two are hard to get and irregular
    DST(dst.?, 3, 2).* = @truncate((extra_out >> 0) & 0xff);
    DST(dst.?, 3, 3).* = @truncate((extra_out >> 8) & 0xff);
}

fn RD4_SSE2(dst: [*c]u8) callconv(.C) void { // Down-right
    const one = webp._mm_set1_epi8(1);
    const XABCD = webp._mm_loadl_epi64(@ptrCast(dst - BPS - 1));
    const ____XABCD = webp._mm_slli_si128(XABCD, 4);
    const I: u32 = (dst - 1 + 0 * BPS)[0];
    const J: u32 = (dst - 1 + 1 * BPS)[0];
    const K: u32 = (dst - 1 + 2 * BPS)[0];
    const L: u32 = (dst - 1 + 3 * BPS)[0];
    const LKJI_____ = webp._mm_cvtsi32_si128(@bitCast(L | (K << 8) | (J << 16) | (I << 24)));
    const LKJIXABCD = webp._mm_or_si128(LKJI_____, ____XABCD);
    const KJIXABCD_ = webp._mm_srli_si128(LKJIXABCD, 1);
    const JIXABCD__ = webp._mm_srli_si128(LKJIXABCD, 2);
    const avg1 = webp._mm_avg_epu8(JIXABCD__, LKJIXABCD);
    const lsb = webp._mm_and_si128(webp._mm_xor_si128(JIXABCD__, LKJIXABCD), one);
    const avg2 = webp._mm_subs_epu8(avg1, lsb);
    const abcdefg = webp._mm_avg_epu8(avg2, KJIXABCD_);
    webp.WebPInt32ToMem(dst + 3 * BPS, webp._mm_cvtsi128_si32(abcdefg));
    webp.WebPInt32ToMem(dst + 2 * BPS, webp._mm_cvtsi128_si32(webp._mm_srli_si128(abcdefg, 1)));
    webp.WebPInt32ToMem(dst + 1 * BPS, webp._mm_cvtsi128_si32(webp._mm_srli_si128(abcdefg, 2)));
    webp.WebPInt32ToMem(dst + 0 * BPS, webp._mm_cvtsi128_si32(webp._mm_srli_si128(abcdefg, 3)));
}

//------------------------------------------------------------------------------
// Luma 16x16

inline fn TrueMotion_SSE2(dst_: [*c]u8, size: c_int) void {
    var dst = dst_;
    const top = dst - BPS;
    const zero = webp._mm_setzero_si128();
    if (size == 4) {
        const top_values = webp._mm_cvtsi32_si128(webp.WebPMemToInt32(top));
        const top_base = webp._mm_unpacklo_epi8(top_values, zero);
        for (0..4) |_| { // y
            defer dst += BPS;
            const val = @as(i16, (dst - 1)[0]) - @as(i16, (top - 1)[0]);
            const base = webp._mm_set1_epi16(val);
            const out = webp._mm_packus_epi16(webp._mm_add_epi16(base, top_base), zero);
            webp.WebPInt32ToMem(dst, webp._mm_cvtsi128_si32(out));
        }
    } else if (size == 8) {
        const top_values = webp._mm_loadl_epi64(@ptrCast(top));
        const top_base = webp._mm_unpacklo_epi8(top_values, zero);
        for (0..8) |_| { // y
            defer dst += BPS;
            const val = @as(i16, (dst - 1)[0]) - @as(i16, (top - 1)[0]);
            const base = webp._mm_set1_epi16(val);
            const out = webp._mm_packus_epi16(webp._mm_add_epi16(base, top_base), zero);
            webp._mm_storel_epi64(@ptrCast(dst), out);
        }
    } else {
        const top_values = webp._mm_loadu_si128(top);
        const top_base_0 = webp._mm_unpacklo_epi8(top_values, zero);
        const top_base_1 = webp._mm_unpackhi_epi8(top_values, zero);
        for (0..16) |_| { // y
            defer dst += BPS;
            const val = @as(i16, (dst - 1)[0]) - @as(i16, (top - 1)[0]);
            const base = webp._mm_set1_epi16(val);
            const out_0 = webp._mm_add_epi16(base, top_base_0);
            const out_1 = webp._mm_add_epi16(base, top_base_1);
            const out = webp._mm_packus_epi16(out_0, out_1);
            dst[0..16].* = @bitCast(out);
        }
    }
}

fn TM4_SSE2(dst: [*c]u8) callconv(.C) void {
    TrueMotion_SSE2(dst, 4);
}

fn TM8uv_SSE2(dst: [*c]u8) callconv(.C) void {
    TrueMotion_SSE2(dst, 8);
}

fn TM16_SSE2(dst: [*c]u8) callconv(.C) void {
    TrueMotion_SSE2(dst, 16);
}

fn VE16_SSE2(dst: [*c]u8) callconv(.C) void {
    const top = webp._mm_loadu_si128(dst - BPS);
    for (0..16) |j| {
        (dst + j * BPS)[0..16].* = @bitCast(top);
    }
}

fn HE16_SSE2(dst_: [*c]u8) callconv(.C) void { // horizontal
    var j: usize, var dst = .{ 16, dst_ };
    while (j > 0) : (j -= 1) {
        const values = webp._mm_set1_epi8(@bitCast((dst - 1)[0]));
        dst[0..16].* = @bitCast(values);
        dst += BPS;
    }
}

inline fn Put16_SSE2(v: u8, dst: [*c]u8) void {
    const values = webp._mm_set1_epi8(@bitCast(v));
    for (0..16) |j| {
        (dst + j * BPS)[0..16].* = @bitCast(values);
    }
}

fn DC16_SSE2(dst: [*c]u8) callconv(.C) void { // DC
    const zero = webp._mm_setzero_si128();
    const top = webp._mm_loadu_si128(dst - BPS);
    const sad8x2 = webp._mm_sad_epu8(top, zero);
    // sum the two sads: sad8x2[0:1] + sad8x2[8:9]
    const sum = webp._mm_add_epi16(sad8x2, webp._mm_shuffle_epi32(sad8x2, 2));
    var left: u32 = 0;
    for (0..16) |j| {
        left += (dst - 1 + j * BPS)[0];
    }
    {
        const DC = @as(u32, @bitCast(webp._mm_cvtsi128_si32(sum))) +% left +% 16;
        Put16_SSE2(@truncate(DC >> 5), dst);
    }
}

fn DC16NoTop_SSE2(dst: [*c]u8) callconv(.C) void { // DC with top samples unavailable
    var DC: u16 = 8;
    for (0..16) |j| {
        DC += (dst - 1 + j * BPS)[0];
    }
    Put16_SSE2(@truncate(DC >> 4), dst);
}

fn DC16NoLeft_SSE2(dst: [*c]u8) callconv(.C) void { // DC with left samples unavailable
    const zero = webp._mm_setzero_si128();
    const top = webp._mm_loadu_si128(@ptrCast(dst - BPS));
    const sad8x2 = webp._mm_sad_epu8(top, zero);
    // sum the two sads: sad8x2[0:1] + sad8x2[8:9]
    const sum = webp._mm_add_epi16(sad8x2, webp._mm_shuffle_epi32(sad8x2, 2));
    const DC = @as(u32, @bitCast(webp._mm_cvtsi128_si32(sum))) +% 8;
    Put16_SSE2(@truncate(DC >> 4), dst);
}

fn DC16NoTopLeft_SSE2(dst: [*c]u8) callconv(.C) void { // DC with no top & left samples
    Put16_SSE2(0x80, dst);
}

//------------------------------------------------------------------------------
// Chroma

fn VE8uv_SSE2(dst: [*c]u8) callconv(.C) void { // vertical
    const top = webp._mm_loadl_epi64(@ptrCast(dst - BPS));
    for (0..8) |j| {
        webp._mm_storel_epi64(@ptrCast(dst + j * BPS), top);
    }
}

// helper for chroma-DC predictions
inline fn Put8x8uv_SSE2(v: u8, dst: [*c]u8) void {
    const values = webp._mm_set1_epi8(@bitCast(v));
    for (0..8) |j| {
        webp._mm_storel_epi64(@ptrCast(dst + j * BPS), values);
    }
}

fn DC8uv_SSE2(dst: [*c]u8) callconv(.C) void { // DC
    const zero = webp._mm_setzero_si128();
    const top = webp._mm_loadl_epi64(@ptrCast(dst - BPS));
    const sum = webp._mm_sad_epu8(top, zero);
    var left: u32 = 0;
    for (0..8) |j| {
        left += (dst - 1 + j * BPS)[0];
    }
    {
        const DC = @as(u32, @bitCast(webp._mm_cvtsi128_si32(sum))) +% left +% 8;
        Put8x8uv_SSE2(@truncate(DC >> 4), dst);
    }
}

fn DC8uvNoLeft_SSE2(dst: [*c]u8) callconv(.C) void { // DC with no left samples
    const zero = webp._mm_setzero_si128();
    const top = webp._mm_loadl_epi64(@ptrCast(dst - BPS));
    const sum = webp._mm_sad_epu8(top, zero);
    const DC = @as(u32, @bitCast(webp._mm_cvtsi128_si32(sum))) +% 4;
    Put8x8uv_SSE2(@truncate(DC >> 3), dst);
}

fn DC8uvNoTop_SSE2(dst: [*c]u8) callconv(.C) void { // DC with no top samples
    var dc0: u32 = 4;
    for (0..8) |i| {
        dc0 += (dst - 1 + i * BPS)[0];
    }
    Put8x8uv_SSE2(@truncate(dc0 >> 3), dst);
}

fn DC8uvNoTopLeft_SSE2(dst: [*c]u8) callconv(.C) void { // DC with nothing
    Put8x8uv_SSE2(0x80, dst);
}

//------------------------------------------------------------------------------
// Entry point

pub fn VP8DspInitSSE2() void {
    dec.VP8Transform = &Transform_SSE2;
    // #if (USE_TRANSFORM_AC3 == 1)
    //     VP8TransformAC3 = TransformAC3_SSE2;
    // #endif

    dec.VP8VFilter16 = &VFilter16_SSE2;
    dec.VP8HFilter16 = &HFilter16_SSE2;
    dec.VP8VFilter8 = &VFilter8_SSE2;
    dec.VP8HFilter8 = &HFilter8_SSE2;
    dec.VP8VFilter16i = &VFilter16i_SSE2;
    dec.VP8HFilter16i = &HFilter16i_SSE2;
    dec.VP8VFilter8i = &VFilter8i_SSE2;
    dec.VP8HFilter8i = &HFilter8i_SSE2;

    dec.VP8SimpleVFilter16 = &SimpleVFilter16_SSE2;
    dec.VP8SimpleHFilter16 = &SimpleHFilter16_SSE2;
    dec.VP8SimpleVFilter16i = &SimpleVFilter16i_SSE2;
    dec.VP8SimpleHFilter16i = &SimpleHFilter16i_SSE2;

    dec.VP8PredLuma4[1] = &TM4_SSE2;
    dec.VP8PredLuma4[2] = &VE4_SSE2;
    dec.VP8PredLuma4[4] = &RD4_SSE2;
    dec.VP8PredLuma4[5] = &VR4_SSE2;
    dec.VP8PredLuma4[6] = &LD4_SSE2;
    dec.VP8PredLuma4[7] = &VL4_SSE2;

    dec.VP8PredLuma16[0] = &DC16_SSE2;
    dec.VP8PredLuma16[1] = &TM16_SSE2;
    dec.VP8PredLuma16[2] = &VE16_SSE2;
    dec.VP8PredLuma16[3] = &HE16_SSE2;
    dec.VP8PredLuma16[4] = &DC16NoTop_SSE2;
    dec.VP8PredLuma16[5] = &DC16NoLeft_SSE2;
    dec.VP8PredLuma16[6] = &DC16NoTopLeft_SSE2;

    dec.VP8PredChroma8[0] = &DC8uv_SSE2;
    dec.VP8PredChroma8[1] = &TM8uv_SSE2;
    dec.VP8PredChroma8[2] = &VE8uv_SSE2;
    dec.VP8PredChroma8[4] = &DC8uvNoTop_SSE2;
    dec.VP8PredChroma8[5] = &DC8uvNoLeft_SSE2;
    dec.VP8PredChroma8[6] = &DC8uvNoTopLeft_SSE2;
}
