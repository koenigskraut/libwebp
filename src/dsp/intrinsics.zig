const std = @import("std");

pub const m128 = @Vector(2, u64);

pub const v128 = packed struct {
    v: @Vector(2, u64),

    pub inline fn vec(self: v128) @Vector(2, u64) {
        return @bitCast(self);
    }

    pub inline fn zero() v128 {
        return .{ .v = @splat(0) };
    }

    pub inline fn set1u8(a: u8) v128 {
        return .{ .v = @bitCast(@as(@Vector(16, u8), @splat(a))) };
    }

    pub inline fn set1u16(a: u16) v128 {
        return .{ .v = @bitCast(@as(@Vector(8, u16), @splat(a))) };
    }

    pub inline fn set1u32(a: u32) v128 {
        return .{ .v = @bitCast(@as(@Vector(4, u32), @splat(a))) };
    }

    /// mirror of _mm_setr_epi8, beware of the reverse order
    pub inline fn setU8(a: [16]u8) v128 {
        return .{ .v = @bitCast(@Vector(16, u8){ a[15], a[14], a[13], a[12], a[11], a[10], a[9], a[8], a[7], a[6], a[5], a[4], a[3], a[2], a[1], a[0] }) };
    }

    /// mirror of _mm_setr_epi8, beware of the reverse order
    pub inline fn setI8(a: [16]i8) v128 {
        return setU8(@bitCast(a));
    }

    /// mirror of _mm_setr_epi8, beware of the reverse order
    pub inline fn setU8R(a: [16]u8) v128 {
        return .{ .v = @bitCast(a) };
    }

    /// mirror of _mm_setr_epi8, beware of the reverse order
    pub inline fn setI8R(a: [16]i8) v128 {
        return setU8R(@bitCast(a));
    }

    /// mirror of _mm_set_epi32, beware of the reverse order
    pub inline fn setU32(a: [4]u32) v128 {
        return .{ .v = @bitCast(@Vector(4, u32){ a[3], a[2], a[1], a[0] }) };
    }

    /// mirror of _mm_set_epi32, beware of the reverse order
    pub inline fn setI32(a: [4]i32) v128 {
        return setU32(@bitCast(a));
    }

    pub inline fn load128(ptr: [*c]const u8) v128 {
        return .{ .v = @bitCast(ptr[0..16].*) };
    }
};

pub inline fn Z_mm_loadl_epi64(ptr: [*c]const u8) @Vector(2, u64) {
    return .{ @as(u64, @bitCast(ptr[0..8].*)), 0 };
}

pub inline fn Z_mm_unpacklo_epi8(A: @Vector(2, u64), B: @Vector(2, u64)) @Vector(2, u64) {
    const a: @Vector(16, u8) = @bitCast(A);
    const b: @Vector(16, u8) = @bitCast(B);
    const c = @shuffle(u8, a, b, @Vector(16, i32){ 0, -1, 1, -2, 2, -3, 3, -4, 4, -5, 5, -6, 6, -7, 7, -8 });
    return @bitCast(c);
}

pub inline fn Z_mm_unpackhi_epi8(A: @Vector(2, u64), B: @Vector(2, u64)) @Vector(2, u64) {
    const a: @Vector(16, u8) = @bitCast(A);
    const b: @Vector(16, u8) = @bitCast(B);
    const c = @shuffle(u8, a, b, @Vector(16, i32){ 8, -9, 9, -10, 10, -11, 11, -12, 12, -13, 13, -14, 14, -15, 15, -16 });
    return @bitCast(c);
}

pub inline fn Z_mm_unpacklo_epi16(A: @Vector(2, u64), B: @Vector(2, u64)) @Vector(2, u64) {
    const a: @Vector(8, u16) = @bitCast(A);
    const b: @Vector(8, u16) = @bitCast(B);
    const c = @shuffle(u16, a, b, @Vector(8, i32){ 0, -1, 1, -2, 2, -3, 3, -4 });
    return @bitCast(c);
}

