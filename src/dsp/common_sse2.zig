const webp = struct {
    usingnamespace @import("intrinsics.zig");
};

pub const m128 = @Vector(2, u64);

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
