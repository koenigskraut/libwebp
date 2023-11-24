const std = @import("std");
const build_options = @import("build_options");
const webp = struct {
    usingnamespace @import("vp8_dec.zig");
    usingnamespace @import("webp_dec.zig");
    usingnamespace @import("../utils/rescaler_utils.zig");
    usingnamespace @import("../utils/utils.zig");
    usingnamespace @import("../webp/decode.zig");

    const WebPSamplerRowFunc = ?*const fn ([*c]const u8, [*c]const u8, [*c]const u8, [*c]u8, c_int) callconv(.C) void;
    extern fn WebPSamplerProcessPlane(y: [*c]const u8, y_stride: c_int, u: [*c]const u8, v: [*c]const u8, uv_stride: c_int, dst: [*c]u8, dst_stride: c_int, width: c_int, height: c_int, func: WebPSamplerRowFunc) void;
    const WebPSamplers: [*c]WebPSamplerRowFunc = @extern([*c]WebPSamplerRowFunc, .{ .name = "WebPSamplers" });

    const WebPUpsampleLinePairFunc = ?*const fn ([*c]const u8, [*c]const u8, [*c]const u8, [*c]const u8, [*c]const u8, [*c]const u8, [*c]u8, [*c]u8, c_int) callconv(.C) void;
    const WebPUpsamplers: [*c]WebPUpsampleLinePairFunc = @extern([*c]WebPUpsampleLinePairFunc, .{ .name = "WebPUpsamplers" });

    const WebPYUV444Converter = ?*const fn ([*c]const u8, [*c]const u8, [*c]const u8, [*c]u8, c_int) callconv(.C) void;
    const WebPYUV444Converters: [*c]WebPYUV444Converter = @extern([*c]WebPYUV444Converter, .{ .name = "WebPYUV444Converters" });

    extern var WebPApplyAlphaMultiply4444: ?*const fn ([*c]u8, c_int, c_int, c_int) callconv(.C) void;
    extern var WebPDispatchAlpha: ?*const fn (noalias [*c]const u8, c_int, c_int, c_int, noalias [*c]u8, c_int) callconv(.C) c_int;
    extern var WebPApplyAlphaMultiply: ?*const fn ([*c]u8, c_int, c_int, c_int, c_int) callconv(.C) void;

    extern fn WebPInitSamplers() void;
    extern fn WebPRescalerImport(rescaler: [*c]@This().WebPRescaler, num_rows: c_int, src: [*c]const u8, src_stride: c_int) c_int;
    extern fn WebPRescalerExport(rescaler: [*c]@This().WebPRescaler) c_int;
    extern fn WebPMultRows(noalias ptr: [*c]u8, stride: c_int, noalias alpha: [*c]const u8, alpha_stride: c_int, width: c_int, num_rows: c_int, inverse: c_int) void;
    extern fn WebPRescalerInit(rescaler: [*c]@This().WebPRescaler, src_width: c_int, src_height: c_int, dst: [*c]u8, dst_width: c_int, dst_height: c_int, dst_stride: c_int, num_channels: c_int, work: [*c]@This().rescaler_t) c_int;
    extern fn WebPInitAlphaProcessing() void;
    extern fn WebPRescalerExportRow(wrk: [*c]@This().WebPRescaler) void;
    extern fn WebPRescaleNeededLines(rescaler: [*c]const @This().WebPRescaler, max_num_lines: c_int) c_int;
    extern fn WebPInitUpsamplers() void;
    extern fn WebPInitYUV444Converters() void;
};

const assert = std.debug.assert;
const c_bool = webp.c_bool;

//------------------------------------------------------------------------------
// Main YUV<->RGB conversion functions

