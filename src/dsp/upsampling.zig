const std = @import("std");
const build_options = @import("build_options");
const webp = struct {
    usingnamespace @import("cpu.zig");
    usingnamespace @import("yuv.zig");
    usingnamespace @import("../webp/decode.zig");
};

const assert = std.debug.assert;
const CspMode = webp.ColorspaceMode;

//------------------------------------------------------------------------------
// Fancy upsampler

const WebPUpsampleLinePairFuncBody = fn (top_y: [*c]const u8, bottom_y: [*c]const u8, top_u: [*c]const u8, top_v: [*c]const u8, cur_u: [*c]const u8, cur_v: [*c]const u8, top_dst: [*c]u8, bottom_dst: [*c]u8, len: c_int) callconv(.C) void;
/// Convert a pair of y/u/v lines together to the output rgb/a colorspace.
/// bottom_y can be NULL if only one line of output is needed (at top/bottom).
pub const WebPUpsampleLinePairFunc = ?*const WebPUpsampleLinePairFuncBody;

// #ifdef FANCY_UPSAMPLING

/// Fancy upsampling functions to convert YUV to RGB(A) modes
pub var WebPUpsamplers = [_]WebPUpsampleLinePairFunc{null} ** @intFromEnum(CspMode.LAST);
comptime {
    @export(WebPUpsamplers, .{ .name = "WebPUpsamplers" });
}

// Given samples laid out in a square as:
//  [a b]
//  [c d]
// we interpolate u/v as:
//  ([9*a + 3*b + 3*c +   d    3*a + 9*b + 3*c +   d] + [8 8]) / 16
//  ([3*a +   b + 9*c + 3*d      a + 3*b + 3*c + 9*d]   [8 8]) / 16

/// We process u and v together stashed into 32bit (16bit each).
inline fn loadUV(u: u8, v: u8) u32 {
    return @as(u32, u) | (@as(u32, v) << 16);
}

const UpsampleFuncHandler = fn (y: u8, u: u8, v: u8, rgba: [*c]u8) callconv(.Inline) void;
fn UpsampleFunc(comptime func: UpsampleFuncHandler, comptime xstep: comptime_int) WebPUpsampleLinePairFuncBody {
    return struct {
        fn _(top_y: [*c]const u8, bottom_y: [*c]const u8, top_u: [*c]const u8, top_v: [*c]const u8, cur_u: [*c]const u8, cur_v: [*c]const u8, top_dst: [*c]u8, bottom_dst: [*c]u8, len: c_int) callconv(.C) void {
            // int x;
            const last_pixel_pair = (len - 1) >> 1;
            var tl_uv = loadUV(top_u[0], top_v[0]); // top-left sample
            var l_uv = loadUV(cur_u[0], cur_v[0]); // left-sample
            assert(top_y != null);
            {
                const uv0: u32 = (3 *% tl_uv +% l_uv +% 0x00020002) >> 2;
                func(top_y[0], @truncate(uv0 & 0xff), @truncate(uv0 >> 16), top_dst);
            }
            if (bottom_y != null) {
                const uv0: u32 = (3 *% l_uv +% tl_uv +% 0x00020002) >> 2;
                func(bottom_y[0], @truncate(uv0 & 0xff), @truncate(uv0 >> 16), bottom_dst);
            }
            for (1..@intCast(last_pixel_pair + 1)) |x| {
                const t_uv = loadUV(top_u[x], top_v[x]); //top sample
                const uv = loadUV(cur_u[x], cur_v[x]); //sample
                // precompute invariant values associated with first and second diagonals
                const avg = tl_uv +% t_uv +% l_uv +% uv +% 0x00080008;
                const diag_12 = (avg +% 2 *% (t_uv +% l_uv)) >> 3;
                const diag_03 = (avg +% 2 *% (tl_uv +% uv)) >> 3;
                {
                    const uv0 = (diag_12 +% tl_uv) >> 1;
                    const uv1 = (diag_03 +% t_uv) >> 1;
                    func(top_y[2 * x - 1], @truncate(uv0 & 0xff), @truncate(uv0 >> 16), top_dst + (2 * x - 1) * xstep);
                    func(top_y[2 * x - 0], @truncate(uv1 & 0xff), @truncate(uv1 >> 16), top_dst + (2 * x - 0) * xstep);
                }
                if (bottom_y != null) {
                    const uv0 = (diag_03 +% l_uv) >> 1;
                    const uv1 = (diag_12 +% uv) >> 1;
                    func(bottom_y[2 * x - 1], @truncate(uv0 & 0xff), @truncate(uv0 >> 16), bottom_dst + (2 * x - 1) * xstep);
                    func(bottom_y[2 * x + 0], @truncate(uv1 & 0xff), @truncate(uv1 >> 16), bottom_dst + (2 * x + 0) * xstep);
                }
                tl_uv = t_uv;
                l_uv = uv;
            }
            if (len & 1 == 0) {
                {
                    const uv0 = (3 *% tl_uv +% l_uv +% 0x00020002) >> 2;
                    func(top_y[@intCast(len - 1)], @truncate(uv0 & 0xff), @truncate(uv0 >> 16), top_dst + @as(usize, @intCast(len - 1)) * xstep);
                }
                if (bottom_y != null) {
                    const uv0 = (3 *% l_uv +% tl_uv +% 0x00020002) >> 2;
                    func(bottom_y[@intCast(len - 1)], @truncate(uv0 & 0xff), @truncate(uv0 >> 16), bottom_dst + @as(usize, @intCast(len - 1)) * xstep);
                }
            }
        }
    }._;
}

