const std = @import("std");
const build_options = @import("build_options");
const webp = struct {
    usingnamespace @import("common_sse2.zig");
    usingnamespace @import("intrinzic");
    usingnamespace @import("yuv.zig");
    usingnamespace @import("../utils/utils.zig");
    usingnamespace @import("../webp/decode.zig");
};

const __m128i = webp.__m128i;
const c_bool = webp.c_bool;
const CspMode = webp.ColorspaceMode;

//-----------------------------------------------------------------------------
// Convert spans of 32 pixels to various RGB formats for the fancy upsampler.

// These constants are 14b fixed-point version of ITU-R BT.601 constants.
// R = (19077 * y             + 26149 * v - 14234) >> 6
// G = (19077 * y -  6419 * u - 13320 * v +  8708) >> 6
// B = (19077 * y + 33050 * u             - 17685) >> 6
fn ConvertYUV444ToRGB_SSE2(Y0: *const __m128i, U0: *const __m128i, V0: *const __m128i, R: *__m128i, G: *__m128i, B: *__m128i) void {
    const k19077 = webp._mm_set1_epi16(19077);
    const k26149 = webp._mm_set1_epi16(26149);
    const k14234 = webp._mm_set1_epi16(14234);
    // 33050 doesn't fit in a signed short: only use this with unsigned arithmetic
    const k33050 = webp._mm_set1_epi16(@bitCast(@as(u16, 33050)));
    const k17685 = webp._mm_set1_epi16(17685);
    const k6419 = webp._mm_set1_epi16(6419);
    const k13320 = webp._mm_set1_epi16(13320);
    const k8708 = webp._mm_set1_epi16(8708);

    const Y1 = webp._mm_mulhi_epu16(Y0.*, k19077);

    const R0 = webp._mm_mulhi_epu16(V0.*, k26149);
    const R1 = webp._mm_sub_epi16(Y1, k14234);
    const R2 = webp._mm_add_epi16(R1, R0);

    const G0 = webp._mm_mulhi_epu16(U0.*, k6419);
    const G1 = webp._mm_mulhi_epu16(V0.*, k13320);
    const G2 = webp._mm_add_epi16(Y1, k8708);
    const G3 = webp._mm_add_epi16(G0, G1);
    const G4 = webp._mm_sub_epi16(G2, G3);

    // be careful with the saturated *unsigned* arithmetic here!
    const B0 = webp._mm_mulhi_epu16(U0.*, k33050);
    const B1 = webp._mm_adds_epu16(B0, Y1);
    const B2 = webp._mm_subs_epu16(B1, k17685);

    // use logical shift for B2, which can be larger than 32767
    R.* = webp._mm_srai_epi16(R2, 6); // range: [-14234, 30815]
    G.* = webp._mm_srai_epi16(G4, 6); // range: [-10953, 27710]
    B.* = webp._mm_srli_epi16(B2, 6); // range: [0, 34238]
}

// Load the bytes into the *upper* part of 16b words. That's "<< 8", basically.
inline fn Load_HI_16_SSE2(src: [*c]const u8) __m128i {
    const zero = webp._mm_setzero_si128();
    return webp._mm_unpacklo_epi8(zero, webp._mm_loadl_epi64(@ptrCast(src)));
}

// Load and replicate the U/V samples
inline fn Load_UV_HI_8_SSE2(src: [*c]const u8) __m128i {
    const zero = webp._mm_setzero_si128();
    const tmp0 = webp._mm_cvtsi32_si128(webp.WebPMemToInt32(src));
    const tmp1 = webp._mm_unpacklo_epi8(zero, tmp0);
    return webp._mm_unpacklo_epi16(tmp1, tmp1); // replicate samples
}

// Convert 32 samples of YUV444 to R/G/B
fn YUV444ToRGB_SSE2(y: [*c]const u8, u: [*c]const u8, v: [*c]const u8, R: *__m128i, G: *__m128i, B: *__m128i) void {
    const Y0 = Load_HI_16_SSE2(y);
    const U0 = Load_HI_16_SSE2(u);
    const V0 = Load_HI_16_SSE2(v);
    ConvertYUV444ToRGB_SSE2(&Y0, &U0, &V0, R, G, B);
}

// Convert 32 samples of YUV420 to R/G/B
fn YUV420ToRGB_SSE2(y: [*c]const u8, u: [*c]const u8, v: [*c]const u8, R: *__m128i, G: *__m128i, B: *__m128i) void {
    const Y0 = Load_HI_16_SSE2(y);
    const U0 = Load_UV_HI_8_SSE2(u);
    const V0 = Load_UV_HI_8_SSE2(v);
    ConvertYUV444ToRGB_SSE2(&Y0, &U0, &V0, R, G, B);
}

// Pack R/G/B/A results into 32b output.
inline fn PackAndStore4_SSE2(R: *const __m128i, G: *const __m128i, B: *const __m128i, A: *const __m128i, dst: [*c]u8) void {
    const rb = webp._mm_packus_epi16(R.*, B.*);
    const ga = webp._mm_packus_epi16(G.*, A.*);
    const rg = webp._mm_unpacklo_epi8(rb, ga);
    const ba = webp._mm_unpackhi_epi8(rb, ga);
    const RGBA_lo = webp._mm_unpacklo_epi16(rg, ba);
    const RGBA_hi = webp._mm_unpackhi_epi16(rg, ba);
    webp._mm_storeu_si128(dst + 0, RGBA_lo);
    webp._mm_storeu_si128(dst + 16, RGBA_hi);
}