fn EmitYUV(io: *const webp.VP8Io, p: *webp.DecParams) c_int {
    var output = p.output.?;
    const buf = &output.u.YUVA;
    const y_dst: [*c]u8 = webp.offsetPtr(buf.y, @as(i64, io.mb_y) * buf.y_stride);
    const u_dst: [*c]u8 = webp.offsetPtr(buf.u, @as(i64, io.mb_y >> 1) * buf.u_stride);
    const v_dst: [*c]u8 = webp.offsetPtr(buf.v, @as(i64, io.mb_y >> 1) * buf.v_stride);
    const mb_w = io.mb_w;
    const mb_h = io.mb_h;
    const uv_w = @divTrunc(mb_w + 1, 2);
    const uv_h = @divTrunc(mb_h + 1, 2);
    webp.WebPCopyPlane(io.y, io.y_stride, y_dst, buf.y_stride, mb_w, mb_h);
    webp.WebPCopyPlane(io.u, io.uv_stride, u_dst, buf.u_stride, uv_w, uv_h);
    webp.WebPCopyPlane(io.v, io.uv_stride, v_dst, buf.v_stride, uv_w, uv_h);
    return io.mb_h;
}

/// Point-sampling U/V sampler.
fn EmitSampledRGB(io: *const webp.VP8Io, p: *webp.DecParams) c_int {
    const output = p.output.?;
    const buf = &output.u.RGBA;
    const dst: [*c]u8 = webp.offsetPtr(buf.rgba, @as(i64, io.mb_y) * buf.stride);
    webp.WebPSamplerProcessPlane(
        io.y,
        io.y_stride,
        io.u,
        io.v,
        io.uv_stride,
        dst,
        buf.stride,
        io.mb_w,
        io.mb_h,
        webp.WebPSamplers[@intFromEnum(output.colorspace)],
    );
    return io.mb_h;
}

//------------------------------------------------------------------------------
// Fancy upsampling

fn EmitFancyRGB(io: *const webp.VP8Io, p: *webp.DecParams) c_int {
    if (comptime !build_options.fancy_upsampling) return;
    var num_lines_out = io.mb_h; // a priori guess
    const buf = &p.output.?.u.RGBA;
    var dst = webp.offsetPtr(buf.rgba, @as(i64, io.mb_y) * buf.stride);
    const upsample = webp.WebPUpsamplers[@intFromEnum(p.output.?.colorspace)].?;
    var cur_y: [*c]const u8 = io.y;
    var cur_u: [*c]const u8 = io.u;
    var cur_v: [*c]const u8 = io.v;
    var top_u: [*c]const u8 = p.tmp_u;
    var top_v: [*c]const u8 = p.tmp_v;
    var y = io.mb_y;
    const y_end = io.mb_y + io.mb_h;
    const mb_w = io.mb_w;
    const uv_w = @divTrunc(mb_w + 1, 2);

    if (y == 0) {
        // First line is special cased. We mirror the u/v samples at boundary.
        upsample(cur_y, null, cur_u, cur_v, cur_u, cur_v, dst, null, mb_w);
    } else {
        // We can finish the left-over line from previous call.
        upsample(p.tmp_y, cur_y, top_u, top_v, cur_u, cur_v, webp.offsetPtr(dst, -buf.stride), dst, mb_w);
        num_lines_out += 1;
    }
    // Loop over each output pairs of row.
    while (y + 2 < y_end) : (y += 2) {
        top_u = cur_u;
        top_v = cur_v;
        cur_u = webp.offsetPtr(cur_u, io.uv_stride);
        cur_v = webp.offsetPtr(cur_v, io.uv_stride);
        dst = webp.offsetPtr(dst, 2 * buf.stride);
        cur_y = webp.offsetPtr(cur_y, 2 * io.y_stride);
        upsample(webp.offsetPtr(cur_y, -io.y_stride), cur_y, top_u, top_v, cur_u, cur_v, webp.offsetPtr(dst, -buf.stride), dst, mb_w);
    }
    // move to last row
    cur_y = webp.offsetPtr(cur_y, io.y_stride);
    if (io.crop_top + y_end < io.crop_bottom) {
        // Save the unfinished samples for next call (as we're not done yet).
        @memcpy(p.tmp_y[0..@intCast(mb_w)], cur_y[0..@intCast(mb_w)]);
        @memcpy(p.tmp_u[0..@intCast(uv_w)], cur_u[0..@intCast(uv_w)]);
        @memcpy(p.tmp_v[0..@intCast(uv_w)], cur_v[0..@intCast(uv_w)]);
        // The fancy upsampler leaves a row unfinished behind
        // (except for the very last row)
        num_lines_out -= 1;
    } else {
        // Process the very last row of even-sized picture
        if (y_end & 1 == 0) {
            upsample(cur_y, null, cur_u, cur_v, cur_u, cur_v, webp.offsetPtr(dst, buf.stride), null, mb_w);
        }
    }
    return num_lines_out;
}

