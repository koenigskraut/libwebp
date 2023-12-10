const std = @import("std");
const build_options = @import("build_options");
const webp = struct {
    usingnamespace @import("alpha_processing.zig");
    usingnamespace @import("cpu.zig");
    usingnamespace @import("lossless_common.zig");
    usingnamespace @import("../dec/vp8l_dec.zig");
    usingnamespace @import("../utils/utils.zig");
    usingnamespace @import("../webp/decode.zig");
    usingnamespace @import("../webp/format_constants.zig");
};

pub usingnamespace @import("lossless_common.zig");

const assert = std.debug.assert;
const c_bool = webp.c_bool;

//------------------------------------------------------------------------------
// Image transforms.

inline fn Average2(a0: u32, a1: u32) u32 {
    return (((a0 ^ a1) & 0xfefefefe) >> 1) +% (a0 & a1);
}

inline fn Average3(a0: u32, a1: u32, a2: u32) u32 {
    return Average2(Average2(a0, a2), a1);
}

inline fn Average4(a0: u32, a1: u32, a2: u32, a3: u32) u32 {
    return Average2(Average2(a0, a1), Average2(a2, a3));
}

inline fn Clip255(a: u32) u32 {
    if (a < 256) return a;

    // return 0, when a is a negative integer.
    // return 255, when a is positive.
    return ~a >> 24;
}

inline fn AddSubtractComponentFull(a: i32, b: i32, c: i32) i32 {
    return @bitCast(Clip255(@bitCast(a + b - c)));
}

inline fn ClampedAddSubtractFull(c0: u32, c1: u32, c2: u32) u32 {
    const a: u32 = @bitCast(AddSubtractComponentFull(@bitCast(c0 >> 24), @bitCast(c1 >> 24), @bitCast(c2 >> 24)));
    const r: u32 = @bitCast(AddSubtractComponentFull(@bitCast((c0 >> 16) & 0xff), @bitCast((c1 >> 16) & 0xff), @bitCast((c2 >> 16) & 0xff)));
    const g: u32 = @bitCast(AddSubtractComponentFull(@bitCast((c0 >> 8) & 0xff), @bitCast((c1 >> 8) & 0xff), @bitCast((c2 >> 8) & 0xff)));
    const b: u32 = @bitCast(AddSubtractComponentFull(@bitCast(c0 & 0xff), @bitCast(c1 & 0xff), @bitCast(c2 & 0xff)));
    return (a << 24) | (r << 16) | (g << 8) | b;
}

inline fn AddSubtractComponentHalf(a: i32, b: i32) i32 {
    return @bitCast(Clip255(@bitCast(a + @divTrunc(a - b, 2))));
}

inline fn ClampedAddSubtractHalf(c0: u32, c1: u32, c2: u32) u32 {
    const ave = Average2(c0, c1);
    const a: u32 = @bitCast(AddSubtractComponentHalf(@bitCast(ave >> 24), @bitCast(c2 >> 24)));
    const r: u32 = @bitCast(AddSubtractComponentHalf(@bitCast((ave >> 16) & 0xff), @bitCast((c2 >> 16) & 0xff)));
    const g: u32 = @bitCast(AddSubtractComponentHalf(@bitCast((ave >> 8) & 0xff), @bitCast((c2 >> 8) & 0xff)));
    const b: u32 = @bitCast(AddSubtractComponentHalf(@bitCast((ave >> 0) & 0xff), @bitCast((c2 >> 0) & 0xff)));
    return (a << 24) | (r << 16) | (g << 8) | b;
}

inline fn Sub3(a: i32, b: i32, c: i32) i32 {
    const pb: i32 = @bitCast(@abs(b - c));
    const pa: i32 = @bitCast(@abs(a - c));
    return pb - pa;
}

inline fn Select(a: u32, b: u32, c: u32) u32 {
    const pa_minus_pb =
        Sub3(@bitCast((a >> 24)), @bitCast((b >> 24)), @bitCast((c >> 24))) +
        Sub3(@bitCast((a >> 16) & 0xff), @bitCast((b >> 16) & 0xff), @bitCast((c >> 16) & 0xff)) +
        Sub3(@bitCast((a >> 8) & 0xff), @bitCast((b >> 8) & 0xff), @bitCast((c >> 8) & 0xff)) +
        Sub3(@bitCast((a) & 0xff), @bitCast((b) & 0xff), @bitCast((c) & 0xff));
    return if (pa_minus_pb <= 0) a else b;
}

//------------------------------------------------------------------------------
// Predictors

