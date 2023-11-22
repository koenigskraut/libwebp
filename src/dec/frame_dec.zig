const std = @import("std");
const build_options = @import("build_options");
const webp = struct {
    usingnamespace @import("common_dec.zig");
    usingnamespace @import("vp8_dec.zig");
    usingnamespace @import("webp_dec.zig");
    usingnamespace @import("../dsp/dsp.zig");
    usingnamespace @import("../utils/random_utils.zig");
    usingnamespace @import("../utils/thread_utils.zig");
    usingnamespace @import("../utils/utils.zig");
    usingnamespace @import("../webp/decode.zig");

    extern fn VP8InitRandom(rg: [*c]@This().VP8Random, dithering: f32) void;
    extern fn VP8InitScanline(dec: [*c]@This().VP8Decoder) void;
    extern fn VP8DspInit() void;
    extern fn VP8DecompressAlphaRows(dec: [*c]@This().VP8Decoder, io: [*c]const @This().VP8Io, row: c_int, num_rows: c_int) [*c]const u8;
    extern fn VP8SetError(dec: [*c]@This().VP8Decoder, @"error": @This().VP8Status, msg: [*c]const u8) c_int;

    pub extern fn WebPSetWorkerInterface(winterface: [*c]const @This().WorkerInterface) c_int;
    pub extern fn WebPGetWorkerInterface() [*c]const @This().WorkerInterface;
};

const assert = std.debug.assert;
const VP8Status = webp.VP8Status;

//------------------------------------------------------------------------------
// Main reconstruction function.

const kScan = [16]u16{
    0 + 0 * webp.BPS,  4 + 0 * webp.BPS,  8 + 0 * webp.BPS,  12 + 0 * webp.BPS,
    0 + 4 * webp.BPS,  4 + 4 * webp.BPS,  8 + 4 * webp.BPS,  12 + 4 * webp.BPS,
    0 + 8 * webp.BPS,  4 + 8 * webp.BPS,  8 + 8 * webp.BPS,  12 + 8 * webp.BPS,
    0 + 12 * webp.BPS, 4 + 12 * webp.BPS, 8 + 12 * webp.BPS, 12 + 12 * webp.BPS,
};

fn CheckMode(mb_x: c_int, mb_y: c_int, mode: c_int) c_int {
    if (mode == webp.B_DC_PRED) {
        if (mb_x == 0) {
            return if (mb_y == 0) webp.B_DC_PRED_NOTOPLEFT else webp.B_DC_PRED_NOLEFT;
        } else {
            return if (mb_y == 0) webp.B_DC_PRED_NOTOP else webp.B_DC_PRED;
        }
    }
    return mode;
}

inline fn Copy32b(dst: [*c]u8, src: [*c]const u8) void {
    @memcpy(dst[0..4], src[0..4]);
}

inline fn DoTransform(bits: u32, src: [*c]const i16, dst: [*c]u8) void {
    switch (bits >> 30) {
        3 => webp.VP8Transform.?(src, dst, 0),
        2 => webp.VP8TransformAC3.?(src, dst),
        1 => webp.VP8TransformDC.?(src, dst),
        else => {},
    }
}

fn DoUVTransform(bits: u32, src: [*c]const i16, dst: [*c]u8) void {
    if (bits & 0xff != 0) { // any non-zero coeff at all?
        if (bits & 0xaa != 0) { // any non-zero AC coefficient?
            webp.VP8TransformUV.?(src, dst); // note we don't use the AC3 variant for U/V
        } else {
            webp.VP8TransformDCUV.?(src, dst);
        }
    }
}