//------------------------------------------------------------------------------

fn FillAlphaPlane(dst_arg: [*c]u8, w: c_int, h: c_int, stride: c_int) void {
    var dst = dst_arg;
    for (0..@abs(h)) |_| {
        @memset(dst[0..@abs(w)], 0xff);
        dst = webp.offsetPtr(dst, stride);
    }
}

fn EmitAlphaYUV(io: *const webp.VP8Io, p: *webp.DecParams, expected_num_lines_out: c_int) c_int {
    var alpha: [*c]const u8 = io.a;
    const buf = &p.output.?.u.YUVA;
    const mb_w = io.mb_w;
    const mb_h = io.mb_h;
    var dst = webp.offsetPtr(buf.a, @as(i64, io.mb_y) * buf.a_stride);
    std.debug.assert(expected_num_lines_out == mb_h);
    if (alpha != null) {
        for (0..@abs(mb_h)) |_| {
            @memcpy(dst[0..@intCast(mb_w)], alpha[0..@intCast(mb_w)]);
            alpha = webp.offsetPtr(alpha, io.width);
            dst = webp.offsetPtr(dst, buf.a_stride);
        }
    } else if (buf.a != null) {
        // the user requested alpha, but there is none, set it to opaque.
        FillAlphaPlane(dst, mb_w, mb_h, buf.a_stride);
    }
    return 0;
}

fn GetAlphaSourceRow(io: *const webp.VP8Io, alpha: [*c][*c]const u8, num_rows: *c_int) c_int {
    var start_y = io.mb_y;
    num_rows.* = io.mb_h;

    // Compensate for the 1-line delay of the fancy upscaler.
    // This is similar to EmitFancyRGB().
    if (io.fancy_upsampling != 0) {
        if (start_y == 0) {
            // We don't process the last row yet. It'll be done during the next call.
            num_rows.* -= 1;
        } else {
            start_y -= 1;
            // Fortunately, *alpha data is persistent, so we can go back
            // one row and finish alpha blending, now that the fancy upscaler
            // completed the YUV->RGB interpolation.
            alpha.* = webp.offsetPtr(alpha.*, -io.width);
        }
        if (io.crop_top + io.mb_y + io.mb_h == io.crop_bottom) {
            // If it's the very last call, we process all the remaining rows!
            num_rows.* = io.crop_bottom - io.crop_top - start_y;
        }
    }
    return start_y;
}

fn EmitAlphaRGB(io: *const webp.VP8Io, p: *webp.DecParams, expected_num_lines_out: c_int) c_int {
    var alpha = io.a;
    if (alpha != null) {
        const mb_w = io.mb_w;
        const colorspace = p.output.?.colorspace;
        const alpha_first = (colorspace == .ARGB or colorspace == .Argb);
        const buf = &p.output.?.u.RGBA;
        var num_rows: c_int = undefined;
        const start_y: i64 = GetAlphaSourceRow(io, &alpha, &num_rows);
        const base_rgba: [*c]u8 = webp.offsetPtr(buf.rgba, start_y * buf.stride);
        const dst: [*c]u8 = webp.offsetPtr(base_rgba, if (alpha_first) 0 else 3);
        const has_alpha = webp.WebPDispatchAlpha.?(alpha, io.width, mb_w, num_rows, dst, buf.stride);
        assert(expected_num_lines_out == num_rows);
        // has_alpha is true if there's non-trivial alpha to premultiply with.
        if (has_alpha != 0 and colorspace.isPremultipliedMode()) {
            webp.WebPApplyAlphaMultiply.?(base_rgba, @intFromBool(alpha_first), mb_w, num_rows, buf.stride);
        }
    }
    return 0;
}

