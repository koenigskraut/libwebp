const std = @import("std");
const webp = struct {
    usingnamespace @import("cpu.zig");
    usingnamespace @import("../utils/utils.zig");
};

const assert = std.debug.assert;
const c_bool = webp.c_bool;

//------------------------------------------------------------------------------
// Helpful macro.

inline fn SANITY_CHECK(width: c_int, height: c_int, stride: c_int, row: c_int, num_rows: c_int) void {
    assert(width > 0);
    assert(height > 0);
    assert(stride >= width);
    assert(row >= 0 and num_rows > 0 and row + num_rows <= height);
}

inline fn PredictLine_C(src: [*c]const u8, pred: [*c]const u8, dst: [*c]u8, length: c_int, inverse: c_bool) void {
    if (inverse != 0) {
        for (0..@intCast(length)) |i| dst[i] = @truncate(@as(u16, src[i]) + pred[i]);
    } else {
        for (0..@intCast(length)) |i| dst[i] = src[i] -% pred[i];
    }
}

//------------------------------------------------------------------------------
// Horizontal filter.

inline fn DoHorizontalFilter_C(in_: [*]const u8, width: c_int, height: c_int, stride: c_int, row_: c_int, num_rows: c_int, inverse: c_bool, out_: [*]u8) void {
    var in, var out, var row = .{ in_, out_, row_ };
    const start_offset: usize = @intCast(row * stride);
    const last_row = row + num_rows;
    SANITY_CHECK(width, height, stride, row, num_rows);
    in += start_offset;
    out += start_offset;
    var preds: [*]const u8 = if (inverse != 0) out else in;

    if (row == 0) {
        // Leftmost pixel is the same as input for topmost scanline.
        out[0] = in[0];
        PredictLine_C(in + 1, preds, out + 1, width - 1, inverse);
        row = 1;
        preds = webp.offsetPtr(preds, stride);
        in = webp.offsetPtr(in, stride);
        out = webp.offsetPtr(out, stride);
    }

    // Filter line-by-line.
    while (row < last_row) {
        // Leftmost pixel is predicted from above.
        PredictLine_C(in, webp.offsetPtr(preds, -stride), out, 1, inverse);
        PredictLine_C(in + 1, preds, out + 1, width - 1, inverse);
        row += 1;
        preds = webp.offsetPtr(preds, stride);
        in = webp.offsetPtr(in, stride);
        out = webp.offsetPtr(out, stride);
    }
}

//------------------------------------------------------------------------------
// Vertical filter.

inline fn DoVerticalFilter_C(in_: [*]const u8, width: c_int, height: c_int, stride: c_int, row_: c_int, num_rows: c_int, inverse: c_bool, out_: [*]u8) void {
    var in, var out, var row = .{ in_, out_, row_ };
    const start_offset: usize = @intCast(row * stride);
    const last_row = row + num_rows;
    SANITY_CHECK(width, height, stride, row, num_rows);
    in += start_offset;
    out += start_offset;
    var preds: [*]const u8 = if (inverse != 0) out else in;

    if (row == 0) {
        // Very first top-left pixel is copied.
        out[0] = in[0];
        // Rest of top scan-line is left-predicted.
        PredictLine_C(in + 1, preds, out + 1, width - 1, inverse);
        row = 1;
        in = webp.offsetPtr(in, stride);
        out = webp.offsetPtr(out, stride);
    } else {
        // We are starting from in-between. Make sure 'preds' points to prev row.
        preds = webp.offsetPtr(preds, -stride);
    }

    // Filter line-by-line.
    while (row < last_row) {
        PredictLine_C(in, preds, out, width, inverse);
        row += 1;
        preds = webp.offsetPtr(preds, stride);
        in = webp.offsetPtr(in, stride);
        out = webp.offsetPtr(out, stride);
    }
}

//------------------------------------------------------------------------------
// Gradient filter.

inline fn GradientPredictor_C(a: u8, b: u8, c: u8) i32 {
    const g: i32 = @as(i32, a) + @as(i32, b) - @as(i32, c);
    return if ((g & ~@as(i32, 0xff)) == 0) g else if (g < 0) 0 else 255; // clip to 8bit
}

