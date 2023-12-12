const std = @import("std");
const common = @import("common.zig");
const comptimePrint = @import("std").fmt.comptimePrint;
const __m128d = common.__m128d;
const __m128i = common.__m128i;
const __m128 = common.__m128;
const __m64 = common.__m64;

const all_1_8: @Vector(16, u8) = @splat(0xff);
const all_0_8: @Vector(16, u8) = @splat(0);

const all_1_16: @Vector(8, u16) = @splat(0xffff);
const all_0_16: @Vector(8, u16) = @splat(0);

const all_1_32: @Vector(4, u32) = @splat(0xffffffff);
const all_0_32: @Vector(4, u32) = @splat(0);

const all_1_64: @Vector(2, u64) = @splat(0xffffffffffffffff);
const all_0_64: @Vector(2, u64) = @splat(0);

// paddw
pub inline fn _mm_add_epi16(a: __m128i, b: __m128i) __m128i {
    const a_: @Vector(8, u16) = @bitCast(a);
    const b_: @Vector(8, u16) = @bitCast(b);
    const c = a_ +% b_;
    return @bitCast(c);
}

// paddd
pub inline fn _mm_add_epi32(a: __m128i, b: __m128i) __m128i {
    const a_: @Vector(4, u32) = @bitCast(a);
    const b_: @Vector(4, u32) = @bitCast(b);
    const c = a_ +% b_;
    return @bitCast(c);
}

// paddq
pub inline fn _mm_add_epi64(a: __m128i, b: __m128i) __m128i {
    const c = a +% b;
    return @bitCast(c);
}

// paddb
pub inline fn _mm_add_epi8(a: __m128i, b: __m128i) __m128i {
    const a_: @Vector(16, u8) = @bitCast(a);
    const b_: @Vector(16, u8) = @bitCast(b);
    const c = a_ +% b_;
    return @bitCast(c);
}

// addpd
pub inline fn _mm_add_pd(a: __m128d, b: __m128d) __m128d {
    const c = a + b;
    return @bitCast(c);
}

// addsd
pub inline fn _mm_add_sd(a: __m128d, b: __m128d) __m128d {
    const c = __m128d{ a[0] + b[0], a[1] };
    return c;
}

// paddq
pub inline fn _mm_add_si64(a: __m64, b: __m64) __m64 {
    return asm volatile (
        \\ paddq %mm1, %mm0
        : [ret] "={mm0}" (-> __m64),
        : [a] "{mm0}" (a),
          [b] "{mm1}" (b),
    );
}

// paddsw
pub inline fn _mm_adds_epi16(a: __m128i, b: __m128i) __m128i {
    const a_: @Vector(8, i16) = @bitCast(a);
    const b_: @Vector(8, i16) = @bitCast(b);
    const c = a_ +| b_;
    return @bitCast(c);
}

// paddsb
pub inline fn _mm_adds_epi8(a: __m128i, b: __m128i) __m128i {
    const a_: @Vector(16, i8) = @bitCast(a);
    const b_: @Vector(16, i8) = @bitCast(b);
    const c = a_ +| b_;
    return @bitCast(c);
}

// paddusw
pub inline fn _mm_adds_epu16(a: __m128i, b: __m128i) __m128i {
    const a_: @Vector(8, u16) = @bitCast(a);
    const b_: @Vector(8, u16) = @bitCast(b);
    const c = a_ +| b_;
    return @bitCast(c);
}

// paddusb
pub inline fn _mm_adds_epu8(a: __m128i, b: __m128i) __m128i {
    const a_: @Vector(16, u8) = @bitCast(a);
    const b_: @Vector(16, u8) = @bitCast(b);
    const c = a_ +| b_;
    return @bitCast(c);
}

// andpd
pub inline fn _mm_and_pd(a: __m128d, b: __m128d) __m128d {
    const a_: __m128i = @bitCast(a);
    const b_: __m128i = @bitCast(b);
    return @bitCast(a_ & b_);
}

// pand
pub inline fn _mm_and_si128(a: __m128i, b: __m128i) __m128i {
    return a & b;
}

// andnpd
pub inline fn _mm_andnot_pd(a: __m128d, b: __m128d) __m128d {
    const a_: __m128i = @bitCast(a);
    const b_: __m128i = @bitCast(b);
    return @bitCast(~a_ & b_);
}

// pandn
pub inline fn _mm_andnot_si128(a: __m128i, b: __m128i) __m128i {
    return ~a & b;
}

// pavgw
pub inline fn _mm_avg_epu16(a: __m128i, b: __m128i) __m128i {
    return asm volatile (
        \\ pavgw %xmm1, %xmm0
        : [ret] "={xmm0}" (-> __m128i),
        : [a] "{xmm0}" (a),
          [b] "{xmm1}" (b),
    );
}

// pavgb
pub inline fn _mm_avg_epu8(a: __m128i, b: __m128i) __m128i {
    return asm volatile (
        \\ pavgb %xmm1, %xmm0
        : [ret] "={xmm0}" (-> __m128i),
        : [a] "{xmm0}" (a),
          [b] "{xmm1}" (b),
    );
}

// pslldq
pub inline fn _mm_bslli_si128(a: __m128i, comptime imm8: u4) __m128i {
    comptime if (imm8 > 16) return @splat(0);
    const b: @Vector(16, u8) = @bitCast(a);
    const c = std.simd.shiftElementsRight(b, imm8, 0);
    return @bitCast(c);
}

// psrldq
pub inline fn _mm_bsrli_si128(a: __m128i, comptime imm8: u8) __m128i {
    comptime if (imm8 > 16) return @splat(0);
    const b: @Vector(16, u8) = @bitCast(a);
    const c = std.simd.shiftElementsLeft(b, imm8, 0);
    return @bitCast(c);
}

pub inline fn _mm_castpd_ps(a: __m128d) __m128 {
    return @bitCast(a);
}
pub inline fn _mm_castpd_si128(a: __m128d) __m128i {
    return @bitCast(a);
}
pub inline fn _mm_castps_pd(a: __m128) __m128d {
    return @bitCast(a);
}
pub inline fn _mm_castps_si128(a: __m128) __m128i {
    return @bitCast(a);
}
pub inline fn _mm_castsi128_pd(a: __m128i) __m128d {
    return @bitCast(a);
}
pub inline fn _mm_castsi128_ps(a: __m128i) __m128 {
    return @bitCast(a);
}

pub inline fn _mm_clflush(p: *const anyopaque) void {
    asm volatile ("clflush (%rdi)"
        : [ret] "=" (-> void),
        : [p] "{rdi}" (p),
    );
}

// pcmpeqw
pub inline fn _mm_cmpeq_epi16(a: __m128i, b: __m128i) __m128i {
    const a_: @Vector(8, u16) = @bitCast(a);
    const b_: @Vector(8, u16) = @bitCast(b);
    const c = @select(u16, a_ == b_, all_1_16, all_0_16);
    return @bitCast(c);
}

// pcmpeqd
pub inline fn _mm_cmpeq_epi32(a: __m128i, b: __m128i) __m128i {
    const a_: @Vector(4, u32) = @bitCast(a);
    const b_: @Vector(4, u32) = @bitCast(b);
    const c = @select(u32, a_ == b_, all_1_32, all_0_32);
    return @bitCast(c);
}

// pcmpeqb
pub inline fn _mm_cmpeq_epi8(a: __m128i, b: __m128i) __m128i {
    const a_: @Vector(16, u8) = @bitCast(a);
    const b_: @Vector(16, u8) = @bitCast(b);
    const c = @select(u8, a_ == b_, all_1_8, all_0_8);
    return @bitCast(c);
}

