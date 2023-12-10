const webp = struct {
    usingnamespace @import("intrinsics.zig");
};

const m128 = webp.m128;
const __m128i = webp.__m128i;

//------------------------------------------------------------------------------
// Math functions.

// // Return the sum of all the 8b in the register.
// pub inline fn VP8HorizontalAdd8b(a: [*c]const @Vector(2, u64)) c_int {
//   const zero: @Vector(2, u64) = @splat(0);
//   const sad8x2 = _mm_sad_epu8(*a, zero);
//   // sum the two sads: sad8x2[0:1] + sad8x2[8:9]
//   const __m128i sum = _mm_add_epi32(sad8x2, _mm_shuffle_epi32(sad8x2, 2));
//   return _mm_cvtsi128_si32(sum);
// }

// Transpose two 4x4 16b matrices horizontally stored in registers.
pub inline fn VP8Transpose_2_4x4_16b(in0: *const m128, in1: *const m128, in2: *const m128, in3: *const m128, out0: *m128, out1: *m128, out2: *m128, out3: *m128) void {
    // Transpose the two 4x4.
    // a00 a01 a02 a03   b00 b01 b02 b03
    // a10 a11 a12 a13   b10 b11 b12 b13
    // a20 a21 a22 a23   b20 b21 b22 b23
    // a30 a31 a32 a33   b30 b31 b32 b33
    const transpose0_0 = webp.Z_mm_unpacklo_epi16(in0.*, in1.*);
    const transpose0_1 = webp.Z_mm_unpacklo_epi16(in2.*, in3.*);
    const transpose0_2 = webp.Z_mm_unpackhi_epi16(in0.*, in1.*);
    const transpose0_3 = webp.Z_mm_unpackhi_epi16(in2.*, in3.*);
    // a00 a10 a01 a11   a02 a12 a03 a13
    // a20 a30 a21 a31   a22 a32 a23 a33
    // b00 b10 b01 b11   b02 b12 b03 b13
    // b20 b30 b21 b31   b22 b32 b23 b33
    const transpose1_0 = webp.Z_mm_unpacklo_epi32(transpose0_0, transpose0_1);
    const transpose1_1 = webp.Z_mm_unpacklo_epi32(transpose0_2, transpose0_3);
    const transpose1_2 = webp.Z_mm_unpackhi_epi32(transpose0_0, transpose0_1);
    const transpose1_3 = webp.Z_mm_unpackhi_epi32(transpose0_2, transpose0_3);
    // a00 a10 a20 a30 a01 a11 a21 a31
    // b00 b10 b20 b30 b01 b11 b21 b31
    // a02 a12 a22 a32 a03 a13 a23 a33
    // b02 b12 a22 b32 b03 b13 b23 b33
    out0.* = webp.Z_mm_unpacklo_epi64(transpose1_0, transpose1_1);
    out1.* = webp.Z_mm_unpackhi_epi64(transpose1_0, transpose1_1);
    out2.* = webp.Z_mm_unpacklo_epi64(transpose1_2, transpose1_3);
    out3.* = webp.Z_mm_unpackhi_epi64(transpose1_2, transpose1_3);
    // a00 a10 a20 a30   b00 b10 b20 b30
    // a01 a11 a21 a31   b01 b11 b21 b31
    // a02 a12 a22 a32   b02 b12 b22 b32
    // a03 a13 a23 a33   b03 b13 b23 b33
}

//------------------------------------------------------------------------------
// Channel mixing.

// Function used several times in VP8PlanarTo24b.
// It samples the in buffer as follows: one every two unsigned char is stored
// at the beginning of the buffer, while the other half is stored at the end.
inline fn VP8PlanarTo24bHelper(in0: __m128i, in1: __m128i, in2: __m128i, in3: __m128i, in4: __m128i, in5: __m128i) struct { __m128i, __m128i, __m128i, __m128i, __m128i, __m128i } {
    const v_mask = webp._mm_set1_epi16(0x00ff);
    return .{
        // Take one every two upper 8b values.
        webp._mm_packus_epi16(webp._mm_and_si128(in0, v_mask), webp._mm_and_si128(in1, v_mask)),
        webp._mm_packus_epi16(webp._mm_and_si128(in2, v_mask), webp._mm_and_si128(in3, v_mask)),
        webp._mm_packus_epi16(webp._mm_and_si128(in4, v_mask), webp._mm_and_si128(in5, v_mask)),
        // Take one every two lower 8b values.
        webp._mm_packus_epi16(webp._mm_srli_epi16(in0, 8), webp._mm_srli_epi16(in1, 8)),
        webp._mm_packus_epi16(webp._mm_srli_epi16(in2, 8), webp._mm_srli_epi16(in3, 8)),
        webp._mm_packus_epi16(webp._mm_srli_epi16(in4, 8), webp._mm_srli_epi16(in5, 8)),
    };
}