// Pack R/G/B/A results into 16b output.
inline fn PackAndStore4444_SSE2(R: *const __m128i, G: *const __m128i, B: *const __m128i, A: *const __m128i, dst: [*c]u8) void {
    const rg0 = if (comptime build_options.swap_16bit_csp) webp._mm_packus_epi16(B.*, A.*) else webp._mm_packus_epi16(R.*, G.*);
    const ba0 = if (comptime build_options.swap_16bit_csp) webp._mm_packus_epi16(R.*, G.*) else webp._mm_packus_epi16(B.*, A.*);
    const mask_0xf0 = webp._mm_set1_epi8(@bitCast(@as(u8, 0xf0)));
    const rb1 = webp._mm_unpacklo_epi8(rg0, ba0); // rbrbrbrbrb...
    const ga1 = webp._mm_unpackhi_epi8(rg0, ba0); // gagagagaga...
    const rb2 = webp._mm_and_si128(rb1, mask_0xf0);
    const ga2 = webp._mm_srli_epi16(webp._mm_and_si128(ga1, mask_0xf0), 4);
    const rgba4444 = webp._mm_or_si128(rb2, ga2);
    webp._mm_storeu_si128(dst, rgba4444);
}

// Pack R/G/B results into 16b output.
inline fn PackAndStore565_SSE2(R: *const __m128i, G: *const __m128i, B: *const __m128i, dst: [*c]u8) void {
    const r0 = webp._mm_packus_epi16(R.*, R.*);
    const g0 = webp._mm_packus_epi16(G.*, G.*);
    const b0 = webp._mm_packus_epi16(B.*, B.*);
    const r1 = webp._mm_and_si128(r0, webp._mm_set1_epi8(@bitCast(@as(u8, 0xf8))));
    const b1 = webp._mm_and_si128(webp._mm_srli_epi16(b0, 3), webp._mm_set1_epi8(0x1f));
    const g1 = webp._mm_srli_epi16(webp._mm_and_si128(g0, webp._mm_set1_epi8(@bitCast(@as(u8, 0xe0)))), 5);
    const g2 = webp._mm_slli_epi16(webp._mm_and_si128(g0, webp._mm_set1_epi8(0x1c)), 3);
    const rg = webp._mm_or_si128(r1, g1);
    const gb = webp._mm_or_si128(g2, b1);
    const rgb565 = if (comptime build_options.swap_16bit_csp)
        webp._mm_unpacklo_epi8(gb, rg)
    else
        webp._mm_unpacklo_epi8(rg, gb);
    webp._mm_storeu_si128(dst, rgb565);
}

// Pack the planar buffers
// rrrr... rrrr... gggg... gggg... bbbb... bbbb....
// triplet by triplet in the output buffer rgb as rgbrgbrgbrgb ...
inline fn PlanarTo24b_SSE2(in0: *__m128i, in1: *__m128i, in2: *__m128i, in3: *__m128i, in4: *__m128i, in5: *__m128i, rgb: [*c]u8) void {
    // The input is 6 registers of sixteen 8b but for the sake of explanation,
    // let's take 6 registers of four 8b values.
    // To pack, we will keep taking one every two 8b integer and move it
    // around as follows:
    // Input:
    //   r0r1r2r3 | r4r5r6r7 | g0g1g2g3 | g4g5g6g7 | b0b1b2b3 | b4b5b6b7
    // Split the 6 registers in two sets of 3 registers: the first set as the even
    // 8b bytes, the second the odd ones:
    //   r0r2r4r6 | g0g2g4g6 | b0b2b4b6 | r1r3r5r7 | g1g3g5g7 | b1b3b5b7
    // Repeat the same permutations twice more:
    //   r0r4g0g4 | b0b4r1r5 | g1g5b1b5 | r2r6g2g6 | b2b6r3r7 | g3g7b3b7
    //   r0g0b0r1 | g1b1r2g2 | b2r3g3b3 | r4g4b4r5 | g5b5r6g6 | b6r7g7b7
    webp.VP8PlanarTo24b_SSE2(in0, in1, in2, in3, in4, in5);

    webp._mm_storeu_si128(rgb + 0, in0.*);
    webp._mm_storeu_si128(rgb + 16, in1.*);
    webp._mm_storeu_si128(rgb + 32, in2.*);
    webp._mm_storeu_si128(rgb + 48, in3.*);
    webp._mm_storeu_si128(rgb + 64, in4.*);
    webp._mm_storeu_si128(rgb + 80, in5.*);
}

pub export fn VP8YuvToRgba32_SSE2(y: [*c]const u8, u: [*c]const u8, v: [*c]const u8, dst_: [*c]u8) void {
    var dst, var n: usize = .{ dst_, 0 };
    const kAlpha = webp._mm_set1_epi16(255);
    while (n < 32) : ({
        n += 8;
        dst += 32;
    }) {
        var R: __m128i, var G: __m128i, var B: __m128i = .{undefined} ** 3;
        YUV444ToRGB_SSE2(y + n, u + n, v + n, &R, &G, &B);
        PackAndStore4_SSE2(&R, &G, &B, &kAlpha, dst);
    }
}

