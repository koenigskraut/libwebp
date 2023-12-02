const std = @import("std");
const webp = struct {
    usingnamespace @import("../utils/utils.zig");
};

const assert = std.debug.assert;

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
    return @truncate((val >> 8) & 0xff);
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
// PrefixEncode()

// Splitting of distance and length codes into prefixes and
// extra bits. The prefixes are encoded with an entropy code
// while the extra bits are stored just as normal bits.
// inline fn VP8LPrefixEncodeBitsNoLUT(distance_: i32, code: *c_int, extra_bits: *c_int) void {
//     var distance = distance_ - 1;
//     const highest_bit = webp.BitsLog2Floor(@bitCast(distance));
//     const second_highest_bit = (distance >> @intCast(highest_bit - 1)) & 1;
//     extra_bits.* = highest_bit - 1;
//     code.* = 2 * highest_bit + second_highest_bit;
// }

// inline fn VP8LPrefixEncodeNoLUT(int distance, int* const code,
//                                               int* const extra_bits,
//                                               int* const extra_bits_value) void {
//   const int highest_bit = BitsLog2Floor(--distance);
//   const int second_highest_bit = (distance >> (highest_bit - 1)) & 1;
//   *extra_bits = highest_bit - 1;
//   *extra_bits_value = distance & ((1 << *extra_bits) - 1);
//   *code = 2 * highest_bit + second_highest_bit;
// }

// #define PREFIX_LOOKUP_IDX_MAX   512
// typedef struct {
//   int8_t code_;
//   int8_t extra_bits_;
// } VP8LPrefixCode;

// // These tables are derived using VP8LPrefixEncodeNoLUT.
// extern const VP8LPrefixCode kPrefixEncodeCode[PREFIX_LOOKUP_IDX_MAX];
// extern const uint8_t kPrefixEncodeExtraBitsValue[PREFIX_LOOKUP_IDX_MAX];
// static WEBP_INLINE void VP8LPrefixEncodeBits(int distance, int* const code,
//                                              int* const extra_bits) {
//   if (distance < PREFIX_LOOKUP_IDX_MAX) {
//     const VP8LPrefixCode prefix_code = kPrefixEncodeCode[distance];
//     *code = prefix_code.code_;
//     *extra_bits = prefix_code.extra_bits_;
//   } else {
//     VP8LPrefixEncodeBitsNoLUT(distance, code, extra_bits);
//   }
// }

// static WEBP_INLINE void VP8LPrefixEncode(int distance, int* const code,
//                                          int* const extra_bits,
//                                          int* const extra_bits_value) {
//   if (distance < PREFIX_LOOKUP_IDX_MAX) {
//     const VP8LPrefixCode prefix_code = kPrefixEncodeCode[distance];
//     *code = prefix_code.code_;
//     *extra_bits = prefix_code.extra_bits_;
//     *extra_bits_value = kPrefixEncodeExtraBitsValue[distance];
//   } else {
//     VP8LPrefixEncodeNoLUT(distance, code, extra_bits, extra_bits_value);
//   }
// }

/// Sum of each component, mod 256.
pub inline fn VP8LAddPixels(a: u32, b: u32) u32 {
    const alpha_and_green: u32 = (a & 0xff00ff00) +% (b & 0xff00ff00);
    const red_and_blue: u32 = (a & 0x00ff00ff) +% (b & 0x00ff00ff);
    return (alpha_and_green & 0xff00ff00) | (red_and_blue & 0x00ff00ff);
}

// Difference of each component, mod 256.
pub inline fn VP8LSubPixels(a: u32, b: u32) u32 {
    const alpha_and_green: u32 = 0x00ff00ff +% (a & 0xff00ff00) -% (b & 0xff00ff00);
    const red_and_blue: u32 = 0xff00ff00 +% (a & 0x00ff00ff) -% (b & 0x00ff00ff);
    return (alpha_and_green & 0xff00ff00) | (red_and_blue & 0x00ff00ff);
}

//------------------------------------------------------------------------------
// Transform-related functions used in both encoding and decoding.

// Macros used to create a batch predictor that iteratively uses a
// one-pixel predictor.

pub const PredictorBody = fn (a: [*c]const u32, b: [*c]const u32) callconv(.C) u32;
pub const PredictorAddBody = fn (in: [*c]const u32, upper: [*c]const u32, num_pixels: c_int, out: [*c]u32) callconv(.C) void;

/// The predictor is added to the output pixel (which
/// is therefore considered as a residual) to get the final prediction.
pub fn GeneratePredictorAdd(comptime predictor: PredictorBody) PredictorAddBody {
    return struct {
        pub fn _(in: [*c]const u32, upper: [*c]const u32, num_pixels: c_int, out: [*c]u32) callconv(.C) void {
            assert(upper != null);
            for (0..@intCast(num_pixels)) |x| {
                const pred: u32 = predictor(out + x - 1, upper + x);
                out[x] = VP8LAddPixels(in[x], pred);
            }
        }
    }._;
}