// Pack the planar buffers
// rrrr... rrrr... gggg... gggg... bbbb... bbbb....
// triplet by triplet in the output buffer rgb as rgbrgbrgbrgb ...
pub inline fn VP8PlanarTo24b_SSE2(in0: *__m128i, in1: *__m128i, in2: *__m128i, in3: *__m128i, in4: *__m128i, in5: *__m128i) void {
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
    var tmp0: __m128i, var tmp1: __m128i, var tmp2: __m128i, var tmp3: __m128i, var tmp4: __m128i, var tmp5: __m128i = .{undefined} ** 6;
    tmp0, tmp1, tmp2, tmp3, tmp4, tmp5 = VP8PlanarTo24bHelper(in0.*, in1.*, in2.*, in3.*, in4.*, in5.*);
    in0.*, in1.*, in2.*, in3.*, in4.*, in5.* = VP8PlanarTo24bHelper(tmp0, tmp1, tmp2, tmp3, tmp4, tmp5);
    tmp0, tmp1, tmp2, tmp3, tmp4, tmp5 = VP8PlanarTo24bHelper(in0.*, in1.*, in2.*, in3.*, in4.*, in5.*);
    // We need to do it two more times than the example as we have sixteen bytes.
    {
        var out0: __m128i, var out1: __m128i, var out2: __m128i, var out3: __m128i, var out4: __m128i, var out5: __m128i = .{undefined} ** 6;
        out0, out1, out2, out3, out4, out5 = VP8PlanarTo24bHelper(tmp0, tmp1, tmp2, tmp3, tmp4, tmp5);
        in0.*, in1.*, in2.*, in3.*, in4.*, in5.* = VP8PlanarTo24bHelper(out0, out1, out2, out3, out4, out5);
    }
}

// Convert four packed four-channel buffers like argbargbargbargb... into the
// split channels aaaaa ... rrrr ... gggg .... bbbbb ......
pub inline fn VP8L32bToPlanar_SSE2(in0: *__m128i, in1: *__m128i, in2: *__m128i, in3: *__m128i) void {
    // Column-wise transpose.
    const A0 = webp._mm_unpacklo_epi8(in0.*, in1.*);
    const A1 = webp._mm_unpackhi_epi8(in0.*, in1.*);
    const A2 = webp._mm_unpacklo_epi8(in2.*, in3.*);
    const A3 = webp._mm_unpackhi_epi8(in2.*, in3.*);
    const B0 = webp._mm_unpacklo_epi8(A0, A1);
    const B1 = webp._mm_unpackhi_epi8(A0, A1);
    const B2 = webp._mm_unpacklo_epi8(A2, A3);
    const B3 = webp._mm_unpackhi_epi8(A2, A3);
    // C0 = g7 g6 ... g1 g0 | b7 b6 ... b1 b0
    // C1 = a7 a6 ... a1 a0 | r7 r6 ... r1 r0
    const C0 = webp._mm_unpacklo_epi8(B0, B1);
    const C1 = webp._mm_unpackhi_epi8(B0, B1);
    const C2 = webp._mm_unpacklo_epi8(B2, B3);
    const C3 = webp._mm_unpackhi_epi8(B2, B3);
    // Gather the channels.
    in0.* = webp._mm_unpackhi_epi64(C1, C3);
    in1.* = webp._mm_unpacklo_epi64(C1, C3);
    in2.* = webp._mm_unpackhi_epi64(C0, C2);
    in3.* = webp._mm_unpacklo_epi64(C0, C2);
}
