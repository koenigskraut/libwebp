const std = @import("std");
const build_options = @import("build_options");
const webp = struct {
    usingnamespace @import("cpu.zig");
    usingnamespace @import("../utils/utils.zig");
    usingnamespace @import("../webp/decode.zig");
};

const assert = std.debug.assert;
const c_bool = webp.c_bool;

const YUV_FIX = 16; // fixed-point precision for RGB->YUV
const YUV_HALF = 1 << (YUV_FIX - 1);

const YUV_FIX2 = 6; // fixed-point precision for YUV->RGB
const YUV_MASK2 = (256 << YUV_FIX2) - 1;

//------------------------------------------------------------------------------
// slower on x86 by ~7-8%, but bit-exact with the SSE2/NEON version

pub inline fn MultHi(v: c_int, coeff: c_int) c_int { // _mm_mulhi_epu16 emulation
    return (v * coeff) >> 8;
}

pub inline fn VP8Clip8(v: c_int) c_int {
    return if ((v & ~@as(c_int, YUV_MASK2)) == 0) (v >> YUV_FIX2) else if (v < 0) 0 else 255;
}

inline fn VP8YUVToR(y: c_int, v: c_int) c_int {
    return VP8Clip8(MultHi(y, 19077) + MultHi(v, 26149) - 14234);
}

inline fn VP8YUVToG(y: c_int, u: c_int, v: c_int) c_int {
    return VP8Clip8(MultHi(y, 19077) - MultHi(u, 6419) - MultHi(v, 13320) + 8708);
}

inline fn VP8YUVToB(y: c_int, u: c_int) c_int {
    return VP8Clip8(MultHi(y, 19077) + MultHi(u, 33050) - 17685);
}

pub inline fn VP8YuvToRgb(y: u8, u: u8, v: u8, rgb: [*c]u8) void {
    rgb[0] = @truncate(@as(c_uint, @bitCast(VP8YUVToR(y, v))));
    rgb[1] = @truncate(@as(c_uint, @bitCast(VP8YUVToG(y, u, v))));
    rgb[2] = @truncate(@as(c_uint, @bitCast(VP8YUVToB(y, u))));
}

pub inline fn VP8YuvToBgr(y: u8, u: u8, v: u8, bgr: [*c]u8) void {
    bgr[0] = @truncate(@as(c_uint, @bitCast(VP8YUVToB(y, u))));
    bgr[1] = @truncate(@as(c_uint, @bitCast(VP8YUVToG(y, u, v))));
    bgr[2] = @truncate(@as(c_uint, @bitCast(VP8YUVToR(y, v))));
}

pub inline fn VP8YuvToRgb565(y: u8, u: u8, v: u8, rgb: [*c]u8) void {
    const r = VP8YUVToR(y, v); // 5 usable bits
    const g = VP8YUVToG(y, u, v); // 6 usable bits
    const b = VP8YUVToB(y, u); // 5 usable bits
    const rg = (r & 0xf8) | (g >> 5);
    const gb = ((g << 3) & 0xe0) | (b >> 3);
    if (build_options.swap_16bit_csp) {
        rgb[0] = @truncate(@as(c_uint, @bitCast(gb)));
        rgb[1] = @truncate(@as(c_uint, @bitCast(rg)));
    } else {
        rgb[0] = @truncate(@as(c_uint, @bitCast(rg)));
        rgb[1] = @truncate(@as(c_uint, @bitCast(gb)));
    }
}

pub inline fn VP8YuvToRgba4444(y: u8, u: u8, v: u8, argb: [*c]u8) void {
    const r = VP8YUVToR(y, v); // 4 usable bits
    const g = VP8YUVToG(y, u, v); // 4 usable bits
    const b = VP8YUVToB(y, u); // 4 usable bits
    const rg = (r & 0xf0) | (g >> 4);
    const ba = (b & 0xf0) | 0x0f; // overwrite the lower 4 bits
    if (build_options.swap_16bit_csp) {
        argb[0] = @truncate(@as(c_uint, @bitCast(ba)));
        argb[1] = @truncate(@as(c_uint, @bitCast(rg)));
    } else {
        argb[0] = @truncate(@as(c_uint, @bitCast(rg)));
        argb[1] = @truncate(@as(c_uint, @bitCast(ba)));
    }
}