pub inline fn Z_mm_unpackhi_epi16(A: @Vector(2, u64), B: @Vector(2, u64)) @Vector(2, u64) {
    const a: @Vector(8, u16) = @bitCast(A);
    const b: @Vector(8, u16) = @bitCast(B);
    const c = @shuffle(u16, a, b, @Vector(8, i32){ 4, -5, 5, -6, 6, -7, 7, -8 });
    return @bitCast(c);
}

pub inline fn Z_mm_unpacklo_epi32(A: @Vector(2, u64), B: @Vector(2, u64)) @Vector(2, u64) {
    const a: @Vector(4, u32) = @bitCast(A);
    const b: @Vector(4, u32) = @bitCast(B);
    const c = @shuffle(u32, a, b, @Vector(4, i32){ 0, -1, 1, -2 });
    return @bitCast(c);
}

pub inline fn Z_mm_unpackhi_epi32(A: @Vector(2, u64), B: @Vector(2, u64)) @Vector(2, u64) {
    const a: @Vector(4, u32) = @bitCast(A);
    const b: @Vector(4, u32) = @bitCast(B);
    const c = @shuffle(u32, a, b, @Vector(4, i32){ 2, -3, 3, -4 });
    return @bitCast(c);
}

pub inline fn Z_mm_unpacklo_epi64(A: @Vector(2, u64), B: @Vector(2, u64)) @Vector(2, u64) {
    const c = @shuffle(u64, A, B, @Vector(2, i32){ 0, -1 });
    return @bitCast(c);
}

pub inline fn Z_mm_unpackhi_epi64(A: @Vector(2, u64), B: @Vector(2, u64)) @Vector(2, u64) {
    const c = @shuffle(u64, A, B, @Vector(2, i32){ 1, -2 });
    return @bitCast(c);
}

pub inline fn Z_mm_or_si128(A: @Vector(2, u64), B: @Vector(2, u64)) @Vector(2, u64) {
    return A | B;
}

pub inline fn Z_mm_mullo_epi16(A: @Vector(2, u64), B: @Vector(2, u64)) @Vector(2, u64) {
    const a: @Vector(8, u16) = @bitCast(A);
    const b: @Vector(8, u16) = @bitCast(B);
    return @bitCast(a * b);
}

pub inline fn Z_mm_mulhi_epi16(A: @Vector(2, u64), B: @Vector(2, u64)) @Vector(2, u64) {
    const a: @Vector(8, u16) = @bitCast(A);
    const b: @Vector(8, u16) = @bitCast(B);
    return asm volatile (
        \\ pmulhw %xmm1, %xmm0
        : [ret] "={xmm0}" (-> @Vector(2, u64)),
        : [a] "{xmm0}" (a),
          [b] "{xmm1}" (b),
    );
}

pub inline fn Z_mm_mulhi_epu16(A: @Vector(2, u64), B: @Vector(2, u64)) @Vector(2, u64) {
    const a: @Vector(8, u16) = @bitCast(A);
    const b: @Vector(8, u16) = @bitCast(B);
    return asm volatile (
        \\ pmulhuw %xmm1, %xmm0
        : [ret] "={xmm0}" (-> @Vector(2, u64)),
        : [a] "{xmm0}" (a),
          [b] "{xmm1}" (b),
    );
}

pub inline fn Z_mm_add_epi16(A: @Vector(2, u64), B: @Vector(2, u64)) @Vector(2, u64) {
    return @bitCast(@as(@Vector(8, u16), @bitCast(A)) +% @as(@Vector(8, u16), @bitCast(B)));
}

pub inline fn Z_mm_sub_epi16(A: @Vector(2, u64), B: @Vector(2, u64)) @Vector(2, u64) {
    return @bitCast(@as(@Vector(8, u16), @bitCast(A)) -% @as(@Vector(8, u16), @bitCast(B)));
}

pub inline fn Z_mm_subs_epu8(A: @Vector(2, u64), B: @Vector(2, u64)) @Vector(2, u64) {
    return @bitCast(@as(@Vector(16, u8), @bitCast(A)) -| @as(@Vector(16, u8), @bitCast(B)));
}