fn EmptyUpsampleFunc(top_y: [*c]const u8, bottom_y: [*c]const u8, top_u: [*c]const u8, top_v: [*c]const u8, cur_u: [*c]const u8, cur_v: [*c]const u8, top_dst: [*c]u8, bottom_dst: [*c]u8, len: c_int) callconv(.C) void {
    _ = top_y;
    _ = bottom_y;
    _ = top_u;
    _ = top_v;
    _ = cur_u;
    _ = cur_v;
    _ = top_dst;
    _ = bottom_dst;
    _ = len;
    assert(false); // COLORSPACE SUPPORT NOT COMPILED
}

const UpsampleRgbaLinePair_C = UpsampleFunc(webp.VP8YuvToRgba, 4);
const UpsampleBgraLinePair_C = UpsampleFunc(webp.VP8YuvToBgra, 4);
const UpsampleArgbLinePair_C: WebPUpsampleLinePairFuncBody = if (!build_options.reduce_csp) UpsampleFunc(webp.VP8YuvToArgb, 4) else EmptyUpsampleFunc;
const UpsampleRgbLinePair_C: WebPUpsampleLinePairFuncBody = if (!build_options.reduce_csp) UpsampleFunc(webp.VP8YuvToRgb, 3) else EmptyUpsampleFunc;
const UpsampleBgrLinePair_C: WebPUpsampleLinePairFuncBody = if (!build_options.reduce_csp) UpsampleFunc(webp.VP8YuvToBgr, 3) else EmptyUpsampleFunc;
const UpsampleRgba4444LinePair_C: WebPUpsampleLinePairFuncBody = if (!build_options.reduce_csp) UpsampleFunc(webp.VP8YuvToRgba4444, 2) else EmptyUpsampleFunc;
const UpsampleRgb565LinePair_C: WebPUpsampleLinePairFuncBody = if (!build_options.reduce_csp) UpsampleFunc(webp.VP8YuvToRgb565, 2) else EmptyUpsampleFunc;

//------------------------------------------------------------------------------