pub export fn VP8YuvToBgra32_SSE2(y: [*c]const u8, u: [*c]const u8, v: [*c]const u8, dst_: [*c]u8) void {
    var dst, var n: usize = .{ dst_, 0 };
    const kAlpha = webp._mm_set1_epi16(255);
    while (n < 32) : ({
        n += 8;
        dst += 32;
    }) {
        var R: __m128i, var G: __m128i, var B: __m128i = .{undefined} ** 3;
        YUV444ToRGB_SSE2(y + n, u + n, v + n, &R, &G, &B);
        PackAndStore4_SSE2(&B, &G, &R, &kAlpha, dst);
    }
}

pub export fn VP8YuvToArgb32_SSE2(y: [*c]const u8, u: [*c]const u8, v: [*c]const u8, dst_: [*c]u8) void {
    var dst, var n: usize = .{ dst_, 0 };
    const kAlpha = webp._mm_set1_epi16(255);
    while (n < 32) : ({
        n += 8;
        dst += 32;
    }) {
        var R: __m128i, var G: __m128i, var B: __m128i = .{undefined} ** 3;
        YUV444ToRGB_SSE2(y + n, u + n, v + n, &R, &G, &B);
        PackAndStore4_SSE2(&kAlpha, &R, &G, &B, dst);
    }
}

pub export fn VP8YuvToRgba444432_SSE2(y: [*c]const u8, u: [*c]const u8, v: [*c]const u8, dst_: [*c]u8) void {
    var dst, var n: usize = .{ dst_, 0 };
    const kAlpha = webp._mm_set1_epi16(255);
    while (n < 32) : ({
        n += 8;
        dst += 16;
    }) {
        var R: __m128i, var G: __m128i, var B: __m128i = .{undefined} ** 3;
        YUV444ToRGB_SSE2(y + n, u + n, v + n, &R, &G, &B);
        PackAndStore4444_SSE2(&R, &G, &B, &kAlpha, dst);
    }
}

pub export fn VP8YuvToRgb56532_SSE2(y: [*c]const u8, u: [*c]const u8, v: [*c]const u8, dst_: [*c]u8) void {
    var dst, var n: usize = .{ dst_, 0 };
    while (n < 32) : ({
        n += 8;
        dst += 16;
    }) {
        var R: __m128i, var G: __m128i, var B: __m128i = .{undefined} ** 3;
        YUV444ToRGB_SSE2(y + n, u + n, v + n, &R, &G, &B);
        PackAndStore565_SSE2(&R, &G, &B, dst);
    }
}

pub export fn VP8YuvToRgb32_SSE2(y: [*c]const u8, u: [*c]const u8, v: [*c]const u8, dst: [*c]u8) void {
    var R0: __m128i = undefined;
    var R1: __m128i = undefined;
    var R2: __m128i = undefined;
    var R3: __m128i = undefined;
    var G0: __m128i = undefined;
    var G1: __m128i = undefined;
    var G2: __m128i = undefined;
    var G3: __m128i = undefined;
    var B0: __m128i = undefined;
    var B1: __m128i = undefined;
    var B2: __m128i = undefined;
    var B3: __m128i = undefined;

    YUV444ToRGB_SSE2(y + 0, u + 0, v + 0, &R0, &G0, &B0);
    YUV444ToRGB_SSE2(y + 8, u + 8, v + 8, &R1, &G1, &B1);
    YUV444ToRGB_SSE2(y + 16, u + 16, v + 16, &R2, &G2, &B2);
    YUV444ToRGB_SSE2(y + 24, u + 24, v + 24, &R3, &G3, &B3);

    // Cast to 8b and store as RRRRGGGGBBBB.
    var rgb0 = webp._mm_packus_epi16(R0, R1);
    var rgb1 = webp._mm_packus_epi16(R2, R3);
    var rgb2 = webp._mm_packus_epi16(G0, G1);
    var rgb3 = webp._mm_packus_epi16(G2, G3);
    var rgb4 = webp._mm_packus_epi16(B0, B1);
    var rgb5 = webp._mm_packus_epi16(B2, B3);

    // Pack as RGBRGBRGBRGB.
    PlanarTo24b_SSE2(&rgb0, &rgb1, &rgb2, &rgb3, &rgb4, &rgb5, dst);
}

pub export fn VP8YuvToBgr32_SSE2(y: [*c]const u8, u: [*c]const u8, v: [*c]const u8, dst: [*c]u8) void {
    var R0: __m128i = undefined;
    var R1: __m128i = undefined;
    var R2: __m128i = undefined;
    var R3: __m128i = undefined;
    var G0: __m128i = undefined;
    var G1: __m128i = undefined;
    var G2: __m128i = undefined;
    var G3: __m128i = undefined;
    var B0: __m128i = undefined;
    var B1: __m128i = undefined;
    var B2: __m128i = undefined;
    var B3: __m128i = undefined;

    YUV444ToRGB_SSE2(y + 0, u + 0, v + 0, &R0, &G0, &B0);
    YUV444ToRGB_SSE2(y + 8, u + 8, v + 8, &R1, &G1, &B1);
    YUV444ToRGB_SSE2(y + 16, u + 16, v + 16, &R2, &G2, &B2);
    YUV444ToRGB_SSE2(y + 24, u + 24, v + 24, &R3, &G3, &B3);

    // Cast to 8b and store as BBBBGGGGRRRR.
    var bgr0 = webp._mm_packus_epi16(B0, B1);
    var bgr1 = webp._mm_packus_epi16(B2, B3);
    var bgr2 = webp._mm_packus_epi16(G0, G1);
    var bgr3 = webp._mm_packus_epi16(G2, G3);
    var bgr4 = webp._mm_packus_epi16(R0, R1);
    var bgr5 = webp._mm_packus_epi16(R2, R3);

    // Pack as BGRBGRBGRBGR.
    PlanarTo24b_SSE2(&bgr0, &bgr1, &bgr2, &bgr3, &bgr4, &bgr5, dst);
}