pub export fn VP8LPredictor0_C(left: [*c]const u32, top: [*c]const u32) callconv(.C) u32 {
    _ = left;
    _ = top;
    return webp.ARGB_BLACK;
}
pub export fn VP8LPredictor1_C(left: [*c]const u32, top: [*c]const u32) callconv(.C) u32 {
    _ = top;
    return left[0];
}
pub export fn VP8LPredictor2_C(left: [*c]const u32, top: [*c]const u32) callconv(.C) u32 {
    _ = left;
    return top[0];
}
pub export fn VP8LPredictor3_C(left: [*c]const u32, top: [*c]const u32) callconv(.C) u32 {
    _ = left;
    return top[1];
}
pub export fn VP8LPredictor4_C(left: [*c]const u32, top: [*c]const u32) callconv(.C) u32 {
    _ = left;
    return (top - 1)[0];
}
pub export fn VP8LPredictor5_C(left: [*c]const u32, top: [*c]const u32) callconv(.C) u32 {
    const pred = Average3(left[0], top[0], top[1]);
    return pred;
}
pub export fn VP8LPredictor6_C(left: [*c]const u32, top: [*c]const u32) callconv(.C) u32 {
    const pred = Average2(left[0], (top - 1)[0]);
    return pred;
}
pub export fn VP8LPredictor7_C(left: [*c]const u32, top: [*c]const u32) callconv(.C) u32 {
    const pred = Average2(left[0], top[0]);
    return pred;
}
pub export fn VP8LPredictor8_C(left: [*c]const u32, top: [*c]const u32) callconv(.C) u32 {
    _ = left;
    const pred = Average2((top - 1)[0], top[0]);
    return pred;
}
pub export fn VP8LPredictor9_C(left: [*c]const u32, top: [*c]const u32) callconv(.C) u32 {
    _ = left;
    const pred = Average2(top[0], top[1]);
    return pred;
}
pub export fn VP8LPredictor10_C(left: [*c]const u32, top: [*c]const u32) callconv(.C) u32 {
    const pred = Average4(left[0], (top - 1)[0], top[0], top[1]);
    return pred;
}
pub export fn VP8LPredictor11_C(left: [*c]const u32, top: [*c]const u32) callconv(.C) u32 {
    const pred = Select(top[0], left[0], (top - 1)[0]);
    return pred;
}
pub export fn VP8LPredictor12_C(left: [*c]const u32, top: [*c]const u32) callconv(.C) u32 {
    const pred = ClampedAddSubtractFull(left[0], top[0], (top - 1)[0]);
    return pred;
}
pub export fn VP8LPredictor13_C(left: [*c]const u32, top: [*c]const u32) callconv(.C) u32 {
    const pred = ClampedAddSubtractHalf(left[0], top[0], (top - 1)[0]);
    return pred;
}

fn PredictorAdd0_C(in: [*c]const u32, upper: [*c]const u32, num_pixels: c_int, out: [*c]u32) callconv(.C) void {
    _ = upper;
    for (0..@intCast(num_pixels)) |x| out[x] = webp.VP8LAddPixels(in[x], webp.ARGB_BLACK);
}

fn PredictorAdd1_C(in: [*c]const u32, upper: [*c]const u32, num_pixels: c_int, out: [*c]u32) callconv(.C) void {
    _ = upper;
    var left = (out - 1)[0];
    for (0..@intCast(num_pixels)) |i| {
        const tmp = webp.VP8LAddPixels(in[i], left);
        out[i], left = .{ tmp, tmp };
    }
}

pub const PredictorAdd2_C = webp.GeneratePredictorAdd(VP8LPredictor2_C);
pub const PredictorAdd3_C = webp.GeneratePredictorAdd(VP8LPredictor3_C);
pub const PredictorAdd4_C = webp.GeneratePredictorAdd(VP8LPredictor4_C);
pub const PredictorAdd5_C = webp.GeneratePredictorAdd(VP8LPredictor5_C);
pub const PredictorAdd6_C = webp.GeneratePredictorAdd(VP8LPredictor6_C);
pub const PredictorAdd7_C = webp.GeneratePredictorAdd(VP8LPredictor7_C);
pub const PredictorAdd8_C = webp.GeneratePredictorAdd(VP8LPredictor8_C);
pub const PredictorAdd9_C = webp.GeneratePredictorAdd(VP8LPredictor9_C);
pub const PredictorAdd10_C = webp.GeneratePredictorAdd(VP8LPredictor10_C);
pub const PredictorAdd11_C = webp.GeneratePredictorAdd(VP8LPredictor11_C);
pub const PredictorAdd12_C = webp.GeneratePredictorAdd(VP8LPredictor12_C);
pub const PredictorAdd13_C = webp.GeneratePredictorAdd(VP8LPredictor13_C);