// cmppd
pub inline fn _mm_cmpeq_pd(a: __m128d, b: __m128d) __m128d {
    const c = @select(f64, a == b, @as(__m128d, @bitCast(all_1_64)), @as(__m128d, @bitCast(all_0_64)));
    return c;
}

// cmpsd
pub inline fn _mm_cmpeq_sd(a: __m128d, b: __m128d) __m128d {
    return asm volatile (
        \\ cmpeqsd %xmm1, %xmm0
        : [ret] "={xmm0}" (-> __m128d),
        : [a] "{xmm0}" (a),
          [b] "{xmm1}" (b),
    );
}

// cmppd
pub inline fn _mm_cmpge_pd(a: __m128d, b: __m128d) __m128d {
    const c = @select(f64, a >= b, @as(__m128d, @bitCast(all_1_64)), @as(__m128d, @bitCast(all_0_64)));
    return c;
}
// cmpsd
pub inline fn _mm_cmpge_sd(a: __m128d, b: __m128d) __m128d {
    return asm volatile (
        \\ cmplesd %xmm0, %xmm1
        : [ret] "={xmm1}" (-> __m128d),
        : [a] "{xmm0}" (a),
          [b] "{xmm1}" (b),
    );
}

// pcmpgtw
pub inline fn _mm_cmpgt_epi16(a: __m128i, b: __m128i) __m128i {
    const a_: @Vector(8, i16) = @bitCast(a);
    const b_: @Vector(8, i16) = @bitCast(b);
    const c = @select(u16, a_ > b_, all_1_16, all_0_16);
    return @bitCast(c);
}

// pcmpgtd
pub inline fn _mm_cmpgt_epi32(a: __m128i, b: __m128i) __m128i {
    const a_: @Vector(4, i32) = @bitCast(a);
    const b_: @Vector(4, i32) = @bitCast(b);
    const c = @select(u32, a_ > b_, all_1_32, all_0_32);
    return @bitCast(c);
}

// pcmpgtb
pub inline fn _mm_cmpgt_epi8(a: __m128i, b: __m128i) __m128i {
    const a_: @Vector(16, i8) = @bitCast(a);
    const b_: @Vector(16, i8) = @bitCast(b);
    const c = @select(u8, a_ > b_, all_1_8, all_0_8);
    return @bitCast(c);
}

// cmppd
pub inline fn _mm_cmpgt_pd(a: __m128d, b: __m128d) __m128d {
    const c = @select(u64, a > b, all_1_64, all_0_64);
    return @bitCast(c);
}

// cmpsd
pub inline fn _mm_cmpgt_sd(a: __m128d, b: __m128d) __m128d {
    return asm volatile (
        \\ cmpltsd %xmm0, %xmm1
        : [ret] "={xmm1}" (-> __m128d),
        : [a] "{xmm0}" (a),
          [b] "{xmm1}" (b),
    );
}

// cmppd
pub inline fn _mm_cmple_pd(a: __m128d, b: __m128d) __m128d {
    const c = @select(f64, a <= b, @as(__m128d, @bitCast(all_1_64)), @as(__m128d, @bitCast(all_0_64)));
    return c;
}

// cmpsd
pub inline fn _mm_cmple_sd(a: __m128d, b: __m128d) __m128d {
    return asm volatile (
        \\ cmplesd %xmm1, %xmm0
        : [ret] "={xmm0}" (-> __m128d),
        : [a] "{xmm0}" (a),
          [b] "{xmm1}" (b),
    );
}

// pcmpgtw
pub inline fn _mm_cmplt_epi16(a: __m128i, b: __m128i) __m128i {
    const a_: @Vector(8, i16) = @bitCast(a);
    const b_: @Vector(8, i16) = @bitCast(b);
    const c = @select(u16, a_ < b_, all_1_16, all_0_16);
    return @bitCast(c);
}

// pcmpgtd
pub inline fn _mm_cmplt_epi32(a: __m128i, b: __m128i) __m128i {
    const a_: @Vector(4, i32) = @bitCast(a);
    const b_: @Vector(4, i32) = @bitCast(b);
    const c = @select(u32, a_ < b_, all_1_32, all_0_32);
    return @bitCast(c);
}

// pcmpgtb
pub inline fn _mm_cmplt_epi8(a: __m128i, b: __m128i) __m128i {
    const a_: @Vector(16, i8) = @bitCast(a);
    const b_: @Vector(16, i8) = @bitCast(b);
    const c = @select(u8, a_ < b_, all_1_8, all_0_8);
    return @bitCast(c);
}

// cmppd
pub inline fn _mm_cmplt_pd(a: __m128d, b: __m128d) __m128d {
    const c = @select(u64, a < b, all_1_64, all_0_64);
    return @bitCast(c);
}

// cmpsd
pub inline fn _mm_cmplt_sd(a: __m128d, b: __m128d) __m128d {
    return asm volatile (
        \\ cmpltsd %xmm1, %xmm0
        : [ret] "={xmm0}" (-> __m128d),
        : [a] "{xmm0}" (a),
          [b] "{xmm1}" (b),
    );
}

// cmppd
pub inline fn _mm_cmpneq_pd(a: __m128d, b: __m128d) __m128d {
    const c = @select(u64, a != b, all_1_64, all_0_64);
    return @bitCast(c);
}

// cmpsd
pub inline fn _mm_cmpneq_sd(a: __m128d, b: __m128d) __m128d {
    return asm volatile (
        \\ cmpneqsd %xmm1, %xmm0
        : [ret] "={xmm0}" (-> __m128d),
        : [a] "{xmm0}" (a),
          [b] "{xmm1}" (b),
    );
}

// cmppd
pub inline fn _mm_cmpnge_pd(a: __m128d, b: __m128d) __m128d {
    return asm volatile (
        \\ cmpnlepd %xmm0, %xmm1
        \\ movapd %xmm1, %xmm0
        : [ret] "={xmm0}" (-> __m128d),
        : [a] "{xmm0}" (a),
          [b] "{xmm1}" (b),
    );
}

// cmpsd
pub inline fn _mm_cmpnge_sd(a: __m128d, b: __m128d) __m128d {
    return asm volatile (
        \\ cmpnlesd %xmm0, %xmm1
        \\ movsd %xmm1, %xmm0
        : [ret] "={xmm0}" (-> __m128d),
        : [a] "{xmm0}" (a),
          [b] "{xmm1}" (b),
    );
}

// cmppd
pub inline fn _mm_cmpngt_pd(a: __m128d, b: __m128d) __m128d {
    return asm volatile (
        \\ cmpnltpd %xmm0, %xmm1
        \\ movapd %xmm1, %xmm0
        : [ret] "={xmm0}" (-> __m128d),
        : [a] "{xmm0}" (a),
          [b] "{xmm1}" (b),
    );
}

// cmpsd
pub inline fn _mm_cmpngt_sd(a: __m128d, b: __m128d) __m128d {
    return asm volatile (
        \\ cmpnltsd %xmm0, %xmm1
        \\ movsd %xmm1, %xmm0
        : [ret] "={xmm0}" (-> __m128d),
        : [a] "{xmm0}" (a),
          [b] "{xmm1}" (b),
    );
}

// cmppd
pub inline fn _mm_cmpnle_pd(a: __m128d, b: __m128d) __m128d {
    return asm volatile (
        \\ cmpnlepd %xmm1, %xmm0
        : [ret] "={xmm0}" (-> __m128d),
        : [a] "{xmm0}" (a),
          [b] "{xmm1}" (b),
    );
}

// cmpsd
pub inline fn _mm_cmpnle_sd(a: __m128d, b: __m128d) __m128d {
    return asm volatile (
        \\ cmpnlesd %xmm1, %xmm0
        : [ret] "={xmm0}" (-> __m128d),
        : [a] "{xmm0}" (a),
          [b] "{xmm1}" (b),
    );
}