//-----------------------------------------------------------------------------
// Alpha handling variants

pub inline fn VP8YuvToArgb(y: u8, u: u8, v: u8, argb: [*c]u8) void {
    argb[0] = 0xff;
    VP8YuvToRgb(y, u, v, argb + 1);
}

pub inline fn VP8YuvToBgra(y: u8, u: u8, v: u8, bgra: [*c]u8) void {
    VP8YuvToBgr(y, u, v, bgra);
    bgra[3] = 0xff;
}

pub inline fn VP8YuvToRgba(y: u8, u: u8, v: u8, rgba: [*c]u8) void {
    VP8YuvToRgb(y, u, v, rgba);
    rgba[3] = 0xff;
}

//-----------------------------------------------------------------------------
// Plain-C version

const RowFuncHandler = fn (y: u8, u: u8, v: u8, rgb: [*c]u8) callconv(.Inline) void;
fn RowFunc(comptime func: RowFuncHandler, comptime xstep: comptime_int) WebPSamplerRowFuncBody {
    return struct {
        fn _(y_: [*c]const u8, u_: [*c]const u8, v_: [*c]const u8, dst_: [*c]u8, len: c_int) callconv(.C) void {
            var y, var u, var v, var dst = .{ y_, u_, v_, dst_ };
            const end = webp.offsetPtr(dst, (len & ~@as(c_int, 1)) * xstep);
            while (dst != end) {
                func(y[0], u[0], v[0], dst);
                func(y[1], u[0], v[0], dst + (xstep));
                y += 2;
                u += 1;
                v += 1;
                dst += 2 * (xstep);
            }
            if (len & 1 != 0) {
                func(y[0], u[0], v[0], dst);
            }
        }
    }._;
}

// All variants implemented.
const YuvToRgbRow = RowFunc(VP8YuvToRgb, 3);
const YuvToBgrRow = RowFunc(VP8YuvToBgr, 3);
const YuvToRgbaRow = RowFunc(VP8YuvToRgba, 4);
const YuvToBgraRow = RowFunc(VP8YuvToBgra, 4);
const YuvToArgbRow = RowFunc(VP8YuvToArgb, 4);
const YuvToRgba4444Row = RowFunc(VP8YuvToRgba4444, 2);
const YuvToRgb565Row = RowFunc(VP8YuvToRgb565, 2);
comptime {
    @export(YuvToRgbRow, .{ .name = "YuvToRgbRow" });
    @export(YuvToBgrRow, .{ .name = "YuvToBgrRow" });
    @export(YuvToRgbaRow, .{ .name = "YuvToRgbaRow" });
    @export(YuvToBgraRow, .{ .name = "YuvToBgraRow" });
    @export(YuvToArgbRow, .{ .name = "YuvToArgbRow" });
    @export(YuvToRgba4444Row, .{ .name = "YuvToRgba4444Row" });
    @export(YuvToRgb565Row, .{ .name = "YuvToRgb565Row" });
}

/// Main call for processing a plane with a WebPSamplerRowFunc function:
pub export fn WebPSamplerProcessPlane(
    y_: [*c]const u8,
    y_stride: c_int,
    u_: [*c]const u8,
    v_: [*c]const u8,
    uv_stride: c_int,
    dst_: [*c]u8,
    dst_stride: c_int,
    width: c_int,
    height: c_int,
    func: WebPSamplerRowFunc,
) void {
    var y, var u, var v, var dst = .{ y_, u_, v_, dst_ };
    for (0..@intCast(height)) |j| {
        func.?(y, u, v, dst, width);
        y = webp.offsetPtr(y, y_stride);
        if (j & 1 != 0) {
            u = webp.offsetPtr(u, uv_stride);
            v = webp.offsetPtr(v, uv_stride);
        }
        dst = webp.offsetPtr(dst, dst_stride);
    }
}

//-----------------------------------------------------------------------------
// Main call

const WebPSamplerRowFuncBody = fn (y: [*c]const u8, u: [*c]const u8, v: [*c]const u8, dst: [*c]u8, len: c_int) callconv(.C) void;
/// Per-row point-sampling methods.
pub const WebPSamplerRowFunc = ?*const WebPSamplerRowFuncBody;

