const common = @import("common.zig");
const comptimePrint = @import("std").fmt.comptimePrint;
const __m128i = common.__m128i;
const __m64 = common.__m64;

// pabsw
pub inline fn _mm_abs_epi16(a: __m128i) __m128i {
    const b: @Vector(8, i16) = @bitCast(a);
    return @bitCast(@abs(b));
}

// pabsd
pub inline fn _mm_abs_epi32(a: __m128i) __m128i {
    const b: @Vector(4, i32) = @bitCast(a);
    const c = @abs(b);
    return @bitCast(c);
}

// pabsb
pub inline fn _mm_abs_epi8(a: __m128i) __m128i {
    const b: @Vector(16, i8) = @bitCast(a);
    const c = @abs(b);
    return @bitCast(c);
}

// pabsw
pub inline fn _mm_abs_pi16(a: __m64) __m64 {
    const b: @Vector(4, i16) = @bitCast(a);
    const c = @abs(b);
    return @bitCast(c);
}

// pabsd
pub inline fn _mm_abs_pi32(a: __m64) __m64 {
    const b: @Vector(2, i32) = @bitCast(a);
    const c = @abs(b);
    return @bitCast(c);
}

// pabsb
pub inline fn _mm_abs_pi8(a: __m64) __m64 {
    const b: @Vector(8, i8) = @bitCast(a);
    const c = @abs(b);
    return @bitCast(c);
}

// palignr
pub inline fn _mm_alignr_epi8(a: __m128i, b: __m128i, comptime imm8: u8) __m128i {
    comptime var vec: [16]i32 = undefined;
    switch (imm8) {
        inline 0...15 => {
            comptime {
                for (0..16, imm8..) |i, v|
                    vec[i] = if (v < 16) @intCast(v) else ~@as(i32, @intCast(v - 16));
            }
            const a0: @Vector(16, i8) = @bitCast(a);
            const b0: @Vector(16, i8) = @bitCast(b);
            const c = @shuffle(i8, b0, a0, vec);
            return @bitCast(c);
        },
        inline 16...31 => {
            comptime {
                for ((imm8 - 16)..imm8, 0..) |v, i|
                    vec[i] = if (v < 16) v else ~@as(i32, @intCast(v - 16));
            }
            const a0: @Vector(16, i8) = @bitCast(a);
            const b0: @Vector(16, i8) = @splat(0);
            const c = @shuffle(i8, a0, b0, vec);
            return @bitCast(c);
        },
        inline else => return @splat(0),
    }
}

// palignr
pub inline fn _mm_alignr_pi8(a: __m64, b: __m64, comptime imm8: u8) __m64 {
    return asm volatile (comptimePrint("palignr ${d}, %mm1, %mm0", .{imm8})
        : [ret] "={mm0}" (-> __m64),
        : [a] "{mm0}" (a),
          [b] "{mm1}" (b),
    );
}

// phaddw
pub inline fn _mm_hadd_epi16(a: __m128i, b: __m128i) __m128i {
    const a0: @Vector(8, u16) = @bitCast(a);
    const b0: @Vector(8, u16) = @bitCast(b);
    const a1 = @Vector(8, u16){ a0[0], a0[2], a0[4], a0[6], b0[0], b0[2], b0[4], b0[6] };
    const b1 = @Vector(8, u16){ a0[1], a0[3], a0[5], a0[7], b0[1], b0[3], b0[5], b0[7] };
    const c = a1 +% b1;
    return @bitCast(c);
}

// phaddd
pub inline fn _mm_hadd_epi32(a: __m128i, b: __m128i) __m128i {
    const a0: @Vector(4, u32) = @bitCast(a);
    const b0: @Vector(4, u32) = @bitCast(b);
    const a1 = @Vector(4, u32){ a0[0], a0[2], b0[0], b0[2] };
    const b1 = @Vector(4, u32){ a0[1], a0[3], b0[1], b0[3] };
    const c = a1 +% b1;
    return @bitCast(c);
}

