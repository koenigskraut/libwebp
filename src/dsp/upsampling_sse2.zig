const std = @import("std");
const build_options = @import("build_options");
const webp = struct {
    usingnamespace @import("intrinsics.zig");
    usingnamespace @import("upsampling.zig");
    usingnamespace @import("yuv.zig");
    usingnamespace @import("yuv_sse2.zig");
    usingnamespace @import("../webp/decode.zig");
};

const assert = std.debug.assert;
const CspMode = webp.ColorspaceMode;
const __m128i = webp.__m128i;

// We compute (9*a + 3*b + 3*c + d + 8) / 16 as follows
// u = (9*a + 3*b + 3*c + d + 8) / 16
//   = (a + (a + 3*b + 3*c + d) / 8 + 1) / 2
//   = (a + m + 1) / 2
// where m = (a + 3*b + 3*c + d) / 8
//         = ((a + b + c + d) / 2 + b + c) / 4
//
// Let's say  k = (a + b + c + d) / 4.
// We can compute k as
// k = (s + t + 1) / 2 - ((a^d) | (b^c) | (s^t)) & 1
// where s = (a + d + 1) / 2 and t = (b + c + 1) / 2
//
// Then m can be written as
// m = (k + t + 1) / 2 - (((b^c) & (s^t)) | (k^t)) & 1

// Computes out = (k + in + 1) / 2 - ((ij & (s^t)) | (k^in)) & 1
inline fn getM(k: __m128i, st: __m128i, one: __m128i, ij: __m128i, in: __m128i) __m128i {
    const tmp0 = webp._mm_avg_epu8(k, in); // (k + in + 1) / 2
    const tmp1 = webp._mm_and_si128(ij, st); // (ij) & (s^t)
    const tmp2 = webp._mm_xor_si128(k, in); // (k^in)
    const tmp3 = webp._mm_or_si128(tmp1, tmp2); // ((ij) & (s^t)) | (k^in)
    const tmp4 = webp._mm_and_si128(tmp3, one); // & 1 -> lsb_correction
    return webp._mm_sub_epi8(tmp0, tmp4); // (k + in + 1) / 2 - lsb_correction
}

// pack and store two alternating pixel rows
inline fn packAndStore(a: __m128i, b: __m128i, da: __m128i, db: __m128i, out: [*c]__m128i) void {
    const t_a = webp._mm_avg_epu8(a, da); // (9a + 3b + 3c +  d + 8) / 16
    const t_b = webp._mm_avg_epu8(b, db); // (3a + 9b +  c + 3d + 8) / 16
    const t_1 = webp._mm_unpacklo_epi8(t_a, t_b);
    const t_2 = webp._mm_unpackhi_epi8(t_a, t_b);
    webp._mm_store_si128(@ptrCast(out[0..]), t_1);
    webp._mm_store_si128(@ptrCast(out[1..]), t_2);
}

// Loads 17 pixels each from rows r1 and r2 and generates 32 pixels.
inline fn upsample32Pixels(r1: [*c]const u8, r2: [*c]const u8, out: [*c]u8) void {
    const one = webp._mm_set1_epi8(1);
    const a = webp._mm_loadu_si128(r1[0..]);
    const b = webp._mm_loadu_si128(r1[1..]);
    const c = webp._mm_loadu_si128(r2[0..]);
    const d = webp._mm_loadu_si128(r2[1..]);

    const s = webp._mm_avg_epu8(a, d); // s = (a + d + 1) / 2
    const t = webp._mm_avg_epu8(b, c); // t = (b + c + 1) / 2
    const st = webp._mm_xor_si128(s, t); // st = s^t

    const ad = webp._mm_xor_si128(a, d); // ad = a^d
    const bc = webp._mm_xor_si128(b, c); // bc = b^c

    const t1 = webp._mm_or_si128(ad, bc); // (a^d) | (b^c)
    const t2 = webp._mm_or_si128(t1, st); // (a^d) | (b^c) | (s^t)
    const t3 = webp._mm_and_si128(t2, one); // (a^d) | (b^c) | (s^t) & 1
    const t4 = webp._mm_avg_epu8(s, t);
    const k = webp._mm_sub_epi8(t4, t3); // k = (a + b + c + d) / 4

    const diag1 = getM(k, st, one, bc, t); // diag1 = (a + 3b + 3c + d) / 8
    const diag2 = getM(k, st, one, ad, s); // diag2 = (3a + b + c + 3d) / 8

    // pack the alternate pixels
    packAndStore(a, b, diag1, diag2, @ptrCast(@alignCast(out + 0))); // store top
    packAndStore(c, d, diag2, diag1, @ptrCast(@alignCast(out + 2 * 32))); // store bottom
}