fn ReconstructRow(dec: *const webp.VP8Decoder, ctx: *const webp.VP8ThreadContext) void {
    const mb_y = ctx.mb_y_;
    const cache_id = ctx.id_;
    const y_dst: [*c]u8 = dec.yuv_b_ + webp.Y_OFF;
    const u_dst: [*c]u8 = dec.yuv_b_ + webp.U_OFF;
    const v_dst: [*c]u8 = dec.yuv_b_ + webp.V_OFF;

    // Initialize left-most block.
    for (0..16) |j| {
        (y_dst + j * webp.BPS - 1).* = 129;
    }
    for (0..8) |j| {
        (u_dst + j * webp.BPS - 1).* = 129;
        (v_dst + j * webp.BPS - 1).* = 129;
    }

    // Init top-left sample on left column too.
    if (mb_y > 0) {
        (v_dst - 1 - webp.BPS).* = 129;
        (u_dst - 1 - webp.BPS).* = 129;
        (y_dst - 1 - webp.BPS).* = 129;
    } else {
        // we only need to do this init once at block (0,0).
        // Afterward, it remains valid for the whole topmost row.
        @memset((y_dst - webp.BPS - 1)[0 .. 16 + 4 + 1], 127);
        @memset((u_dst - webp.BPS - 1)[0 .. 8 + 1], 127);
        @memset((v_dst - webp.BPS - 1)[0 .. 8 + 1], 127);
    }

    var mb_x: c_int = 0;
    // Reconstruct one row.
    while (mb_x < dec.mb_w_) : (mb_x += 1) {
        const block: *const webp.VP8MBData = webp.offsetPtr(ctx.mb_data_, mb_x);

        // Rotate in the left samples from previously decoded block. We move four
        // pixels at a time for alignment reason, and because of in-loop filter.
        if (mb_x > 0) {
            var j: c_int = -1;
            while (j < 16) : (j += 1) {
                Copy32b(webp.offsetPtr(y_dst, j * webp.BPS - 4), webp.offsetPtr(y_dst, j * webp.BPS + 12));
            }
            j = -1;
            while (j < 8) : (j += 1) {
                Copy32b(webp.offsetPtr(u_dst, j * webp.BPS - 4), webp.offsetPtr(u_dst, j * webp.BPS + 4));
                Copy32b(webp.offsetPtr(v_dst, j * webp.BPS - 4), webp.offsetPtr(v_dst, j * webp.BPS + 4));
            }
        }
        {
            // bring top samples into the cache
            const top_yuv: [*]webp.VP8TopSamples = webp.offsetPtr(dec.yuv_t_, mb_x);
            const coeffs: [*]const i16 = &block.coeffs_;
            var bits: u32 = block.non_zero_y_;
            // int n;

            if (mb_y > 0) {
                @memcpy((y_dst - webp.BPS)[0..16], top_yuv[0].y[0..16]);
                @memcpy((u_dst - webp.BPS)[0..8], top_yuv[0].u[0..8]);
                @memcpy((v_dst - webp.BPS)[0..8], top_yuv[0].v[0..8]);
            }

            // predict and add residuals
            if (block.is_i4x4_ != 0) { // 4x4
                const top_right: [*c]u32 = @ptrCast(@alignCast(y_dst - webp.BPS + 16));
                if (mb_y > 0) {
                    if (mb_x >= dec.mb_w_ - 1) { // on rightmost border
                        @memset(@as([*c]u8, @ptrCast(top_right))[0..@sizeOf(u32)], top_yuv[0].y[15]);
                    } else {
                        @memcpy(@as([*c]u8, @ptrCast(top_right))[0..@sizeOf(u32)], top_yuv[1].y[0..@sizeOf(u32)]);
                    }
                }
                // replicate the top-right pixels below
                top_right[webp.BPS], top_right[2 * webp.BPS], top_right[3 * webp.BPS] = .{ top_right[0], top_right[0], top_right[0] };

                // predict and add residuals for all 4x4 blocks in turn.
                var n: usize = 0;
                while (n < 16) : ({
                    n += 1;
                    bits <<= 2;
                }) {
                    const dst: [*c]u8 = y_dst + kScan[n];
                    webp.VP8PredLuma4[block.imodes_[n]].?(dst);
                    DoTransform(bits, coeffs + n * 16, dst);
                }
            } else { // 16x16
                const pred_func = @abs(CheckMode(mb_x, mb_y, @intCast(block.imodes_[0])));
                webp.VP8PredLuma16[pred_func].?(y_dst);
                if (bits != 0) {
                    var n: usize = 0;
                    while (n < 16) : ({
                        n += 1;
                        bits <<= 2;
                    }) {
                        DoTransform(bits, coeffs + n * 16, y_dst + kScan[n]);
                    }
                }
            }
            {
                // Chroma
                const bits_uv: u32 = block.non_zero_uv_;
                const pred_func = @abs(CheckMode(mb_x, mb_y, @intCast(block.uvmode_)));
                webp.VP8PredChroma8[pred_func].?(u_dst);
                webp.VP8PredChroma8[pred_func].?(v_dst);
                DoUVTransform(bits_uv >> 0, coeffs + 16 * 16, u_dst);
                DoUVTransform(bits_uv >> 8, coeffs + 20 * 16, v_dst);
            }

            // stash away top samples for next block
            if (mb_y < dec.mb_h_ - 1) {
                @memcpy(top_yuv[0].y[0..16], (y_dst + 15 * webp.BPS)[0..16]);
                @memcpy(top_yuv[0].u[0..8], (u_dst + 7 * webp.BPS)[0..8]);
                @memcpy(top_yuv[0].v[0..8], (v_dst + 7 * webp.BPS)[0..8]);
            }
        }
        // Transfer reconstructed samples from yuv_b_ cache to final destination.
        {
            const y_offset: c_int = cache_id * 16 * dec.cache_y_stride_;
            const uv_offset: c_int = cache_id * 8 * dec.cache_uv_stride_;
            const y_out: [*c]u8 = webp.offsetPtr(dec.cache_y_, mb_x * 16 + y_offset);
            const u_out: [*c]u8 = webp.offsetPtr(dec.cache_u_, mb_x * 8 + uv_offset);
            const v_out: [*c]u8 = webp.offsetPtr(dec.cache_v_, mb_x * 8 + uv_offset);
            for (0..16) |j| {
                @memcpy(webp.offsetPtr(y_out, @as(c_int, @intCast(j)) * dec.cache_y_stride_)[0..16], webp.offsetPtr(y_dst, @as(c_int, @intCast(j)) * webp.BPS)[0..16]);
            }
            for (0..8) |j| {
                @memcpy(webp.offsetPtr(u_out, @as(c_int, @intCast(j)) * dec.cache_uv_stride_)[0..8], webp.offsetPtr(u_dst, @as(c_int, @intCast(j)) * webp.BPS)[0..8]);
                @memcpy(webp.offsetPtr(v_out, @as(c_int, @intCast(j)) * dec.cache_uv_stride_)[0..8], webp.offsetPtr(v_dst, @as(c_int, @intCast(j)) * webp.BPS)[0..8]);
            }
        }
    }
}

