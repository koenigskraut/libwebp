const std = @import("std");
const build_options = @import("build_options");
const webp = struct {
    usingnamespace @import("cpu.zig");
    usingnamespace @import("../utils/rescaler_utils.zig");
    usingnamespace @import("../utils/utils.zig");
};

const assert = std.debug.assert;

//------------------------------------------------------------------------------
// Implementations of critical functions ImportRow / ExportRow

const ROUNDER = webp.WEBP_RESCALER_ONE >> 1;

inline fn MULT_FIX(x: u64, y: u64) u32 {
    return @truncate((x *% y +% ROUNDER) >> webp.WEBP_RESCALER_RFIX);
}

inline fn MULT_FIX_FLOOR(x: u64, y: u64) u32 {
    return @truncate((x * y) >> webp.WEBP_RESCALER_RFIX);
}

//------------------------------------------------------------------------------
// Row import

// Plain-C implementation, as fall-back.

pub export fn WebPRescalerImportRowExpand_C(wrk: *webp.WebPRescaler, src: [*c]const u8) void {
    const x_stride: usize = @intCast(wrk.num_channels);
    const x_out_max: usize = @intCast(wrk.dst_width * wrk.num_channels);
    assert(!wrk.inputDone());
    assert(wrk.x_expand != 0);
    for (0..x_stride) |channel| {
        var x_in = channel;
        var x_out = channel;
        // simple bilinear interpolation
        var accum = wrk.x_add;
        var left: webp.rescaler_t = src[x_in];
        var right: webp.rescaler_t = if (wrk.src_width > 1) src[x_in + x_stride] else left;
        x_in += x_stride;
        while (true) {
            wrk.frow[x_out] = right *% @as(u32, @intCast(wrk.x_add)) +% (left -% right) *% @abs(accum);
            x_out += x_stride;
            if (x_out >= x_out_max) break;
            accum -= wrk.x_sub;
            if (accum < 0) {
                left = right;
                x_in += x_stride;
                assert(x_in < wrk.src_width * @as(i64, @intCast(x_stride)));
                right = src[x_in];
                accum += wrk.x_add;
            }
        }
        assert(wrk.x_sub == 0 or accum == 0);
        //     ^^^^^^^^^^^^^^ special case for src_width=1
    }
}

pub export fn WebPRescalerImportRowShrink_C(wrk: *webp.WebPRescaler, src: [*c]const u8) void {
    const x_stride: usize = @intCast(wrk.num_channels);
    const x_out_max: usize = @intCast(wrk.dst_width * wrk.num_channels);
    assert(!wrk.inputDone());
    assert(wrk.x_expand == 0);
    for (0..x_stride) |channel| {
        var x_in = channel;
        var x_out = channel;
        var sum: u32 = 0;
        var accum: i32 = 0;
        while (x_out < x_out_max) {
            var base: u32 = 0;
            accum += wrk.x_add;
            while (accum > 0) {
                accum -= wrk.x_sub;
                assert(x_in < wrk.src_width * @as(i64, @intCast(x_stride)));
                base = src[x_in];
                sum += base;
                x_in += x_stride;
            }
            { // Emit next horizontal pixel.
                const frac: webp.rescaler_t = @bitCast(@as(i32, @bitCast(base)) * (-accum));
                wrk.frow[x_out] = sum *% @as(u32, @bitCast(wrk.x_sub)) -% frac;
                // fresh fractional start for next pixel
                sum = MULT_FIX(frac, wrk.fx_scale);
            }
            x_out += x_stride;
        }
        assert(accum == 0);
    }
}

//------------------------------------------------------------------------------
// Row export