// cmppd
pub inline fn _mm_cmpnlt_pd(a: __m128d, b: __m128d) __m128d {
    return asm volatile (
        \\ cmpnltpd %xmm1, %xmm0
        : [ret] "={xmm0}" (-> __m128d),
        : [a] "{xmm0}" (a),
          [b] "{xmm1}" (b),
    );
}
// cmpsd
pub inline fn _mm_cmpnlt_sd(a: __m128d, b: __m128d) __m128d {
    return asm volatile (
        \\ cmpnltsd %xmm1, %xmm0
        : [ret] "={xmm0}" (-> __m128d),
        : [a] "{xmm0}" (a),
          [b] "{xmm1}" (b),
    );
}

// cmppd
pub inline fn _mm_cmpord_pd(a: __m128d, b: __m128d) __m128d {
    return asm volatile (
        \\ cmpordpd %xmm1, %xmm0
        : [ret] "={xmm0}" (-> __m128d),
        : [a] "{xmm0}" (a),
          [b] "{xmm1}" (b),
    );
}
// cmpsd
pub inline fn _mm_cmpord_sd(a: __m128d, b: __m128d) __m128d {
    return asm volatile (
        \\ cmpordsd %xmm1, %xmm0
        : [ret] "={xmm0}" (-> __m128d),
        : [a] "{xmm0}" (a),
          [b] "{xmm1}" (b),
    );
}
// cmppd
pub inline fn _mm_cmpunord_pd(a: __m128d, b: __m128d) __m128d {
    return asm volatile (
        \\ cmpunordpd %xmm1, %xmm0
        : [ret] "={xmm0}" (-> __m128d),
        : [a] "{xmm0}" (a),
          [b] "{xmm1}" (b),
    );
}
// cmpsd
pub inline fn _mm_cmpunord_sd(a: __m128d, b: __m128d) __m128d {
    return asm volatile (
        \\ cmpunordsd %xmm1, %xmm0
        : [ret] "={xmm0}" (-> __m128d),
        : [a] "{xmm0}" (a),
          [b] "{xmm1}" (b),
    );
}

// comisd
pub inline fn _mm_comieq_sd(a: __m128d, b: __m128d) bool {
    return a[0] == b[0];
}

// comisd
pub inline fn _mm_comige_sd(a: __m128d, b: __m128d) bool {
    return asm volatile (
        \\ comisd %xmm1, %xmm0
        \\ setae  %al
        : [ret] "={al}" (-> bool),
        : [a] "{xmm0}" (a),
          [b] "{xmm1}" (b),
    );
}

// comisd
pub inline fn _mm_comigt_sd(a: __m128d, b: __m128d) bool {
    return asm volatile (
        \\ comisd %xmm1, %xmm0
        \\ seta  %al
        : [ret] "={al}" (-> bool),
        : [a] "{xmm0}" (a),
          [b] "{xmm1}" (b),
    );
}

// comisd
pub inline fn _mm_comile_sd(a: __m128d, b: __m128d) bool {
    return asm volatile (
        \\ comisd %xmm0, %xmm1
        \\ setae  %al
        : [ret] "={al}" (-> bool),
        : [a] "{xmm0}" (a),
          [b] "{xmm1}" (b),
    );
}
// comisd
pub inline fn _mm_comilt_sd(a: __m128d, b: __m128d) bool {
    return asm volatile (
        \\ comisd %xmm0, %xmm1
        \\ seta  %al
        : [ret] "={al}" (-> bool),
        : [a] "{xmm0}" (a),
          [b] "{xmm1}" (b),
    );
}
// comisd
pub inline fn _mm_comineq_sd(a: __m128d, b: __m128d) bool {
    return asm volatile (
        \\ comisd %xmm1, %xmm0
        \\ setp   %al
        \\ setne  %cl
        \\ or     %cl, %al
        : [ret] "={al}" (-> bool),
        : [a] "{xmm0}" (a),
          [b] "{xmm1}" (b),
        : "cl"
    );
}

// cvtdq2pd
pub inline fn _mm_cvtepi32_pd(a: __m128i) __m128d {
    const b: @Vector(4, i32) = @bitCast(a);
    return .{ @floatFromInt(b[0]), @floatFromInt(b[1]) };
}
// cvtdq2ps
pub inline fn _mm_cvtepi32_ps(a: __m128i) __m128 {
    const b: @Vector(4, i32) = @bitCast(a);
    const c: @Vector(4, f32) = .{ @floatFromInt(b[0]), @floatFromInt(b[1]), @floatFromInt(b[2]), @floatFromInt(b[3]) };
    return @bitCast(c);
}
// cvtpd2dq
pub inline fn _mm_cvtpd_epi32(a: __m128d) __m128i {
    return asm volatile (
        \\ cvtpd2dq %xmm0, %xmm0
        : [ret] "={xmm0}" (-> __m128i),
        : [a] "{xmm0}" (a),
    );
}
// cvtpd2pi
pub inline fn _mm_cvtpd_pi32(a: __m128d) __m64 {
    return asm volatile (
        \\ cvtpd2pi %xmm0, %mm0
        : [ret] "={mm0}" (-> __m64),
        : [a] "{xmm0}" (a),
    );
}
// cvtpd2ps
pub inline fn _mm_cvtpd_ps(a: __m128d) __m128 {
    return asm volatile (
        \\ cvtpd2ps %xmm0, %xmm0
        : [ret] "={xmm0}" (-> __m128),
        : [a] "{xmm0}" (a),
    );
}
// cvtpi2pd
pub inline fn _mm_cvtpi32_pd(a: __m64) __m128d {
    return asm volatile (
        \\ cvtpi2pd %mm0, %xmm0
        : [ret] "={xmm0}" (-> __m128d),
        : [a] "{mm0}" (a),
    );
}
// cvtps2dq
pub inline fn _mm_cvtps_epi32(a: __m128) __m128i {
    return asm volatile (
        \\ cvtps2dq %xmm0, %xmm0
        : [ret] "={xmm0}" (-> __m128i),
        : [a] "{xmm0}" (a),
    );
}
// cvtps2pd
pub inline fn _mm_cvtps_pd(a: __m128) __m128d {
    return asm volatile (
        \\ cvtps2pd %xmm0, %xmm0
        : [ret] "={xmm0}" (-> __m128d),
        : [a] "{xmm0}" (a),
    );
}

// movsd
pub inline fn _mm_cvtsd_f64(a: __m128d) f64 {
    return a[0];
}
// cvtsd2si
pub inline fn _mm_cvtsd_si32(a: __m128d) i32 {
    return asm volatile (
        \\ cvtsd2si %xmm0, %eax
        : [ret] "={eax}" (-> i32),
        : [a] "{xmm0}" (a),
    );
}

// cvtsd2si
pub inline fn _mm_cvtsd_si64(a: __m128d) i64 {
    return asm volatile (
        \\ cvtsd2si %xmm0, %rax
        : [ret] "={rax}" (-> i64),
        : [a] "{xmm0}" (a),
    );
}

// cvtsd2si
pub inline fn _mm_cvtsd_si64x(a: __m128d) i64 {
    return _mm_cvtsd_si64(a);
}

// cvtsd2ss
pub inline fn _mm_cvtsd_ss(a: __m128, b: __m128d) __m128 {
    return asm volatile (
        \\ cvtsd2ss %xmm1, %xmm0
        : [ret] "={xmm0}" (-> __m128),
        : [a] "{xmm0}" (a),
          [b] "{xmm1}" (b),
    );
}

// movd
pub inline fn _mm_cvtsi128_si32(a: __m128i) i32 {
    const b: @Vector(4, i32) = @bitCast(a);
    return b[0];
}