//------------------------------------------------------------------------------
// Filtering

/// kFilterExtraRows[] = How many extra lines are needed on the MB boundary
/// for caching, given a filtering level.
///
/// Simple filter:  up to 2 luma samples are read and 1 is written.
///
/// Complex filter: up to 4 luma samples are read and 3 are written. Same for
///                 U/V, so it's 8 samples total (because of the 2x upsampling).
const kFilterExtraRows = [3]u8{ 0, 2, 8 };

fn DoFilter(dec: *const webp.VP8Decoder, mb_x: c_int, mb_y: c_int) void {
    const ctx: *const webp.VP8ThreadContext = &dec.thread_ctx_;
    const cache_id: c_int = ctx.id_;
    const y_bps: c_int = dec.cache_y_stride_;
    const f_info: *const webp.VP8FInfo = webp.offsetPtr(ctx.f_info_, mb_x);
    const y_dst: [*c]u8 = webp.offsetPtr(dec.cache_y_, cache_id * 16 * y_bps + mb_x * 16);
    const ilevel: c_int = @intCast(f_info.f_ilevel_);
    const limit: c_int = @intCast(f_info.f_limit_);
    if (limit == 0) return;
    assert(limit >= 3);
    if (dec.filter_type_ == 1) { // simple
        if (mb_x > 0)
            webp.VP8SimpleHFilter16.?(y_dst, y_bps, limit + 4);
        if (f_info.f_inner_ != 0)
            webp.VP8SimpleHFilter16i.?(y_dst, y_bps, limit);
        if (mb_y > 0)
            webp.VP8SimpleVFilter16.?(y_dst, y_bps, limit + 4);
        if (f_info.f_inner_ != 0)
            webp.VP8SimpleVFilter16i.?(y_dst, y_bps, limit);
    } else { // complex
        const uv_bps: c_int = dec.cache_uv_stride_;
        const u_dst = webp.offsetPtr(dec.cache_u_, cache_id * 8 * uv_bps + mb_x * 8);
        const v_dst = webp.offsetPtr(dec.cache_v_, cache_id * 8 * uv_bps + mb_x * 8);
        const hev_thresh: c_int = @intCast(f_info.hev_thresh_);
        if (mb_x > 0) {
            webp.VP8HFilter16.?(y_dst, y_bps, limit + 4, ilevel, hev_thresh);
            webp.VP8HFilter8.?(u_dst, v_dst, uv_bps, limit + 4, ilevel, hev_thresh);
        }
        if (f_info.f_inner_ != 0) {
            webp.VP8HFilter16i.?(y_dst, y_bps, limit, ilevel, hev_thresh);
            webp.VP8HFilter8i.?(u_dst, v_dst, uv_bps, limit, ilevel, hev_thresh);
        }
        if (mb_y > 0) {
            webp.VP8VFilter16.?(y_dst, y_bps, limit + 4, ilevel, hev_thresh);
            webp.VP8VFilter8.?(u_dst, v_dst, uv_bps, limit + 4, ilevel, hev_thresh);
        }
        if (f_info.f_inner_ != 0) {
            webp.VP8VFilter16i.?(y_dst, y_bps, limit, ilevel, hev_thresh);
            webp.VP8VFilter8i.?(u_dst, v_dst, uv_bps, limit, ilevel, hev_thresh);
        }
    }
}

///Filter the decoded macroblock row (if needed)
fn FilterRow(dec: *const webp.VP8Decoder) void {
    const mb_y = dec.thread_ctx_.mb_y_;
    assert(dec.thread_ctx_.filter_row_ != 0);
    var mb_x: c_int = dec.tl_mb_x_;
    while (mb_x < dec.br_mb_x_) : (mb_x += 1) {
        DoFilter(dec, mb_x, mb_y);
    }
}

//------------------------------------------------------------------------------
// Precompute the filtering strength for each segment and each i4x4/i16x16 mode.