//-----------------------------------------------------------------------------
// Arbitrary-length row conversion functions

fn YuvToRgbaRow_SSE2(y_: [*c]const u8, u_: [*c]const u8, v_: [*c]const u8, dst_: [*c]u8, len: c_int) callconv(.C) void {
    var y, var u, var v, var dst = .{ y_, u_, v_, dst_ };
    const kAlpha = webp._mm_set1_epi16(255);
    var n: usize = 0;
    while (n + 8 <= len) : ({
        n += 8;
        dst += 32;
    }) {
        var R: __m128i, var G: __m128i, var B: __m128i = .{undefined} ** 3;
        YUV420ToRGB_SSE2(y, u, v, &R, &G, &B);
        PackAndStore4_SSE2(&R, &G, &B, &kAlpha, dst);
        y += 8;
        u += 4;
        v += 4;
    }
    while (n < len) : (n += 1) { // Finish off
        webp.VP8YuvToRgba(y[0], u[0], v[0], dst);
        dst += 4;
        y += 1;
        u += (n & 1);
        v += (n & 1);
    }
}

fn YuvToBgraRow_SSE2(y_: [*c]const u8, u_: [*c]const u8, v_: [*c]const u8, dst_: [*c]u8, len: c_int) callconv(.C) void {
    var y, var u, var v, var dst = .{ y_, u_, v_, dst_ };
    const kAlpha = webp._mm_set1_epi16(255);
    var n: usize = 0;
    while (n + 8 <= len) : ({
        n += 8;
        dst += 32;
    }) {
        var R: __m128i, var G: __m128i, var B: __m128i = .{undefined} ** 3;
        YUV420ToRGB_SSE2(y, u, v, &R, &G, &B);
        PackAndStore4_SSE2(&B, &G, &R, &kAlpha, dst);
        y += 8;
        u += 4;
        v += 4;
    }
    while (n < len) : (n += 1) { // Finish off
        webp.VP8YuvToBgra(y[0], u[0], v[0], dst);
        dst += 4;
        y += 1;
        u += (n & 1);
        v += (n & 1);
    }
}

fn YuvToArgbRow_SSE2(y_: [*c]const u8, u_: [*c]const u8, v_: [*c]const u8, dst_: [*c]u8, len: c_int) callconv(.C) void {
    var y, var u, var v, var dst = .{ y_, u_, v_, dst_ };
    const kAlpha = webp._mm_set1_epi16(255);
    var n: usize = 0;
    while (n + 8 <= len) : ({
        n += 8;
        dst += 32;
    }) {
        var R: __m128i, var G: __m128i, var B: __m128i = .{undefined} ** 3;
        YUV420ToRGB_SSE2(y, u, v, &R, &G, &B);
        PackAndStore4_SSE2(&kAlpha, &R, &G, &B, dst);
        y += 8;
        u += 4;
        v += 4;
    }
    while (n < len) : (n += 1) { // Finish off
        webp.VP8YuvToArgb(y[0], u[0], v[0], dst);
        dst += 4;
        y += 1;
        u += (n & 1);
        v += (n & 1);
    }
}

fn YuvToRgbRow_SSE2(y_: [*c]const u8, u_: [*c]const u8, v_: [*c]const u8, dst_: [*c]u8, len: c_int) callconv(.C) void {
    var y, var u, var v, var dst = .{ y_, u_, v_, dst_ };
    var n: usize = 0;
    while (n + 32 <= len) : ({
        n += 32;
        dst += 32 * 3;
    }) {
        var R0: __m128i = undefined;
        var R1: __m128i = undefined;
        var R2: __m128i = undefined;
        var R3: __m128i = undefined;
        var G0: __m128i = undefined;
        var G1: __m128i = undefined;
        var G2: __m128i = undefined;
        var G3: __m128i = undefined;
        var B0: __m128i = undefined;
        var B1: __m128i = undefined;
        var B2: __m128i = undefined;
        var B3: __m128i = undefined;

        YUV420ToRGB_SSE2(y + 0, u + 0, v + 0, &R0, &G0, &B0);
        YUV420ToRGB_SSE2(y + 8, u + 4, v + 4, &R1, &G1, &B1);
        YUV420ToRGB_SSE2(y + 16, u + 8, v + 8, &R2, &G2, &B2);
        YUV420ToRGB_SSE2(y + 24, u + 12, v + 12, &R3, &G3, &B3);

        // Cast to 8b and store as RRRRGGGGBBBB.
        var rgb0 = webp._mm_packus_epi16(R0, R1);
        var rgb1 = webp._mm_packus_epi16(R2, R3);
        var rgb2 = webp._mm_packus_epi16(G0, G1);
        var rgb3 = webp._mm_packus_epi16(G2, G3);
        var rgb4 = webp._mm_packus_epi16(B0, B1);
        var rgb5 = webp._mm_packus_epi16(B2, B3);

        // Pack as RGBRGBRGBRGB.
        PlanarTo24b_SSE2(&rgb0, &rgb1, &rgb2, &rgb3, &rgb4, &rgb5, dst);

        y += 32;
        u += 16;
        v += 16;
    }
    while (n < len) : (n += 1) { // Finish off
        webp.VP8YuvToRgb(y[0], u[0], v[0], dst);
        dst += 3;
        y += 1;
        u += (n & 1);
        v += (n & 1);
    }
}