// movq
pub inline fn _mm_cvtsi128_si64(a: __m128i) i64 {
    return a[0];
}

// movq
pub inline fn _mm_cvtsi128_si64x(a: __m128i) i64 {
    return a[0];
}

// cvtsi2sd
pub inline fn _mm_cvtsi32_sd(a: __m128d, b: i32) __m128d {
    return .{ @floatFromInt(b), a[1] };
}

// movd
pub inline fn _mm_cvtsi32_si128(a: i32) __m128i {
    const b = @Vector(4, i32){ a, 0, 0, 0 };
    return @bitCast(b);
}

// cvtsi2sd
pub inline fn _mm_cvtsi64_sd(a: __m128d, b: i64) __m128d {
    return .{ @floatFromInt(b), a[1] };
}

pub inline fn _mm_cvtsi64_si128(a: i64) __m128i {
    return .{ a, 0 };
}

// cvtsi2sd
pub inline fn _mm_cvtsi64x_sd(a: __m128d, b: i64) __m128d {
    return _mm_cvtsi64_sd(a, b);
}

// movq
pub inline fn _mm_cvtsi64x_si128(a: i64) __m128i {
    return _mm_cvtsi64_si128(a);
}

// cvtss2sd
pub inline fn _mm_cvtss_sd(a: __m128d, b: __m128) __m128d {
    const c: @Vector(4, f32) = @bitCast(b);
    return .{ c[0], a[1] };
}

// cvttpd2dq
pub inline fn _mm_cvttpd_epi32(a: __m128d) __m128i {
    const b = @Vector(4, i32){ @intFromFloat(a[0]), @intFromFloat(a[1]), 0, 0 };
    return @bitCast(b);
}

// cvttpd2pi
pub inline fn _mm_cvttpd_pi32(a: __m128d) __m64 {
    return asm volatile (
        \\ cvttpd2pi %xmm0, %mm0
        : [ret] "={mm0}" (-> __m64),
        : [a] "{xmm0}" (a),
    );
}

// cvttps2dq
pub inline fn _mm_cvttps_epi32(a: __m128) __m128i {
    const b: [4]f32 = @bitCast(a);
    var c: @Vector(4, i32) = undefined;
    inline for (b, 0..) |v, i| c[i] = @intFromFloat(v);
    return @bitCast(c);
}

// cvttsd2si
pub inline fn _mm_cvttsd_si32(a: __m128d) i32 {
    return @intFromFloat(a[0]);
}

// cvttsd2si
pub inline fn _mm_cvttsd_si64(a: __m128d) i64 {
    return @intFromFloat(a[0]);
}

// cvttsd2si
pub inline fn _mm_cvttsd_si64x(a: __m128d) i64 {
    return _mm_cvttsd_si64(a);
}

// divpd
pub inline fn _mm_div_pd(a: __m128d, b: __m128d) __m128d {
    return asm volatile (
        \\ divpd %xmm1, %xmm0
        : [ret] "={xmm0}" (-> __m128d),
        : [a] "{xmm0}" (a),
          [b] "{xmm1}" (b),
    );
}

// divsd
pub inline fn _mm_div_sd(a: __m128d, b: __m128d) __m128d {
    return asm volatile (
        \\ divsd %xmm1, %xmm0
        : [ret] "={xmm0}" (-> __m128d),
        : [a] "{xmm0}" (a),
          [b] "{xmm1}" (b),
    );
}

// pextrw
pub inline fn _mm_extract_epi16(a: __m128i, comptime imm8: u3) i16 {
    const b: @Vector(8, i16) = @bitCast(a);
    return b[imm8];
}

// pinsrw
pub inline fn _mm_insert_epi16(a: __m128i, i: i16, comptime imm8: u3) __m128i {
    var b: @Vector(8, i16) = @bitCast(a);
    b[imm8] = i;
    return @bitCast(b);
}

// lfence
pub inline fn _mm_lfence() void {
    asm volatile ("lfence");
}

// movapd
pub inline fn _mm_load_pd(mem_addr: [*]align(16) const f64) __m128d {
    return mem_addr[0..2].*;
}

// ...
pub inline fn _mm_load_pd1(mem_addr: *const f64) __m128d {
    return .{ mem_addr.*, mem_addr.* };
}

// movsd
pub inline fn _mm_load_sd(mem_addr: *align(1) const f64) __m128d {
    return .{ mem_addr.*, 0 };
}

// movdqa
pub inline fn _mm_load_si128(mem_addr: [*]align(16) const u8) __m128i {
    return @bitCast(mem_addr[0..16].*);
}

// ...
// __m128d _mm_load1_pd (f64 const* mem_addr)
pub inline fn _mm_load1_pd(mem_addr: *const f64) __m128d {
    return .{ mem_addr.*, mem_addr.* };
}

// movhpd
pub inline fn _mm_loadh_pd(a: __m128d, mem_addr: *align(1) const f64) __m128d {
    return .{ a[0], mem_addr.* };
}

// movq
pub inline fn _mm_loadl_epi64(mem_addr: *align(1) const i64) __m128i {
    return .{ mem_addr.*, 0 };
}

// movlpd
pub inline fn _mm_loadl_pd(a: __m128d, mem_addr: *align(1) const f64) __m128d {
    return .{ mem_addr.*, a[1] };
}

// ...
pub inline fn _mm_loadr_pd(mem_addr: [*]align(16) const f64) __m128d {
    return .{ mem_addr[1], mem_addr[0] };
}

// movupd
pub inline fn _mm_loadu_pd(mem_addr: [*]align(1) const f64) __m128d {
    return mem_addr[0..2].*;
}

// movdqu
pub inline fn _mm_loadu_si128(mem_addr: [*]align(1) const u8) __m128i {
    return @bitCast(mem_addr[0..16].*);
}

// movd
// __m128i _mm_loadu_si32 (void const* mem_addr)
pub inline fn _mm_loadu_si32(mem_addr: *align(1) const u32) __m128i {
    const c = @Vector(4, u32){ mem_addr.*, 0, 0, 0 };
    return @bitCast(c);
}

// pmaddwd
pub inline fn _mm_madd_epi16(a: __m128i, b: __m128i) __m128i {
    const a_: @Vector(8, i16) = @bitCast(a);
    const b_: @Vector(8, i16) = @bitCast(b);
    var c: @Vector(4, i32) = undefined;
    inline for (0..4) |i| {
        const c0 = @as(i32, a_[i * 2]) * b_[i * 2];
        const c1 = @as(i32, a_[i * 2 + 1]) * b_[i * 2 + 1];
        c[i] = c0 +% c1;
    }
    return @bitCast(c);
}

// maskmovdqu
pub inline fn _mm_maskmoveu_si128(a: __m128i, mask: __m128i, mem_addr: [*]u8) void {
    asm volatile (
        \\ maskmovdqu  %xmm1, %xmm0
        : [ret] "=" (-> void),
        : [a] "{xmm0}" (a),
          [mask] "{xmm1}" (mask),
          [mem] "{rdi}" (mem_addr),
    );
}

// pmaxsw
pub inline fn _mm_max_epi16(a: __m128i, b: __m128i) __m128i {
    const a_: @Vector(8, i16) = @bitCast(a);
    const b_: @Vector(8, i16) = @bitCast(b);
    const c = @max(a_, b_);
    return @bitCast(c);
}

// pmaxub
pub inline fn _mm_max_epu8(a: __m128i, b: __m128i) __m128i {
    const a_: @Vector(16, u8) = @bitCast(a);
    const b_: @Vector(16, u8) = @bitCast(b);
    const c = @max(a_, b_);
    return @bitCast(c);
}