pub inline fn Z_mm_subs_epi8(A: @Vector(2, u64), B: @Vector(2, u64)) @Vector(2, u64) {
    return @bitCast(@as(@Vector(16, i8), @bitCast(A)) -| @as(@Vector(16, i8), @bitCast(B)));
}

pub inline fn Z_mm_adds_epi8(A: @Vector(2, u64), B: @Vector(2, u64)) @Vector(2, u64) {
    return @bitCast(@as(@Vector(16, i8), @bitCast(A)) +| @as(@Vector(16, i8), @bitCast(B)));
}

pub inline fn Z_mm_sub_epi8(A: @Vector(2, u64), B: @Vector(2, u64)) @Vector(2, u64) {
    return @bitCast(@as(@Vector(16, i8), @bitCast(A)) -% @as(@Vector(16, i8), @bitCast(B)));
}

pub inline fn Z_mm_add_epi8(A: @Vector(2, u64), B: @Vector(2, u64)) @Vector(2, u64) {
    return @bitCast(@as(@Vector(16, i8), @bitCast(A)) +% @as(@Vector(16, i8), @bitCast(B)));
}

pub inline fn Z_mm_storel_epi64(P: [*c]u8, B: @Vector(2, u64)) void {
    P[0..8].* = @bitCast(@as([2]u64, B)[0]);
}

pub inline fn Z_mm_packus_epi16(A: @Vector(2, u64), B: @Vector(2, u64)) @Vector(2, u64) {
    const a: @Vector(8, u16) = @bitCast(A);
    const b: @Vector(8, u16) = @bitCast(B);
    return asm volatile (
        \\ packuswb %xmm1, %xmm0
        : [ret] "={xmm0}" (-> @Vector(2, u64)),
        : [a] "{xmm0}" (a),
          [b] "{xmm1}" (b),
    );
}

pub inline fn Z_mm_packs_epi16(A: @Vector(2, u64), B: @Vector(2, u64)) @Vector(2, u64) {
    const a: @Vector(8, u16) = @bitCast(A);
    const b: @Vector(8, u16) = @bitCast(B);
    return asm volatile (
        \\ packsswb %xmm1, %xmm0
        : [ret] "={xmm0}" (-> @Vector(2, u64)),
        : [a] "{xmm0}" (a),
          [b] "{xmm1}" (b),
    );
}

pub inline fn shuffleMask(comptime mask: [4]i32, mode: enum { lo, hi }) @Vector(8, u32) {
    return switch (mode) {
        .lo => mask ++ [4]i32{ 4, 5, 6, 7 },
        .hi => comptime std.simd.join(@Vector(4, u32){ 0, 1, 2, 3 }, @as(@Vector(4, i32), mask) + @as(@Vector(4, i32), @splat(4))),
    };
}

pub inline fn Z_mm_shufflelo_epi16(A: @Vector(2, u64), comptime shuffle: [4]i32) @Vector(2, u64) {
    const a: @Vector(8, u16) = @bitCast(A);
    return @bitCast(@shuffle(u16, a, undefined, shuffleMask(shuffle, .lo)));
}

pub inline fn Z_mm_shufflehi_epi16(A: @Vector(2, u64), comptime shuffle: [4]i32) @Vector(2, u64) {
    const a: @Vector(8, u16) = @bitCast(A);
    return @bitCast(@shuffle(u16, a, undefined, shuffleMask(shuffle, .hi)));
}

pub inline fn Z_mm_cvtsi32_si128(a: u32) @Vector(2, u64) {
    return @bitCast(@Vector(4, u32){ a, 0, 0, 0 });
}

pub inline fn Z_mm_cvtsi128_si32(A: @Vector(2, u64)) u32 {
    return @as([4]u32, @bitCast(A))[0];
}

pub inline fn Z_mm_cmpeq_epi8(A: @Vector(2, u64), B: @Vector(2, u64)) @Vector(2, u64) {
    const a: @Vector(16, u8) = @bitCast(A);
    const b: @Vector(16, u8) = @bitCast(B);
    const all_0xff: @Vector(16, u8) = @splat(0xff);
    const zero: @Vector(16, u8) = @splat(0);
    return @bitCast(@select(u8, a == b, all_0xff, zero));
}