fn PrecomputeFilterStrengths(dec: *webp.VP8Decoder) void {
    if (dec.filter_type_ > 0) {
        const hdr: *const webp.VP8FilterHeader = &dec.filter_hdr_;
        for (0..webp.NUM_MB_SEGMENTS) |s| {
            // int i4x4;
            // First, compute the initial level
            var base_level: c_int = undefined;
            if (dec.segment_hdr_.use_segment_ != 0) {
                base_level = dec.segment_hdr_.filter_strength_[s];
                if (dec.segment_hdr_.absolute_delta_ == 0)
                    base_level += hdr.level_;
            } else {
                base_level = hdr.level_;
            }

            for (0..2) |i4x4| {
                const info: *webp.VP8FInfo = &dec.fstrengths_[s][i4x4];
                var level = base_level;
                if (hdr.use_lf_delta_ != 0) {
                    level += hdr.ref_lf_delta_[0];
                    if (i4x4 != 0)
                        level += hdr.mode_lf_delta_[0];
                }
                level = if (level < 0) 0 else if (level > 63) 63 else level;
                if (level > 0) {
                    var ilevel = level;
                    if (hdr.sharpness_ > 0) {
                        if (hdr.sharpness_ > 4) ilevel >>= 2 else ilevel >>= 1;
                        if (ilevel > 9 - hdr.sharpness_)
                            ilevel = 9 - hdr.sharpness_;
                    }
                    if (ilevel < 1) ilevel = 1;
                    info.f_ilevel_ = @intCast(ilevel);
                    info.f_limit_ = @intCast(2 * level + ilevel);
                    info.hev_thresh_ = if (level >= 40) 2 else if (level >= 15) 1 else 0;
                } else {
                    info.f_limit_ = 0; // no filtering
                }
                info.f_inner_ = @truncate(i4x4);
            }
        }
    }
}

//------------------------------------------------------------------------------
// Dithering

// minimal amp that will provide a non-zero dithering effect
const MIN_DITHER_AMP = 4;

const DITHER_AMP_TAB_SIZE = 12;
// roughly, it's dqm->uv_mat_[1]
const kQuantToDitherAmp = [DITHER_AMP_TAB_SIZE]u8{ 8, 7, 6, 4, 4, 2, 2, 2, 1, 1, 1, 1 };

pub export fn VP8InitDithering(options_arg: ?*const webp.DecoderOptions, dec: *webp.VP8Decoder) void {
    const options = options_arg orelse return;
    const d: c_int = options.dithering_strength;
    const max_amp: c_int = (@as(c_int, 1) << webp.VP8_RANDOM_DITHER_FIX) - 1;
    const f: c_int = if (d < 0) 0 else if (d > 100) max_amp else @divTrunc(d * max_amp, 100);
    if (f > 0) {
        var all_amp: c_int = 0;
        for (0..webp.NUM_MB_SEGMENTS) |s| {
            const dqm: *webp.VP8QuantMatrix = &dec.dqm_[s];
            if (dqm.uv_quant_ < DITHER_AMP_TAB_SIZE) {
                const idx: c_uint = @intCast(if (dqm.uv_quant_ < 0) 0 else dqm.uv_quant_);
                dqm.dither_ = (f * @as(c_int, @intCast(kQuantToDitherAmp[idx]))) >> 3;
            }
            all_amp |= dqm.dither_;
        }
        if (all_amp != 0) {
            webp.VP8InitRandom(@ptrCast(&dec.dithering_rg_), 1.0);
            dec.dither_ = 1;
        }
    }
    // potentially allow alpha dithering
    dec.alpha_dithering_ = options.alpha_dithering_strength;
    if (dec.alpha_dithering_ > 100) {
        dec.alpha_dithering_ = 100;
    } else if (dec.alpha_dithering_ < 0) {
        dec.alpha_dithering_ = 0;
    }
}

// Convert to range: [-2,2] for dither=50, [-4,4] for dither=100
fn Dither8x8(rg: *webp.VP8Random, dst: [*c]u8, bps: c_int, amp: c_int) void {
    var dither: [64]u8 = undefined;
    for (0..8 * 8) |i| {
        dither[i] = @intCast(webp.VP8RandomBits2(rg, webp.VP8_DITHER_AMP_BITS + 1, amp));
    }
    webp.VP8DitherCombine8x8.?(&dither, dst, bps);
}

fn DitherRow(dec: *webp.VP8Decoder) void {
    var mb_x: c_int = dec.tl_mb_x_;
    assert(dec.dither_ != 0);
    while (mb_x < dec.br_mb_x_) : (mb_x += 1) {
        const ctx: *const webp.VP8ThreadContext = &dec.thread_ctx_;
        const data: *const webp.VP8MBData = webp.offsetPtr(ctx.mb_data_, mb_x);
        const cache_id: c_int = ctx.id_;
        const uv_bps: c_int = dec.cache_uv_stride_;
        if (data.dither_ >= MIN_DITHER_AMP) {
            const u_dst: [*c]u8 = webp.offsetPtr(dec.cache_u_, cache_id * 8 * uv_bps + mb_x * 8);
            const v_dst: [*c]u8 = webp.offsetPtr(dec.cache_v_, cache_id * 8 * uv_bps + mb_x * 8);
            Dither8x8(&dec.dithering_rg_, u_dst, uv_bps, @intCast(data.dither_));
            Dither8x8(&dec.dithering_rg_, v_dst, uv_bps, @intCast(data.dither_));
        }
    }
}

