const std = @import("std");

pub const __m128d = @Vector(2, f64);
pub const __m128i = @Vector(2, i64);
pub const __m128 = @Vector(4, f32);

pub const __m64 = @Vector(1, i64);
pub const __v1di = @Vector(1, i64);
pub const __v2si = @Vector(2, i64);
pub const __v4hi = @Vector(4, i16);
pub const __v8qi = @Vector(8, u8);

pub inline fn _mm_shuffle(mask: [4]u8) u8 {
    return (mask[0] << 6) | (mask[1] << 4) | (mask[2] << 2) | mask[3];
}

pub inline fn clampInt(comptime To: type, v: anytype) To {
    return @truncate(std.math.clamp(v, std.math.minInt(To), std.math.maxInt(To)));
}