comptime {
    @export(PredictorAdd2_C, .{ .name = "PredictorAdd2_C" });
    @export(PredictorAdd3_C, .{ .name = "PredictorAdd3_C" });
    @export(PredictorAdd4_C, .{ .name = "PredictorAdd4_C" });
    @export(PredictorAdd5_C, .{ .name = "PredictorAdd5_C" });
    @export(PredictorAdd6_C, .{ .name = "PredictorAdd6_C" });
    @export(PredictorAdd7_C, .{ .name = "PredictorAdd7_C" });
    @export(PredictorAdd8_C, .{ .name = "PredictorAdd8_C" });
    @export(PredictorAdd9_C, .{ .name = "PredictorAdd9_C" });
    @export(PredictorAdd10_C, .{ .name = "PredictorAdd10_C" });
    @export(PredictorAdd11_C, .{ .name = "PredictorAdd11_C" });
    @export(PredictorAdd12_C, .{ .name = "PredictorAdd12_C" });
    @export(PredictorAdd13_C, .{ .name = "PredictorAdd13_C" });
}

//------------------------------------------------------------------------------

// Inverse prediction.

pub const VP8LMultipliers = extern struct {
    // Note: the members are uint8_t, so that any negative values are
    // automatically converted to "mod 256" values.
    green_to_red_: u8,
    green_to_blue_: u8,
    red_to_blue_: u8,
};

fn PredictorInverseTransform_C(transform: *const webp.VP8LTransform, y_start_: c_int, y_end: c_int, in_: [*c]const u32, out_: [*c]u32) void {
    const width = transform.xsize_;
    var y_start: u32, var in, var out = .{ @bitCast(y_start_), in_, out_ };
    if (y_start == 0) { // First Row follows the L (mode=1) mode.
        PredictorAdd0_C(in, null, 1, out);
        PredictorAdd1_C(in + 1, null, width - 1, out + 1);
        in = webp.offsetPtr(in, width);
        out = webp.offsetPtr(out, width);
        y_start += 1;
    }

    {
        var y = y_start;
        const tile_width = @as(u32, 1) << @intCast(transform.bits_);
        const mask = tile_width - 1;
        const tiles_per_row = webp.VP8LSubSampleSize(@bitCast(width), @bitCast(transform.bits_));
        var pred_mode_base: [*c]const u32 = webp.offsetPtr(transform.data_, (y >> @intCast(transform.bits_)) * tiles_per_row);

        while (y < y_end) {
            var pred_mode_src = pred_mode_base;
            var x: u32 = 1;
            // First pixel follows the T (mode=2) mode.
            PredictorAdd2_C(in, webp.offsetPtr(out, -width), 1, out);
            // .. the rest:
            while (x < width) {
                const pred_func = VP8LPredictorsAdd[((pred_mode_src.*) >> 8) & 0xf].?;
                pred_mode_src += 1;
                var x_end = (x & ~mask) +% tile_width;
                if (x_end > width) x_end = @bitCast(width);
                pred_func(in + x, webp.offsetPtr(out + x, -width), @intCast(x_end - x), out + x);
                x = x_end;
            }
            in = webp.offsetPtr(in, width);
            out = webp.offsetPtr(out, width);
            y += 1;
            if ((y & mask) == 0) { // Use the same mask, since tiles are squares.
                pred_mode_base += tiles_per_row;
            }
        }
    }
}

// Add green to blue and red channels (i.e. perform the inverse transform of
// 'subtract green').
pub export fn VP8LAddGreenToBlueAndRed_C(src: [*c]const u32, num_pixels: c_int, dst: [*c]u32) callconv(.C) void {
    for (0..@intCast(num_pixels)) |i| {
        const argb = src[i];
        const green = ((argb >> 8) & 0xff);
        var red_blue = (argb & 0x00ff00ff);
        red_blue +%= (green << 16) | green;
        red_blue &= 0x00ff00ff;
        dst[i] = (argb & 0xff00ff00) | red_blue;
    }
}

inline fn ColorTransformDelta(color_pred: i8, color: i8) i32 {
    return (@as(i32, color_pred) * @as(i32, color)) >> 5;
}

inline fn ColorCodeToMultipliers(color_code: u32, m: *VP8LMultipliers) void {
    m.green_to_red_ = @truncate((color_code >> 0) & 0xff);
    m.green_to_blue_ = @truncate((color_code >> 8) & 0xff);
    m.red_to_blue_ = @truncate((color_code >> 16) & 0xff);
}