//------------------------------------------------------------------------------
// This function is called after a row of macroblocks is finished decoding.
// It also takes into account the following restrictions:
//  * In case of in-loop filtering, we must hold off sending some of the bottom
//    pixels as they are yet unfiltered. They will be when the next macroblock
//    row is decoded. Meanwhile, we must preserve them by rotating them in the
//    cache area. This doesn't hold for the very bottom row of the uncropped
//    picture of course.
//  * we must clip the remaining pixels against the cropping area. The VP8Io
//    struct must have the following fields set correctly before calling put():

/// vertical position of a MB
inline fn MACROBLOCK_VPOS(mb_y: anytype) @TypeOf(mb_y) {
    return mb_y * 16;
}

// Finalize and transmit a complete row. Return false in case of user-abort.
fn FinishRow(arg_arg1: ?*anyopaque, arg_arg2: ?*anyopaque) callconv(.C) c_int {
    var arg1 = arg_arg1;
    var arg2 = arg_arg2;
    const dec: *webp.VP8Decoder = @ptrCast(@alignCast(arg1.?));
    const io: *webp.VP8Io = @ptrCast(@alignCast(arg2.?));
    var ok: c_int = 1;
    const ctx: *const webp.VP8ThreadContext = &dec.thread_ctx_;
    const cache_id: c_int = ctx.id_;
    const extra_y_rows: c_int = @intCast(kFilterExtraRows[@intCast(dec.filter_type_)]);
    const ysize: c_int = extra_y_rows * dec.cache_y_stride_;
    const uvsize: c_int = @divTrunc(extra_y_rows, 2) * dec.cache_uv_stride_;
    const y_offset: c_int = cache_id * 16 * dec.cache_y_stride_;
    const uv_offset: c_int = cache_id * 8 * dec.cache_uv_stride_;
    const ydst: [*c]u8 = webp.offsetPtr(dec.cache_y_, -ysize + y_offset);
    const udst: [*c]u8 = webp.offsetPtr(dec.cache_u_, -uvsize + uv_offset);
    const vdst: [*c]u8 = webp.offsetPtr(dec.cache_v_, -uvsize + uv_offset);
    const mb_y: c_int = ctx.mb_y_;
    const is_first_row = mb_y == 0;
    const is_last_row = mb_y >= (dec.*.br_mb_y_ - 1);

    if (dec.mt_method_ == 2) {
        ReconstructRow(dec, ctx);
    }
    if (ctx.filter_row_ != 0) {
        FilterRow(dec);
    }
    if (dec.dither_ != 0) {
        DitherRow(dec);
    }

    if (io.put != null) {
        var y_start: c_int = MACROBLOCK_VPOS(mb_y);
        var y_end: c_int = MACROBLOCK_VPOS(mb_y + 1);
        if (!is_first_row) {
            y_start -= extra_y_rows;
            io.y = ydst;
            io.u = udst;
            io.v = vdst;
        } else {
            io.y = webp.offsetPtr(dec.cache_y_, y_offset);
            io.u = webp.offsetPtr(dec.cache_u_, uv_offset);
            io.v = webp.offsetPtr(dec.cache_v_, uv_offset);
        }

        if (!is_last_row) {
            y_end -= extra_y_rows;
        }
        if (y_end > io.crop_bottom) {
            y_end = io.crop_bottom; // make sure we don't overflow on last row.
        }
        // If dec->alpha_data_ is not null, we have some alpha plane present.
        io.a = null;
        if (dec.alpha_data_ != null and y_start < y_end) {
            io.a = webp.VP8DecompressAlphaRows(dec, io, y_start, y_end - y_start);
            if (io.a == null) {
                return webp.VP8SetError(dec, .BitstreamError, "Could not decode alpha data.");
            }
        }
        if (y_start < io.crop_top) {
            const delta_y: c_int = io.crop_top - y_start;
            y_start = io.crop_top;
            assert(delta_y & 1 == 0);
            io.y = webp.offsetPtr(io.y, dec.cache_y_stride_ * delta_y);
            io.u = webp.offsetPtr(io.u, dec.cache_uv_stride_ * (delta_y >> 1));
            io.v = webp.offsetPtr(io.v, dec.cache_uv_stride_ * (delta_y >> 1));
            if (io.a != null) {
                io.a = webp.offsetPtr(io.a.?, io.width * delta_y);
            }
        }

        if (y_start < y_end) {
            io.y = webp.offsetPtr(io.y, io.crop_left);
            io.u = webp.offsetPtr(io.u, io.crop_left >> 1);
            io.v = webp.offsetPtr(io.v, io.crop_left >> 1);
            if (io.a != null) {
                io.a = webp.offsetPtr(io.a.?, io.crop_left);
            }
            io.mb_y = y_start - io.crop_top;
            io.mb_w = io.crop_right - io.crop_left;
            io.mb_h = y_end - y_start;
            ok = io.put.?(io);
        }
    }

    // rotate top samples if needed
    if (cache_id + 1 == dec.num_caches_) {
        if (!is_last_row) {
            @memcpy(webp.offsetPtr(dec.cache_y_, -ysize)[0..@intCast(ysize)], webp.offsetPtr(ydst, 16 * dec.cache_y_stride_)[0..@intCast(ysize)]);
            @memcpy(webp.offsetPtr(dec.cache_u_, -uvsize)[0..@intCast(uvsize)], webp.offsetPtr(udst, 8 * dec.cache_uv_stride_)[0..@intCast(uvsize)]);
            @memcpy(webp.offsetPtr(dec.cache_v_, -uvsize)[0..@intCast(uvsize)], webp.offsetPtr(vdst, 8 * dec.cache_uv_stride_)[0..@intCast(uvsize)]);
        }
    }

    return ok;
}