// maxpd
pub inline fn _mm_max_pd(a: __m128d, b: __m128d) __m128d {
    return asm volatile (
        \\ maxpd %xmm1, %xmm0
        : [ret] "={xmm0}" (-> __m128d),
        : [a] "{xmm0}" (a),
          [b] "{xmm1}" (b),
    );
}

// maxsd
pub inline fn _mm_max_sd(a: __m128d, b: __m128d) __m128d {
    return asm volatile (
        \\ maxsd %xmm1, %xmm0
        : [ret] "={xmm0}" (-> __m128d),
        : [a] "{xmm0}" (a),
          [b] "{xmm1}" (b),
    );
}

// mfence
pub inline fn _mm_mfence() void {
    asm volatile ("mfence");
}

// pminsw
pub inline fn _mm_min_epi16(a: __m128i, b: __m128i) __m128i {
    const a_: @Vector(8, i16) = @bitCast(a);
    const b_: @Vector(8, i16) = @bitCast(b);
    const c = @min(a_, b_);
    return @bitCast(c);
}

// pminub
pub inline fn _mm_min_epu8(a: __m128i, b: __m128i) __m128i {
    const a_: @Vector(16, u8) = @bitCast(a);
    const b_: @Vector(16, u8) = @bitCast(b);
    const c = @min(a_, b_);
    return @bitCast(c);
}

// minpd
pub inline fn _mm_min_pd(a: __m128d, b: __m128d) __m128d {
    return asm volatile (
        \\ minpd %xmm1, %xmm0
        : [ret] "={xmm0}" (-> __m128d),
        : [a] "{xmm0}" (a),
          [b] "{xmm1}" (b),
    );
}

// minsd
pub inline fn _mm_min_sd(a: __m128d, b: __m128d) __m128d {
    return asm volatile (
        \\ minsd %xmm1, %xmm0
        : [ret] "={xmm0}" (-> __m128d),
        : [a] "{xmm0}" (a),
          [b] "{xmm1}" (b),
    );
}

// movq
pub inline fn _mm_move_epi64(a: __m128i) __m128i {
    return .{ a[0], 0 };
}

// movsd
pub inline fn _mm_move_sd(a: __m128d, b: __m128d) __m128d {
    return .{ b[0], a[1] };
}

// pmovmskb
pub inline fn _mm_movemask_epi8(a: __m128i) i16 {
    const b: @Vector(16, u8) = @bitCast(a);
    const c = b >> @splat(7);
    const d = c == @as(@Vector(16, u8), @splat(1));
    return @bitCast(d);
}

// movmskpd
pub inline fn _mm_movemask_pd(a: __m128d) u2 {
    const b: @Vector(2, u64) = @bitCast(a);
    const c = @Vector(2, u1){ @truncate(b[0] >> 63), @truncate(b[1] >> 63) };
    return @bitCast(c);
}

// movdq2q
pub inline fn _mm_movepi64_pi64(a: __m128i) __m64 {
    return @bitCast(a[0]);
}

// movq2dq
pub inline fn _mm_movpi64_epi64(a: __m64) __m128i {
    return .{ @bitCast(a), 0 };
}

// pmuludq
pub inline fn _mm_mul_epu32(a: __m128i, b: __m128i) __m128i {
    const a_: @Vector(4, u32) = @bitCast(a);
    const b_: @Vector(4, u32) = @bitCast(b);
    const c = @Vector(2, u64){
        @as(u64, a_[0]) *% b_[0],
        @as(u64, a_[2]) *% b_[2],
    };
    return @bitCast(c);
}

// mulpd
pub inline fn _mm_mul_pd(a: __m128d, b: __m128d) __m128d {
    return a * b;
}

// mulsd
pub inline fn _mm_mul_sd(a: __m128d, b: __m128d) __m128d {
    return .{ a[0] * b[0], a[1] };
}

// pmuludq
pub inline fn _mm_mul_su32(a: __m64, b: __m64) __m64 {
    return asm volatile (
        \\ pmuludq %mm1, %mm0
        : [ret] "={mm0}" (-> __m64),
        : [a] "{mm0}" (a),
          [b] "{mm1}" (b),
    );
}

// pmulhw
pub inline fn _mm_mulhi_epi16(a: __m128i, b: __m128i) __m128i {
    return asm volatile (
        \\ pmulhw %[b], %[a]
        : [ret] "=x" (-> __m128i),
        : [a] "0" (a),
          [b] "x" (b),
    );
}

// pmulhuw
pub inline fn _mm_mulhi_epu16(a: __m128i, b: __m128i) __m128i {
    return asm volatile (
        \\ pmulhuw %[b], %[a]
        : [ret] "=x" (-> __m128i),
        : [a] "0" (a),
          [b] "x" (b),
    );
}

// pmullw
pub inline fn _mm_mullo_epi16(a: __m128i, b: __m128i) __m128i {
    const a_: @Vector(8, i16) = @bitCast(a);
    const b_: @Vector(8, i16) = @bitCast(b);
    const c = a_ *% b_;
    return @bitCast(c);
}

// orpd
pub inline fn _mm_or_pd(a: __m128d, b: __m128d) __m128d {
    const a_: @Vector(2, u64) = @bitCast(a);
    const b_: @Vector(2, u64) = @bitCast(b);
    const c = a_ | b_;
    return @bitCast(c);
}

// por
pub inline fn _mm_or_si128(a: __m128i, b: __m128i) __m128i {
    return a | b;
}

// packsswb
pub inline fn _mm_packs_epi16(a: __m128i, b: __m128i) __m128i {
    return asm volatile (
        \\ packsswb %[b], %[a]
        : [ret] "=x" (-> __m128i),
        : [a] "0" (a),
          [b] "x" (b),
    );
}

// packssdw
pub inline fn _mm_packs_epi32(a: __m128i, b: __m128i) __m128i {
    return asm volatile (
        \\ packssdw %[b], %[a]
        : [ret] "=x" (-> __m128i),
        : [a] "0" (a),
          [b] "x" (b),
    );
}

// packuswb
pub inline fn _mm_packus_epi16(a: __m128i, b: __m128i) __m128i {
    return asm volatile (
        \\ packuswb %[b], %[a]
        : [ret] "=x" (-> __m128i),
        : [a] "0" (a),
          [b] "x" (b),
    );
}

// pause
pub inline fn _mm_pause() void {
    asm volatile ("pause");
}

// psadbw
pub inline fn _mm_sad_epu8(a: __m128i, b: __m128i) __m128i {
    return asm volatile (
        \\ psadbw %[b], %[a]
        : [ret] "=x" (-> __m128i),
        : [a] "0" (a),
          [b] "x" (b),
    );
}

// ...
pub inline fn _mm_set_epi16(e7: i16, e6: i16, e5: i16, e4: i16, e3: i16, e2: i16, e1: i16, e0: i16) __m128i {
    const a = @Vector(8, i16){ e0, e1, e2, e3, e4, e5, e6, e7 };
    return @bitCast(a);
}

// ...
pub inline fn _mm_set_epi32(e3: i32, e2: i32, e1: i32, e0: i32) __m128i {
    const a = @Vector(4, i32){ e0, e1, e2, e3 };
    return @bitCast(a);
}

// ...
pub inline fn _mm_set_epi64(e1: __m64, e0: __m64) __m128i {
    return .{ @bitCast(e0), @bitCast(e1) };
}

// ...
pub inline fn _mm_set_epi64x(e1: i64, e0: i64) __m128i {
    return .{ e0, e1 };
}