const DualSampleFuncHandler = fn (y: u8, u: u8, v: u8, bgra: [*c]u8) callconv(.Inline) void;
fn DualSampleFunc(comptime func: DualSampleFuncHandler) WebPUpsampleLinePairFuncBody {
    return struct {
        fn _(top_y: [*c]const u8, bot_y: [*c]const u8, top_u: [*c]const u8, top_v: [*c]const u8, bot_u: [*c]const u8, bot_v: [*c]const u8, top_dst: [*c]u8, bot_dst: [*c]u8, len: c_int) callconv(.C) void {
            const half_len = len >> 1;
            assert(top_dst != null);
            {
                var x: usize = 0;
                while (x < half_len) : (x += 1) {
                    func(top_y[2 * x + 0], top_u[x], top_v[x], top_dst + 8 * x + 0);
                    func(top_y[2 * x + 1], top_u[x], top_v[x], top_dst + 8 * x + 4);
                }
                if (len & 1 != 0) func(top_y[2 * x + 0], top_u[x], top_v[x], top_dst + 8 * x);
            }
            if (bot_dst != null) {
                var x: usize = 0;
                while (x < half_len) : (x += 1) {
                    func(bot_y[2 * x + 0], bot_u[x], bot_v[x], bot_dst + 8 * x + 0);
                    func(bot_y[2 * x + 1], bot_u[x], bot_v[x], bot_dst + 8 * x + 4);
                }
                if (len & 1 != 0) func(bot_y[2 * x + 0], bot_u[x], bot_v[x], bot_dst + 8 * x);
            }
        }
    }._;
}

const DualLineSamplerBGRA = DualSampleFunc(webp.VP8YuvToBgra);
const DualLineSamplerARGB = DualSampleFunc(webp.VP8YuvToArgb);

/// General function for converting two lines of ARGB or RGBA.
/// 'alpha_is_last' should be true if 0xff000000 is stored in memory as
/// as 0x00, 0x00, 0x00, 0xff (little endian).
pub export fn WebPGetLinePairConverter(alpha_is_last: c_int) WebPUpsampleLinePairFunc {
    WebPInitUpsamplers();
    if (comptime build_options.fancy_upsampling)
        return WebPUpsamplers[@intFromEnum(if (alpha_is_last != 0) CspMode.BGRA else CspMode.ARGB)]
    else
        return if (alpha_is_last != 0) &DualLineSamplerBGRA else &DualLineSamplerARGB;
}

//------------------------------------------------------------------------------
// YUV444 converter

const Yuv444FuncHandler = fn (y: u8, u: u8, v: u8, rgba: [*c]u8) callconv(.Inline) void;
fn Yuv444Func(comptime func: Yuv444FuncHandler, comptime xstep: comptime_int) WebPYUV444ConverterBody {
    return struct {
        fn _(y: [*c]const u8, u: [*c]const u8, v: [*c]const u8, dst: [*c]u8, len: c_int) callconv(.C) void {
            for (0..@intCast(len)) |i| func(y[i], u[i], v[i], &dst[i * xstep]);
        }
    }._;
}

fn EmptyYuv444Func(y: [*c]const u8, u: [*c]const u8, v: [*c]const u8, dst: [*c]u8, len: c_int) callconv(.C) void {
    _ = y;
    _ = u;
    _ = v;
    _ = dst;
    _ = len;
}

pub const WebPYuv444ToRgba_C = Yuv444Func(webp.VP8YuvToRgba, 4);
pub const WebPYuv444ToBgra_C = Yuv444Func(webp.VP8YuvToBgra, 4);
pub const WebPYuv444ToRgb_C: WebPYUV444ConverterBody = if (!build_options.reduce_csp) Yuv444Func(webp.VP8YuvToRgb, 3) else EmptyYuv444Func;
pub const WebPYuv444ToBgr_C: WebPYUV444ConverterBody = if (!build_options.reduce_csp) Yuv444Func(webp.VP8YuvToBgr, 3) else EmptyYuv444Func;
pub const WebPYuv444ToArgb_C: WebPYUV444ConverterBody = if (!build_options.reduce_csp) Yuv444Func(webp.VP8YuvToArgb, 4) else EmptyYuv444Func;
pub const WebPYuv444ToRgba4444_C: WebPYUV444ConverterBody = if (!build_options.reduce_csp) Yuv444Func(webp.VP8YuvToRgba4444, 2) else EmptyYuv444Func;
pub const WebPYuv444ToRgb565_C: WebPYUV444ConverterBody = if (!build_options.reduce_csp) Yuv444Func(webp.VP8YuvToRgb565, 2) else EmptyYuv444Func;
comptime {
    @export(WebPYuv444ToRgba_C, .{ .name = "WebPYuv444ToRgba_C" });
    @export(WebPYuv444ToBgra_C, .{ .name = "WebPYuv444ToBgra_C" });
    @export(WebPYuv444ToRgb_C, .{ .name = "WebPYuv444ToRgb_C" });
    @export(WebPYuv444ToBgr_C, .{ .name = "WebPYuv444ToBgr_C" });
    @export(WebPYuv444ToArgb_C, .{ .name = "WebPYuv444ToArgb_C" });
    @export(WebPYuv444ToRgba4444_C, .{ .name = "WebPYuv444ToRgba4444_C" });
    @export(WebPYuv444ToRgb565_C, .{ .name = "WebPYuv444ToRgb565_C" });
}