// ------------------------------------------------------------------------------

pub export fn VP8ProcessRow(dec: *webp.VP8Decoder, io: *webp.VP8Io) c_int {
    var ok: c_int = 1;
    const ctx: *webp.VP8ThreadContext = &dec.thread_ctx_;
    const filter_row = (dec.filter_type_ > 0) and (dec.mb_y_ >= dec.tl_mb_y_) and (dec.mb_y_ <= dec.br_mb_y_);
    if (dec.mt_method_ == 0) {
        // ctx.id_ and ctx.f_info_ are already set
        ctx.mb_y_ = dec.mb_y_;
        ctx.filter_row_ = @intFromBool(filter_row);
        ReconstructRow(dec, ctx);
        ok = FinishRow(dec, io);
    } else {
        const worker: *webp.Worker = &dec.worker_;
        // Finish previous job *before* updating context
        ok &= webp.WebPGetWorkerInterface().*.Sync.?(worker);
        assert(worker.status_ == .ok);
        if (ok != 0) { // spawn a new deblocking/output job
            ctx.io_ = io.*;
            ctx.id_ = dec.cache_id_;
            ctx.mb_y_ = dec.mb_y_;
            ctx.filter_row_ = @intFromBool(filter_row);
            if (dec.mt_method_ == 2) { // swap macroblock data
                const tmp = ctx.mb_data_;
                ctx.mb_data_ = dec.mb_data_;
                dec.mb_data_ = tmp;
            } else {
                // perform reconstruction directly in main thread
                ReconstructRow(dec, ctx);
            }
            if (filter_row) { // swap filter info
                const tmp = ctx.f_info_;
                ctx.f_info_ = dec.f_info_;
                dec.f_info_ = tmp;
            }
            // (reconstruct)+filter in parallel
            webp.WebPGetWorkerInterface().*.Launch.?(worker);
            dec.cache_id_ += 1;
            if (dec.cache_id_ == dec.num_caches_) {
                dec.cache_id_ = 0;
            }
        }
    }
    return ok;
}

// ------------------------------------------------------------------------------
// Finish setting up the decoding parameter once user's setup() is called.

pub export fn VP8EnterCritical(dec: *webp.VP8Decoder, io: *webp.VP8Io) VP8Status {
    // Call setup() first. This may trigger additional decoding features on 'io'.
    // Note: Afterward, we must call teardown() no matter what.
    if (io.setup != null and io.setup.?(io) == 0) {
        _ = webp.VP8SetError(dec, .UserAbort, "Frame setup failed");
        return dec.status_;
    }

    // Disable filtering per user request
    if (io.bypass_filtering != 0) {
        dec.filter_type_ = 0;
    }

    // Define the area where we can skip in-loop filtering, in case of cropping.
    //
    // 'Simple' filter reads two luma samples outside of the macroblock
    // and filters one. It doesn't filter the chroma samples. Hence, we can
    // avoid doing the in-loop filtering before crop_top/crop_left position.
    // For the 'Complex' filter, 3 samples are read and up to 3 are filtered.
    // Means: there's a dependency chain that goes all the way up to the
    // top-left corner of the picture (MB #0). We must filter all the previous
    // macroblocks.
    {
        const extra_pixels: c_int = @intCast(kFilterExtraRows[@intCast(dec.filter_type_)]);
        if (dec.filter_type_ == 2) {
            // For complex filter, we need to preserve the dependency chain.
            dec.tl_mb_x_ = 0;
            dec.tl_mb_y_ = 0;
        } else {
            // For simple filter, we can filter only the cropped region.
            // We include 'extra_pixels' on the other side of the boundary, since
            // vertical or horizontal filtering of the previous macroblock can
            // modify some abutting pixels.
            dec.tl_mb_x_ = (io.crop_left - extra_pixels) >> 4;
            dec.tl_mb_y_ = (io.crop_top - extra_pixels) >> 4;
            if (dec.tl_mb_x_ < 0) dec.tl_mb_x_ = 0;
            if (dec.tl_mb_y_ < 0) dec.tl_mb_y_ = 0;
        }
        // We need some 'extra' pixels on the right/bottom.
        dec.br_mb_y_ = (io.crop_bottom + 15 + extra_pixels) >> 4;
        dec.br_mb_x_ = (io.crop_right + 15 + extra_pixels) >> 4;
        if (dec.br_mb_x_ > dec.mb_w_) {
            dec.br_mb_x_ = dec.mb_w_;
        }
        if (dec.br_mb_y_ > dec.mb_h_) {
            dec.br_mb_y_ = dec.mb_h_;
        }
    }
    PrecomputeFilterStrengths(dec);
    return .Ok;
}