// ...
pub inline fn _mm_set_epi8(e15: i8, e14: i8, e13: i8, e12: i8, e11: i8, e10: i8, e9: i8, e8: i8, e7: i8, e6: i8, e5: i8, e4: i8, e3: i8, e2: i8, e1: i8, e0: i8) __m128i {
    const a = @Vector(16, i8){ e0, e1, e2, e3, e4, e5, e6, e7, e8, e9, e10, e11, e12, e13, e14, e15 };
    return @bitCast(a);
}

// ...
pub inline fn _mm_set_pd(e1: f64, e0: f64) __m128d {
    return .{ e0, e1 };
}

// ...
pub inline fn _mm_set_pd1(a: f64) __m128d {
    return .{ a, a };
}

// ...
pub inline fn _mm_set_sd(a: f64) __m128d {
    return .{ a, 0 };
}

// ...
pub inline fn _mm_set1_epi16(a: i16) __m128i {
    const b: @Vector(8, i16) = @splat(a);
    return @bitCast(b);
}

// ...
pub inline fn _mm_set1_epi32(a: i32) __m128i {
    const b: @Vector(4, i32) = @splat(a);
    return @bitCast(b);
}

// ...
pub inline fn _mm_set1_epi64(a: __m64) __m128i {
    return .{ @bitCast(a), @bitCast(a) };
}

// ...
pub inline fn _mm_set1_epi64x(a: i64) __m128i {
    return _mm_set1_epi64(@bitCast(a));
}

// ...
pub inline fn _mm_set1_epi8(a: i8) __m128i {
    const b: @Vector(16, i8) = @splat(a);
    return @bitCast(b);
}

// ...
pub inline fn _mm_set1_pd(a: f64) __m128d {
    return .{ a, a };
}

// ...
pub inline fn _mm_setr_epi16(e7: i16, e6: i16, e5: i16, e4: i16, e3: i16, e2: i16, e1: i16, e0: i16) __m128i {
    const a = @Vector(8, i16){ e7, e6, e5, e4, e3, e2, e1, e0 };
    return @bitCast(a);
}

// ...
pub inline fn _mm_setr_epi32(e3: i32, e2: i32, e1: i32, e0: i32) __m128i {
    const a = @Vector(4, i32){ e3, e2, e1, e0 };
    return @bitCast(a);
}

// ...
pub inline fn _mm_setr_epi64(e1: __m64, e0: __m64) __m128i {
    return .{ @bitCast(e1), @bitCast(e0) };
}

// ...
pub inline fn _mm_setr_epi8(e15: i8, e14: i8, e13: i8, e12: i8, e11: i8, e10: i8, e9: i8, e8: i8, e7: i8, e6: i8, e5: i8, e4: i8, e3: i8, e2: i8, e1: i8, e0: i8) __m128i {
    const a = @Vector(16, i8){ e15, e14, e13, e12, e11, e10, e9, e8, e7, e6, e5, e4, e3, e2, e1, e0 };
    return @bitCast(a);
}

// ...
pub inline fn _mm_setr_pd(e1: f64, e0: f64) __m128d {
    return .{ e1, e0 };
}

// xorpd
pub inline fn _mm_setzero_pd() __m128d {
    return .{ 0, 0 };
}

// pxor
pub inline fn _mm_setzero_si128() __m128i {
    return .{ 0, 0 };
}

// pshufd
pub inline fn _mm_shuffle_epi32(a: __m128i, comptime imm8: u8) __m128i {
    const shuffle = comptime @Vector(4, i32){ imm8 & 3, (imm8 >> 2) & 3, (imm8 >> 4) & 3, (imm8 >> 6) & 3 };
    const a_: @Vector(4, i32) = @bitCast(a);
    const b = @shuffle(i32, a_, undefined, shuffle);
    return @bitCast(b);
}

// shufpd
pub inline fn _mm_shuffle_pd(a: __m128d, b: __m128d, comptime imm8: u2) __m128d {
    const select: @Vector(2, bool) = @bitCast(imm8);
    const c = __m128d{ a[0], b[0] };
    const d = __m128d{ a[1], b[1] };
    const e = @select(f64, select, d, c);
    return @bitCast(e);
}

// pshufhw
pub inline fn _mm_shufflehi_epi16(a: __m128i, comptime imm8: u8) __m128i {
    const shuffle: @Vector(8, i32) = comptime blk: {
        var mask = [4]i32{ imm8 & 3, (imm8 >> 2) & 3, (imm8 >> 4) & 3, (imm8 >> 6) & 3 };
        for (&mask) |*v| v.* += 4;
        break :blk .{ 0, 1, 2, 3 } ++ mask;
    };
    const a_: @Vector(8, i16) = @bitCast(a);
    const b = @shuffle(i16, a_, undefined, shuffle);
    return @bitCast(b);
}

// pshuflw
pub inline fn _mm_shufflelo_epi16(a: __m128i, comptime imm8: u8) __m128i {
    const shuffle: @Vector(8, i32) = comptime blk: {
        const mask = [4]i32{ imm8 & 3, (imm8 >> 2) & 3, (imm8 >> 4) & 3, (imm8 >> 6) & 3 };
        break :blk mask ++ .{ 4, 5, 6, 7 };
    };
    const a_: @Vector(8, i16) = @bitCast(a);
    const b = @shuffle(i16, a_, undefined, shuffle);
    return @bitCast(b);
}

// psllw
pub inline fn _mm_sll_epi16(a: __m128i, count: __m128i) __m128i {
    return asm volatile (
        \\ psllw %[count], %[a]
        : [ret] "=x" (-> __m128i),
        : [a] "0" (a),
          [count] "x" (count),
    );
}

// pslld
pub inline fn _mm_sll_epi32(a: __m128i, count: __m128i) __m128i {
    return asm volatile (
        \\ pslld %[count], %[a]
        : [ret] "=x" (-> __m128i),
        : [a] "0" (a),
          [count] "x" (count),
    );
}

// psllq
pub inline fn _mm_sll_epi64(a: __m128i, count: __m128i) __m128i {
    return asm volatile (
        \\ psllq %[count], %[a]
        : [ret] "=x" (-> __m128i),
        : [a] "0" (a),
          [count] "x" (count),
    );
}

// psllw
pub inline fn _mm_slli_epi16(a: __m128i, imm8: u32) __m128i {
    return asm volatile (
        \\ psllw %[count], %[a]
        : [ret] "=x" (-> __m128i),
        : [a] "0" (a),
          [count] "x" (imm8),
    );
}

// pslld
pub inline fn _mm_slli_epi32(a: __m128i, imm8: u32) __m128i {
    return asm volatile (
        \\ pslld %[count], %[a]
        : [ret] "=x" (-> __m128i),
        : [a] "0" (a),
          [count] "x" (imm8),
    );
}

// psllq
pub inline fn _mm_slli_epi64(a: __m128i, imm8: u32) __m128i {
    return asm volatile (
        \\ psllq %xmm1, %[count], %[a]
        : [ret] "=x" (-> __m128i),
        : [a] "0" (a),
          [count] "x" (imm8),
    );
}

// pslldq
pub inline fn _mm_slli_si128(a: __m128i, comptime imm8: u8) __m128i {
    return asm volatile (comptimePrint("pslldq ${d}, %[a]", .{imm8})
        : [ret] "=x" (-> __m128i),
        : [a] "0" (a),
    );
}

// sqrtpd
pub inline fn _mm_sqrt_pd(a: __m128d) __m128d {
    return @sqrt(a);
}

// sqrtsd
pub inline fn _mm_sqrt_sd(a: __m128d, b: __m128d) __m128d {
    return .{ @sqrt(b[0]), a[1] };
}

// psraw
pub inline fn _mm_sra_epi16(a: __m128i, count: __m128i) __m128i {
    return asm volatile (
        \\ psraw %[count], %[a]
        : [ret] "=x" (-> __m128i),
        : [a] "0" (a),
          [count] "x" (count),
    );
}

