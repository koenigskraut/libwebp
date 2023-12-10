const common = @import("common.zig");
const comptimePrint = @import("std").fmt.comptimePrint;
const __m128d = common.__m128d;
const __m128i = common.__m128i;
const __m128 = common.__m128;

// https://godbolt.org/z/1qebK4745

pub inline fn _mm_blend_epi16(a: __m128i, b: __m128i, comptime imm8: u8) __m128i {
    const mask: @Vector(8, bool) = @bitCast(imm8);
    const a_: @Vector(8, i16) = @bitCast(a);
    const b_: @Vector(8, i16) = @bitCast(b);
    return @bitCast(@select(i16, mask, b_, a_));
}

pub inline fn _mm_blend_pd(a: __m128d, b: __m128d, comptime imm8: u2) __m128d {
    const mask: @Vector(2, bool) = @bitCast(imm8);
    return @select(f64, mask, b, a);
}

// blendps
pub inline fn _mm_blend_ps(a: __m128, b: __m128, comptime imm8: u4) __m128 {
    const mask: @Vector(4, bool) = @bitCast(imm8);
    return @select(f32, mask, b, a);
}

// pblendvb
pub inline fn _mm_blendv_epi8(a: __m128i, b: __m128i, mask: __m128i) __m128i {
    return asm volatile (
        \\ pblendvb %xmm0, %xmm1, %xmm2
        : [ret] "={xmm0}" (-> __m128i),
        : [a] "{xmm0}" (a),
          [b] "{xmm1}" (b),
          [mask] "{xmm2}" (mask),
    );
}

// blendvpd
pub inline fn _mm_blendv_pd(a: __m128d, b: __m128d, mask: __m128d) __m128d {
    return asm volatile (
        \\ blendvpd %xmm0, %xmm1, %xmm2
        : [ret] "={xmm0}" (-> __m128d),
        : [a] "{xmm0}" (a),
          [b] "{xmm1}" (b),
          [mask] "{xmm2}" (mask),
    );
}

// blendvps
pub inline fn _mm_blendv_ps(a: __m128, b: __m128, mask: __m128) __m128 {
    return asm volatile (
        \\ blendvps %xmm0, %xmm1, %xmm2
        : [ret] "={xmm0}" (-> __m128),
        : [a] "{xmm0}" (a),
          [b] "{xmm1}" (b),
          [mask] "{xmm2}" (mask),
    );
}

// roundpd
pub inline fn _mm_ceil_pd(a: __m128d) __m128d {
    return asm volatile (
        \\ roundpd $2, %xmm0, %xmm0
        : [ret] "={xmm0}" (-> __m128d),
        : [a] "{xmm0}" (a),
    );
}

// roundps
pub inline fn _mm_ceil_ps(a: __m128) __m128 {
    return asm volatile (
        \\ roundps $2, %xmm0, %xmm0
        : [ret] "={xmm0}" (-> __m128),
        : [a] "{xmm0}" (a),
    );
}

// roundsd
pub inline fn _mm_ceil_sd(a: __m128d, b: __m128d) __m128d {
    return asm volatile (
        \\ roundsd $2, %xmm1, %xmm0
        : [ret] "={xmm0}" (-> __m128d),
        : [a] "{xmm0}" (a),
          [b] "{xmm1}" (b),
    );
}

// roundss
pub inline fn _mm_ceil_ss(a: __m128, b: __m128) __m128 {
    return asm volatile (
        \\ roundss $2, %xmm1, %xmm0
        : [ret] "={xmm0}" (-> __m128),
        : [a] "{xmm0}" (a),
          [b] "{xmm1}" (b),
    );
}

// pcmpeqq
pub inline fn _mm_cmpeq_epi64(a: __m128i, b: __m128i) __m128i {
    const all_0xff: __m128i = @splat(-1);
    const zero: __m128i = @splat(0);
    return @select(i64, a == b, all_0xff, zero);
}

// pmovsxwd
pub inline fn _mm_cvtepi16_epi32(a: __m128i) __m128i {
    const b: [8]i16 = @bitCast(a);
    const c = @Vector(4, i32){ b[0], b[2], b[4], b[6] };
    return @bitCast(c);
}

// pmovsxwq
pub inline fn _mm_cvtepi16_epi64(a: __m128i) __m128i {
    const b: [8]i16 = @bitCast(a);
    return .{ b[0], b[1] };
}