pub export fn VP8ExitCritical(dec: *webp.VP8Decoder, io: *webp.VP8Io) c_int {
    var ok: c_int = 1;
    if (dec.mt_method_ > 0) {
        ok = webp.WebPGetWorkerInterface().*.Sync.?(&dec.worker_);
    }

    if (io.teardown != null) {
        io.teardown.?(io);
    }
    return ok;
}

//------------------------------------------------------------------------------
// For multi-threaded decoding we need to use 3 rows of 16 pixels as delay line.
//
// Reason is: the deblocking filter cannot deblock the bottom horizontal edges
// immediately, and needs to wait for first few rows of the next macroblock to
// be decoded. Hence, deblocking is lagging behind by 4 or 8 pixels (depending
// on strength).
// With two threads, the vertical positions of the rows being decoded are:
// Decode:  [ 0..15][16..31][32..47][48..63][64..79][...
// Deblock:         [ 0..11][12..27][28..43][44..59][...
// If we use two threads and two caches of 16 pixels, the sequence would be:
// Decode:  [ 0..15][16..31][ 0..15!!][16..31][ 0..15][...
// Deblock:         [ 0..11][12..27!!][-4..11][12..27][...
// The problem occurs during row [12..15!!] that both the decoding and
// deblocking threads are writing simultaneously.
// With 3 cache lines, one get a safe write pattern:
// Decode:  [ 0..15][16..31][32..47][ 0..15][16..31][32..47][0..
// Deblock:         [ 0..11][12..27][28..43][-4..11][12..27][28...
// Note that multi-threaded output _without_ deblocking can make use of two
// cache lines of 16 pixels only, since there's no lagging behind. The decoding
// and output process have non-concurrent writing:
// Decode:  [ 0..15][16..31][ 0..15][16..31][...
// io->put:         [ 0..15][16..31][ 0..15][...

const MT_CACHE_LINES = 3;
const ST_CACHE_LINES = 1; // 1 cache row only for single-threaded case

// Initialize multi/single-thread worker
fn InitThreadContext(dec: *webp.VP8Decoder) bool {
    dec.cache_id_ = 0;
    if (dec.mt_method_ > 0) {
        const worker: *webp.Worker = &dec.worker_;
        if (webp.WebPGetWorkerInterface().*.Reset.?(worker) == 0) {
            return webp.VP8SetError(dec, .OutOfMemory, "thread initialization failed.") != 0;
        }
        worker.data1 = dec;
        worker.data2 = &dec.thread_ctx_.io_;
        worker.hook = @ptrCast(&FinishRow);
        dec.num_caches_ = if (dec.filter_type_ > 0) MT_CACHE_LINES else MT_CACHE_LINES - 1;
    } else {
        dec.num_caches_ = ST_CACHE_LINES;
    }
    return true;
}

pub export fn VP8GetThreadMethod(options: ?*const webp.DecoderOptions, headers: ?*const webp.HeaderStructure, width: c_int, height: c_int) c_int {
    if (options == null or options.?.use_threads == 0) return 0;
    _ = height;
    assert(headers == null or headers.?.is_lossless == 0);
    if (comptime build_options.WEBP_USE_THREAD)
        if (width >= webp.MIN_WIDTH_FOR_THREADS) return 2;
    return 0;
}

//------------------------------------------------------------------------------
// Memory setup