fn EmitAlphaRGBA4444(io: *const webp.VP8Io, p: *webp.DecParams, expected_num_lines_out: c_int) c_int {
    var alpha = io.a orelse return 0;

    const mb_w = io.mb_w;
    const colorspace = p.output.?.colorspace;
    const buf = &p.output.?.u.RGBA;
    var num_rows: c_int = undefined;
    const start_y: i64 = GetAlphaSourceRow(io, @ptrCast(&alpha), &num_rows);
    const base_rgba = webp.offsetPtr(buf.rgba, start_y * buf.stride);
    var alpha_dst: [*c]u8 = if (build_options.swap_16bit_csp) base_rgba else base_rgba + 1;
    var alpha_mask: u32 = 0x0f;
    for (0..@abs(num_rows)) |_| {
        for (0..@abs(mb_w)) |i| {
            // Fill in the alpha value (converted to 4 bits).
            const alpha_value: u32 = alpha[i] >> 4;
            alpha_dst[2 * i] = (alpha_dst[2 * i] & 0xf0) | @as(u8, @truncate(alpha_value));
            alpha_mask &= alpha_value;
        }
        alpha = webp.offsetPtr(alpha, io.width);
        alpha_dst = webp.offsetPtr(alpha_dst, buf.stride);
    }

    assert(expected_num_lines_out == num_rows);
    if (alpha_mask != 0x0f and colorspace.isPremultipliedMode()) {
        webp.WebPApplyAlphaMultiply4444.?(base_rgba, mb_w, num_rows, buf.stride);
    }

    return 0;
}

//------------------------------------------------------------------------------
// YUV rescaling (no final RGB conversion needed)

fn Rescale(src_arg: [*]const u8, src_stride: c_int, new_lines_arg: c_int, wrk: ?*webp.WebPRescaler) c_int {
    var num_lines_out: c_int = 0;
    var src, var new_lines = .{ src_arg, new_lines_arg };
    while (new_lines > 0) { // import new contributions of source rows.
        const lines_in = webp.WebPRescalerImport(wrk, new_lines, src, src_stride);
        src = webp.offsetPtr(src, lines_in * src_stride);
        new_lines -= lines_in;
        num_lines_out += webp.WebPRescalerExport(wrk); // emit output row(s)
    }
    return num_lines_out;
}

fn EmitRescaledYUV(io: *const webp.VP8Io, p: *webp.DecParams) c_int {
    const mb_h = io.mb_h;
    const uv_mb_h = (mb_h + 1) >> 1;
    const scaler = p.scaler_y;
    var num_lines_out: c_int = 0;
    if (p.output.?.colorspace.isAlphaMode() and io.a != null) {
        // Before rescaling, we premultiply the luma directly into the io->y
        // internal buffer. This is OK since these samples are not used for
        // intra-prediction (the top samples are saved in cache_y_/u_/v_).
        // But we need to cast the const away, though.
        webp.WebPMultRows(@constCast(io.y), io.y_stride, io.a, io.width, io.mb_w, mb_h, 0);
    }
    num_lines_out = Rescale(io.y, io.y_stride, mb_h, scaler);
    _ = Rescale(io.u, io.uv_stride, uv_mb_h, p.scaler_u);
    _ = Rescale(io.v, io.uv_stride, uv_mb_h, p.scaler_v);
    return num_lines_out;
}

fn EmitRescaledAlphaYUV(io: *const webp.VP8Io, p: *webp.DecParams, expected_num_lines_out: c_int) c_int {
    const buf = &p.output.?.u.YUVA;
    const dst_a = webp.offsetPtr(buf.a, @as(i64, p.last_y) * buf.a_stride);
    if (io.a) |alpha| {
        const dst_y = webp.offsetPtr(buf.y, @as(i64, p.last_y) * buf.y_stride);
        const num_lines_out = Rescale(alpha, io.width, io.mb_h, p.scaler_a);
        assert(expected_num_lines_out == num_lines_out);
        if (num_lines_out > 0) { // unmultiply the Y
            webp.WebPMultRows(dst_y, buf.y_stride, dst_a, buf.a_stride, p.scaler_a.?.dst_width, num_lines_out, 1);
        }
    } else if (buf.a != null) {
        // the user requested alpha, but there is none, set it to opaque.
        assert(p.last_y + expected_num_lines_out <= io.scaled_height);
        FillAlphaPlane(dst_a, io.scaled_width, expected_num_lines_out, buf.a_stride);
    }
    return 0;
}