const WebPYUV444ConverterBody = fn (y: [*c]const u8, u: [*c]const u8, v: [*c]const u8, dst: [*c]u8, len: c_int) callconv(.C) void;
pub const WebPYUV444Converter = ?*const WebPYUV444ConverterBody;
/// YUV444->RGB converters
pub var WebPYUV444Converters = [_]WebPYUV444Converter{null} ** @intFromEnum(CspMode.LAST);
comptime {
    @export(WebPYUV444Converters, .{ .name = "WebPYUV444Converters" });
}

extern var VP8GetCPUInfo: webp.VP8CPUInfo;
extern fn WebPInitYUV444ConvertersMIPSdspR2() callconv(.C) void;
extern fn WebPInitYUV444ConvertersSSE2() callconv(.C) void;
extern fn WebPInitYUV444ConvertersSSE41() callconv(.C) void;

/// Must be called before using WebPYUV444Converters[]
pub const WebPInitYUV444Converters = webp.WEBP_DSP_INIT_FUNC(struct {
    fn _() void {
        WebPYUV444Converters[@intFromEnum(CspMode.RGBA)] = &WebPYuv444ToRgba_C;
        WebPYUV444Converters[@intFromEnum(CspMode.BGRA)] = &WebPYuv444ToBgra_C;
        WebPYUV444Converters[@intFromEnum(CspMode.RGB)] = &WebPYuv444ToRgb_C;
        WebPYUV444Converters[@intFromEnum(CspMode.BGR)] = &WebPYuv444ToBgr_C;
        WebPYUV444Converters[@intFromEnum(CspMode.ARGB)] = &WebPYuv444ToArgb_C;
        WebPYUV444Converters[@intFromEnum(CspMode.RGBA_4444)] = &WebPYuv444ToRgba4444_C;
        WebPYUV444Converters[@intFromEnum(CspMode.RGB_565)] = &WebPYuv444ToRgb565_C;
        WebPYUV444Converters[@intFromEnum(CspMode.rgbA)] = &WebPYuv444ToRgba_C;
        WebPYUV444Converters[@intFromEnum(CspMode.bgrA)] = &WebPYuv444ToBgra_C;
        WebPYUV444Converters[@intFromEnum(CspMode.Argb)] = &WebPYuv444ToArgb_C;
        WebPYUV444Converters[@intFromEnum(CspMode.rgbA_4444)] = &WebPYuv444ToRgba4444_C;

        if (VP8GetCPUInfo) |getCpuInfo| {
            if (comptime webp.have_sse2) {
                if (getCpuInfo(.kSSE2) != 0) WebPInitYUV444ConvertersSSE2();
            }
            if (comptime webp.have_sse41) {
                if (getCpuInfo(.kSSE4_1) != 0) WebPInitYUV444ConvertersSSE41();
            }
            if (comptime webp.use_mips_dsp_r2) {
                if (getCpuInfo(.kMIPSdspR2) != 0) WebPInitYUV444ConvertersMIPSdspR2();
            }
        }
    }
}._);

fn WebPInitYUV444Converters_C() callconv(.C) void {
    WebPInitYUV444Converters();
}
comptime {
    @export(WebPInitYUV444Converters_C, .{ .name = "WebPInitYUV444Converters" });
}

//------------------------------------------------------------------------------
// Main calls

extern fn WebPInitUpsamplersSSE2() callconv(.C) void;
extern fn WebPInitUpsamplersSSE41() callconv(.C) void;
extern fn WebPInitUpsamplersNEON() callconv(.C) void;
extern fn WebPInitUpsamplersMIPSdspR2() callconv(.C) void;
extern fn WebPInitUpsamplersMSA() callconv(.C) void;