fn AllocateMemory(dec: *webp.VP8Decoder) bool {
    const num_caches = dec.num_caches_;
    const mb_w = dec.mb_w_;
    // Note: we use 'size_t' when there's no overflow risk, uint64_t otherwise.
    const intra_pred_mode_size: usize = @abs(4 * mb_w) * @sizeOf(u8);
    const top_size: usize = @sizeOf(webp.VP8TopSamples) * @abs(mb_w);
    const mb_info_size: usize = @abs(mb_w + 1) * @sizeOf(webp.VP8MB);
    const f_info_size: usize = if (dec.filter_type_ > 0)
        @abs(mb_w) * (if (dec.mt_method_ > 0) @as(usize, 2) else 1) * @sizeOf(webp.VP8FInfo)
    else
        0;
    const yuv_size: usize = webp.YUV_SIZE * @sizeOf(u8);
    const mb_data_size: usize = (if (dec.mt_method_ == 2) @as(usize, 2) else 1) * @abs(mb_w) * @sizeOf(webp.VP8MBData);
    const cache_height: usize = (16 * @abs(num_caches) + kFilterExtraRows[@abs(dec.filter_type_)]) * 3 / 2;
    const cache_size: usize = top_size * cache_height;
    // alpha_size is the only one that scales as width x height.
    const alpha_size: u64 = if (dec.alpha_data_ != null) @as(u64, dec.pic_hdr_.width_) * dec.pic_hdr_.height_ else 0;
    const needed: u64 = intra_pred_mode_size + top_size + mb_info_size + f_info_size + yuv_size + mb_data_size + cache_size + alpha_size + webp.WEBP_ALIGN_CST;
    // uint8_t* mem;

    if (!webp.CheckSizeOverflow(needed)) return false; // check for overflow
    if (needed > dec.mem_size_) {
        webp.WebPSafeFree(dec.mem_);
        dec.mem_size_ = 0;
        dec.mem_ = webp.WebPSafeMalloc(needed, @sizeOf(u8));
        if (dec.mem_ == null) {
            return webp.VP8SetError(dec, .OutOfMemory, "no memory during frame initialization.") != 0;
        }
        // down-cast is ok, thanks to WebPSafeMalloc() above.
        dec.mem_size_ = @intCast(needed);
    }

    var mem: [*]u8 = @ptrCast(dec.mem_.?);
    dec.intra_t_ = mem;
    mem += intra_pred_mode_size;

    dec.yuv_t_ = @ptrCast(@alignCast(mem));
    mem += top_size;

    dec.mb_info_ = @as([*c]webp.VP8MB, @ptrCast(@alignCast(mem))) + 1;
    mem += mb_info_size;

    dec.f_info_ = if (f_info_size != 0) @ptrCast(@alignCast(mem)) else null;
    mem += f_info_size;
    dec.thread_ctx_.id_ = 0;
    dec.thread_ctx_.f_info_ = dec.f_info_;
    if (dec.filter_type_ > 0 and dec.mt_method_ > 0) {
        // secondary cache line. The deblocking process need to make use of the
        // filtering strength from previous macroblock row, while the new ones
        // are being decoded in parallel. We'll just swap the pointers.
        dec.thread_ctx_.f_info_ = webp.offsetPtr(dec.thread_ctx_.f_info_, mb_w);
    }

    mem = @ptrFromInt(webp.WEBP_ALIGN(mem));
    assert((yuv_size & webp.WEBP_ALIGN_CST) == 0);
    dec.yuv_b_ = mem;
    mem += yuv_size;

    dec.mb_data_ = @ptrCast(@alignCast(mem));
    dec.thread_ctx_.mb_data_ = @ptrCast(@alignCast(mem));
    if (dec.mt_method_ == 2) {
        dec.thread_ctx_.mb_data_ = webp.offsetPtr(dec.thread_ctx_.mb_data_, mb_w);
    }
    mem += mb_data_size;

    dec.cache_y_stride_ = 16 * mb_w;
    dec.cache_uv_stride_ = 8 * mb_w;
    {
        const extra_rows: c_int = @intCast(kFilterExtraRows[@abs(dec.filter_type_)]);
        const extra_y: c_int = extra_rows * dec.cache_y_stride_;
        const extra_uv: c_int = @divTrunc(extra_rows, 2) * dec.cache_uv_stride_;
        dec.cache_y_ = webp.offsetPtr(mem, extra_y);
        dec.cache_u_ = webp.offsetPtr(dec.cache_y_, 16 * num_caches * dec.cache_y_stride_ + extra_uv);
        dec.cache_v_ = webp.offsetPtr(dec.cache_u_, 8 * num_caches * dec.cache_uv_stride_ + extra_uv);
        dec.cache_id_ = 0;
    }
    mem += cache_size;

    // alpha plane
    dec.alpha_plane_ = if (alpha_size != 0) mem else null;
    mem += alpha_size;
    assert(@intFromPtr(mem) <= @intFromPtr(dec.mem_) + dec.mem_size_);

    // note: left/top-info is initialized once for all.
    @memset((dec.mb_info_ - 1)[0 .. mb_info_size / @sizeOf(webp.VP8MB)], std.mem.zeroes(webp.VP8MB));
    // _ = c.memset(@as(?*anyopaque, @ptrCast(dec.mb_info_ - 1)), 0, mb_info_size);
    webp.VP8InitScanline(dec); // initialize left too.

    // initialize top
    @memset(dec.intra_t_[0..intra_pred_mode_size], webp.B_DC_PRED);

    return true;
}

fn InitIo(dec: *webp.VP8Decoder, io: *webp.VP8Io) void {
    io.mb_y = 0;
    io.y = dec.cache_y_;
    io.u = dec.cache_u_;
    io.v = dec.cache_v_;
    io.y_stride = dec.cache_y_stride_;
    io.uv_stride = dec.cache_uv_stride_;
    io.a = null;
}

pub export fn VP8InitFrame(dec: *webp.VP8Decoder, io: *webp.VP8Io) c_int {
    if (!InitThreadContext(dec)) return 0; // call first. Sets dec->num_caches_.
    if (!AllocateMemory(dec)) return 0;
    InitIo(dec, io);
    webp.VP8DspInit(); // Init critical function pointers and look-up tables.
    return 1;
}

//------------------------------------------------------------------------------