// psrad
pub inline fn _mm_sra_epi32(a: __m128i, count: __m128i) __m128i {
    return asm volatile (
        \\ psrad %[count], %[a]
        : [ret] "=x" (-> __m128i),
        : [a] "0" (a),
          [count] "x" (count),
    );
}

// psraw
pub inline fn _mm_srai_epi16(a: __m128i, comptime imm8: u8) __m128i {
    const b: @Vector(8, i16) = @bitCast(a);
    const c = b >> @splat(@truncate(comptime if (imm8 > 15) 15 else imm8));
    return @bitCast(c);
}

// psrad
pub inline fn _mm_srai_epi32(a: __m128i, comptime imm8: u8) __m128i {
    const b: @Vector(4, i32) = @bitCast(a);
    const c = b >> @splat(@truncate(comptime if (imm8 > 31) 31 else imm8));
    return @bitCast(c);
}

// psrlw
pub inline fn _mm_srl_epi16(a: __m128i, count: __m128i) __m128i {
    return asm volatile (
        \\ psrlw %[count], %[a]
        : [ret] "=x" (-> __m128i),
        : [a] "0" (a),
          [count] "x" (count),
    );
}

// psrld
pub inline fn _mm_srl_epi32(a: __m128i, count: __m128i) __m128i {
    return asm volatile (
        \\ psrld %[count], %[a]
        : [ret] "=x" (-> __m128i),
        : [a] "0" (a),
          [count] "x" (count),
    );
}

// psrlq
pub inline fn _mm_srl_epi64(a: __m128i, count: __m128i) __m128i {
    return asm volatile (
        \\ psrlq %[count], %[a]
        : [ret] "=x" (-> __m128i),
        : [a] "0" (a),
          [count] "x" (count),
    );
}

// psrlw
pub inline fn _mm_srli_epi16(a: __m128i, comptime imm8: u8) __m128i {
    comptime if (imm8 > 15) return @splat(0);
    const b: @Vector(8, u16) = @bitCast(a);
    const c = b >> @splat(@truncate(imm8));
    return @bitCast(c);
}

// psrld
pub inline fn _mm_srli_epi32(a: __m128i, comptime imm8: u8) __m128i {
    comptime if (imm8 > 31) return @splat(0);
    const b: @Vector(4, u32) = @bitCast(a);
    const c = b >> @splat(@truncate(imm8));
    return @bitCast(c);
}

// psrlq
pub inline fn _mm_srli_epi64(a: __m128i, comptime imm8: u8) __m128i {
    comptime if (imm8 > 63) return @splat(0);
    const b: @Vector(2, u64) = @bitCast(a);
    const c = b >> @splat(@truncate(imm8));
    return @bitCast(c);
}

// psrldq
pub inline fn _mm_srli_si128(a: __m128i, comptime imm8: u8) __m128i {
    comptime if (imm8 > 15) return @splat(0);
    const b: @Vector(16, u8) = @bitCast(a);
    const c = std.simd.shiftElementsLeft(b, imm8, 0);
    return @bitCast(c);
}

// movapd
pub inline fn _mm_store_pd(mem_addr: [*]align(16) f64, a: __m128d) void {
    mem_addr[0..2].* = @bitCast(a);
}

// ...
pub inline fn _mm_store_pd1(mem_addr: [*]align(16) f64, a: __m128d) void {
    mem_addr[0..2].* = .{ a[0], a[0] };
}

// movsd
pub inline fn _mm_store_sd(mem_addr: *align(1) f64, a: __m128d) void {
    mem_addr.* = a[0];
}

// movdqa
pub inline fn _mm_store_si128(mem_addr: [*]align(16) u8, a: __m128i) void {
    mem_addr[0..16].* = @bitCast(a);
}

// ...
pub inline fn _mm_store1_pd(mem_addr: [*]align(16) f64, a: __m128d) void {
    mem_addr[0..2].* = .{ a[0], a[0] };
}

// movhpd
pub inline fn _mm_storeh_pd(mem_addr: *f64, a: __m128d) void {
    mem_addr.* = a[1];
}

// movq
pub inline fn _mm_storel_epi64(mem_addr: *align(1) i64, a: __m128i) void {
    mem_addr.* = a[0];
}

// movlpd
pub inline fn _mm_storel_pd(mem_addr: *f64, a: __m128d) void {
    mem_addr.* = a[0];
}

// ...
pub inline fn _mm_storer_pd(mem_addr: [*]align(16) f64, a: __m128d) void {
    mem_addr[0..2].* = .{ a[1], a[0] };
}

// movupd
pub inline fn _mm_storeu_pd(mem_addr: [*]align(1) f64, a: __m128d) void {
    mem_addr[0..2].* = a;
}

// movdqu
pub inline fn _mm_storeu_si128(mem_addr: [*]align(1) u8, a: __m128i) void {
    mem_addr[0..16].* = @bitCast(a);
}

// movd
// void _mm_storeu_si32 (void* mem_addr, __m128i a)
pub inline fn _mm_storeu_si32(mem_addr: *align(1) u32, a: __m128i) void {
    const b: @Vector(4, u32) = @bitCast(a);
    mem_addr.* = b[0];
}

// movntpd
pub inline fn _mm_stream_pd(mem_addr: [*]align(16) f64, a: __m128d) void {
    asm volatile (
        \\ movntpd %xmm0, (%rdi)
        : [ret] "=" (-> void),
        : [a] "{xmm0}" (a),
          [addr] "{rdi}" (mem_addr),
    );
}

// movntdq
pub inline fn _mm_stream_si128(mem_addr: *[16]u8, a: __m128i) void {
    asm volatile (
        \\ movntdq %xmm0, (%rdi)
        : [ret] "=" (-> void),
        : [a] "{xmm0}" (a),
          [mem_addr] "{rdi}" (mem_addr),
    );
}

// movnti
pub inline fn _mm_stream_si32(mem_addr: *i32, a: i32) void {
    asm volatile (
        \\ movnti %esi, (%rdi)
        : [ret] "=" (-> void),
        : [a] "{esi}" (a),
          [mem_addr] "{rdi}" (mem_addr),
    );
}

// movnti
pub inline fn _mm_stream_si64(mem_addr: *i64, a: i64) void {
    asm volatile (
        \\ movnti %rsi, (%rdi)
        : [ret] "=" (-> void),
        : [a] "{rsi}" (a),
          [mem_addr] "{rdi}" (mem_addr),
    );
}

// psubw
pub inline fn _mm_sub_epi16(a: __m128i, b: __m128i) __m128i {
    const a_: @Vector(8, u16) = @bitCast(a);
    const b_: @Vector(8, u16) = @bitCast(b);
    const c = a_ -% b_;
    return @bitCast(c);
}

// psubd
pub inline fn _mm_sub_epi32(a: __m128i, b: __m128i) __m128i {
    const a_: @Vector(4, u32) = @bitCast(a);
    const b_: @Vector(4, u32) = @bitCast(b);
    const c = a_ -% b_;
    return @bitCast(c);
}

// psubq
pub inline fn _mm_sub_epi64(a: __m128i, b: __m128i) __m128i {
    const c = a -% b;
    return @bitCast(c);
}

// psubb
pub inline fn _mm_sub_epi8(a: __m128i, b: __m128i) __m128i {
    const a_: @Vector(16, u8) = @bitCast(a);
    const b_: @Vector(16, u8) = @bitCast(b);
    const c = a_ -% b_;
    return @bitCast(c);
}

// subpd
pub inline fn _mm_sub_pd(a: __m128d, b: __m128d) __m128d {
    const c = a - b;
    return @bitCast(c);
}

