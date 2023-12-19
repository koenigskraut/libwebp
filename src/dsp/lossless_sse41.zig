const std = @import("std");
const webp = struct {
    usingnamespace @import("lossless.zig");
    usingnamespace @import("intrinzic");
    usingnamespace @import("../utils/utils.zig");
};

const __m128i = webp.__m128i;

//------------------------------------------------------------------------------
// Color-space conversion functions

/// sign-extended multiplying constants, pre-shifted by 5.
inline fn CST(comptime field_name: []const u8, m: webp.VP8LMultipliers) u16 {
    const field: i16 = @field(m, field_name);
    return @bitCast((field << 8) >> 5);
}

fn TransformColorInverse_SSE41(m: *const webp.VP8LMultipliers, src: [*c]const u32, num_pixels: c_int, dst: [*c]u32) callconv(.C) void {
    // #define CST(X)  (((int16_t)(m->X << 8)) >> 5)   // sign-extend
    const mults_rb = webp._mm_set1_epi32(@bitCast(@as(u32, CST("green_to_red_", m.*)) << 16 | (CST("green_to_blue_", m.*) & 0xffff)));
    const mults_b2 = webp._mm_set1_epi32(CST("red_to_blue_", m.*));
    const mask_ag = webp._mm_set1_epi32(@bitCast(@as(u32, 0xff00ff00)));
    const perm1 = webp._mm_setr_epi8(-1, 1, -1, 1, -1, 5, -1, 5, -1, 9, -1, 9, -1, 13, -1, 13);
    const perm2 = webp._mm_setr_epi8(-1, 2, -1, -1, -1, 6, -1, -1, -1, 10, -1, -1, -1, 14, -1, -1);
    var i: usize = 0;
    while (i + 4 <= num_pixels) : (i += 4) {
        const A = webp._mm_loadu_si128(@ptrCast(src + i));
        const B = webp._mm_shuffle_epi8(A, perm1); // argb -> g0g0
        const C = webp._mm_mulhi_epi16(B, mults_rb);
        const D = webp._mm_add_epi8(A, C);
        const E = webp._mm_shuffle_epi8(D, perm2);
        const F = webp._mm_mulhi_epi16(E, mults_b2);
        const G = webp._mm_add_epi8(D, F);
        const out = webp._mm_blendv_epi8(G, A, mask_ag);
        dst[i..][0..4].* = @bitCast(out);
    }
    // Fall-back to C-version for left-overs.
    if (i != num_pixels) {
        webp.VP8LTransformColorInverse_C(m, src + i, num_pixels - @as(c_int, @intCast(i)), dst + i);
    }
}

//------------------------------------------------------------------------------

fn ConvertBGRAToRGB_SSE41(src: [*c]const u32, num_pixels_: c_int, dst: [*c]u8) callconv(.C) void {
    var in: [*c]const u8 = @ptrCast(src);
    var out: [*c]u8 = dst;
    var num_pixels = num_pixels_;

    const perm0 = webp._mm_setr_epi8(2, 1, 0, 6, 5, 4, 10, 9, 8, 14, 13, 12, -1, -1, -1, -1);
    const perm1 = webp._mm_shuffle_epi32(perm0, 0x39); // 0x39 00_11_10_01
    const perm2 = webp._mm_shuffle_epi32(perm0, 0x4e); // 0x4e
    const perm3 = webp._mm_shuffle_epi32(perm0, 0x93); // 0x93

    while (num_pixels >= 16) {
        const in0 = webp._mm_loadu_si128(in + 0 * 16);
        const in1 = webp._mm_loadu_si128(in + 1 * 16);
        const in2 = webp._mm_loadu_si128(in + 2 * 16);
        const in3 = webp._mm_loadu_si128(in + 3 * 16);
        const a0 = webp._mm_shuffle_epi8(in0, perm0);
        const a1 = webp._mm_shuffle_epi8(in1, perm1);
        const a2 = webp._mm_shuffle_epi8(in2, perm2);
        const a3 = webp._mm_shuffle_epi8(in3, perm3);
        const b0 = webp._mm_blend_epi16(a0, a1, 0xc0);
        const b1 = webp._mm_blend_epi16(a1, a2, 0xf0);
        const b2 = webp._mm_blend_epi16(a2, a3, 0xfc);
        (out + 0 * 16)[0..16].* = @bitCast(b0);
        (out + 1 * 16)[0..16].* = @bitCast(b1);
        (out + 2 * 16)[0..16].* = @bitCast(b2);
        in += 4 * 16;
        out += 3 * 16;
        num_pixels -= 16;
    }

    // left-overs
    if (num_pixels > 0) {
        webp.VP8LConvertBGRAToRGB_C(@ptrCast(@alignCast(in)), num_pixels, out);
    }
}

fn ConvertBGRAToBGR_SSE41(src: [*c]const u32, num_pixels_: c_int, dst: [*c]u8) callconv(.C) void {
    var in: [*c]const u8 = @ptrCast(src);
    var out: [*c]u8 = dst;
    var num_pixels = num_pixels_;

    const perm0 = webp._mm_setr_epi8(0, 1, 2, 4, 5, 6, 8, 9, 10, 12, 13, 14, -1, -1, -1, -1);
    const perm1 = webp._mm_shuffle_epi32(perm0, 0x39); // 0x39 00_11_10_01
    const perm2 = webp._mm_shuffle_epi32(perm0, 0x4e); // 0x4e
    const perm3 = webp._mm_shuffle_epi32(perm0, 0x93); // 0x93

    while (num_pixels >= 16) {
        const in0 = webp._mm_loadu_si128(in + 0 * 16);
        const in1 = webp._mm_loadu_si128(in + 1 * 16);
        const in2 = webp._mm_loadu_si128(in + 2 * 16);
        const in3 = webp._mm_loadu_si128(in + 3 * 16);
        const a0 = webp._mm_shuffle_epi8(in0, perm0);
        const a1 = webp._mm_shuffle_epi8(in1, perm1);
        const a2 = webp._mm_shuffle_epi8(in2, perm2);
        const a3 = webp._mm_shuffle_epi8(in3, perm3);
        const b0 = webp._mm_blend_epi16(a0, a1, 0xc0);
        const b1 = webp._mm_blend_epi16(a1, a2, 0xf0);
        const b2 = webp._mm_blend_epi16(a2, a3, 0xfc);
        (out + 0 * 16)[0..16].* = @bitCast(b0);
        (out + 1 * 16)[0..16].* = @bitCast(b1);
        (out + 2 * 16)[0..16].* = @bitCast(b2);
        in += 4 * 16;
        out += 3 * 16;
        num_pixels -= 16;
    }

    // left-overs
    if (num_pixels > 0) {
        webp.VP8LConvertBGRAToBGR_C(@ptrCast(@alignCast(in)), num_pixels, out);
    }
}

//------------------------------------------------------------------------------
// Entry point

pub fn VP8LDspInitSSE41() void {
    webp.VP8LTransformColorInverse = &TransformColorInverse_SSE41;
    webp.VP8LConvertBGRAToRGB = &ConvertBGRAToRGB_SSE41;
    webp.VP8LConvertBGRAToBGR = &ConvertBGRAToBGR_SSE41;
}