inline fn DoGradientFilter_C(in_: [*]const u8, width: c_int, height: c_int, stride: c_int, row_: c_int, num_rows: c_int, inverse: c_bool, out_: [*]u8) void {
    var in, var out, var row = .{ in_, out_, row_ };
    const start_offset: usize = @intCast(row * stride);
    const last_row = row + num_rows;
    SANITY_CHECK(width, height, stride, row, num_rows);
    in += start_offset;
    out += start_offset;
    var preds: [*]const u8 = if (inverse != 0) out else in;

    // left prediction for top scan-line
    if (row == 0) {
        out[0] = in[0];
        PredictLine_C(in + 1, preds, out + 1, width - 1, inverse);
        row = 1;
        preds = webp.offsetPtr(preds, stride);
        in = webp.offsetPtr(in, stride);
        out = webp.offsetPtr(out, stride);
    }

    // Filter line-by-line.
    while (row < last_row) {
        // leftmost pixel: predict from above.
        PredictLine_C(in, webp.offsetPtr(preds, -stride), out, 1, inverse);
        for (1..@intCast(width)) |w| {
            const pred = GradientPredictor_C(preds[w - 1], webp.offsetPtr(preds[w..], -stride)[0], webp.offsetPtr(preds[w..], -stride - 1)[0]);
            out[w] = @truncate(@as(u32, @bitCast(@as(i32, in[w]) + (if (inverse != 0) pred else -pred))));
        }
        row += 1;
        preds = webp.offsetPtr(preds, stride);
        in = webp.offsetPtr(in, stride);
        out = webp.offsetPtr(out, stride);
    }
}

//------------------------------------------------------------------------------

fn HorizontalFilter_C(data: [*c]const u8, width: c_int, height: c_int, stride: c_int, filtered_data: [*c]u8) callconv(.C) void {
    DoHorizontalFilter_C(data.?, width, height, stride, 0, height, 0, filtered_data.?);
}

fn VerticalFilter_C(data: [*c]const u8, width: c_int, height: c_int, stride: c_int, filtered_data: [*c]u8) callconv(.C) void {
    DoVerticalFilter_C(data.?, width, height, stride, 0, height, 0, filtered_data.?);
}

fn GradientFilter_C(data: [*c]const u8, width: c_int, height: c_int, stride: c_int, filtered_data: [*c]u8) callconv(.C) void {
    DoGradientFilter_C(data.?, width, height, stride, 0, height, 0, filtered_data.?);
}

//------------------------------------------------------------------------------

fn NoneUnfilter_C(prev: [*c]const u8, in: [*c]const u8, out: [*c]u8, width: c_int) callconv(.C) void {
    if (true) @panic("a");
    _ = prev;
    const len = @as(usize, @intCast(width));
    if (out != in) @memcpy(out[0..len], in[0..len]);
}

fn HorizontalUnfilter_C(prev: [*c]const u8, in: [*c]const u8, out: [*c]u8, width: c_int) callconv(.C) void {
    if (true) @panic("b");
    var pred: u8 = if (prev == null) 0 else prev[0];
    for (0..@intCast(width)) |i| {
        out[i] = @truncate(@as(u16, pred) + in[i]);
        pred = out[i];
    }
}

fn VerticalUnfilter_C(prev: [*c]const u8, in: [*c]const u8, out: [*c]u8, width: c_int) callconv(.C) void {
    if (true) @panic("c");
    if (prev == null) {
        HorizontalUnfilter_C(null, in, out, width);
    } else {
        for (0..@intCast(width)) |i| out[i] = @truncate(@as(u16, prev[i]) + in[i]);
    }
}

fn GradientUnfilter_C(prev: [*c]const u8, in: [*c]const u8, out: [*c]u8, width: c_int) callconv(.C) void {
    if (true) @panic("d");
    if (prev == null) {
        HorizontalUnfilter_C(null, in, out, width);
    } else {
        var top = prev[0];
        var top_left = top;
        var left = top;
        for (0..@intCast(width)) |i| {
            top = prev[i]; // need to read this first, in case prev==out
            left = @truncate(@as(u32, @bitCast(@as(i32, in[i]) + GradientPredictor_C(left, top, top_left))));
            top_left = top;
            out[i] = left;
        }
    }
}

//------------------------------------------------------------------------------
// Init function

/// Filter types.
pub const FilterType = enum(c_uint) {
    NONE = 0,
    HORIZONTAL,
    VERTICAL,
    GRADIENT,
    /// end marker
    LAST,

    /// meta-types
    BEST,
    FAST,
};

