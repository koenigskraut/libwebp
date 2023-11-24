const std = @import("std");

const assert = std.debug.assert;

pub const VP8_RANDOM_DITHER_FIX = 8; // fixed-point precision for dithering
pub const VP8_RANDOM_TABLE_SIZE = 55;

pub const VP8Random = extern struct {
    index1_: c_int,
    index2_: c_int,
    tab_: [VP8_RANDOM_TABLE_SIZE]u32,
    amp_: c_int, // TODO: change it to u32
};

/// 31b-range values
const kRandomTable = [VP8_RANDOM_TABLE_SIZE]u32{
    0x0de15230, 0x03b31886, 0x775faccb, 0x1c88626a, 0x68385c55, 0x14b3b828,
    0x4a85fef8, 0x49ddb84b, 0x64fcf397, 0x5c550289, 0x4a290000, 0x0d7ec1da,
    0x5940b7ab, 0x5492577d, 0x4e19ca72, 0x38d38c69, 0x0c01ee65, 0x32a1755f,
    0x5437f652, 0x5abb2c32, 0x0faa57b1, 0x73f533e7, 0x685feeda, 0x7563cce2,
    0x6e990e83, 0x4730a7ed, 0x4fc0d9c6, 0x496b153c, 0x4f1403fa, 0x541afb0c,
    0x73990b32, 0x26d7cb1c, 0x6fcc3706, 0x2cbb77d8, 0x75762f2a, 0x6425ccdd,
    0x24b35461, 0x0a7d8715, 0x220414a8, 0x141ebf67, 0x56b41583, 0x73e502e3,
    0x44cab16f, 0x28264d42, 0x73baaefb, 0x0a50ebed, 0x1d6ab6fb, 0x0d3ad40b,
    0x35db3b68, 0x2b081e83, 0x77ce6b95, 0x5181e5f0, 0x78853bbc, 0x009f9494,
    0x27e5ed3c,
};

/// Initializes random generator with an amplitude 'dithering' in range [0..1].
pub export fn VP8InitRandom(rg: *VP8Random, dithering: f32) void {
    @memcpy(&rg.tab_, &kRandomTable);
    rg.index1_ = 0;
    rg.index2_ = 31;
    rg.amp_ = if (dithering < 0.0)
        0
    else if (dithering > 1.0)
        (@as(c_int, 1) << VP8_RANDOM_DITHER_FIX)
    else
        @intCast(@as(u32, @intFromFloat(((1 << VP8_RANDOM_DITHER_FIX) * dithering))));
}

// Returns a centered pseudo-random number with `num_bits` amplitude.
// (uses D.Knuth's Difference-based random generator).
// 'amp' is in VP8_RANDOM_DITHER_FIX fixed-point precision.
pub inline fn VP8RandomBits2(rg: *VP8Random, num_bits: c_int, amp: c_int) c_int {
    assert(num_bits + VP8_RANDOM_DITHER_FIX <= 31);
    var diff: i32 = @bitCast(rg.tab_[@intCast(rg.index1_)] -% rg.tab_[@intCast(rg.index2_)]);
    if (diff < 0) diff +%= (@as(i32, 1) << 31);
    rg.tab_[@intCast(rg.index1_)] = @bitCast(diff);
    rg.index1_ += 1;
    if (rg.index1_ == VP8_RANDOM_TABLE_SIZE) rg.index1_ = 0;
    rg.index2_ += 1;
    if (rg.index2_ == VP8_RANDOM_TABLE_SIZE) rg.index2_ = 0;
    // sign-extend, 0-center
    diff = @as(i32, @bitCast(@as(u32, @bitCast(diff)) << 1)) >> @intCast(32 - num_bits);
    diff = (diff * amp) >> VP8_RANDOM_DITHER_FIX; // restrict range
    diff += 1 << @intCast(num_bits - 1); // shift back to 0.5-center
    return @intCast(diff);
}

pub inline fn VP8RandomBits(rg: *VP8Random, num_bits: c_int) c_int {
    return VP8RandomBits2(rg, num_bits, rg.amp_);
}