// pmovsxdq
pub inline fn _mm_cvtepi32_epi64(a: __m128i) __m128i {
    const b: [4]i32 = @bitCast(a);
    return .{ b[0], b[1] };
}

// pmovsxbw
pub inline fn _mm_cvtepi8_epi16(a: __m128i) __m128i {
    const b: [16]i8 = @bitCast(a);
    const c = @Vector(8, i16){ b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7] };
    return @bitCast(c);
}

// pmovsxbd
pub inline fn _mm_cvtepi8_epi32(a: __m128i) __m128i {
    const b: [16]i8 = @bitCast(a);
    const c = @Vector(4, i32){ b[0], b[1], b[2], b[3] };
    return @bitCast(c);
}

// pmovsxbq
pub inline fn _mm_cvtepi8_epi64(a: __m128i) __m128i {
    const b: [16]i8 = @bitCast(a);
    const c = @Vector(2, i64){ b[0], b[1] };
    return @bitCast(c);
}

// pmovzxwd
pub inline fn _mm_cvtepu16_epi32(a: __m128i) __m128i {
    const b: [8]u16 = @bitCast(a);
    const c = @Vector(4, u32){ b[0], b[1], b[2], b[3] };
    return @bitCast(c);
}

// pmovzxwq
pub inline fn _mm_cvtepu16_epi64(a: __m128i) __m128i {
    const b: [8]u16 = @bitCast(a);
    const c = @Vector(2, u64){ b[0], b[1] };
    return @bitCast(c);
}

// pmovzxdq
pub inline fn _mm_cvtepu32_epi64(a: __m128i) __m128i {
    const b: [4]u32 = @bitCast(a);
    const c = @Vector(2, u64){ b[0], b[1] };
    return @bitCast(c);
}

// pmovzxbw
pub inline fn _mm_cvtepu8_epi16(a: __m128i) __m128i {
    const b: [16]u8 = @bitCast(a);
    const c = @Vector(8, u16){ b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7] };
    return @bitCast(c);
}

// pmovzxbd
pub inline fn _mm_cvtepu8_epi32(a: __m128i) __m128i {
    const b: [16]u8 = @bitCast(a);
    const c = @Vector(4, u32){ b[0], b[1], b[2], b[3] };
    return @bitCast(c);
}

// pmovzxbq
pub inline fn _mm_cvtepu8_epi64(a: __m128i) __m128i {
    const b: [16]u8 = @bitCast(a);
    const c = @Vector(2, u64){ b[0], b[1] };
    return @bitCast(c);
}

// dppd
pub inline fn _mm_dp_pd(a: __m128d, b: __m128d, comptime imm8: u8) __m128d {
    return asm volatile (comptimePrint("dppd ${d}, %xmm1, %xmm0", .{imm8})
        : [ret] "={xmm0}" (-> __m128d),
        : [a] "{xmm0}" (a),
          [b] "{xmm1}" (b),
    );
}

// dpps
pub inline fn _mm_dp_ps(a: __m128, b: __m128, comptime imm8: u8) __m128 {
    return asm volatile (comptimePrint("dpps ${d}, %xmm1, %xmm0", .{imm8})
        : [ret] "={xmm0}" (-> __m128),
        : [a] "{xmm0}" (a),
          [b] "{xmm1}" (b),
    );
}

// pextrd
pub inline fn _mm_extract_epi32(a: __m128i, comptime imm8: u2) i32 {
    const b: [4]i32 = @bitCast(a);
    return b[imm8];
}

// pextrq
pub inline fn _mm_extract_epi64(a: __m128i, comptime imm8: u1) i64 {
    return @as([2]i64, a)[imm8];
}

// pextrb
pub inline fn _mm_extract_epi8(a: __m128i, comptime imm8: u4) i8 {
    const b: [16]i8 = @bitCast(a);
    return b[imm8];
}

// extractps
pub inline fn _mm_extract_ps(a: __m128, comptime imm8: u2) i32 {
    const b: [4]i32 = @bitCast(a);
    return b[imm8];
}

// roundpd
pub inline fn _mm_floor_pd(a: __m128d) __m128d {
    return asm volatile (
        \\ roundpd $1, %xmm0, %xmm0
        : [ret] "={xmm0}" (-> __m128d),
        : [a] "{xmm0}" (a),
    );
}

// roundps
pub inline fn _mm_floor_ps(a: __m128) __m128 {
    return asm volatile (
        \\ roundps $1, %xmm0, %xmm0
        : [ret] "={xmm0}" (-> __m128),
        : [a] "{xmm0}" (a),
    );
}