fn YuvToBgrRow_SSE2(y_: [*c]const u8, u_: [*c]const u8, v_: [*c]const u8, dst_: [*c]u8, len: c_int) callconv(.C) void {
    var y, var u, var v, var dst = .{ y_, u_, v_, dst_ };
    var n: usize = 0;
    while (n + 32 <= len) : ({
        n += 32;
        dst += 32 * 3;
    }) {
        var R0: __m128i = undefined;
        var R1: __m128i = undefined;
        var R2: __m128i = undefined;
        var R3: __m128i = undefined;
        var G0: __m128i = undefined;
        var G1: __m128i = undefined;
        var G2: __m128i = undefined;
        var G3: __m128i = undefined;
        var B0: __m128i = undefined;
        var B1: __m128i = undefined;
        var B2: __m128i = undefined;
        var B3: __m128i = undefined;

        YUV420ToRGB_SSE2(y + 0, u + 0, v + 0, &R0, &G0, &B0);
        YUV420ToRGB_SSE2(y + 8, u + 4, v + 4, &R1, &G1, &B1);
        YUV420ToRGB_SSE2(y + 16, u + 8, v + 8, &R2, &G2, &B2);
        YUV420ToRGB_SSE2(y + 24, u + 12, v + 12, &R3, &G3, &B3);

        // Cast to 8b and store as BBBBGGGGRRRR.
        var bgr0 = webp._mm_packus_epi16(B0, B1);
        var bgr1 = webp._mm_packus_epi16(B2, B3);
        var bgr2 = webp._mm_packus_epi16(G0, G1);
        var bgr3 = webp._mm_packus_epi16(G2, G3);
        var bgr4 = webp._mm_packus_epi16(R0, R1);
        var bgr5 = webp._mm_packus_epi16(R2, R3);

        // Pack as BGRBGRBGRBGR.
        PlanarTo24b_SSE2(&bgr0, &bgr1, &bgr2, &bgr3, &bgr4, &bgr5, dst);

        y += 32;
        u += 16;
        v += 16;
    }
    while (n < len) : (n += 1) { // Finish off
        webp.VP8YuvToBgr(y[0], u[0], v[0], dst);
        dst += 3;
        y += 1;
        u += (n & 1);
        v += (n & 1);
    }
}

//------------------------------------------------------------------------------
// Entry point

pub fn WebPInitSamplersSSE2() void {
    webp.WebPSamplers[@intFromEnum(CspMode.RGB)] = &YuvToRgbRow_SSE2;
    webp.WebPSamplers[@intFromEnum(CspMode.RGBA)] = &YuvToRgbaRow_SSE2;
    webp.WebPSamplers[@intFromEnum(CspMode.BGR)] = &YuvToBgrRow_SSE2;
    webp.WebPSamplers[@intFromEnum(CspMode.BGRA)] = &YuvToBgraRow_SSE2;
    webp.WebPSamplers[@intFromEnum(CspMode.ARGB)] = &YuvToArgbRow_SSE2;
}

//------------------------------------------------------------------------------
// RGB24/32 -> YUV converters

// Load eight 16b-words from *src.
inline fn load16(src: *const anyopaque) __m128i {
    return webp._mm_loadu_si128(@ptrCast(src));
}
// Store either 16b-words into *dst
inline fn store16(v: __m128i, dst: *anyopaque) void {
    webp._mm_storeu_si128(@ptrCast(dst), v);
}

// Function that inserts a value of the second half of the in buffer in between
// every two char of the first half.
inline fn RGB24PackedToPlanarHelper_SSE2(in: []const __m128i, out: []__m128i) void {
    out[0] = webp._mm_unpacklo_epi8(in[0], in[3]);
    out[1] = webp._mm_unpackhi_epi8(in[0], in[3]);
    out[2] = webp._mm_unpacklo_epi8(in[1], in[4]);
    out[3] = webp._mm_unpackhi_epi8(in[1], in[4]);
    out[4] = webp._mm_unpacklo_epi8(in[2], in[5]);
    out[5] = webp._mm_unpackhi_epi8(in[2], in[5]);
}