/// Sampling functions to convert rows of YUV to RGB(A)
pub var WebPSamplers = [_]WebPSamplerRowFunc{null} ** @intFromEnum(webp.ColorspaceMode.LAST);
comptime {
    @export(WebPSamplers, .{ .name = "WebPSamplers" });
}

extern var VP8GetCPUInfo: webp.VP8CPUInfo;
extern fn WebPInitSamplersSSE2() callconv(.C) void;
extern fn WebPInitSamplersSSE41() callconv(.C) void;
extern fn WebPInitSamplersMIPS32() callconv(.C) void;
extern fn WebPInitSamplersMIPSdspR2() callconv(.C) void;

/// Must be called before using WebPSamplers[]
pub const WebPInitSamplers = webp.WEBP_DSP_INIT_FUNC(struct {
    fn _() void {
        WebPSamplers[@intFromEnum(webp.ColorspaceMode.RGB)] = &YuvToRgbRow;
        WebPSamplers[@intFromEnum(webp.ColorspaceMode.RGBA)] = &YuvToRgbaRow;
        WebPSamplers[@intFromEnum(webp.ColorspaceMode.BGR)] = &YuvToBgrRow;
        WebPSamplers[@intFromEnum(webp.ColorspaceMode.BGRA)] = &YuvToBgraRow;
        WebPSamplers[@intFromEnum(webp.ColorspaceMode.ARGB)] = &YuvToArgbRow;
        WebPSamplers[@intFromEnum(webp.ColorspaceMode.RGBA_4444)] = &YuvToRgba4444Row;
        WebPSamplers[@intFromEnum(webp.ColorspaceMode.RGB_565)] = &YuvToRgb565Row;
        WebPSamplers[@intFromEnum(webp.ColorspaceMode.rgbA)] = &YuvToRgbaRow;
        WebPSamplers[@intFromEnum(webp.ColorspaceMode.bgrA)] = &YuvToBgraRow;
        WebPSamplers[@intFromEnum(webp.ColorspaceMode.Argb)] = &YuvToArgbRow;
        WebPSamplers[@intFromEnum(webp.ColorspaceMode.rgbA_4444)] = &YuvToRgba4444Row;

        // If defined, use CPUInfo() to overwrite some pointers with faster versions.
        if (VP8GetCPUInfo) |getCpuInfo| {
            if (comptime webp.have_sse2) {
                // if (getCpuInfo(.kSSE2)) WebPInitSamplersSSE2();
            }
            if (comptime webp.have_sse41) {
                // if (getCpuInfo(.kSSE4_1))  WebPInitSamplersSSE41();
            }
            if (comptime webp.use_mips32) {
                if (getCpuInfo(.kMIPS32)) WebPInitSamplersMIPS32();
            }
            if (comptime webp.use_mips_dsp_r2) {
                if (getCpuInfo(.kMIPSdspR2)) WebPInitSamplersMIPSdspR2();
            }
        }
    }
}._);

fn WebPInitSamplers_C() callconv(.C) void {
    WebPInitSamplers();
}

comptime {
    @export(WebPInitSamplers_C, .{ .name = "WebPInitSamplers" });
}

//------------------------------------------------------------------------------
// RGB -> YUV conversion

// Stub functions that can be called with various rounding values:
inline fn VP8ClipUV(uv_: i32, rounding: i32) u8 {
    const uv = (uv_ + rounding + (128 << (YUV_FIX + 2))) >> (YUV_FIX + 2);
    return if ((uv & ~@as(c_int, 0xff)) == 0)
        @truncate(@as(u32, @bitCast(uv)))
    else if (uv < 0) 0 else 255;
}

pub inline fn VP8RGBToY(r: u32, g: u32, b: u32, rounding: u32) u8 {
    const luma = 16839 * r + 33059 * g + 6420 * b;
    return @truncate((luma + rounding + (16 << YUV_FIX)) >> YUV_FIX); // no need to clip
}

pub inline fn VP8RGBToU(r: i32, g: i32, b: i32, rounding: i32) u8 {
    const u = -9719 * r - 19081 * g + 28800 * b;
    return VP8ClipUV(u, rounding);
}