fn InitYUVRescaler(io: *const webp.VP8Io, p: *webp.DecParams) c_bool {
    const has_alpha = p.output.?.colorspace.isAlphaMode();
    const buf = &p.output.?.u.YUVA;
    const out_width = io.scaled_width;
    const out_height = io.scaled_height;
    const uv_out_width = (out_width + 1) >> 1;
    const uv_out_height = (out_height + 1) >> 1;
    const uv_in_width = (io.mb_w + 1) >> 1;
    const uv_in_height = (io.mb_h + 1) >> 1;
    // scratch memory for luma rescaler
    const work_size: usize = @intCast(2 * out_width);
    const uv_work_size: usize = @intCast(2 * uv_out_width); // and for each u/v ones

    const num_rescalers: usize = if (has_alpha) 4 else 3;

    var total_size: u64 = (work_size + 2 * uv_work_size) * @sizeOf(webp.rescaler_t);
    if (has_alpha) {
        total_size += work_size * @sizeOf(webp.rescaler_t);
    }
    var rescaler_size: usize = num_rescalers * @sizeOf(webp.WebPRescaler) + webp.WEBP_ALIGN_CST;
    total_size += rescaler_size;
    if (!webp.CheckSizeOverflow(total_size)) return 0;

    p.memory = webp.WebPSafeMalloc(1, total_size);
    if (p.memory == null) return 0; // memory error
    var work: [*]webp.rescaler_t = @ptrCast(@alignCast(p.memory.?));
    var scalers: [*]webp.WebPRescaler = @ptrFromInt(webp.WEBP_ALIGN(@as([*]const u8, @ptrCast(work)) + total_size - rescaler_size));
    p.scaler_y = &scalers[0];
    p.scaler_u = &scalers[1];
    p.scaler_v = &scalers[2];
    p.scaler_a = if (has_alpha) &scalers[3] else null;

    if (webp.WebPRescalerInit(p.scaler_y, io.mb_w, io.mb_h, buf.y, out_width, out_height, buf.y_stride, 1, work) == 0 or
        webp.WebPRescalerInit(p.scaler_u, uv_in_width, uv_in_height, buf.u, uv_out_width, uv_out_height, buf.u_stride, 1, work + work_size) == 0 or
        webp.WebPRescalerInit(p.scaler_v, uv_in_width, uv_in_height, buf.v, uv_out_width, uv_out_height, buf.v_stride, 1, work + work_size + uv_work_size) == 0)
    {
        return 0;
    }
    p.emit = @ptrCast(&EmitRescaledYUV);

    if (has_alpha) {
        if (webp.WebPRescalerInit(p.scaler_a, io.mb_w, io.mb_h, buf.a, out_width, out_height, buf.a_stride, 1, work + work_size + 2 * uv_work_size) == 0) {
            return 0;
        }
        p.emit_alpha = @ptrCast(&EmitRescaledAlphaYUV);
        webp.WebPInitAlphaProcessing();
    }
    return 1;
}

//------------------------------------------------------------------------------
// RGBA rescaling

fn ExportRGB(p: *webp.DecParams, y_pos: c_int) c_int {
    const convert = webp.WebPYUV444Converters[@intFromEnum(p.output.?.colorspace)].?;
    const buf = &p.output.?.u.RGBA;
    var dst = webp.offsetPtr(buf.rgba, @as(i64, y_pos) * buf.stride);
    var num_lines_out: c_int = 0;
    // For RGB rescaling, because of the YUV420, current scan position
    // U/V can be +1/-1 line from the Y one.  Hence the double test.
    while (webp.WebPRescalerHasPendingOutput(p.scaler_y.?) and
        webp.WebPRescalerHasPendingOutput(p.scaler_u.?))
    {
        assert(y_pos + num_lines_out < p.output.?.height);
        assert(p.scaler_u.?.y_accum == p.scaler_v.?.y_accum);
        webp.WebPRescalerExportRow(p.scaler_y);
        webp.WebPRescalerExportRow(p.scaler_u);
        webp.WebPRescalerExportRow(p.scaler_v);
        convert(p.scaler_y.?.dst, p.scaler_u.?.dst, p.scaler_v.?.dst, dst, p.scaler_y.?.dst_width);
        dst = webp.offsetPtr(dst, buf.stride);
        num_lines_out += 1;
    }
    return num_lines_out;
}