// phaddw
pub inline fn _mm_hadd_pi16(a: __m64, b: __m64) __m64 {
    return asm volatile (
        \\ phaddw %mm1, %mm0
        : [ret] "={mm0}" (-> __m64),
        : [a] "{mm0}" (a),
          [b] "{mm1}" (b),
    );
}

// phaddw
pub inline fn _mm_hadd_pi32(a: __m64, b: __m64) __m64 {
    return asm volatile (
        \\ phaddd %mm1, %mm0
        : [ret] "={mm0}" (-> __m64),
        : [a] "{mm0}" (a),
          [b] "{mm1}" (b),
    );
}

// phaddsw
pub inline fn _mm_hadds_epi16(a: __m128i, b: __m128i) __m128i {
    return asm volatile (
        \\ phaddsw %xmm1, %xmm0
        : [ret] "={xmm0}" (-> __m128i),
        : [a] "{xmm0}" (a),
          [b] "{xmm1}" (b),
    );
}

// phaddsw
pub inline fn _mm_hadds_pi16(a: __m64, b: __m64) __m64 {
    return asm volatile (
        \\ phaddsw %mm1, %mm0
        : [ret] "={mm0}" (-> __m64),
        : [a] "{mm0}" (a),
          [b] "{mm1}" (b),
    );
}

// phsubw
pub inline fn _mm_hsub_epi16(a: __m128i, b: __m128i) __m128i {
    const a0: @Vector(8, u16) = @bitCast(a);
    const b0: @Vector(8, u16) = @bitCast(b);
    const a1 = @Vector(8, u16){ a0[0], a0[2], a0[4], a0[6], b0[0], b0[2], b0[4], b0[6] };
    const b1 = @Vector(8, u16){ a0[1], a0[3], a0[5], a0[7], b0[1], b0[3], b0[5], b0[7] };
    const c = a1 -% b1;
    return @bitCast(c);
}

// phsubd
pub inline fn _mm_hsub_epi32(a: __m128i, b: __m128i) __m128i {
    const a0: @Vector(4, u32) = @bitCast(a);
    const b0: @Vector(4, u32) = @bitCast(b);
    const a1 = @Vector(4, u32){ a0[0], a0[2], b0[0], b0[2] };
    const b1 = @Vector(4, u32){ a0[1], a0[3], b0[1], b0[3] };
    const c = a1 -% b1;
    return @bitCast(c);
}

// phsubw
pub inline fn _mm_hsub_pi16(a: __m64, b: __m64) __m64 {
    return asm volatile (
        \\ phsubw %mm1, %mm0
        : [ret] "={mm0}" (-> __m64),
        : [a] "{mm0}" (a),
          [b] "{mm1}" (b),
    );
}

// phsubd
pub inline fn _mm_hsub_pi32(a: __m64, b: __m64) __m64 {
    return asm volatile (
        \\ phsubd %mm1, %mm0
        : [ret] "={mm0}" (-> __m64),
        : [a] "{mm0}" (a),
          [b] "{mm1}" (b),
    );
}

// phsubsw
pub inline fn _mm_hsubs_epi16(a: __m128i, b: __m128i) __m128i {
    return asm volatile (
        \\ phsubsw %xmm1, %xmm0
        : [ret] "={xmm0}" (-> __m128i),
        : [a] "{xmm0}" (a),
          [b] "{xmm1}" (b),
    );
}

// phsubsw
pub inline fn _mm_hsubs_pi16(a: __m64, b: __m64) __m64 {
    return asm volatile (
        \\ phsubsw %mm1, %mm0
        : [ret] "={mm0}" (-> __m64),
        : [a] "{mm0}" (a),
          [b] "{mm1}" (b),
    );
}