pub inline fn VP8RGBToV(r: i32, g: i32, b: i32, rounding: i32) u8 {
    const v = 28800 * r - 24116 * g - 4684 * b;
    return VP8ClipUV(v, rounding);
}

//-----------------------------------------------------------------------------
// ARGB -> YUV converters

fn ConvertARGBToY_C(argb: [*c]const u32, y: [*c]u8, width: c_int) callconv(.C) void {
    for (0..@intCast(width)) |i| {
        const p = argb[i];
        y[i] = VP8RGBToY((p >> 16) & 0xff, (p >> 8) & 0xff, (p >> 0) & 0xff, YUV_HALF);
    }
}

/// used for plain-C fallback.
pub export fn WebPConvertARGBToUV_C(argb: [*c]const u32, u: [*c]u8, v: [*c]u8, src_width: c_int, do_store: c_bool) callconv(.C) void {
    // No rounding. Last pixel is dealt with separately.
    const uv_width = src_width >> 1;
    var i: usize = 0;
    while (i < uv_width) : (i += 1) {
        const v0 = argb[2 * i + 0];
        const v1 = argb[2 * i + 1];
        // VP8RGBToU/V expects four accumulated pixels. Hence we need to
        // scale r/g/b value by a factor 2. We just shift v0/v1 one bit less.
        const r: i32 = @bitCast(((v0 >> 15) & 0x1fe) + ((v1 >> 15) & 0x1fe));
        const g: i32 = @bitCast(((v0 >> 7) & 0x1fe) + ((v1 >> 7) & 0x1fe));
        const b: i32 = @bitCast(((v0 << 1) & 0x1fe) + ((v1 << 1) & 0x1fe));
        const tmp_u = VP8RGBToU(r, g, b, YUV_HALF << 2);
        const tmp_v = VP8RGBToV(r, g, b, YUV_HALF << 2);
        if (do_store != 0) {
            u[i] = tmp_u;
            v[i] = tmp_v;
        } else {
            // Approximated average-of-four. But it's an acceptable diff.
            u[i] = @truncate((@as(u16, u[i]) + tmp_u + 1) >> 1);
            v[i] = @truncate((@as(u16, v[i]) + tmp_v + 1) >> 1);
        }
    }
    if (src_width & 1 != 0) { // last pixel
        const v0 = argb[2 * i + 0];
        const r: i32 = @bitCast((v0 >> 14) & 0x3fc);
        const g: i32 = @bitCast((v0 >> 6) & 0x3fc);
        const b: i32 = @bitCast((v0 << 2) & 0x3fc);
        const tmp_u = VP8RGBToU(r, g, b, YUV_HALF << 2);
        const tmp_v = VP8RGBToV(r, g, b, YUV_HALF << 2);
        if (do_store != 0) {
            u[i] = tmp_u;
            v[i] = tmp_v;
        } else {
            u[i] = @truncate((@as(u16, u[i]) + tmp_u + 1) >> 1);
            v[i] = @truncate((@as(u16, v[i]) + tmp_v + 1) >> 1);
        }
    }
}

//-----------------------------------------------------------------------------

fn ConvertRGB24ToY_C(rgb_: [*c]const u8, y: [*c]u8, width: c_int) callconv(.C) void {
    if (true) @panic("a");
    var rgb = rgb_;
    for (0..@intCast(width)) |i| {
        y[i] = VP8RGBToY(rgb[0], rgb[1], rgb[2], YUV_HALF);
        rgb += 3;
    }
}

fn ConvertBGR24ToY_C(bgr_: [*c]const u8, y: [*c]u8, width: c_int) callconv(.C) void {
    if (true) @panic("b");
    var bgr = bgr_;
    for (0..@intCast(width)) |i| {
        y[i] = VP8RGBToY(bgr[2], bgr[1], bgr[0], YUV_HALF);
        bgr += 3;
    }
}