fn EmitRescaledRGB(io: *const webp.VP8Io, p: *webp.DecParams) c_int {
    const mb_h = io.mb_h;
    const uv_mb_h = (mb_h + 1) >> 1;
    var j: c_int, var uv_j: c_int = .{ 0, 0 };
    var num_lines_out: c_int = 0;
    while (j < mb_h) {
        const y_lines_in = webp.WebPRescalerImport(
            p.scaler_y,
            mb_h - j,
            webp.offsetPtr(io.y, @as(i64, j) * io.y_stride),
            io.y_stride,
        );
        j += y_lines_in;
        if (webp.WebPRescaleNeededLines(p.scaler_u, uv_mb_h - uv_j) != 0) {
            const u_lines_in = webp.WebPRescalerImport(
                p.scaler_u,
                uv_mb_h - uv_j,
                webp.offsetPtr(io.u, @as(i64, uv_j) * io.uv_stride),
                io.uv_stride,
            );
            const v_lines_in = webp.WebPRescalerImport(
                p.scaler_v,
                uv_mb_h - uv_j,
                webp.offsetPtr(io.v, @as(i64, uv_j) * io.uv_stride),
                io.uv_stride,
            );
            assert(u_lines_in == v_lines_in);
            uv_j += u_lines_in;
        }
        num_lines_out += ExportRGB(p, p.last_y + num_lines_out);
    }
    return num_lines_out;
}

fn ExportAlpha(p: *webp.DecParams, y_pos: c_int, max_lines_out: c_int) c_int {
    const buf = &p.output.?.u.RGBA;
    const base_rgba = webp.offsetPtr(buf.rgba, @as(i64, y_pos) * buf.stride);
    const colorspace = p.output.?.colorspace;
    const alpha_first = (colorspace == .ARGB or colorspace == .Argb);
    var dst = webp.offsetPtr(base_rgba, if (alpha_first) 0 else 3);
    var num_lines_out: c_int = 0;
    const is_premult_alpha = colorspace.isPremultipliedMode();
    var non_opaque: u32 = 0;
    const width = p.scaler_a.?.dst_width;

    while (webp.WebPRescalerHasPendingOutput(p.scaler_a.?) and
        num_lines_out < max_lines_out)
    {
        assert(y_pos + num_lines_out < p.output.?.height);
        webp.WebPRescalerExportRow(p.scaler_a.?);
        non_opaque |= @bitCast(webp.WebPDispatchAlpha.?(p.scaler_a.?.dst, 0, width, 1, dst, 0));
        dst = webp.offsetPtr(dst, buf.stride);
        num_lines_out += 1;
    }
    if (is_premult_alpha and non_opaque != 0) {
        webp.WebPApplyAlphaMultiply.?(base_rgba, @intFromBool(alpha_first), width, num_lines_out, buf.stride);
    }
    return num_lines_out;
}

fn ExportAlphaRGBA4444(p: *webp.DecParams, y_pos: c_int, max_lines_out: c_int) c_int {
    const buf = &p.output.?.u.RGBA;
    const base_rgba = webp.offsetPtr(buf.rgba, @as(i64, y_pos) * buf.stride);
    var alpha_dst = if (build_options.swap_16bit_csp) base_rgba else base_rgba + 1;
    var num_lines_out: c_int = 0;
    const colorspace = p.output.?.colorspace;
    const width = p.scaler_a.?.dst_width;
    const is_premult_alpha = colorspace.isPremultipliedMode();
    var alpha_mask: u32 = 0x0f;

    while (webp.WebPRescalerHasPendingOutput(p.scaler_a.?) and
        num_lines_out < max_lines_out)
    {
        assert(y_pos + num_lines_out < p.output.?.height);
        webp.WebPRescalerExportRow(p.scaler_a);
        for (0..@abs(width)) |i| {
            // Fill in the alpha value (converted to 4 bits).
            const alpha_value: u32 = p.scaler_a.?.dst[i] >> 4;
            alpha_dst[2 * i] = (alpha_dst[2 * i] & 0xf0) | @as(u8, @truncate(alpha_value));
            alpha_mask &= alpha_value;
        }
        alpha_dst = webp.offsetPtr(alpha_dst, buf.stride);
        num_lines_out += 1;
    }
    if (is_premult_alpha and alpha_mask != 0x0f) {
        webp.WebPApplyAlphaMultiply4444.?(base_rgba, width, num_lines_out, buf.stride);
    }
    return num_lines_out;
}