// pmaddubsw
pub inline fn _mm_maddubs_epi16(a: __m128i, b: __m128i) __m128i {
    return asm volatile (
        \\ pmaddubsw %xmm1, %xmm0
        : [ret] "={xmm0}" (-> __m128i),
        : [a] "{xmm0}" (a),
          [b] "{xmm1}" (b),
    );
}

// pmaddubsw
pub inline fn _mm_maddubs_pi16(a: __m64, b: __m64) __m64 {
    return asm volatile (
        \\ pmaddubsw %mm1, %mm0
        : [ret] "={mm0}" (-> __m64),
        : [a] "{mm0}" (a),
          [b] "{mm1}" (b),
    );
}

// pmulhrsw
pub inline fn _mm_mulhrs_epi16(a: __m128i, b: __m128i) __m128i {
    return asm volatile (
        \\ pmulhrsw %xmm1, %xmm0
        : [ret] "={xmm0}" (-> __m128i),
        : [a] "{xmm0}" (a),
          [b] "{xmm1}" (b),
    );
}

// pmulhrsw
pub inline fn _mm_mulhrs_pi16(a: __m64, b: __m64) __m64 {
    return asm volatile (
        \\ pmulhrsw %mm1, %mm0
        : [ret] "={mm0}" (-> __m64),
        : [a] "{mm0}" (a),
          [b] "{mm1}" (b),
    );
}

// pshufb
pub inline fn _mm_shuffle_epi8(a: __m128i, b: __m128i) __m128i {
    return asm volatile (
        \\ pshufb %xmm1, %xmm0
        : [ret] "={xmm0}" (-> __m128i),
        : [a] "{xmm0}" (a),
          [b] "{xmm1}" (b),
    );
}

// pshufb
pub inline fn _mm_shuffle_pi8(a: __m64, b: __m64) __m64 {
    return asm volatile (
        \\ pshufb %mm1, %mm0
        : [ret] "={mm0}" (-> __m64),
        : [a] "{mm0}" (a),
          [b] "{mm1}" (b),
    );
}

// psignw
pub inline fn _mm_sign_epi16(a: __m128i, b: __m128i) __m128i {
    return asm volatile (
        \\ psignw %xmm1, %xmm0
        : [ret] "={xmm0}" (-> __m128i),
        : [a] "{xmm0}" (a),
          [b] "{xmm1}" (b),
    );
}

// psignd
pub inline fn _mm_sign_epi32(a: __m128i, b: __m128i) __m128i {
    return asm volatile (
        \\ psignd %xmm1, %xmm0
        : [ret] "={xmm0}" (-> __m128i),
        : [a] "{xmm0}" (a),
          [b] "{xmm1}" (b),
    );
}

// psignb
pub inline fn _mm_sign_epi8(a: __m128i, b: __m128i) __m128i {
    return asm volatile (
        \\ psignb %xmm1, %xmm0
        : [ret] "={xmm0}" (-> __m128i),
        : [a] "{xmm0}" (a),
          [b] "{xmm1}" (b),
    );
}

// psignw
pub inline fn _mm_sign_pi16(a: __m64, b: __m64) __m64 {
    return asm volatile (
        \\ psignw %mm1, %mm0
        : [ret] "={mm0}" (-> __m64),
        : [a] "{mm0}" (a),
          [b] "{mm1}" (b),
    );
}

// psignd
pub inline fn _mm_sign_pi32(a: __m64, b: __m64) __m64 {
    return asm volatile (
        \\ psignd %mm1, %mm0
        : [ret] "={mm0}" (-> __m64),
        : [a] "{mm0}" (a),
          [b] "{mm1}" (b),
    );
}

// psignb
pub inline fn _mm_sign_pi8(a: __m64, b: __m64) __m64 {
    return asm volatile (
        \\ psignb %mm1, %mm0
        : [ret] "={mm0}" (-> __m64),
        : [a] "{mm0}" (a),
          [b] "{mm1}" (b),
    );
}