pub export fn WebPRescalerExportRowExpand_C(wrk: *webp.WebPRescaler) void {
    const dst = wrk.dst;
    const irow = wrk.irow;
    const x_out_max: usize = @intCast(wrk.dst_width * wrk.num_channels);
    const frow: [*c]const webp.rescaler_t = wrk.frow;
    assert(!wrk.outputDone());
    assert(wrk.y_accum <= 0);
    assert(wrk.y_expand != 0);
    assert(wrk.y_sub != 0);
    if (wrk.y_accum == 0) {
        for (0..x_out_max) |x_out| {
            const J = frow[x_out];
            const v = MULT_FIX(J, wrk.fy_scale);
            dst[x_out] = if (v > 255) 255 else @truncate(v);
        }
    } else {
        const B = webp.WEBP_RESCALER_FRAC(-wrk.y_accum, wrk.y_sub);
        const A: u32 = @truncate(@as(u64, webp.WEBP_RESCALER_ONE) -% B);
        for (0..x_out_max) |x_out| {
            const I: u64 = @as(u64, A) * frow[x_out] +% @as(u64, B) * irow[x_out];
            const J: u32 = @truncate((I + ROUNDER) >> webp.WEBP_RESCALER_RFIX);
            const v = MULT_FIX(J, wrk.fy_scale);
            dst[x_out] = if (v > 255) 255 else @truncate(v);
        }
    }
}

pub export fn WebPRescalerExportRowShrink_C(wrk: *webp.WebPRescaler) void {
    const dst = wrk.dst;
    const irow = wrk.irow;
    const x_out_max: usize = @intCast(wrk.dst_width * wrk.num_channels);
    const frow: [*c]const webp.rescaler_t = wrk.frow;
    const yscale: u32 = wrk.fy_scale * @abs(wrk.y_accum);
    assert(!wrk.outputDone());
    assert(wrk.y_accum <= 0);
    assert(wrk.y_expand == 0);
    if (yscale != 0) {
        for (0..x_out_max) |x_out| {
            const frac = MULT_FIX_FLOOR(frow[x_out], yscale);
            const v = MULT_FIX(irow[x_out] -% frac, wrk.fxy_scale);
            dst[x_out] = if (v > 255) 255 else @truncate(v);
            irow[x_out] = frac; // new fractional start
        }
    } else {
        for (0..x_out_max) |x_out| {
            const v = MULT_FIX(irow[x_out], wrk.fxy_scale);
            dst[x_out] = if (v > 255) 255 else @truncate(v);
            irow[x_out] = 0;
        }
    }
}

//------------------------------------------------------------------------------
// Main entry calls

pub export fn WebPRescalerImportRow(wrk: *webp.WebPRescaler, src: [*c]const u8) void {
    assert(!wrk.inputDone());
    if (!(wrk.x_expand != 0)) {
        WebPRescalerImportRowShrink.?(wrk, src);
    } else {
        WebPRescalerImportRowExpand.?(wrk, src);
    }
}

/// Export one row (starting at x_out position) from rescaler.
pub export fn WebPRescalerExportRow(wrk: *webp.WebPRescaler) void {
    if (wrk.y_accum <= 0) {
        assert(!wrk.outputDone());
        if (wrk.y_expand != 0) {
            WebPRescalerExportRowExpand.?(wrk);
        } else if (wrk.fxy_scale != 0) {
            WebPRescalerExportRowShrink.?(wrk);
        } else { // special case
            assert(wrk.src_height == wrk.dst_height and wrk.x_add == 1);
            assert(wrk.src_width == 1 and wrk.dst_width <= 2);
            for (0..@intCast(wrk.num_channels * wrk.dst_width)) |i| {
                wrk.dst[i] = @truncate(wrk.irow[i]);
                wrk.irow[i] = 0;
            }
        }
        wrk.y_accum += wrk.y_add;
        wrk.dst = webp.offsetPtr(wrk.dst, wrk.dst_stride);
        wrk.dst_y += 1;
    }
}

//------------------------------------------------------------------------------

