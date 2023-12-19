const std = @import("std");
const webp = struct {
    usingnamespace @import("intrinzic");
    usingnamespace @import("../utils/utils.zig");
};

const __m128i = webp.__m128i;
const c_bool = webp.c_bool;

//------------------------------------------------------------------------------
// Channel mixing.
// Shuffles the input buffer as A0 0 0 A1 0 0 A2 ...
inline fn SSE41Shuff(in_0: *__m128i, in_1: *__m128i, shuff0: __m128i, shuff1: __m128i, shuff2: __m128i) struct { __m128i, __m128i, __m128i, __m128i, __m128i, __m128i } {
    return .{
        webp._mm_shuffle_epi8(in_0.*, shuff0),
        webp._mm_shuffle_epi8(in_0.*, shuff1),
        webp._mm_shuffle_epi8(in_0.*, shuff2),
        webp._mm_shuffle_epi8(in_1.*, shuff0),
        webp._mm_shuffle_epi8(in_1.*, shuff1),
        webp._mm_shuffle_epi8(in_1.*, shuff2),
    };
}

// Pack the planar buffers
// rrrr... rrrr... gggg... gggg... bbbb... bbbb....
// triplet by triplet in the output buffer rgb as rgbrgbrgbrgb ...
pub inline fn VP8PlanarTo24b_SSE41(in0: *__m128i, in1: *__m128i, in2: *__m128i, in3: *__m128i, in4: *__m128i, in5: *__m128i) void {
    // Process R.
    const shuff0R = webp._mm_set_epi8(5, -1, -1, 4, -1, -1, 3, -1, -1, 2, -1, -1, 1, -1, -1, 0);
    const shuff1R = webp._mm_set_epi8(-1, 10, -1, -1, 9, -1, -1, 8, -1, -1, 7, -1, -1, 6, -1, -1);
    const shuff2R = webp._mm_set_epi8(-1, -1, 15, -1, -1, 14, -1, -1, 13, -1, -1, 12, -1, -1, 11, -1);
    const R0, const R1, const R2, const R3, const R4, const R5 = SSE41Shuff(in0, in1, shuff0R, shuff1R, shuff2R);

    // Process G.
    // Same as before, just shifted to the left by one and including the right
    // padding.
    const shuff0G = webp._mm_set_epi8(-1, -1, 4, -1, -1, 3, -1, -1, 2, -1, -1, 1, -1, -1, 0, -1);
    const shuff1G = webp._mm_set_epi8(10, -1, -1, 9, -1, -1, 8, -1, -1, 7, -1, -1, 6, -1, -1, 5);
    const shuff2G = webp._mm_set_epi8(-1, 15, -1, -1, 14, -1, -1, 13, -1, -1, 12, -1, -1, 11, -1, -1);
    const G0, const G1, const G2, const G3, const G4, const G5 = SSE41Shuff(in2, in3, shuff0G, shuff1G, shuff2G);

    // Process B.
    const shuff0B = webp._mm_set_epi8(-1, 4, -1, -1, 3, -1, -1, 2, -1, -1, 1, -1, -1, 0, -1, -1);
    const shuff1B = webp._mm_set_epi8(-1, -1, 9, -1, -1, 8, -1, -1, 7, -1, -1, 6, -1, -1, 5, -1);
    const shuff2B = webp._mm_set_epi8(15, -1, -1, 14, -1, -1, 13, -1, -1, 12, -1, -1, 11, -1, -1, 10);
    const B0, const B1, const B2, const B3, const B4, const B5 = SSE41Shuff(in4, in5, shuff0B, shuff1B, shuff2B);

    // OR the different channels.
    {
        const RG0 = webp._mm_or_si128(R0, G0);
        const RG1 = webp._mm_or_si128(R1, G1);
        const RG2 = webp._mm_or_si128(R2, G2);
        const RG3 = webp._mm_or_si128(R3, G3);
        const RG4 = webp._mm_or_si128(R4, G4);
        const RG5 = webp._mm_or_si128(R5, G5);
        in0.* = webp._mm_or_si128(RG0, B0);
        in1.* = webp._mm_or_si128(RG1, B1);
        in2.* = webp._mm_or_si128(RG2, B2);
        in3.* = webp._mm_or_si128(RG3, B3);
        in4.* = webp._mm_or_si128(RG4, B4);
        in5.* = webp._mm_or_si128(RG5, B5);
    }
}

// Convert four packed four-channel buffers like argbargbargbargb... into the
// split channels aaaaa ... rrrr ... gggg .... bbbbb ......
pub inline fn VP8L32bToPlanar_SSE41(in0: *__m128i, in1: *__m128i, in2: *__m128i, in3: *__m128i) void {
    // aaaarrrrggggbbbb
    const shuff0 = webp._mm_set_epi8(15, 11, 7, 3, 14, 10, 6, 2, 13, 9, 5, 1, 12, 8, 4, 0);
    const A0 = webp._mm_shuffle_epi8(in0.*, shuff0);
    const A1 = webp._mm_shuffle_epi8(in1.*, shuff0);
    const A2 = webp._mm_shuffle_epi8(in2.*, shuff0);
    const A3 = webp._mm_shuffle_epi8(in3.*, shuff0);
    // A0A1R0R1
    // G0G1B0B1
    // A2A3R2R3
    // G0G1B0B1
    const B0 = webp._mm_unpacklo_epi32(A0, A1);
    const B1 = webp._mm_unpackhi_epi32(A0, A1);
    const B2 = webp._mm_unpacklo_epi32(A2, A3);
    const B3 = webp._mm_unpackhi_epi32(A2, A3);
    in3.* = webp._mm_unpacklo_epi64(B0, B2);
    in2.* = webp._mm_unpackhi_epi64(B0, B2);
    in1.* = webp._mm_unpacklo_epi64(B1, B3);
    in0.* = webp._mm_unpackhi_epi64(B1, B3);
}