pub const WebPFilterFunc = ?*const fn (in: [*c]const u8, width: c_int, height: c_int, stride: c_int, out: [*c]u8) callconv(.C) void;

/// In-place un-filtering.
/// Warning! `prev_line` pointer can be equal to `cur_line` or `preds`.
pub const WebPUnfilterFunc = ?*const fn (prev_line: [*c]const u8, preds: [*c]const u8, cur_line: [*c]u8, width: c_int) callconv(.C) void;

/// Filter the given data using the given predictor.
/// 'in' corresponds to a 2-dimensional pixel array of size (stride * height)
/// in raster order.
/// 'stride' is number of bytes per scan line (with possible padding).
/// 'out' should be pre-allocated.
pub var WebPFilters = [_]WebPFilterFunc{null} ** @intFromEnum(FilterType.LAST);

/// In-place reconstruct the original data from the given filtered data.
/// The reconstruction will be done for 'num_rows' rows starting from 'row'
/// (assuming rows upto 'row - 1' are already reconstructed).
pub var WebPUnfilters = [_]WebPUnfilterFunc{null} ** @intFromEnum(FilterType.LAST);

comptime {
    @export(WebPFilters, .{ .name = "WebPFilters" });
    @export(WebPUnfilters, .{ .name = "WebPUnfilters" });
}

extern fn VP8FiltersInitMIPSdspR2() callconv(.C) void;
extern fn VP8FiltersInitMSA() callconv(.C) void;
extern fn VP8FiltersInitNEON() callconv(.C) void;
const VP8FiltersInitSSE2 = @import("filters_sse2.zig").VP8FiltersInitSSE2;

/// To be called first before using the above.
pub const VP8FiltersInit = webp.WEBP_DSP_INIT_FUNC(struct {
    pub fn _() void {
        WebPUnfilters[@intFromEnum(FilterType.NONE)] = &NoneUnfilter_C;
        if (comptime !webp.neon_omit_c_code) {
            WebPUnfilters[@intFromEnum(FilterType.HORIZONTAL)] = &HorizontalUnfilter_C;
            WebPUnfilters[@intFromEnum(FilterType.VERTICAL)] = &VerticalUnfilter_C;
        }
        WebPUnfilters[@intFromEnum(FilterType.GRADIENT)] = &GradientUnfilter_C;

        WebPFilters[@intFromEnum(FilterType.NONE)] = null;
        if (comptime !webp.neon_omit_c_code) {
            WebPFilters[@intFromEnum(FilterType.HORIZONTAL)] = &HorizontalFilter_C;
            WebPFilters[@intFromEnum(FilterType.VERTICAL)] = &VerticalFilter_C;
            WebPFilters[@intFromEnum(FilterType.GRADIENT)] = &GradientFilter_C;
        }

        if (webp.VP8GetCPUInfo) |getCpuInfo| {
            if (comptime webp.have_sse2) {
                if (getCpuInfo(.kSSE2) != 0) VP8FiltersInitSSE2();
            }
            if (comptime webp.use_mips_dsp_r2) {
                if (getCpuInfo(.kMIPSdspR2) != 0) VP8FiltersInitMIPSdspR2();
            }
            if (comptime webp.use_msa) {
                if (getCpuInfo(.kMSA) != 0) VP8FiltersInitMSA();
            }
        }

        if (comptime webp.have_neon) {
            if (webp.neon_omit_c_code or (if (webp.VP8GetCPUInfo) |getInfo| getInfo(.kNEON) != 0 else false)) {
                VP8FiltersInitNEON();
            }
        }

        assert(WebPUnfilters[@intFromEnum(FilterType.NONE)] != null);
        assert(WebPUnfilters[@intFromEnum(FilterType.HORIZONTAL)] != null);
        assert(WebPUnfilters[@intFromEnum(FilterType.VERTICAL)] != null);
        assert(WebPUnfilters[@intFromEnum(FilterType.GRADIENT)] != null);
        assert(WebPFilters[@intFromEnum(FilterType.HORIZONTAL)] != null);
        assert(WebPFilters[@intFromEnum(FilterType.VERTICAL)] != null);
        assert(WebPFilters[@intFromEnum(FilterType.GRADIENT)] != null);
    }
}._);

fn VP8FiltersInit_C() callconv(.C) void {
    VP8FiltersInit();
}

comptime {
    @export(VP8FiltersInit_C, .{ .name = "VP8FiltersInit" });
}