// Unpack the 8b input rgbrgbrgbrgb ... as contiguous registers:
// rrrr... rrrr... gggg... gggg... bbbb... bbbb....
// Similar to PlanarTo24bHelper(), but in reverse order.
inline fn RGB24PackedToPlanar_SSE2(rgb: [*c]const u8, out: []__m128i) void {
    var tmp_buf: [6]__m128i = undefined;
    var tmp: []__m128i = &tmp_buf;
    tmp[0] = webp._mm_loadu_si128(rgb + 0);
    tmp[1] = webp._mm_loadu_si128(rgb + 16);
    tmp[2] = webp._mm_loadu_si128(rgb + 32);
    tmp[3] = webp._mm_loadu_si128(rgb + 48);
    tmp[4] = webp._mm_loadu_si128(rgb + 64);
    tmp[5] = webp._mm_loadu_si128(rgb + 80);

    RGB24PackedToPlanarHelper_SSE2(tmp, out);
    RGB24PackedToPlanarHelper_SSE2(out, tmp);
    RGB24PackedToPlanarHelper_SSE2(tmp, out);
    RGB24PackedToPlanarHelper_SSE2(out, tmp);
    RGB24PackedToPlanarHelper_SSE2(tmp, out);
}

// Convert 8 packed ARGB to r[], g[], b[]
inline fn RGB32PackedToPlanar_SSE2(argb: [*c]const u32, rgb: []__m128i) void {
    const zero = webp._mm_setzero_si128();
    var a0 = load16(argb + 0);
    var a1 = load16(argb + 4);
    var a2 = load16(argb + 8);
    var a3 = load16(argb + 12);
    webp.VP8L32bToPlanar_SSE2(&a0, &a1, &a2, &a3);
    rgb[0] = webp._mm_unpacklo_epi8(a1, zero);
    rgb[1] = webp._mm_unpackhi_epi8(a1, zero);
    rgb[2] = webp._mm_unpacklo_epi8(a2, zero);
    rgb[3] = webp._mm_unpackhi_epi8(a2, zero);
    rgb[4] = webp._mm_unpacklo_epi8(a3, zero);
    rgb[5] = webp._mm_unpackhi_epi8(a3, zero);
}

// This macro computes (RG * MULT_RG + GB * MULT_GB + ROUNDER) >> DESCALE_FIX
// It's a macro and not a function because we need to use immediate values with
// srai_epi32, e.g.
inline fn transform(rg_lo: __m128i, rg_hi: __m128i, gb_lo: __m128i, gb_hi: __m128i, mult_rg: __m128i, mult_gb: __m128i, rounder: __m128i, descale_fix: u32) __m128i {
    const V0_lo = webp._mm_madd_epi16(rg_lo, mult_rg);
    const V0_hi = webp._mm_madd_epi16(rg_hi, mult_rg);
    const V1_lo = webp._mm_madd_epi16(gb_lo, mult_gb);
    const V1_hi = webp._mm_madd_epi16(gb_hi, mult_gb);
    const V2_lo = webp._mm_add_epi32(V0_lo, V1_lo);
    const V2_hi = webp._mm_add_epi32(V0_hi, V1_hi);
    const V3_lo = webp._mm_add_epi32(V2_lo, rounder);
    const V3_hi = webp._mm_add_epi32(V2_hi, rounder);
    const V5_lo = webp._mm_srai_epi32(V3_lo, descale_fix);
    const V5_hi = webp._mm_srai_epi32(V3_hi, descale_fix);
    return webp._mm_packs_epi32(V5_lo, V5_hi);
}

inline fn mkCst16(A: i16, B: i16) __m128i {
    return webp._mm_set_epi16(B, A, B, A, B, A, B, A);
}
inline fn ConvertRGBToY_SSE2(R: *const __m128i, G: *const __m128i, B: *const __m128i, Y: *__m128i) void {
    const kRG_y = mkCst16(16839, 33059 - 16384);
    const kGB_y = mkCst16(16384, 6420);
    const kHALF_Y = webp._mm_set1_epi32((16 << webp.YUV_FIX) + webp.YUV_HALF);

    const RG_lo = webp._mm_unpacklo_epi16(R.*, G.*);
    const RG_hi = webp._mm_unpackhi_epi16(R.*, G.*);
    const GB_lo = webp._mm_unpacklo_epi16(G.*, B.*);
    const GB_hi = webp._mm_unpackhi_epi16(G.*, B.*);
    Y.* = transform(RG_lo, RG_hi, GB_lo, GB_hi, kRG_y, kGB_y, kHALF_Y, webp.YUV_FIX);
}

inline fn ConvertRGBToUV_SSE2(R: *const __m128i, G: *const __m128i, B: *const __m128i, U: *__m128i, V: *__m128i) void {
    const kRG_u = mkCst16(-9719, -19081);
    const kGB_u = mkCst16(0, 28800);
    const kRG_v = mkCst16(28800, 0);
    const kGB_v = mkCst16(-24116, -4684);
    const kHALF_UV = webp._mm_set1_epi32(((128 << webp.YUV_FIX) + webp.YUV_HALF) << 2);

    const RG_lo = webp._mm_unpacklo_epi16(R.*, G.*);
    const RG_hi = webp._mm_unpackhi_epi16(R.*, G.*);
    const GB_lo = webp._mm_unpacklo_epi16(G.*, B.*);
    const GB_hi = webp._mm_unpackhi_epi16(G.*, B.*);
    U.* = transform(RG_lo, RG_hi, GB_lo, GB_hi, kRG_u, kGB_u, kHALF_UV, webp.YUV_FIX + 2);
    V.* = transform(RG_lo, RG_hi, GB_lo, GB_hi, kRG_v, kGB_v, kHALF_UV, webp.YUV_FIX + 2);
}