// Turn the macro into a function for reducing code-size when non-critical
fn Upsample32Pixels_SSE2(r1: [*c]const u8, r2: [*c]const u8, out: [*c]u8) void {
    upsample32Pixels(r1, r2, out);
}

inline fn upsampleLastBlock(tb: [*c]const u8, bb: [*c]const u8, num_pixels: usize, out: [*c]u8) void {
    var r1: [17]u8 = undefined;
    var r2: [17]u8 = undefined;
    @memcpy(r1[0..num_pixels], tb[0..num_pixels]);
    @memcpy(r2[0..num_pixels], bb[0..num_pixels]);
    // replicate last byte
    @memset(r1[num_pixels..], r1[num_pixels - 1]);
    @memset(r2[num_pixels..], r2[num_pixels - 1]);
    // using the shared function instead of the macro saves ~3k code size
    Upsample32Pixels_SSE2(&r1, &r2, out);
}

const convert_handler = fn (y: [*c]const u8, u: [*c]const u8, v: [*c]const u8, dst: [*c]u8) callconv(.C) void;
fn convert2RGB32(
    comptime func_name: []const u8,
    comptime xstep: comptime_int,
    top_y: [*c]const u8,
    bottom_y: [*c]const u8,
    top_dst: [*c]u8,
    bottom_dst: [*c]u8,
    cur_x: usize,
    r_u: [*c]u8,
    r_v: [*c]u8,
) void {
    const func: convert_handler = @field(webp, func_name ++ "32_SSE2");
    func(top_y[cur_x..], r_u, r_v, top_dst[cur_x * xstep ..]);
    if (bottom_y != null)
        func(bottom_y[cur_x..], r_u + 64, r_v + 64, bottom_dst[cur_x * xstep ..]);
}

