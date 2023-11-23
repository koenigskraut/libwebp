const std = @import("std");

//------------------------------------------------------------------------------
// Decoding

// color mapping related functions.
pub inline fn VP8GetARGBIndex(idx: u32) u32 {
    return (idx >> 8) & 0xff;
}

pub inline fn VP8GetAlphaIndex(idx: u8) u8 {
    return idx;
}

pub inline fn VP8GetARGBValue(val: u32) u32 {
    return val;
}

pub inline fn VP8GetAlphaValue(val: u32) u8 {
    return (val >> 8) & 0xff;
}

//------------------------------------------------------------------------------
// Misc methods.

/// Computes sampled size of 'size' when sampling using 'sampling bits'.
pub inline fn VP8LSubSampleSize(size: u32, sampling_bits: u32) u32 {
    return (size +% @as(u32, (@as(u32, 1) << @truncate(sampling_bits))) -% 1) >> @truncate(sampling_bits);
}

// Converts near lossless quality into max number of bits shaved off.
pub inline fn VP8LNearLosslessBits(near_lossless_quality: c_int) c_int {
    //    100 -> 0
    // 80..99 -> 1
    // 60..79 -> 2
    // 40..59 -> 3
    // 20..39 -> 4
    //  0..19 -> 5
    return 5 - @divTrunc(near_lossless_quality, 20);
}

// -----------------------------------------------------------------------------
