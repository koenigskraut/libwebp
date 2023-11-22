const std = @import("std");

const assert = std.debug.assert;

pub const VP8_RANDOM_DITHER_FIX = 8; // fixed-point precision for dithering
pub const VP8_RANDOM_TABLE_SIZE = 55;

pub const VP8Random = extern struct {
    index1_: c_int,
    index2_: c_int,
    tab_: [VP8_RANDOM_TABLE_SIZE]u32,
    amp_: c_int,
};

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