pub inline fn Z_mm_avg_epu8(A: @Vector(2, u64), B: @Vector(2, u64)) @Vector(2, u64) {
    const a: @Vector(16, u8) = @bitCast(A);
    const b: @Vector(16, u8) = @bitCast(B);
    return asm volatile (
        \\ pavgb %xmm1, %xmm0
        : [ret] "={xmm0}" (-> @Vector(2, u64)),
        : [a] "{xmm0}" (a),
          [b] "{xmm1}" (b),
    );
}

pub inline fn Z_mm_andnot_si128(A: @Vector(2, u64), B: @Vector(2, u64)) @Vector(2, u64) {
    return B & ~A;
}

pub inline fn Z_mm_srli_si128(A: @Vector(2, u64), comptime amount: comptime_int) @Vector(2, u64) {
    const a: @Vector(16, u8) = @bitCast(A);
    return @bitCast(std.simd.shiftElementsLeft(a, amount, 0));
}

pub inline fn Z_mm_slli_si128(A: @Vector(2, u64), comptime amount: comptime_int) @Vector(2, u64) {
    const a: @Vector(16, u8) = @bitCast(A);
    return @bitCast(std.simd.shiftElementsRight(a, amount, 0));
}

pub inline fn Z_mm_max_epu8(A: @Vector(2, u64), B: @Vector(2, u64)) @Vector(2, u64) {
    const a: @Vector(16, u8) = @bitCast(A);
    const b: @Vector(16, u8) = @bitCast(B);
    return @bitCast(@max(a, b));
}

pub inline fn Z_mm_insert_epi16(A: @Vector(2, u64), i: i16, comptime pos: comptime_int) @Vector(2, u64) {
    var a: [8]i16 = @bitCast(A);
    a[pos] = @truncate(i);
    return @bitCast(a);
}

pub inline fn Z_mm_sad_epu8(A: @Vector(2, u64), B: @Vector(2, u64)) @Vector(2, u64) {
    return asm volatile (
        \\ psadbw %xmm1, %xmm0
        : [ret] "={xmm0}" (-> @Vector(2, u64)),
        : [a] "{xmm0}" (A),
          [b] "{xmm1}" (B),
    );
}

pub inline fn Z_mm_shuffle_epi32(A: @Vector(2, u64), comptime shuffle: [4]i32) @Vector(2, u64) {
    const a: @Vector(4, u32) = @bitCast(A);
    return @bitCast(@shuffle(u32, a, undefined, shuffle));
}

pub inline fn Z_mm_shuffle_epi8(A: @Vector(2, u64), B: @Vector(2, u64)) @Vector(2, u64) {
    return asm volatile (
        \\ pshufb %xmm1, %xmm0
        : [ret] "={xmm0}" (-> @Vector(2, u64)),
        : [a] "{xmm0}" (A),
          [b] "{xmm1}" (B),
    );
}

pub inline fn Z_mm_blendv_epi8(A: @Vector(2, u64), B: @Vector(2, u64), mask: @Vector(2, u64)) @Vector(2, u64) {
    return asm volatile (
        \\ pblendvb %xmm0, %xmm1, %xmm3
        : [ret] "={xmm3}" (-> @Vector(2, u64)),
        : [a] "{xmm3}" (A),
          [b] "{xmm1}" (B),
          [mask] "{xmm0}" (mask),
    );
}

pub inline fn Z_mm_blend_epi16(A: @Vector(2, u64), B: @Vector(2, u64), comptime i: u8) @Vector(2, u64) {
    const a: @Vector(8, u16) = @bitCast(A);
    const b: @Vector(8, u16) = @bitCast(B);
    const mask: @Vector(8, bool) = @bitCast(i);
    return @bitCast(@select(u16, mask, b, a));
}

pub inline fn Z_mm_srli_epi64(A: @Vector(2, u64), comptime amount: comptime_int) @Vector(2, u64) {
    return A >> @splat(amount);
}