pub export fn VP8LTransformColorInverse_C(m: *const VP8LMultipliers, src: [*c]const u32, num_pixels: c_int, dst: [*c]u32) callconv(.C) void {
    for (0..@intCast(num_pixels)) |i| {
        const argb = src[i];
        const green: i8 = @truncate(@as(i32, @bitCast(argb >> 8)));
        const red: u32 = argb >> 16;
        var new_red: i32 = @bitCast(red & 0xff);
        var new_blue: i32 = @bitCast(argb & 0xff);
        new_red += ColorTransformDelta(@bitCast(m.green_to_red_), green);
        new_red &= 0xff;
        new_blue += ColorTransformDelta(@bitCast(m.green_to_blue_), green);
        new_blue += ColorTransformDelta(@bitCast(m.red_to_blue_), @truncate(new_red));
        new_blue &= 0xff;
        dst[i] = (argb & 0xff00ff00) | @as(u32, @bitCast(new_red << 16)) | @as(u32, @bitCast(new_blue));
    }
}

/// Color space inverse transform.
fn ColorSpaceInverseTransform_C(transform: *const webp.VP8LTransform, y_start: c_int, y_end: c_int, src_: [*c]const u32, dst_: [*c]u32) void {
    var src, var dst = .{ src_, dst_ };
    const width: u32 = @intCast(transform.xsize_);
    const transform_bits: u32 = @intCast(transform.bits_);
    const tile_width = @as(u32, 1) << @truncate(transform_bits);
    const mask = tile_width - 1;
    const safe_width = width & ~mask;
    const remaining_width: u32 = width - safe_width;
    const tiles_per_row = webp.VP8LSubSampleSize(width, transform_bits);
    var y: u32 = @intCast(y_start);
    var pred_row: [*c]const u32 = transform.data_ + (y >> @truncate(transform_bits)) * tiles_per_row;

    while (y < y_end) {
        var pred: [*c]const u32 = pred_row;
        var m = VP8LMultipliers{ .green_to_red_ = 0, .green_to_blue_ = 0, .red_to_blue_ = 0 };
        const src_safe_end = src + safe_width;
        const src_end = src + width;
        while (src < src_safe_end) {
            ColorCodeToMultipliers(pred[0], &m);
            pred += 1;
            VP8LTransformColorInverse.?(&m, src, @intCast(tile_width), dst);
            src += tile_width;
            dst += tile_width;
        }
        if (src < src_end) { // Left-overs using C-version.
            ColorCodeToMultipliers(pred[0], &m);
            pred += 1;
            VP8LTransformColorInverse.?(&m, src, @intCast(remaining_width), dst);
            src += remaining_width;
            dst += remaining_width;
        }
        y += 1;
        if ((y & mask) == 0) pred_row += tiles_per_row;
    }
}

// Separate out pixels packed together using pixel-bundling.
// We define two methods for ARGB data (uint32_t) and alpha-only data (uint8_t).

fn MapARGB_C(src_: [*c]const u32, color_map: [*c]const u32, dst_: [*c]u32, y_start: c_int, y_end: c_int, width: c_int) callconv(.C) void {
    var src, var dst = .{ src_, dst_ };
    for (@intCast(y_start)..@intCast(y_end)) |_| { // y
        for (0..@intCast(width)) |_| { // x
            dst[0] = webp.VP8GetARGBValue(color_map[webp.VP8GetARGBIndex(src[0])]);
            dst += 1;
            src += 1;
        }
    }
}

fn ColorIndexInverseTransform_C(transform: *const webp.VP8LTransform, y_start: c_int, y_end: c_int, src_: [*c]const u32, dst_: [*c]u32) void {
    var src, var dst = .{ src_, dst_ };
    const bits_per_pixel: u32 = @as(u32, 8) >> @intCast(transform.bits_);
    const width: u32 = @intCast(transform.xsize_);
    const color_map: [*c]const u32 = transform.data_;
    if (bits_per_pixel < 8) {
        const pixels_per_byte = @as(u32, 1) << @intCast(transform.bits_);
        const count_mask = pixels_per_byte -% 1;
        const bit_mask = (@as(u32, 1) << @truncate(bits_per_pixel)) -% 1;
        for (@intCast(y_start)..@intCast(y_end)) |_| { // y
            var packed_pixels: u32 = 0;
            for (0..width) |x| {
                // We need to load fresh 'packed_pixels' once every
                // 'pixels_per_byte' increments of x. Fortunately, pixels_per_byte
                // is a power of 2, so can just use a mask for that, instead of
                // decrementing a counter.
                if ((x & count_mask) == 0) {
                    packed_pixels = webp.VP8GetARGBIndex(src[0]);
                    src += 1;
                }
                dst[0] = webp.VP8GetARGBValue(color_map[packed_pixels & bit_mask]);
                dst += 1;
                packed_pixels >>= @truncate(bits_per_pixel);
            }
        }
    } else {
        VP8LMapColor32b.?(src, color_map, dst, y_start, y_end, @intCast(width));
    }
}