fn ConvertRGB24ToY_SSE2(rgb_: [*c]const u8, y: [*c]u8, width: c_int) callconv(.C) void {
    var rgb = rgb_;
    const max_width = width & ~@as(c_int, 31);
    var i: usize = 0;
    while (i < max_width) : (rgb += 3 * 16 * 2) {
        var rgb_plane: [6]__m128i = undefined;

        RGB24PackedToPlanar_SSE2(rgb, &rgb_plane);

        var j: usize = 0;
        while (j < 2) : ({
            j += 1;
            i += 16;
        }) {
            const zero = webp._mm_setzero_si128();
            var Y0: __m128i, var Y1: __m128i = .{ undefined, undefined };

            // Convert to 16-bit Y.
            var r = webp._mm_unpacklo_epi8(rgb_plane[0 + j], zero);
            var g = webp._mm_unpacklo_epi8(rgb_plane[2 + j], zero);
            var b = webp._mm_unpacklo_epi8(rgb_plane[4 + j], zero);
            ConvertRGBToY_SSE2(&r, &g, &b, &Y0);

            // Convert to 16-bit Y.
            r = webp._mm_unpackhi_epi8(rgb_plane[0 + j], zero);
            g = webp._mm_unpackhi_epi8(rgb_plane[2 + j], zero);
            b = webp._mm_unpackhi_epi8(rgb_plane[4 + j], zero);
            ConvertRGBToY_SSE2(&r, &g, &b, &Y1);

            // Cast to 8-bit and store.
            store16(webp._mm_packus_epi16(Y0, Y1), y + i);
        }
    }
    while (i < width) : ({
        i += 1;
        rgb += 3;
    }) { // left-over
        y[i] = webp.VP8RGBToY(rgb[0], rgb[1], rgb[2], webp.YUV_HALF);
    }
}

fn ConvertBGR24ToY_SSE2(bgr_: [*c]const u8, y: [*c]u8, width: c_int) callconv(.C) void {
    var bgr = bgr_;
    const max_width = width & ~@as(c_int, 31);
    var i: usize = 0;
    while (i < max_width) : (bgr += 3 * 16 * 2) {
        var bgr_plane: [6]__m128i = undefined;

        RGB24PackedToPlanar_SSE2(bgr, &bgr_plane);

        var j: usize = 0;
        while (j < 2) : ({
            j += 1;
            i += 16;
        }) {
            const zero = webp._mm_setzero_si128();
            var Y0: __m128i, var Y1: __m128i = .{ undefined, undefined };

            // Convert to 16-bit Y.
            var b = webp._mm_unpacklo_epi8(bgr_plane[0 + j], zero);
            var g = webp._mm_unpacklo_epi8(bgr_plane[2 + j], zero);
            var r = webp._mm_unpacklo_epi8(bgr_plane[4 + j], zero);
            ConvertRGBToY_SSE2(&r, &g, &b, &Y0);

            // Convert to 16-bit Y.
            b = webp._mm_unpackhi_epi8(bgr_plane[0 + j], zero);
            g = webp._mm_unpackhi_epi8(bgr_plane[2 + j], zero);
            r = webp._mm_unpackhi_epi8(bgr_plane[4 + j], zero);
            ConvertRGBToY_SSE2(&r, &g, &b, &Y1);

            // Cast to 8-bit and store.
            store16(webp._mm_packus_epi16(Y0, Y1), y + i);
        }
    }
    while (i < width) : ({
        i += 1;
        bgr += 3;
    }) { // left-over
        y[i] = webp.VP8RGBToY(bgr[2], bgr[1], bgr[0], webp.YUV_HALF);
    }
}

fn ConvertARGBToY_SSE2(argb: [*c]const u32, y: [*c]u8, width: c_int) callconv(.C) void {
    const max_width = width & ~@as(c_int, 15);
    var i: usize = 0;
    while (i < max_width) : (i += 16) {
        var Y0: __m128i, var Y1: __m128i, var rgb: [6]__m128i = .{undefined} ** 3;
        RGB32PackedToPlanar_SSE2(argb[i..], &rgb);
        ConvertRGBToY_SSE2(&rgb[0], &rgb[2], &rgb[4], &Y0);
        ConvertRGBToY_SSE2(&rgb[1], &rgb[3], &rgb[5], &Y1);
        store16(webp._mm_packus_epi16(Y0, Y1), y + i);
    }
    while (i < width) : (i += 1) { // left-over
        const p = argb[i];
        y[i] = webp.VP8RGBToY((p >> 16) & 0xff, (p >> 8) & 0xff, (p >> 0) & 0xff, webp.YUV_HALF);
    }
}

// Horizontal add (doubled) of two 16b values, result is 16b.
// in: A | B | C | D | ... -> out: 2*(A+B) | 2*(C+D) | ...
fn HorizontalAddPack_SSE2(A: *const __m128i, B: *const __m128i, out: *__m128i) void {
    const k2 = webp._mm_set1_epi16(2);
    const C = webp._mm_madd_epi16(A.*, k2);
    const D = webp._mm_madd_epi16(B.*, k2);
    out.* = webp._mm_packs_epi32(C, D);
}