/// Must be called before using the WebPUpsamplers[] (and for premultiplied
/// colorspaces like rgbA, rgbA4444, etc)
pub const WebPInitUpsamplers = webp.WEBP_DSP_INIT_FUNC(struct {
    fn _() void {
        if (comptime !build_options.fancy_upsampling) return;
        if (comptime !webp.neon_omit_c_code) {
            WebPUpsamplers[@intFromEnum(CspMode.RGBA)] = &UpsampleRgbaLinePair_C;
            WebPUpsamplers[@intFromEnum(CspMode.BGRA)] = &UpsampleBgraLinePair_C;
            WebPUpsamplers[@intFromEnum(CspMode.rgbA)] = &UpsampleRgbaLinePair_C;
            WebPUpsamplers[@intFromEnum(CspMode.bgrA)] = &UpsampleBgraLinePair_C;
            WebPUpsamplers[@intFromEnum(CspMode.RGB)] = &UpsampleRgbLinePair_C;
            WebPUpsamplers[@intFromEnum(CspMode.BGR)] = &UpsampleBgrLinePair_C;
            WebPUpsamplers[@intFromEnum(CspMode.ARGB)] = &UpsampleArgbLinePair_C;
            WebPUpsamplers[@intFromEnum(CspMode.RGBA_4444)] = &UpsampleRgba4444LinePair_C;
            WebPUpsamplers[@intFromEnum(CspMode.RGB_565)] = &UpsampleRgb565LinePair_C;
            WebPUpsamplers[@intFromEnum(CspMode.Argb)] = &UpsampleArgbLinePair_C;
            WebPUpsamplers[@intFromEnum(CspMode.rgbA_4444)] = &UpsampleRgba4444LinePair_C;
        }

        // If defined, use CPUInfo() to overwrite some pointers with faster versions.
        if (VP8GetCPUInfo) |getCpuInfo| {
            if (comptime webp.have_sse2) {
                if (getCpuInfo(.kSSE2) != 0) WebPInitUpsamplersSSE2();
            }
            if (comptime webp.have_sse41) {
                if (getCpuInfo(.kSSE4_1) != 0) WebPInitUpsamplersSSE41();
            }
            if (comptime webp.use_mips_dsp_r2) {
                if (getCpuInfo(.kMIPSdspR2) != 0) WebPInitUpsamplersMIPSdspR2();
            }
            if (comptime webp.use_msa) {
                if (getCpuInfo(.kMSA) != 0) WebPInitUpsamplersMSA();
            }
        }

        if (comptime webp.have_neon) {
            if (webp.neon_omit_c_code or (if (VP8GetCPUInfo) |getInfo| getInfo(.kNEON) != 0 else false))
                WebPInitUpsamplersNEON();
        }

        assert(WebPUpsamplers[@intFromEnum(CspMode.RGBA)] != null);
        assert(WebPUpsamplers[@intFromEnum(CspMode.BGRA)] != null);
        assert(WebPUpsamplers[@intFromEnum(CspMode.rgbA)] != null);
        assert(WebPUpsamplers[@intFromEnum(CspMode.bgrA)] != null);
        if (comptime !build_options.reduce_csp or !webp.neon_omit_c_code) {
            assert(WebPUpsamplers[@intFromEnum(CspMode.RGB)] != null);
            assert(WebPUpsamplers[@intFromEnum(CspMode.BGR)] != null);
            assert(WebPUpsamplers[@intFromEnum(CspMode.ARGB)] != null);
            assert(WebPUpsamplers[@intFromEnum(CspMode.RGBA_4444)] != null);
            assert(WebPUpsamplers[@intFromEnum(CspMode.RGB_565)] != null);
            assert(WebPUpsamplers[@intFromEnum(CspMode.Argb)] != null);
            assert(WebPUpsamplers[@intFromEnum(CspMode.rgbA_4444)] != null);
        }
    }
}._);

fn WebPInitUpsamplers_C() callconv(.C) void {
    WebPInitUpsamplers();
}
comptime {
    @export(WebPInitUpsamplers_C, .{ .name = "WebPInitUpsamplers" });
}

//------------------------------------------------------------------------------