fn MapAlpha_C(src_: [*c]const u8, color_map: [*c]const u32, dst_: [*c]u8, y_start: c_int, y_end: c_int, width: c_int) callconv(.C) void {
    var src, var dst = .{ src_, dst_ };
    for (@intCast(y_start)..@intCast(y_end)) |_| { // y
        for (0..@intCast(width)) |_| { // x
            dst[0] = webp.VP8GetAlphaValue(color_map[webp.VP8GetAlphaIndex(src[0])]);
            dst += 1;
            src += 1;
        }
    }
}

pub export fn VP8LColorIndexInverseTransformAlpha(transform: *const webp.VP8LTransform, y_start: c_int, y_end: c_int, src_: [*c]const u8, dst_: [*c]u8) void {
    var src, var dst = .{ src_, dst_ };
    const bits_per_pixel = @as(u32, 8) >> @intCast(transform.bits_);
    const width: u32 = @intCast(transform.xsize_);
    const color_map: [*c]const u32 = transform.data_;
    if (bits_per_pixel < 8) {
        const pixels_per_byte = @as(u32, 1) << @intCast(transform.bits_);
        const count_mask = pixels_per_byte -% 1;
        const bit_mask = (@as(u32, 1) << @truncate(bits_per_pixel)) -% 1;
        for (@intCast(y_start)..@intCast(y_end)) |_| { // y
            var packed_pixels: u32 = 0;
            for (0..width) |x| {
                // We need to load fresh 'packed_pixels' once every
                // 'pixels_per_byte' increments of x. Fortunately, pixels_per_byte
                // is a power of 2, so can just use a mask for that, instead of
                // decrementing a counter.
                if ((x & count_mask) == 0) {
                    packed_pixels = webp.VP8GetAlphaIndex(src[0]);
                    src += 1;
                }
                dst[0] = webp.VP8GetAlphaValue(color_map[packed_pixels & bit_mask]);
                dst += 1;
                packed_pixels >>= @truncate(bits_per_pixel);
            }
        }
    } else {
        VP8LMapColor8b.?(src, color_map, dst, y_start, y_end, @intCast(width));
    }
}

pub export fn VP8LInverseTransform(transform: *const webp.VP8LTransform, row_start: c_int, row_end: c_int, in: [*c]const u32, out: [*c]u32) void {
    const width: u32 = @intCast(transform.xsize_);
    assert(row_start < row_end);
    assert(row_end <= transform.ysize_);
    switch (transform.type_) {
        .SUBTRACT_GREEN_TRANSFORM => {
            VP8LAddGreenToBlueAndRed.?(in, (row_end - row_start) * @as(i32, @intCast(width)), out);
        },
        .PREDICTOR_TRANSFORM => {
            PredictorInverseTransform_C(transform, row_start, row_end, in, out);
            if (row_end != transform.ysize_) {
                // The last predicted row in this iteration will be the top-pred row
                // for the first row in next iteration.
                @memcpy((out - width)[0..width], webp.offsetPtr(out, (row_end - row_start - 1) * @as(i32, @intCast(width)))[0..width]);
            }
        },
        .CROSS_COLOR_TRANSFORM => {
            ColorSpaceInverseTransform_C(transform, row_start, row_end, in, out);
        },
        .COLOR_INDEXING_TRANSFORM => {
            if (in == out and transform.bits_ > 0) {
                // Move packed pixels to the end of unpacked region, so that unpacking
                // can occur seamlessly.
                // Also, note that this is the only transform that applies on
                // the effective width of VP8LSubSampleSize(xsize_, bits_). All other
                // transforms work on effective width of xsize_.
                const out_stride: u32 = @intCast((row_end - row_start) * @as(i32, @intCast(width)));
                const in_stride: u32 = @as(u32, @intCast(row_end - row_start)) * webp.VP8LSubSampleSize(@intCast(transform.xsize_), @intCast(transform.bits_));
                const src: [*c]u32 = out + out_stride - in_stride;
                std.mem.copyForwards(u32, src[0..in_stride], out[0..in_stride]);
                ColorIndexInverseTransform_C(transform, row_start, row_end, src, out);
            } else {
                ColorIndexInverseTransform_C(transform, row_start, row_end, in, out);
            }
        },
    }
}

//------------------------------------------------------------------------------
// Color space conversion.

fn is_big_endian() c_bool {
    const S = struct {
        const tmp = extern union {
            w: u16,
            b: [2]u8,
        }{ .w = 1 };
    };
    return @intFromBool(S.tmp.b[0] != 1);
}

pub export fn VP8LConvertBGRAToRGB_C(src_: [*c]const u32, num_pixels: c_int, dst_: [*c]u8) callconv(.C) void {
    var src, var dst = .{ src_, dst_ };
    const src_end = webp.offsetPtr(src, num_pixels);
    while (src < src_end) {
        const argb = src[0];
        src += 1;
        dst[0] = @truncate((argb >> 16) & 0xff);
        dst += 1;
        dst[0] = @truncate((argb >> 8) & 0xff);
        dst += 1;
        dst[0] = @truncate((argb >> 0) & 0xff);
        dst += 1;
    }
}