const upsample_handler = fn (y: u8, u: u8, v: u8, rgb: [*c]u8) callconv(.Inline) void;
fn Sse2UpsampleFunc(comptime func_name: []const u8, comptime xstep: comptime_int) webp.WebPUpsampleLinePairFuncBody {
    return struct {
        fn _(top_y: [*c]const u8, bottom_y: [*c]const u8, top_u: [*c]const u8, top_v: [*c]const u8, cur_u: [*c]const u8, cur_v: [*c]const u8, top_dst: [*c]u8, bottom_dst: [*c]u8, len: c_int) callconv(.C) void {
            // 16byte-aligned array to cache reconstructed u and v
            var uv_buf = [_]u8{0} ** (14 * 32 + 15);
            const r_u: [*c]u8 = @ptrFromInt(@intFromPtr(@as([*]u8, &uv_buf) + 15) & ~@as(usize, 15));
            const r_v: [*c]u8 = r_u + 32;
            const func: upsample_handler = @field(webp, func_name);

            assert(top_y != null);
            { // Treat the first pixel in regular way
                const u_diag = ((@as(u32, top_u[0]) + cur_u[0]) >> 1) + 1;
                const v_diag = ((@as(u32, top_v[0]) + cur_v[0]) >> 1) + 1;
                const _u0_t = (@as(u32, top_u[0]) + u_diag) >> 1;
                const _v0_t = (@as(u32, top_v[0]) + v_diag) >> 1;
                func(top_y[0], @truncate(_u0_t), @truncate(_v0_t), top_dst);
                if (bottom_y != null) {
                    const _u0_b = (@as(u32, cur_u[0]) + u_diag) >> 1;
                    const _v0_b = (@as(u32, cur_v[0]) + v_diag) >> 1;
                    func(bottom_y[0], @truncate(_u0_b), @truncate(_v0_b), bottom_dst);
                }
            }
            // For UPSAMPLE_32PIXELS, 17 u/v values must be read-able for each block
            var pos: usize = 1;
            var uv_pos: usize = 0;
            while (pos + 32 + 1 <= len) : ({
                pos += 32;
                uv_pos += 16;
            }) {
                upsample32Pixels(top_u + uv_pos, cur_u + uv_pos, r_u);
                upsample32Pixels(top_v + uv_pos, cur_v + uv_pos, r_v);
                convert2RGB32(func_name, xstep, top_y, bottom_y, top_dst, bottom_dst, pos, r_u, r_v);
            }

            if (len > 1) {
                const left_over = (@as(usize, @intCast(len + 1)) >> 1) -| (pos >> 1);
                const tmp_top_dst: [*c]u8 = r_u + 4 * 32;
                const tmp_bottom_dst: [*c]u8 = tmp_top_dst + 4 * 32;
                const tmp_top: [*c]u8 = tmp_bottom_dst + 4 * 32;
                const tmp_bottom: [*c]u8 = if (bottom_y == null) null else tmp_top + 32;
                assert(left_over > 0);
                upsampleLastBlock(top_u + uv_pos, cur_u + uv_pos, left_over, r_u);
                upsampleLastBlock(top_v + uv_pos, cur_v + uv_pos, left_over, r_v);
                const l = @as(usize, @intCast(len)) - pos;
                @memcpy(tmp_top[0..l], top_y[pos..][0..l]);
                if (bottom_y != null) @memcpy(tmp_bottom[0..l], bottom_y[pos..][0..l]);
                convert2RGB32(func_name, xstep, tmp_top, tmp_bottom, tmp_top_dst, tmp_bottom_dst, 0, r_u, r_v);
                @memcpy(top_dst[pos * xstep ..][0 .. l * xstep], tmp_top_dst[0 .. l * xstep]);
                if (bottom_y != null)
                    @memcpy(bottom_dst[pos * xstep ..][0 .. l * xstep], tmp_bottom_dst[0 .. l * xstep]);
            }
        }
    }._;
}

// SSE2 variants of the fancy upsampler.
const UpsampleRgbaLinePair_SSE2 = Sse2UpsampleFunc("VP8YuvToRgba", 4);
const UpsampleBgraLinePair_SSE2 = Sse2UpsampleFunc("VP8YuvToBgra", 4);

const UpsampleRgbLinePair_SSE2 = Sse2UpsampleFunc("VP8YuvToRgb", 3);
const UpsampleBgrLinePair_SSE2 = Sse2UpsampleFunc("VP8YuvToBgr", 3);
const UpsampleArgbLinePair_SSE2 = Sse2UpsampleFunc("VP8YuvToArgb", 4);
const UpsampleRgba4444LinePair_SSE2 = Sse2UpsampleFunc("VP8YuvToRgba4444", 2);
const UpsampleRgb565LinePair_SSE2 = Sse2UpsampleFunc("VP8YuvToRgb565", 2);

//------------------------------------------------------------------------------
// Entry point

pub fn WebPInitUpsamplersSSE2() void {
    webp.WebPUpsamplers[@intFromEnum(CspMode.RGBA)] = &UpsampleRgbaLinePair_SSE2;
    webp.WebPUpsamplers[@intFromEnum(CspMode.BGRA)] = &UpsampleBgraLinePair_SSE2;
    webp.WebPUpsamplers[@intFromEnum(CspMode.rgbA)] = &UpsampleRgbaLinePair_SSE2;
    webp.WebPUpsamplers[@intFromEnum(CspMode.bgrA)] = &UpsampleBgraLinePair_SSE2;
    if (comptime !build_options.reduce_csp) {
        webp.WebPUpsamplers[@intFromEnum(CspMode.RGB)] = &UpsampleRgbLinePair_SSE2;
        webp.WebPUpsamplers[@intFromEnum(CspMode.BGR)] = &UpsampleBgrLinePair_SSE2;
        webp.WebPUpsamplers[@intFromEnum(CspMode.ARGB)] = &UpsampleArgbLinePair_SSE2;
        webp.WebPUpsamplers[@intFromEnum(CspMode.Argb)] = &UpsampleArgbLinePair_SSE2;
        webp.WebPUpsamplers[@intFromEnum(CspMode.RGB_565)] = &UpsampleRgb565LinePair_SSE2;
        webp.WebPUpsamplers[@intFromEnum(CspMode.RGBA_4444)] = &UpsampleRgba4444LinePair_SSE2;
        webp.WebPUpsamplers[@intFromEnum(CspMode.rgbA_4444)] = &UpsampleRgba4444LinePair_SSE2;
    }
}