const WebPRescalerImportRowFuncBody = fn (wrk: *webp.WebPRescaler, src: [*c]const u8) callconv(.C) void;
/// Import a row of data and save its contribution in the rescaler.
/// 'channel' denotes the channel number to be imported. 'Expand' corresponds to
/// the wrk->x_expand case. Otherwise, 'Shrink' is to be used.
pub const WebPRescalerImportRowFunc = ?*const WebPRescalerImportRowFuncBody;

pub var WebPRescalerImportRowExpand: WebPRescalerImportRowFunc = null;
pub var WebPRescalerImportRowShrink: WebPRescalerImportRowFunc = null;

const WebPRescalerExportRowFuncBody = fn (wrk: *webp.WebPRescaler) callconv(.C) void;
/// Export one row (starting at x_out position) from rescaler.
/// 'Expand' corresponds to the wrk->y_expand case.
/// Otherwise 'Shrink' is to be used
pub const WebPRescalerExportRowFunc = ?*const WebPRescalerExportRowFuncBody;
pub var WebPRescalerExportRowExpand: WebPRescalerExportRowFunc = null;
pub var WebPRescalerExportRowShrink: WebPRescalerExportRowFunc = null;

comptime {
    @export(WebPRescalerImportRowExpand, .{ .name = "WebPRescalerImportRowExpand" });
    @export(WebPRescalerImportRowShrink, .{ .name = "WebPRescalerImportRowShrink" });
    @export(WebPRescalerExportRowExpand, .{ .name = "WebPRescalerExportRowExpand" });
    @export(WebPRescalerExportRowShrink, .{ .name = "WebPRescalerExportRowShrink" });
}

extern fn WebPRescalerDspInitSSE2() callconv(.C) void;
extern fn WebPRescalerDspInitMIPS32() callconv(.C) void;
extern fn WebPRescalerDspInitMIPSdspR2() callconv(.C) void;
extern fn WebPRescalerDspInitMSA() callconv(.C) void;
extern fn WebPRescalerDspInitNEON() callconv(.C) void;

/// Must be called first before using the above.
pub const WebPRescalerDspInit = webp.WEBP_DSP_INIT_FUNC(struct {
    fn _() void {
        if (comptime build_options.reduce_size) return;
        if (comptime !webp.neon_omit_c_code) {
            WebPRescalerExportRowExpand = &WebPRescalerExportRowExpand_C;
            WebPRescalerExportRowShrink = &WebPRescalerExportRowShrink_C;
        }
        WebPRescalerImportRowExpand = &WebPRescalerImportRowExpand_C;
        WebPRescalerImportRowShrink = &WebPRescalerImportRowShrink_C;

        if (webp.VP8GetCPUInfo) |getCpuInfo| {
            if (comptime webp.have_sse2) {
                if (getCpuInfo(.kSSE2) != 0) WebPRescalerDspInitSSE2();
            }
            if (comptime webp.use_mips32) {
                if (getCpuInfo(.kMIPS32) != 0) WebPRescalerDspInitMIPS32();
            }
            if (comptime webp.use_mips_dsp_r2) {
                if (getCpuInfo(.kMIPSdspR2) != 0) WebPRescalerDspInitMIPSdspR2();
            }
            if (comptime webp.use_msa) {
                if (getCpuInfo(.kMSA) != 0) WebPRescalerDspInitMSA();
            }
        }

        if (comptime webp.have_neon) {
            if (webp.neon_omit_c_code or (if (webp.VP8GetCPUInfo) |getInfo| getInfo(.kNEON) != 0 else false))
                WebPRescalerDspInitNEON();
        }

        assert(WebPRescalerExportRowExpand != null);
        assert(WebPRescalerExportRowShrink != null);
        assert(WebPRescalerImportRowExpand != null);
        assert(WebPRescalerImportRowShrink != null);
    }
}._);

fn WebPRescalerDspInit_C() callconv(.C) void {
    WebPRescalerDspInit();
}

comptime {
    @export(WebPRescalerDspInit_C, .{ .name = "WebPRescalerDspInit" });
}