fn EmitRescaledAlphaRGB(io: *const webp.VP8Io, p: *webp.DecParams, expected_num_out_lines: c_int) c_int {
    if (io.a != null) {
        const scaler = p.scaler_a.?;
        var lines_left: c_int = expected_num_out_lines;
        const y_end = p.last_y + lines_left;
        while (lines_left > 0) {
            const row_offset: i64 = scaler.src_y - io.mb_y;
            _ = webp.WebPRescalerImport(scaler, io.mb_h + io.mb_y - scaler.src_y, webp.offsetPtr(io.a.?, row_offset * io.width), io.width);
            lines_left -= p.emit_alpha_row.?(p, y_end - lines_left, lines_left);
        }
    }
    return 0;
}

fn InitRGBRescaler(io: *const webp.VP8Io, p: *webp.DecParams) c_bool {
    const has_alpha = p.output.?.colorspace.isAlphaMode();
    const out_width = io.scaled_width;
    const out_height = io.scaled_height;
    const uv_in_width = (io.mb_w + 1) >> 1;
    const uv_in_height = (io.mb_h + 1) >> 1;
    // scratch memory for one rescaler
    const work_size: i64 = @intCast(2 * out_width);
    // size_t rescaler_size;
    // WebPRescaler* scalers;
    const num_rescalers: c_int = if (has_alpha) 4 else 3;

    var tmp_size1: u64 = @intCast(num_rescalers * work_size);
    var tmp_size2: u64 = @intCast(num_rescalers * out_width);
    var total_size: u64 = tmp_size1 * @sizeOf(webp.rescaler_t) + tmp_size2 * @sizeOf(u8);
    var rescaler_size: u64 = @abs(num_rescalers) * @sizeOf(webp.WebPRescaler) + webp.WEBP_ALIGN_CST;
    total_size += rescaler_size;
    if (!webp.CheckSizeOverflow(total_size)) return 0;

    p.memory = webp.WebPSafeMalloc(1, total_size);
    if (p.memory == null) {
        return 0; // memory error
    }
    var work: [*]webp.rescaler_t = @ptrCast(@alignCast(p.memory.?)); // rescalers work area
    var tmp: [*c]u8 = @ptrCast(work + tmp_size1); // tmp storage for scaled YUV444 samples before RGB conversion

    var scalers: [*]webp.WebPRescaler = @ptrFromInt(webp.WEBP_ALIGN(@as([*]const u8, @ptrCast(work)) + total_size - rescaler_size));
    p.scaler_y = &scalers[0];
    p.scaler_u = &scalers[1];
    p.scaler_v = &scalers[2];
    p.scaler_a = if (has_alpha) &scalers[3] else null;

    if (webp.WebPRescalerInit(p.scaler_y, io.mb_w, io.mb_h, webp.offsetPtr(tmp, 0 * out_width), out_width, out_height, 0, 1, webp.offsetPtr(work, 0 * work_size)) == 0 or
        webp.WebPRescalerInit(p.scaler_u, uv_in_width, uv_in_height, webp.offsetPtr(tmp, 1 * out_width), out_width, out_height, 0, 1, webp.offsetPtr(work, 1 * work_size)) == 0 or
        webp.WebPRescalerInit(p.scaler_v, uv_in_width, uv_in_height, webp.offsetPtr(tmp, 2 * out_width), out_width, out_height, 0, 1, webp.offsetPtr(work, 2 * work_size)) == 0)
    {
        return 0;
    }
    p.emit = @ptrCast(&EmitRescaledRGB);
    webp.WebPInitYUV444Converters();

    if (has_alpha) {
        if (webp.WebPRescalerInit(p.scaler_a, io.mb_w, io.mb_h, webp.offsetPtr(tmp, 3 * out_width), out_width, out_height, 0, 1, webp.offsetPtr(work, 3 * work_size)) == 0) {
            return 0;
        }
        p.emit_alpha = @ptrCast(&EmitRescaledAlphaRGB);
        if (p.output.?.colorspace == .RGBA_4444 or
            p.output.?.colorspace == .rgbA_4444)
        {
            p.emit_alpha_row = @ptrCast(&ExportAlphaRGBA4444);
        } else {
            p.emit_alpha_row = @ptrCast(&ExportAlpha);
        }
        webp.WebPInitAlphaProcessing();
    }
    return 1;
}