/// used for plain-C fallback.
pub export fn WebPConvertRGBA32ToUV_C(rgb_: [*c]const u16, u: [*c]u8, v: [*c]u8, width: c_int) callconv(.C) void {
    if (true) @panic("c");
    var rgb = rgb_;
    for (0..@intCast(width)) |i| {
        const r: i32 = @bitCast(@as(u32, rgb[0]));
        const g: i32 = @bitCast(@as(u32, rgb[1]));
        const b: i32 = @bitCast(@as(u32, rgb[2]));
        u[i] = VP8RGBToU(r, g, b, YUV_HALF << 2);
        v[i] = VP8RGBToV(r, g, b, YUV_HALF << 2);
        rgb += 4;
    }
}

//-----------------------------------------------------------------------------

/// Convert RGB to Y
pub var WebPConvertRGB24ToY: ?*const fn (rgb: [*c]const u8, y: [*c]u8, width: c_int) callconv(.C) void = null;

/// Convert BGR to Y
pub var WebPConvertBGR24ToY: ?*const fn (bgr: [*c]const u8, y: [*c]u8, width: c_int) callconv(.C) void = null;

/// Convert a row of accumulated (four-values) of rgba32 toward U/V
pub var WebPConvertRGBA32ToUV: ?*const fn (rgb: [*c]const u16, u: [*c]u8, v: [*c]u8, width: c_int) callconv(.C) void = null;

/// Convert ARGB samples to luma Y.
pub var WebPConvertARGBToY: ?*const fn (argb: [*c]const u32, y: [*c]u8, width: c_int) callconv(.C) void = null;

/// Convert ARGB samples to U/V with downsampling. do_store should be '1' for
/// even lines and '0' for odd ones. 'src_width' is the original width, not
/// the U/V one.
pub var WebPConvertARGBToUV: ?*const fn (argb: [*c]const u32, u: [*c]u8, v: [*c]u8, src_width: c_int, do_store: c_bool) callconv(.C) void = null;

comptime {
    @export(WebPConvertRGB24ToY, .{ .name = "WebPConvertRGB24ToY" });
    @export(WebPConvertBGR24ToY, .{ .name = "WebPConvertBGR24ToY" });
    @export(WebPConvertRGBA32ToUV, .{ .name = "WebPConvertRGBA32ToUV" });

    @export(WebPConvertARGBToY, .{ .name = "WebPConvertARGBToY" });
    @export(WebPConvertARGBToUV, .{ .name = "WebPConvertARGBToUV" });
}

extern fn WebPInitConvertARGBToYUVSSE2() callconv(.C) void;
extern fn WebPInitConvertARGBToYUVSSE41() callconv(.C) void;
extern fn WebPInitConvertARGBToYUVNEON() callconv(.C) void;

// Must be called before using the above.
pub const WebPInitConvertARGBToYUV = webp.WEBP_DSP_INIT_FUNC(struct {
    fn _() void {
        WebPConvertARGBToY = &ConvertARGBToY_C;
        WebPConvertARGBToUV = &WebPConvertARGBToUV_C;

        WebPConvertRGB24ToY = &ConvertRGB24ToY_C;
        WebPConvertBGR24ToY = &ConvertBGR24ToY_C;

        WebPConvertRGBA32ToUV = &WebPConvertRGBA32ToUV_C;

        if (VP8GetCPUInfo) |getCpuInfo| {
            if (comptime webp.have_sse2) {
                if (getCpuInfo(.kSSE2) != 0) {
                    // WebPInitConvertARGBToYUVSSE2();
                }
            }
            if (comptime webp.have_sse41) {
                if (getCpuInfo(.kSSE4_1) != 0) {
                    // WebPInitConvertARGBToYUVSSE41();
                }
            }
        }

        if (comptime webp.have_neon) {
            if (webp.neon_omit_c_code or (if (VP8GetCPUInfo) |getCpuInfo| getCpuInfo(.kNEON) != 0 else false)) {
                WebPInitConvertARGBToYUVNEON();
            }
        }

        assert(WebPConvertARGBToY != null);
        assert(WebPConvertARGBToUV != null);
        assert(WebPConvertRGB24ToY != null);
        assert(WebPConvertBGR24ToY != null);
        assert(WebPConvertRGBA32ToUV != null);
    }
}._);

fn WebPInitConvertARGBToYUV_C() callconv(.C) void {
    WebPInitConvertARGBToYUV();
}

comptime {
    @export(WebPInitConvertARGBToYUV_C, .{ .name = "WebPInitConvertARGBToYUV" });
}