// roundsd
pub inline fn _mm_floor_sd(a: __m128d, b: __m128d) __m128d {
    return asm volatile (
        \\ roundsd $1, %xmm1, %xmm0
        : [ret] "={xmm0}" (-> __m128d),
        : [a] "{xmm0}" (a),
          [b] "{xmm1}" (b),
    );
}

// roundss
pub inline fn _mm_floor_ss(a: __m128, b: __m128) __m128 {
    return asm volatile (
        \\ roundss $1, %xmm1, %xmm0
        : [ret] "={xmm0}" (-> __m128),
        : [a] "{xmm0}" (a),
          [b] "{xmm1}" (b),
    );
}

// pinsrd
pub inline fn _mm_insert_epi32(a: __m128i, i: i32, comptime imm8: u2) __m128i {
    var b: [4]i32 = @bitCast(a);
    b[imm8] = i;
    return @bitCast(b);
}

// pinsrq
pub inline fn _mm_insert_epi64(a: __m128i, i: i64, comptime imm8: u1) __m128i {
    var b: [2]i64 = a;
    b[imm8] = i;
    return b;
}

// pinsrb
pub inline fn _mm_insert_epi8(a: __m128i, i: i8, comptime imm8: u4) __m128i {
    var b: [16]i8 = @bitCast(a);
    b[imm8] = i;
    return @bitCast(b);
}

// insertps
pub inline fn _mm_insert_ps(a: __m128, b: __m128, comptime imm8: u8) __m128 {
    return asm volatile (comptimePrint("insertps ${d}, %xmm1, %xmm0", .{imm8})
        : [ret] "={xmm0}" (-> __m128),
        : [a] "{xmm0}" (a),
          [b] "{xmm1}" (b),
    );
}

// pmaxsd
pub inline fn _mm_max_epi32(a: __m128i, b: __m128i) __m128i {
    const a_: @Vector(4, i32) = @bitCast(a);
    const b_: @Vector(4, i32) = @bitCast(b);
    const c = @max(a_, b_);
    return @bitCast(c);
}

// pmaxsb
pub inline fn _mm_max_epi8(a: __m128i, b: __m128i) __m128i {
    const a_: @Vector(16, i8) = @bitCast(a);
    const b_: @Vector(16, i8) = @bitCast(b);
    const c = @max(a_, b_);
    return @bitCast(c);
}

// pmaxuw
pub inline fn _mm_max_epu16(a: __m128i, b: __m128i) __m128i {
    const a_: @Vector(8, u16) = @bitCast(a);
    const b_: @Vector(8, u16) = @bitCast(b);
    const c = @max(a_, b_);
    return @bitCast(c);
}

// pmaxud
pub inline fn _mm_max_epu32(a: __m128i, b: __m128i) __m128i {
    const a_: @Vector(4, u32) = @bitCast(a);
    const b_: @Vector(4, u32) = @bitCast(b);
    const c = @max(a_, b_);
    return @bitCast(c);
}

// pminsd
pub inline fn _mm_min_epi32(a: __m128i, b: __m128i) __m128i {
    const a_: @Vector(4, i32) = @bitCast(a);
    const b_: @Vector(4, i32) = @bitCast(b);
    const c = @min(a_, b_);
    return @bitCast(c);
}

// pminsb
pub inline fn _mm_min_epi8(a: __m128i, b: __m128i) __m128i {
    const a_: @Vector(16, i8) = @bitCast(a);
    const b_: @Vector(16, i8) = @bitCast(b);
    const c = @min(a_, b_);
    return @bitCast(c);
}

// pminuw
pub inline fn _mm_min_epu16(a: __m128i, b: __m128i) __m128i {
    const a_: @Vector(8, u16) = @bitCast(a);
    const b_: @Vector(8, u16) = @bitCast(b);
    const c = @min(a_, b_);
    return @bitCast(c);
}

// pminud
pub inline fn _mm_min_epu32(a: __m128i, b: __m128i) __m128i {
    const a_: @Vector(4, u32) = @bitCast(a);
    const b_: @Vector(4, u32) = @bitCast(b);
    const c = @min(a_, b_);
    return @bitCast(c);
}

// phminposuw
pub inline fn _mm_minpos_epu16(a: __m128i) __m128i {
    return asm volatile (
        \\ phminposuw %xmm0, %xmm0
        : [ret] "={xmm0}" (-> __m128i),
        : [a] "{xmm0}" (a),
    );
}