//------------------------------------------------------------------------------

const call_handler = fn (y: [*c]const u8, u: [*c]const u8, v: [*c]const u8, dst: [*c]u8) callconv(.C) void;
fn YUV444Func(comptime call: call_handler, comptime call_c: webp.WebPYUV444ConverterBody, comptime xstep: comptime_int) webp.WebPYUV444ConverterBody {
    return struct {
        pub fn _(y: [*c]const u8, u: [*c]const u8, v: [*c]const u8, dst: [*c]u8, len: c_int) callconv(.C) void {
            const max_len = len & ~@as(c_int, 31);
            var i: usize = 0;
            while (i < max_len) : (i += 32) {
                call(y[i..], u[i..], v[i..], dst[i * xstep ..]);
            }
            if (i < len) { // C-fallback
                call_c(y[i..], u[i..], v[i..], dst[i * xstep ..], len - @as(c_int, @intCast(i)));
            }
        }
    }._;
}

const Yuv444ToRgba_SSE2 = YUV444Func(webp.VP8YuvToRgba32_SSE2, webp.WebPYuv444ToRgba_C, 4);
const Yuv444ToBgra_SSE2 = YUV444Func(webp.VP8YuvToBgra32_SSE2, webp.WebPYuv444ToBgra_C, 4);
const Yuv444ToRgb_SSE2 = YUV444Func(webp.VP8YuvToRgb32_SSE2, webp.WebPYuv444ToRgb_C, 3);
const Yuv444ToBgr_SSE2 = YUV444Func(webp.VP8YuvToBgr32_SSE2, webp.WebPYuv444ToBgr_C, 3);
const Yuv444ToArgb_SSE2 = YUV444Func(webp.VP8YuvToArgb32_SSE2, webp.WebPYuv444ToArgb_C, 4);
const Yuv444ToRgba4444_SSE2 = YUV444Func(webp.VP8YuvToRgba444432_SSE2, webp.WebPYuv444ToRgba4444_C, 2);
const Yuv444ToRgb565_SSE2 = YUV444Func(webp.VP8YuvToRgb56532_SSE2, webp.WebPYuv444ToRgb565_C, 2);

pub fn WebPInitYUV444ConvertersSSE2() void {
    webp.WebPYUV444Converters[@intFromEnum(CspMode.RGBA)] = &Yuv444ToRgba_SSE2;
    webp.WebPYUV444Converters[@intFromEnum(CspMode.BGRA)] = &Yuv444ToBgra_SSE2;
    webp.WebPYUV444Converters[@intFromEnum(CspMode.rgbA)] = &Yuv444ToRgba_SSE2;
    webp.WebPYUV444Converters[@intFromEnum(CspMode.bgrA)] = &Yuv444ToBgra_SSE2;
    if (comptime !build_options.reduce_csp) {
        webp.WebPYUV444Converters[@intFromEnum(CspMode.RGB)] = &Yuv444ToRgb_SSE2;
        webp.WebPYUV444Converters[@intFromEnum(CspMode.BGR)] = &Yuv444ToBgr_SSE2;
        webp.WebPYUV444Converters[@intFromEnum(CspMode.ARGB)] = &Yuv444ToArgb_SSE2;
        webp.WebPYUV444Converters[@intFromEnum(CspMode.RGBA_4444)] = &Yuv444ToRgba4444_SSE2;
        webp.WebPYUV444Converters[@intFromEnum(CspMode.RGB_565)] = &Yuv444ToRgb565_SSE2;
        webp.WebPYUV444Converters[@intFromEnum(CspMode.Argb)] = &Yuv444ToArgb_SSE2;
        webp.WebPYUV444Converters[@intFromEnum(CspMode.rgbA_4444)] = &Yuv444ToRgba4444_SSE2;
    }
}