pub export fn VP8LConvertBGRAToRGBA_C(src_: [*c]const u32, num_pixels: c_int, dst_: [*c]u8) callconv(.C) void {
    var src, var dst = .{ src_, dst_ };
    const src_end = webp.offsetPtr(src, num_pixels);
    while (src < src_end) {
        const argb = src[0];
        src += 1;
        dst[0] = @truncate((argb >> 16) & 0xff);
        dst += 1;
        dst[0] = @truncate((argb >> 8) & 0xff);
        dst += 1;
        dst[0] = @truncate((argb >> 0) & 0xff);
        dst += 1;
        dst[0] = @truncate((argb >> 24) & 0xff);
        dst += 1;
    }
}

pub export fn VP8LConvertBGRAToRGBA4444_C(src_: [*c]const u32, num_pixels: c_int, dst_: [*c]u8) callconv(.C) void {
    var src, var dst = .{ src_, dst_ };
    const src_end = webp.offsetPtr(src, num_pixels);
    while (src < src_end) {
        const argb = src[0];
        src += 1;
        const rg: u8 = @truncate(((argb >> 16) & 0xf0) | ((argb >> 12) & 0xf));
        const ba: u8 = @truncate(((argb >> 0) & 0xf0) | ((argb >> 28) & 0xf));
        if (build_options.swap_16bit_csp) {
            dst[0] = ba;
            dst += 1;
            dst[0] = rg;
            dst += 1;
        } else {
            dst[0] = rg;
            dst += 1;
            dst[0] = ba;
            dst += 1;
        }
    }
}

pub export fn VP8LConvertBGRAToRGB565_C(src_: [*c]const u32, num_pixels: c_int, dst_: [*c]u8) callconv(.C) void {
    var src, var dst = .{ src_, dst_ };
    const src_end = webp.offsetPtr(src, num_pixels);
    while (src < src_end) {
        const argb: u32 = src[0];
        src += 1;
        const rg: u8 = @truncate(((argb >> 16) & 0xf8) | ((argb >> 13) & 0x7));
        const gb: u8 = @truncate(((argb >> 5) & 0xe0) | ((argb >> 3) & 0x1f));
        if (build_options.swap_16bit_csp) {
            dst[0] = gb;
            dst += 1;
            dst[0] = rg;
            dst += 1;
        } else {
            dst[0] = rg;
            dst += 1;
            dst[0] = gb;
            dst += 1;
        }
    }
}

pub export fn VP8LConvertBGRAToBGR_C(src_: [*c]const u32, num_pixels: c_int, dst_: [*c]u8) callconv(.C) void {
    var src, var dst = .{ src_, dst_ };
    const src_end = webp.offsetPtr(src, num_pixels);
    while (src < src_end) {
        const argb: u32 = src[0];
        src += 1;
        dst[0] = @truncate((argb >> 0) & 0xff);
        dst += 1;
        dst[0] = @truncate((argb >> 8) & 0xff);
        dst += 1;
        dst[0] = @truncate((argb >> 16) & 0xff);
        dst += 1;
    }
}

fn CopyOrSwap(src_: [*c]const u32, num_pixels: c_int, dst_: [*c]u8, swap_on_big_endian: c_bool) void {
    var src, var dst = .{ src_, dst_ };
    if (is_big_endian() == swap_on_big_endian) {
        const src_end = webp.offsetPtr(src, num_pixels);
        while (src < src_end) {
            const argb = src[0];
            src += 1;
            webp.WebPUint32ToMem(dst, @byteSwap(argb));
            dst += @sizeOf(u32);
        }
    } else {
        @memcpy(dst[0 .. @as(usize, @intCast(num_pixels)) * @sizeOf(u32)], @as([*c]const u8, @ptrCast(src))[0 .. @as(usize, @intCast(num_pixels)) * @sizeOf(u32)]);
    }
}