//------------------------------------------------------------------------------
// Default custom functions

fn CustomSetup(io: *webp.VP8Io) c_int {
    const p: *webp.DecParams = @ptrCast(@alignCast(io.@"opaque".?));
    const colorspace = p.output.?.colorspace;
    const is_rgb = colorspace.isRGBMode();
    const is_alpha = colorspace.isAlphaMode();

    p.memory = null;
    p.emit = null;
    p.emit_alpha = null;
    p.emit_alpha_row = null;
    if (webp.WebPIoInitFromOptions(p.options, io, if (is_alpha) .YUV else .YUVA) == 0) {
        return 0;
    }

    if (is_alpha and colorspace.isPremultipliedMode()) {
        webp.WebPInitUpsamplers();
    }
    if (io.use_scaling != 0) {
        if (comptime !build_options.reduce_size) {
            const ok = if (is_rgb) InitRGBRescaler(io, p) else InitYUVRescaler(io, p);
            if (ok == 0) return 0; // memory error
        } else return 0; // rescaling support not compiled
    } else {
        if (is_rgb) {
            webp.WebPInitSamplers();
            p.emit = @ptrCast(&EmitSampledRGB); // default
            if (io.fancy_upsampling != 0) {
                if (comptime build_options.fancy_upsampling) {
                    const uv_width = (io.mb_w + 1) >> 1;
                    p.memory = webp.WebPSafeMalloc(1, @abs(io.mb_w + 2 * uv_width));
                    if (p.memory == null) return 0; // memory error.
                    p.tmp_y = @ptrCast(p.memory.?);
                    p.tmp_u = webp.offsetPtr(p.tmp_y, io.mb_w);
                    p.tmp_v = webp.offsetPtr(p.tmp_u, uv_width);
                    p.emit = @ptrCast(&EmitFancyRGB);
                    webp.WebPInitUpsamplers();
                }
            }
        } else p.emit = @ptrCast(&EmitYUV);

        if (is_alpha) { // need transparency output
            p.emit_alpha = @ptrCast(if (colorspace == .RGBA_4444 or colorspace == .rgbA_4444)
                &EmitAlphaRGBA4444
            else if (is_rgb)
                &EmitAlphaRGB
            else
                &EmitAlphaYUV);
            if (is_rgb) webp.WebPInitAlphaProcessing();
        }
    }

    return 1;
}

//------------------------------------------------------------------------------

fn CustomPut(io: *const webp.VP8Io) c_int {
    const p: *webp.DecParams = @ptrCast(@alignCast(io.@"opaque".?));
    const mb_w = io.mb_w;
    const mb_h = io.mb_h;
    assert(io.mb_y & 1 == 0);

    if (mb_w <= 0 or mb_h <= 0) return 0;

    var num_lines_out = p.emit.?(io, p);
    if (p.emit_alpha) |emit_alpha| _ = emit_alpha(io, p, num_lines_out);
    p.last_y += num_lines_out;
    return 1;
}

//------------------------------------------------------------------------------

fn CustomTeardown(io: *const webp.VP8Io) void {
    const p: *webp.DecParams = @ptrCast(@alignCast(io.@"opaque".?));
    webp.WebPSafeFree(p.memory);
    p.memory = null;
}

//------------------------------------------------------------------------------
// Main entry point

/// Initializes VP8Io with custom setup, io and teardown functions. The default
/// hooks will use the supplied 'params' as io->opaque handle.
pub export fn WebPInitCustomIo(params: ?*webp.DecParams, io: *webp.VP8Io) void {
    io.put = @ptrCast(&CustomPut);
    io.setup = @ptrCast(&CustomSetup);
    io.teardown = @ptrCast(&CustomTeardown);
    io.@"opaque" = params;
}

//------------------------------------------------------------------------------