// mpsadbw
pub inline fn _mm_mpsadbw_epu8(a: __m128i, b: __m128i, comptime imm8: u8) __m128i {
    return asm volatile (comptimePrint("mpsadbw ${d}, %xmm1, %xmm0", .{imm8})
        : [ret] "={xmm0}" (-> __m128i),
        : [a] "{xmm0}" (a),
          [b] "{xmm1}" (b),
    );
}

// pmuldq
pub inline fn _mm_mul_epi32(a: __m128i, b: __m128i) __m128i {
    const a0 = a << @splat(32);
    const b0 = b << @splat(32);
    const a1 = a0 >> @splat(32);
    const b1 = b0 >> @splat(32);
    const c = a1 *% b1;
    return @bitCast(c);
}

// pmulld
pub inline fn _mm_mullo_epi32(a: __m128i, b: __m128i) __m128i {
    const a_: @Vector(4, i32) = @bitCast(a);
    const b_: @Vector(4, i32) = @bitCast(b);
    const c = a_ *% b_;
    return @bitCast(c);
}

// packusdw
pub inline fn _mm_packus_epi32(a: __m128i, b: __m128i) __m128i {
    return asm volatile (
        \\ packusdw %xmm1, %xmm0
        : [ret] "={xmm0}" (-> __m128i),
        : [a] "{xmm0}" (a),
          [b] "{xmm1}" (b),
    );
}

// roundpd
pub inline fn _mm_round_pd(a: __m128d, comptime rounding: u4) __m128d {
    return asm volatile (comptimePrint("roundpd ${d}, %xmm0, %xmm0", .{rounding})
        : [ret] "={xmm0}" (-> __m128d),
        : [a] "{xmm0}" (a),
    );
}

// roundps
pub inline fn _mm_round_ps(a: __m128, comptime rounding: u4) __m128 {
    return asm volatile (comptimePrint("roundps ${d}, %xmm0, %xmm0", .{rounding})
        : [ret] "={xmm0}" (-> __m128),
        : [a] "{xmm0}" (a),
    );
}

// roundsd
pub inline fn _mm_round_sd(a: __m128d, b: __m128d, comptime rounding: u4) __m128d {
    return asm volatile (comptimePrint("roundsd ${d}, %xmm1, %xmm0", .{rounding})
        : [ret] "={xmm0}" (-> __m128d),
        : [a] "{xmm0}" (a),
          [b] "{xmm1}" (b),
    );
}

// roundss
pub inline fn _mm_round_ss(a: __m128, b: __m128, comptime rounding: u4) __m128 {
    return asm volatile (comptimePrint("roundss ${d}, %xmm1, %xmm0", .{rounding})
        : [ret] "={xmm0}" (-> __m128),
        : [a] "{xmm0}" (a),
          [b] "{xmm1}" (b),
    );
}

// movntdqa
pub inline fn _mm_stream_load_si128(mem_addr: *align(16) anyopaque) __m128i {
    return asm volatile (
        \\ movntdqa rdi, %xmm0
        : [ret] "={xmm0}" (-> __m128i),
        : [mem_addr] "{rdi}" (mem_addr),
    );
}

// ...
pub inline fn _mm_test_all_ones(a: __m128i) bool {
    const not_a: @Vector(128, u1) = @bitCast(a);
    return @reduce(.And, not_a) == 1;
}

// ptest
pub inline fn _mm_test_all_zeros(a: __m128i, mask: __m128i) bool {
    const b = a & mask;
    const c: @Vector(128, u1) = @bitCast(b);
    return @reduce(.Or, c) == 0;
}

// ptest
pub inline fn _mm_test_mix_ones_zeros(a: __m128i, mask: __m128i) bool {
    return asm volatile (
        \\ ptest %xmm1, %xmm0
        \\ seta  %al
        : [ret] "={al}" (-> bool),
        : [a] "{xmm0}" (a),
          [mask] "{xmm1}" (mask),
    );
}

// ptest
pub inline fn _mm_testc_si128(a: __m128i, b: __m128i) bool {
    const c: @Vector(128, u1) = @bitCast((~a) & b);
    return @reduce(.Or, c) == 0;
}

// ptest
pub inline fn _mm_testnzc_si128(a: __m128i, b: __m128i) bool {
    return _mm_test_mix_ones_zeros(a, b);
}

// ptest
pub inline fn _mm_testz_si128(a: __m128i, b: __m128i) bool {
    return _mm_test_all_zeros(a, b);
}