fn ConvertARGBToUV_SSE2(argb: [*c]const u32, u_: [*c]u8, v_: [*c]u8, src_width: c_int, do_store: c_bool) callconv(.C) void {
    var u, var v = .{ u_, v_ };
    const max_width = src_width & ~@as(c_int, 31);
    var i: usize = 0;
    while (i < max_width) : ({
        i += 32;
        u += 16;
        v += 16;
    }) {
        var rgb: [6]__m128i, var U0: __m128i, var V0: __m128i, var U1: __m128i, var V1: __m128i = .{undefined} ** 5;
        RGB32PackedToPlanar_SSE2(argb[i..], &rgb);
        HorizontalAddPack_SSE2(&rgb[0], &rgb[1], &rgb[0]);
        HorizontalAddPack_SSE2(&rgb[2], &rgb[3], &rgb[2]);
        HorizontalAddPack_SSE2(&rgb[4], &rgb[5], &rgb[4]);
        ConvertRGBToUV_SSE2(&rgb[0], &rgb[2], &rgb[4], &U0, &V0);

        RGB32PackedToPlanar_SSE2(argb[i + 16 ..], &rgb);
        HorizontalAddPack_SSE2(&rgb[0], &rgb[1], &rgb[0]);
        HorizontalAddPack_SSE2(&rgb[2], &rgb[3], &rgb[2]);
        HorizontalAddPack_SSE2(&rgb[4], &rgb[5], &rgb[4]);
        ConvertRGBToUV_SSE2(&rgb[0], &rgb[2], &rgb[4], &U1, &V1);

        U0 = webp._mm_packus_epi16(U0, U1);
        V0 = webp._mm_packus_epi16(V0, V1);
        if (!(do_store != 0)) {
            const prev_u = load16(u);
            const prev_v = load16(v);
            U0 = webp._mm_avg_epu8(U0, prev_u);
            V0 = webp._mm_avg_epu8(V0, prev_v);
        }
        store16(U0, u);
        store16(V0, v);
    }
    if (i < src_width) { // left-over
        webp.WebPConvertARGBToUV_C(argb + i, u, v, src_width - @as(c_int, @intCast(i)), do_store);
    }
}

// Convert 16 packed ARGB 16b-values to r[], g[], b[]
inline fn RGBA32PackedToPlanar_16b_SSE2(rgbx: [*c]const u16, r: *__m128i, g: *__m128i, b: *__m128i) void {
    const in0 = load16(rgbx + 0); // r0 | g0 | b0 |x| r1 | g1 | b1 |x
    const in1 = load16(rgbx + 8); // r2 | g2 | b2 |x| r3 | g3 | b3 |x
    const in2 = load16(rgbx + 16); // r4 | ...
    const in3 = load16(rgbx + 24); // r6 | ...
    // column-wise transpose
    const A0 = webp._mm_unpacklo_epi16(in0, in1);
    const A1 = webp._mm_unpackhi_epi16(in0, in1);
    const A2 = webp._mm_unpacklo_epi16(in2, in3);
    const A3 = webp._mm_unpackhi_epi16(in2, in3);
    const B0 = webp._mm_unpacklo_epi16(A0, A1); // r0 r1 r2 r3 | g0 g1 ..
    const B1 = webp._mm_unpackhi_epi16(A0, A1); // b0 b1 b2 b3 | x x x x
    const B2 = webp._mm_unpacklo_epi16(A2, A3); // r4 r5 r6 r7 | g4 g5 ..
    const B3 = webp._mm_unpackhi_epi16(A2, A3); // b4 b5 b6 b7 | x x x x
    r.* = webp._mm_unpacklo_epi64(B0, B2);
    g.* = webp._mm_unpackhi_epi64(B0, B2);
    b.* = webp._mm_unpacklo_epi64(B1, B3);
}

fn ConvertRGBA32ToUV_SSE2(rgb_: [*c]const u16, u_: [*c]u8, v_: [*c]u8, width: c_int) callconv(.C) void {
    var rgb, var u, var v = .{ rgb_, u_, v_ };
    const max_width = width & ~@as(c_int, 15);
    const last_rgb: [*c]const u16 = webp.offsetPtr(rgb, 4 * max_width);
    while (rgb < last_rgb) {
        var r: __m128i, var g: __m128i, var b: __m128i, var U0: __m128i, var V0: __m128i, var U1: __m128i, var V1: __m128i = .{undefined} ** 7;
        RGBA32PackedToPlanar_16b_SSE2(rgb + 0, &r, &g, &b);
        ConvertRGBToUV_SSE2(&r, &g, &b, &U0, &V0);
        RGBA32PackedToPlanar_16b_SSE2(rgb + 32, &r, &g, &b);
        ConvertRGBToUV_SSE2(&r, &g, &b, &U1, &V1);
        store16(webp._mm_packus_epi16(U0, U1), u);
        store16(webp._mm_packus_epi16(V0, V1), v);
        u += 16;
        v += 16;
        rgb += 2 * 32;
    }
    if (max_width < width) { // left-over
        webp.WebPConvertRGBA32ToUV_C(rgb, u, v, width - max_width);
    }
}

//------------------------------------------------------------------------------

pub fn WebPInitConvertARGBToYUVSSE2() void {
    webp.WebPConvertARGBToY = &ConvertARGBToY_SSE2;
    webp.WebPConvertARGBToUV = &ConvertARGBToUV_SSE2;

    webp.WebPConvertRGB24ToY = &ConvertRGB24ToY_SSE2;
    webp.WebPConvertBGR24ToY = &ConvertBGR24ToY_SSE2;

    webp.WebPConvertRGBA32ToUV = &ConvertRGBA32ToUV_SSE2;
}