pub export fn VP8LConvertFromBGRA(in_data: [*c]const u32, num_pixels: c_int, out_colorspace: webp.ColorspaceMode, rgba: [*c]u8) void {
    switch (out_colorspace) {
        .RGB => {
            VP8LConvertBGRAToRGB.?(in_data, num_pixels, rgba);
        },
        .RGBA => {
            VP8LConvertBGRAToRGBA.?(in_data, num_pixels, rgba);
        },
        .rgbA => {
            VP8LConvertBGRAToRGBA.?(in_data, num_pixels, rgba);
            webp.WebPApplyAlphaMultiply.?(rgba, 0, num_pixels, 1, 0);
        },
        .BGR => {
            VP8LConvertBGRAToBGR.?(in_data, num_pixels, rgba);
        },
        .BGRA => {
            CopyOrSwap(in_data, num_pixels, rgba, 1);
        },
        .bgrA => {
            CopyOrSwap(in_data, num_pixels, rgba, 1);
            webp.WebPApplyAlphaMultiply.?(rgba, 0, num_pixels, 1, 0);
        },
        .ARGB => {
            CopyOrSwap(in_data, num_pixels, rgba, 0);
        },
        .Argb => {
            CopyOrSwap(in_data, num_pixels, rgba, 0);
            webp.WebPApplyAlphaMultiply.?(rgba, 1, num_pixels, 1, 0);
        },
        .RGBA_4444 => {
            VP8LConvertBGRAToRGBA4444.?(in_data, num_pixels, rgba);
        },
        .rgbA_4444 => {
            VP8LConvertBGRAToRGBA4444.?(in_data, num_pixels, rgba);
            webp.WebPApplyAlphaMultiply4444.?(rgba, num_pixels, 1, 0);
        },
        .RGB_565 => {
            VP8LConvertBGRAToRGB565.?(in_data, num_pixels, rgba);
        },
        else => unreachable, // Code flow should not reach here.
    }
}

//------------------------------------------------------------------------------

pub const VP8LProcessDecBlueAndRedFunc = ?*const fn (src: [*c]const u32, num_pixels: c_int, dst: [*c]u32) callconv(.C) void;
pub var VP8LAddGreenToBlueAndRed: VP8LProcessDecBlueAndRedFunc = null;

// These Add/Sub function expects upper[-1] and out[-1] to be readable.
pub const VP8LPredictorAddSubFunc = ?*const fn (in: [*c]const u32, upper: [*c]const u32, num_pixels: c_int, out: [*c]u32) callconv(.C) void;
pub var VP8LPredictorsAdd = [_]VP8LPredictorAddSubFunc{null} ** 16;
pub var VP8LPredictorsAdd_C = [_]VP8LPredictorAddSubFunc{null} ** 16;

pub const VP8LPredictorFunc = ?*const fn (left: [*c]const u32, top: [*c]const u32) callconv(.C) u32;
pub var VP8LPredictors = [_]VP8LPredictorFunc{null} ** 16;

pub const VP8LTransformColorInverseFunc = ?*const fn (m: *const VP8LMultipliers, src: [*c]const u32, num_pixels: c_int, dst: [*c]u32) callconv(.C) void;
pub var VP8LTransformColorInverse: VP8LTransformColorInverseFunc = null;

// Color space conversion.
pub const VP8LConvertFunc = ?*const fn (src: [*c]const u32, num_pixels: c_int, dst: [*c]u8) callconv(.C) void;
pub var VP8LConvertBGRAToRGB: VP8LConvertFunc = null;
pub var VP8LConvertBGRAToRGBA: VP8LConvertFunc = null;
pub var VP8LConvertBGRAToRGBA4444: VP8LConvertFunc = null;
pub var VP8LConvertBGRAToRGB565: VP8LConvertFunc = null;
pub var VP8LConvertBGRAToBGR: VP8LConvertFunc = null;

pub const VP8LMapARGBFunc = ?*const fn (src: [*c]const u32, color_map: [*c]const u32, dst: [*c]u32, y_start: c_int, y_end: c_int, width: c_int) callconv(.C) void;
pub const VP8LMapAlphaFunc = ?*const fn (src: [*c]const u8, color_map: [*c]const u32, dst: [*c]u8, y_start: c_int, y_end: c_int, width: c_int) callconv(.C) void;
pub var VP8LMapColor32b: VP8LMapARGBFunc = null;
pub var VP8LMapColor8b: VP8LMapAlphaFunc = null;
comptime {
    @export(VP8LAddGreenToBlueAndRed, .{ .name = "VP8LAddGreenToBlueAndRed" });
    @export(VP8LPredictorsAdd, .{ .name = "VP8LPredictorsAdd" });
    @export(VP8LPredictorsAdd_C, .{ .name = "VP8LPredictorsAdd_C" });
    @export(VP8LPredictors, .{ .name = "VP8LPredictors" });
    @export(VP8LTransformColorInverse, .{ .name = "VP8LTransformColorInverse" });
    @export(VP8LConvertBGRAToRGB, .{ .name = "VP8LConvertBGRAToRGB" });
    @export(VP8LConvertBGRAToRGBA, .{ .name = "VP8LConvertBGRAToRGBA" });
    @export(VP8LConvertBGRAToRGBA4444, .{ .name = "VP8LConvertBGRAToRGBA4444" });
    @export(VP8LConvertBGRAToRGB565, .{ .name = "VP8LConvertBGRAToRGB565" });
    @export(VP8LConvertBGRAToBGR, .{ .name = "VP8LConvertBGRAToBGR" });
    @export(VP8LMapColor32b, .{ .name = "VP8LMapColor32b" });
    @export(VP8LMapColor8b, .{ .name = "VP8LMapColor8b" });
}