// subsd
pub inline fn _mm_sub_sd(a: __m128d, b: __m128d) __m128d {
    const c = __m128d{ a[0] - b[0], a[1] };
    return c;
}

// psubq
pub inline fn _mm_sub_si64(a: __m64, b: __m64) __m64 {
    return asm volatile (
        \\ psubq %mm1, %mm0
        : [ret] "={mm0}" (-> __m64),
        : [a] "{mm0}" (a),
          [b] "{mm1}" (b),
    );
}

// psubsw
pub inline fn _mm_subs_epi16(a: __m128i, b: __m128i) __m128i {
    const a_: @Vector(8, i16) = @bitCast(a);
    const b_: @Vector(8, i16) = @bitCast(b);
    const c = a_ -| b_;
    return @bitCast(c);
}

// psubsb
pub inline fn _mm_subs_epi8(a: __m128i, b: __m128i) __m128i {
    const a_: @Vector(16, i8) = @bitCast(a);
    const b_: @Vector(16, i8) = @bitCast(b);
    const c = a_ -| b_;
    return @bitCast(c);
}

// psubusw
pub inline fn _mm_subs_epu16(a: __m128i, b: __m128i) __m128i {
    const a_: @Vector(8, u16) = @bitCast(a);
    const b_: @Vector(8, u16) = @bitCast(b);
    const c = a_ -| b_;
    return @bitCast(c);
}

// psubusb
pub inline fn _mm_subs_epu8(a: __m128i, b: __m128i) __m128i {
    const a_: @Vector(16, u8) = @bitCast(a);
    const b_: @Vector(16, u8) = @bitCast(b);
    const c = a_ -| b_;
    return @bitCast(c);
}

// ucomisd
pub inline fn _mm_ucomieq_sd(a: __m128d, b: __m128d) bool {
    return asm volatile (
        \\ ucomisd %xmm1, %xmm0
        \\ setnp  %al
        \\ sete %cl
        \\ test %al, %cl
        \\ setne %al
        : [ret] "={al}" (-> bool),
        : [a] "{xmm0}" (a),
          [b] "{xmm1}" (b),
        : "cl"
    );
}

// ucomisd
pub inline fn _mm_ucomige_sd(a: __m128d, b: __m128d) bool {
    return asm volatile (
        \\ ucomisd %xmm1, %xmm0
        \\ setae  %al
        : [ret] "={al}" (-> bool),
        : [a] "{xmm0}" (a),
          [b] "{xmm1}" (b),
    );
}

// ucomisd
pub inline fn _mm_ucomigt_sd(a: __m128d, b: __m128d) bool {
    return asm volatile (
        \\ ucomisd %xmm1, %xmm0
        \\ seta  %al
        : [ret] "={al}" (-> bool),
        : [a] "{xmm0}" (a),
          [b] "{xmm1}" (b),
    );
}

// ucomisd
pub inline fn _mm_ucomile_sd(a: __m128d, b: __m128d) bool {
    return asm volatile (
        \\ ucomisd %xmm0, %xmm1
        \\ setae  %al
        : [ret] "={al}" (-> bool),
        : [a] "{xmm0}" (a),
          [b] "{xmm1}" (b),
    );
}

// ucomisd
pub inline fn _mm_ucomilt_sd(a: __m128d, b: __m128d) bool {
    return asm volatile (
        \\ ucomisd %xmm0, %xmm1
        \\ seta  %al
        : [ret] "={al}" (-> bool),
        : [a] "{xmm0}" (a),
          [b] "{xmm1}" (b),
    );
}

// ucomisd
pub inline fn _mm_ucomineq_sd(a: __m128d, b: __m128d) bool {
    return asm volatile (
        \\ ucomisd %xmm1, %xmm0
        \\ setp  %al
        \\ setne %cl
        \\ or %al, %cl
        \\ setne %al
        : [ret] "={al}" (-> bool),
        : [a] "{xmm0}" (a),
          [b] "{xmm1}" (b),
        : "cl"
    );
}

pub inline fn _mm_undefined_pd() __m128d {
    return .{ 0, 0 };
}

pub inline fn _mm_undefined_si128() __m128i {
    return .{ 0, 0 };
}

// punpckhwd
pub inline fn _mm_unpackhi_epi16(a: __m128i, b: __m128i) __m128i {
    const a_: @Vector(8, u16) = @bitCast(a);
    const b_: @Vector(8, u16) = @bitCast(b);
    const c = @shuffle(u16, a_, b_, @Vector(8, i32){ 4, -5, 5, -6, 6, -7, 7, -8 });
    return @bitCast(c);
}

// punpckhdq
pub inline fn _mm_unpackhi_epi32(a: __m128i, b: __m128i) __m128i {
    const a_: @Vector(4, u32) = @bitCast(a);
    const b_: @Vector(4, u32) = @bitCast(b);
    const c = @shuffle(u32, a_, b_, @Vector(4, i32){ 2, -3, 3, -4 });
    return @bitCast(c);
}

// punpckhqdq
pub inline fn _mm_unpackhi_epi64(a: __m128i, b: __m128i) __m128i {
    return .{ a[1], b[1] };
}

// punpckhbw
pub inline fn _mm_unpackhi_epi8(a: __m128i, b: __m128i) __m128i {
    const a_: @Vector(16, u8) = @bitCast(a);
    const b_: @Vector(16, u8) = @bitCast(b);
    const c = @shuffle(u8, a_, b_, @Vector(16, i32){ 8, -9, 9, -10, 10, -11, 11, -12, 12, -13, 13, -14, 14, -15, 15, -16 });
    return @bitCast(c);
}

// unpckhpd
pub inline fn _mm_unpackhi_pd(a: __m128d, b: __m128d) __m128d {
    return .{ a[1], b[1] };
}

// punpcklwd
pub inline fn _mm_unpacklo_epi16(a: __m128i, b: __m128i) __m128i {
    const a_: @Vector(8, u16) = @bitCast(a);
    const b_: @Vector(8, u16) = @bitCast(b);
    const c = @shuffle(u16, a_, b_, @Vector(8, i32){ 0, -1, 1, -2, 2, -3, 3, -4 });
    return @bitCast(c);
}

// punpckldq
pub inline fn _mm_unpacklo_epi32(a: __m128i, b: __m128i) __m128i {
    const a_: @Vector(4, u32) = @bitCast(a);
    const b_: @Vector(4, u32) = @bitCast(b);
    const c = @shuffle(u32, a_, b_, @Vector(4, i32){ 0, -1, 1, -2 });
    return @bitCast(c);
}

// punpcklqdq
pub inline fn _mm_unpacklo_epi64(a: __m128i, b: __m128i) __m128i {
    return .{ a[0], b[0] };
}

// punpcklbw
pub inline fn _mm_unpacklo_epi8(a: __m128i, b: __m128i) __m128i {
    const a_: @Vector(16, u8) = @bitCast(a);
    const b_: @Vector(16, u8) = @bitCast(b);
    const c = @shuffle(u8, a_, b_, @Vector(16, i32){ 0, -1, 1, -2, 2, -3, 3, -4, 4, -5, 5, -6, 6, -7, 7, -8 });
    return @bitCast(c);
}

// unpcklpd
pub inline fn _mm_unpacklo_pd(a: __m128d, b: __m128d) __m128d {
    return .{ a[0], b[0] };
}

// xorpd
pub inline fn _mm_xor_pd(a: __m128d, b: __m128d) __m128d {
    const a_: @Vector(2, u64) = @bitCast(a);
    const b_: @Vector(2, u64) = @bitCast(b);
    const c = a_ ^ b_;
    return @bitCast(c);
}

// pxor
pub inline fn _mm_xor_si128(a: __m128i, b: __m128i) __m128i {
    return a ^ b;
}