const VP8LDspInitSSE2 = @import("lossless_sse2.zig").VP8LDspInitSSE2;
const VP8LDspInitSSE41 = @import("lossless_sse41.zig").VP8LDspInitSSE41;
extern fn VP8LDspInitNEON() callconv(.C) void;
extern fn VP8LDspInitMIPSdspR2() callconv(.C) void;
extern fn VP8LDspInitMSA() callconv(.C) void;

fn copyPredictorArray(comptime in: []const u8, comptime T: type, out: []T) void {
    out[0] = &@field(@This(), in ++ "0_C");
    out[1] = &@field(@This(), in ++ "1_C");
    out[2] = &@field(@This(), in ++ "2_C");
    out[3] = &@field(@This(), in ++ "3_C");
    out[4] = &@field(@This(), in ++ "4_C");
    out[5] = &@field(@This(), in ++ "5_C");
    out[6] = &@field(@This(), in ++ "6_C");
    out[7] = &@field(@This(), in ++ "7_C");
    out[8] = &@field(@This(), in ++ "8_C");
    out[9] = &@field(@This(), in ++ "9_C");
    out[10] = &@field(@This(), in ++ "10_C");
    out[11] = &@field(@This(), in ++ "11_C");
    out[12] = &@field(@This(), in ++ "12_C");
    out[13] = &@field(@This(), in ++ "13_C");
    out[14] = &@field(@This(), in ++ "0_C"); // <- padding security sentinels
    out[15] = &@field(@This(), in ++ "0_C");
}

pub const VP8LDspInit = webp.WEBP_DSP_INIT_FUNC(struct {
    fn _() void {
        copyPredictorArray("VP8LPredictor", VP8LPredictorFunc, &VP8LPredictors);
        copyPredictorArray("PredictorAdd", VP8LPredictorAddSubFunc, &VP8LPredictorsAdd);
        copyPredictorArray("PredictorAdd", VP8LPredictorAddSubFunc, &VP8LPredictorsAdd_C);

        if (comptime !webp.neon_omit_c_code) {
            VP8LAddGreenToBlueAndRed = &VP8LAddGreenToBlueAndRed_C;

            VP8LTransformColorInverse = &VP8LTransformColorInverse_C;

            VP8LConvertBGRAToRGBA = &VP8LConvertBGRAToRGBA_C;
            VP8LConvertBGRAToRGB = &VP8LConvertBGRAToRGB_C;
            VP8LConvertBGRAToBGR = &VP8LConvertBGRAToBGR_C;
        }

        VP8LConvertBGRAToRGBA4444 = &VP8LConvertBGRAToRGBA4444_C;
        VP8LConvertBGRAToRGB565 = &VP8LConvertBGRAToRGB565_C;

        VP8LMapColor32b = &MapARGB_C;
        VP8LMapColor8b = &MapAlpha_C;

        // If defined, use CPUInfo() to overwrite some pointers with faster versions.
        if (webp.VP8GetCPUInfo) |getCpuInfo| {
            if (comptime webp.have_sse2) {
                if (getCpuInfo(.kSSE2) != 0) {
                    VP8LDspInitSSE2();
                    if (comptime webp.have_sse41) {
                        if (getCpuInfo(.kSSE4_1) != 0) VP8LDspInitSSE41();
                    }
                }
            }
            if (comptime webp.use_mips_dsp_r2) {
                if (getCpuInfo(.kMIPSdspR2) != 0) VP8LDspInitMIPSdspR2();
            }
            if (comptime webp.use_msa) {
                if (getCpuInfo(.kMSA) != 0) VP8LDspInitMSA();
            }
        }

        if (comptime webp.have_neon) {
            if (webp.neon_omit_c_code or (if (webp.VP8GetCPUInfo) |getInfo| getInfo(.kNEON) != 0 else false))
                VP8LDspInitNEON();
        }

        assert(VP8LAddGreenToBlueAndRed != null);
        assert(VP8LTransformColorInverse != null);
        assert(VP8LConvertBGRAToRGBA != null);
        assert(VP8LConvertBGRAToRGB != null);
        assert(VP8LConvertBGRAToBGR != null);
        assert(VP8LConvertBGRAToRGBA4444 != null);
        assert(VP8LConvertBGRAToRGB565 != null);
        assert(VP8LMapColor32b != null);
        assert(VP8LMapColor8b != null);
    }
}._);

fn VP8LDspInit_C() callconv(.C) void {
    VP8LDspInit();
}
comptime {
    @export(VP8LDspInit_C, .{ .name = "VP8LDspInit" });
}
