const std = @import("std");
const webp = struct {
    usingnamespace @import("cpu.zig");
    usingnamespace @import("dec_clip_tables.zig");
    usingnamespace @import("../dec/common_dec.zig");
    usingnamespace @import("../utils/utils.zig");
};

const assert = std.debug.assert;
const c_bool = webp.c_bool;
const BPS = @import("dsp.zig").BPS;
const VP8WHT = ?*const fn ([*c]const i16, [*c]i16) callconv(.C) void;

// Dithering. Combines dithering values (centered around 128) with dst[],
// according to: dst[] = clip(dst[] + (((dither[]-128) + 8) >> 4)
pub const VP8_DITHER_DESCALE = 4;
pub const VP8_DITHER_DESCALE_ROUNDER = (1 << (VP8_DITHER_DESCALE - 1));
pub const VP8_DITHER_AMP_BITS = 7;
pub const VP8_DITHER_AMP_CENTER = (1 << VP8_DITHER_AMP_BITS);

/// *dst is the destination block, with stride BPS. Boundary samples are
/// assumed accessible when needed.
pub const VP8PredFunc = ?*const fn (dst: [*c]u8) callconv(.C) void;
pub const VP8DecIdct = ?*const fn ([*c]const i16, [*c]u8) callconv(.C) void;
// when doing two transforms, coeffs is actually int16_t[2][16].
pub const VP8DecIdct2 = ?*const fn ([*c]const i16, [*c]u8, c_int) callconv(.C) void;
pub var VP8Transform: VP8DecIdct2 = null;
pub var VP8TransformAC3: VP8DecIdct = null;
pub var VP8TransformUV: VP8DecIdct = null;
pub var VP8TransformDC: VP8DecIdct = null;
pub var VP8TransformDCUV: VP8DecIdct = null;
pub var VP8TransformWHT: VP8WHT = null;
comptime {
    @export(VP8Transform, .{ .name = "VP8Transform" });
    @export(VP8TransformAC3, .{ .name = "VP8TransformAC3" });
    @export(VP8TransformUV, .{ .name = "VP8TransformUV" });
    @export(VP8TransformDC, .{ .name = "VP8TransformDC" });
    @export(VP8TransformDCUV, .{ .name = "VP8TransformDCUV" });
    @export(VP8TransformWHT, .{ .name = "VP8TransformWHT" });
}

// simple filter (only for luma)
pub const VP8SimpleFilterFunc = ?*const fn ([*c]u8, c_int, c_int) callconv(.C) void;
pub var VP8SimpleVFilter16: VP8SimpleFilterFunc = null;
pub var VP8SimpleHFilter16: VP8SimpleFilterFunc = null;
pub var VP8SimpleVFilter16i: VP8SimpleFilterFunc = null; // filter 3 inner edges
pub var VP8SimpleHFilter16i: VP8SimpleFilterFunc = null;

// regular filter (on both macroblock edges and inner edges)
pub const VP8LumaFilterFunc = ?*const fn ([*c]u8, c_int, c_int, c_int, c_int) callconv(.C) void;
pub const VP8ChromaFilterFunc = ?*const fn ([*c]u8, [*c]u8, c_int, c_int, c_int, c_int) callconv(.C) void;

// on outer edge
pub var VP8VFilter16: VP8LumaFilterFunc = null;
pub var VP8HFilter16: VP8LumaFilterFunc = null;
pub var VP8VFilter8: VP8ChromaFilterFunc = null;
pub var VP8HFilter8: VP8ChromaFilterFunc = null;

// // on inner edge
pub var VP8VFilter16i: VP8LumaFilterFunc = null; // filtering 3 inner edges altogether
pub var VP8HFilter16i: VP8LumaFilterFunc = null;
pub var VP8VFilter8i: VP8ChromaFilterFunc = null; // filtering u and v altogether
pub var VP8HFilter8i: VP8ChromaFilterFunc = null;

comptime {
    @export(VP8VFilter16, .{ .name = "VP8VFilter16" });
    @export(VP8HFilter16, .{ .name = "VP8HFilter16" });
    @export(VP8VFilter8, .{ .name = "VP8VFilter8" });
    @export(VP8HFilter8, .{ .name = "VP8HFilter8" });
    @export(VP8VFilter16i, .{ .name = "VP8VFilter16i" });
    @export(VP8HFilter16i, .{ .name = "VP8HFilter16i" });
    @export(VP8VFilter8i, .{ .name = "VP8VFilter8i" });
    @export(VP8HFilter8i, .{ .name = "VP8HFilter8i" });
    @export(VP8SimpleVFilter16, .{ .name = "VP8SimpleVFilter16" });
    @export(VP8SimpleHFilter16, .{ .name = "VP8SimpleHFilter16" });
    @export(VP8SimpleVFilter16i, .{ .name = "VP8SimpleVFilter16i" });
    @export(VP8SimpleHFilter16i, .{ .name = "VP8SimpleHFilter16i" });
    @export(VP8DitherCombine8x8, .{ .name = "VP8DitherCombine8x8" });
}

pub var VP8DitherCombine8x8: ?*const fn ([*c]const u8, [*c]u8, c_int) callconv(.C) void = null;

inline fn clip_8b(v: i32) u8 {
    return if ((v & ~@as(i32, 0xff) == 0)) @truncate(@as(c_uint, @intCast(v))) else if (v < 0) 0 else 255;
}

//------------------------------------------------------------------------------
// Transforms (Paragraph 14.4)

inline fn STORE(dst: [*c]u8, x: u32, y: u32, v: i32) void {
    dst[x + y * BPS] = clip_8b(@as(i32, @intCast(dst[x + y * BPS])) + (v >> 3));
}

inline fn STORE2(dst: [*c]u8, y: u32, dc: i32, d: i32, c: i32) void {
    STORE(dst, 0, y, dc + (d));
    STORE(dst, 1, y, dc + (c));
    STORE(dst, 2, y, dc - (c));
    STORE(dst, 3, y, dc - (d));
}

inline fn MUL1(a: i32) i32 {
    return ((a * 20091) >> 16) + a;
}

inline fn MUL2(a: i32) i32 {
    return (a * 35468) >> 16;
}

fn TransformOne_C(in_: [*c]const i16, dst_: [*c]u8) void {
    var in, var dst = .{ in_, dst_ };
    var C: [4 * 4]i32 = undefined;
    var tmp: []i32 = &C;
    for (0..4) |_| { // vertical pass
        const a = @as(i32, in[0]) + @as(i32, in[8]); // [-4096, 4094]
        const b = @as(i32, in[0]) - @as(i32, in[8]); // [-4095, 4095]
        const c = MUL2(in[4]) - MUL1(in[12]); // [-3783, 3783]
        const d = MUL1(in[4]) + MUL2(in[12]); // [-3785, 3781]
        tmp[0] = a + d; // [-7881, 7875]
        tmp[1] = b + c; // [-7878, 7878]
        tmp[2] = b - c; // [-7878, 7878]
        tmp[3] = a - d; // [-7877, 7879]
        tmp = tmp[4..];
        in += 1;
    }
    // Each pass is expanding the dynamic range by ~3.85 (upper bound).
    // The exact value is (2. + (20091 + 35468) / 65536).
    // After the second pass, maximum interval is [-3794, 3794], assuming
    // an input in [-2048, 2047] interval. We then need to add a dst value
    // in the [0, 255] range.
    // In the worst case scenario, the input to clip_8b() can be as large as
    // [-60713, 60968].
    tmp = &C;
    for (0..4) |_| { // horizontal pass
        const dc = tmp[0] + 4;
        const a = dc + tmp[8];
        const b = dc - tmp[8];
        const c = MUL2(tmp[4]) - MUL1(tmp[12]);
        const d = MUL1(tmp[4]) + MUL2(tmp[12]);
        STORE(dst, 0, 0, a + d);
        STORE(dst, 1, 0, b + c);
        STORE(dst, 2, 0, b - c);
        STORE(dst, 3, 0, a - d);
        tmp = tmp[1..];
        dst += BPS;
    }
}

// Simplified transform when only in[0], in[1] and in[4] are non-zero
fn TransformAC3_C(in_: [*c]const i16, dst_: [*c]u8) callconv(.C) void {
    var in, var dst = .{ in_, dst_ };
    const a = @as(i32, in[0]) + 4;
    const c4 = MUL2(in[4]);
    const d4 = MUL1(in[4]);
    const c1 = MUL2(in[1]);
    const d1 = MUL1(in[1]);
    STORE2(dst, 0, a + d4, d1, c1);
    STORE2(dst, 1, a + c4, d1, c1);
    STORE2(dst, 2, a - c4, d1, c1);
    STORE2(dst, 3, a - d4, d1, c1);
}

fn TransformTwo_C(in: [*c]const i16, dst: [*c]u8, do_two: c_bool) callconv(.C) void {
    TransformOne_C(in, dst);
    if (do_two != 0) {
        TransformOne_C(in + 16, dst + 4);
    }
}

fn TransformUV_C(in: [*c]const i16, dst: [*c]u8) callconv(.C) void {
    VP8Transform.?(in + 0 * 16, dst, 1);
    VP8Transform.?(in + 2 * 16, dst + 4 * BPS, 1);
}

fn TransformDC_C(in: [*c]const i16, dst: [*c]u8) callconv(.C) void {
    const DC = @as(i32, in[0]) + 4;
    for (0..4) |j| {
        for (0..4) |i| {
            STORE(dst, @truncate(i), @truncate(j), DC);
        }
    }
}

fn TransformDCUV_C(in: [*c]const i16, dst: [*c]u8) callconv(.C) void {
    if (in[0 * 16] != 0) VP8TransformDC.?(in + 0 * 16, dst);
    if (in[1 * 16] != 0) VP8TransformDC.?(in + 1 * 16, dst + 4);
    if (in[2 * 16] != 0) VP8TransformDC.?(in + 2 * 16, dst + 4 * BPS);
    if (in[3 * 16] != 0) VP8TransformDC.?(in + 3 * 16, dst + 4 * BPS + 4);
}

//------------------------------------------------------------------------------
// Paragraph 14.3

fn TransformWHT_C(in: [*c]const i16, out_: [*c]i16) callconv(.C) void {
    var out = out_;
    var tmp: [16]i32 = undefined;
    for (0..4) |i| {
        const a0 = @as(i32, in[0 + i]) + in[12 + i];
        const a1 = @as(i32, in[4 + i]) + in[8 + i];
        const a2 = @as(i32, in[4 + i]) - in[8 + i];
        const a3 = @as(i32, in[0 + i]) - in[12 + i];
        tmp[0 + i] = a0 + a1;
        tmp[8 + i] = a0 - a1;
        tmp[4 + i] = a3 + a2;
        tmp[12 + i] = a3 - a2;
    }
    for (0..4) |i| {
        const dc = tmp[0 + i * 4] + 3; // w/ rounder
        const a0 = dc + tmp[3 + i * 4];
        const a1 = tmp[1 + i * 4] + tmp[2 + i * 4];
        const a2 = tmp[1 + i * 4] - tmp[2 + i * 4];
        const a3 = dc - tmp[3 + i * 4];
        out[0] = @truncate((a0 + a1) >> 3);
        out[16] = @truncate((a3 + a2) >> 3);
        out[32] = @truncate((a0 - a1) >> 3);
        out[48] = @truncate((a3 - a2) >> 3);
        out += 64;
    }
}

//------------------------------------------------------------------------------
// Intra predictions

inline fn DST(dst: [*c]u8, x: u8, y: u8) [*c]u8 {
    return dst + x + y * BPS;
}

inline fn TrueMotion(dst_: [*c]u8, size: u32) void {
    var dst = dst_;
    var top: [*c]const u8 = dst - BPS;
    const clip0: [*c]const u8 = webp.VP8kclip1 - (top - 1)[0];
    for (0..size) |_| { // y
        const clip: [*c]const u8 = clip0 + (dst - 1)[0];
        for (0..size) |x| {
            dst[x] = clip[top[x]];
        }
        dst += BPS;
    }
}
fn TM4_C(dst: [*c]u8) callconv(.C) void {
    TrueMotion(dst, 4);
}
fn TM8uv_C(dst: [*c]u8) callconv(.C) void {
    TrueMotion(dst, 8);
}
fn TM16_C(dst: [*c]u8) callconv(.C) void {
    TrueMotion(dst, 16);
}

//------------------------------------------------------------------------------
// 16x16

fn VE16_C(dst: [*c]u8) callconv(.C) void { // vertical
    for (0..16) |j| {
        @memcpy(dst[j * BPS ..][0..16], (dst - BPS)[0..16]);
    }
}

fn HE16_C(dst_: [*c]u8) callconv(.C) void { // horizontal
    var j: usize, var dst = .{ 16, dst_ };
    while (j > 0) : (j -= 1) {
        std.mem.copyForwards(u8, dst[0..16], (dst - 1)[0..16]);
        dst += BPS;
    }
}

inline fn Put16(v: u8, dst: [*c]u8) void {
    for (0..16) |j| {
        @memset(dst[j * BPS ..][0..16], v);
    }
}

fn DC16_C(dst: [*c]u8) callconv(.C) void { // DC
    var DC: u16 = 16;
    for (0..16) |j| {
        DC += @as(u16, (dst - 1 + j * BPS)[0]) + (dst + j - BPS)[0];
    }
    Put16(@truncate(DC >> 5), dst);
}

fn DC16NoTop_C(dst: [*c]u8) callconv(.C) void { // DC with top samples not available
    var DC: u16 = 8;
    for (0..16) |j| {
        DC += @as(u16, (dst - 1 + j * BPS)[0]);
    }
    Put16(@truncate(DC >> 4), dst);
}

fn DC16NoLeft_C(dst: [*c]u8) callconv(.C) void { // DC with left samples not available
    var DC: u16 = 8;
    for (0..16) |i| {
        DC += @as(u16, (dst + i - BPS)[0]);
    }
    Put16(@truncate(DC >> 4), dst);
}

fn DC16NoTopLeft_C(dst: [*c]u8) callconv(.C) void { // DC with no top and left samples
    Put16(0x80, dst);
}

pub var VP8PredLuma16: [webp.NUM_B_DC_MODES]VP8PredFunc = .{null} ** webp.NUM_B_DC_MODES;
comptime {
    @export(VP8PredLuma16, .{ .name = "VP8PredLuma16" });
}

//------------------------------------------------------------------------------
// 4x4

inline fn AVG3(a: u32, b: u32, c: u32) u32 {
    return (a +% 2 *% b +% c +% 2) >> 2;
}

inline fn AVG2(a: u32, b: u32) u32 {
    return (a +% b +% 1) >> 1;
}

fn VE4_C(dst: [*c]u8) callconv(.C) void { // vertical
    var top: [*c]const u8 = dst - BPS;
    const vals = [4]u8{
        @truncate(AVG3((top - 1)[0], top[0], top[1])),
        @truncate(AVG3(top[0], top[1], top[2])),
        @truncate(AVG3(top[1], top[2], top[3])),
        @truncate(AVG3(top[2], top[3], top[4])),
    };
    for (0..4) |i| {
        @memcpy(dst[i * BPS ..][0..4], &vals);
    }
}

fn HE4_C(dst: [*c]u8) callconv(.C) void { // horizontal
    const A: u32 = (dst - 1 - BPS)[0];
    const B: u32 = (dst - 1)[0];
    const C: u32 = (dst - 1 + BPS)[0];
    const D: u32 = (dst - 1 + 2 * BPS)[0];
    const E: u32 = (dst - 1 + 3 * BPS)[0];
    webp.WebPUint32ToMem(dst + 0 * BPS, 0x01010101 *% AVG3(A, B, C));
    webp.WebPUint32ToMem(dst + 1 * BPS, 0x01010101 *% AVG3(B, C, D));
    webp.WebPUint32ToMem(dst + 2 * BPS, 0x01010101 *% AVG3(C, D, E));
    webp.WebPUint32ToMem(dst + 3 * BPS, 0x01010101 *% AVG3(D, E, E));
}

fn DC4_C(dst: [*c]u8) callconv(.C) void { // DC
    var dc: u32 = 4;
    for (0..4) |i| dc += @as(u32, (dst + i - BPS)[0]) + (dst - 1 + i * BPS)[0];
    dc >>= 3;
    for (0..4) |i| @memset(dst[i * BPS ..][0..4], @truncate(dc));
}

fn RD4_C(dst: [*c]u8) callconv(.C) void { // Down-right
    const I = (dst - 1 + 0 * BPS)[0];
    const J = (dst - 1 + 1 * BPS)[0];
    const K = (dst - 1 + 2 * BPS)[0];
    const L = (dst - 1 + 3 * BPS)[0];
    const X = (dst - 1 - BPS)[0];
    const A = (dst + 0 - BPS)[0];
    const B = (dst + 1 - BPS)[0];
    const C = (dst + 2 - BPS)[0];
    const D = (dst + 3 - BPS)[0];
    DST(dst, 0, 3)[0] = @truncate(AVG3(J, K, L));
    {
        const tmp: u8 = @truncate(AVG3(I, J, K));
        DST(dst, 1, 3)[0], DST(dst, 0, 2)[0] = .{ tmp, tmp };
    }
    {
        const tmp: u8 = @truncate(AVG3(X, I, J));
        DST(dst, 2, 3)[0], DST(dst, 1, 2)[0], DST(dst, 0, 1)[0] = .{ tmp, tmp, tmp };
    }
    {
        const tmp: u8 = @truncate(AVG3(A, X, I));
        DST(dst, 3, 3)[0], DST(dst, 2, 2)[0], DST(dst, 1, 1)[0], DST(dst, 0, 0)[0] = .{ tmp, tmp, tmp, tmp };
    }
    {
        const tmp: u8 = @truncate(AVG3(B, A, X));
        DST(dst, 3, 2)[0], DST(dst, 2, 1)[0], DST(dst, 1, 0)[0] = .{ tmp, tmp, tmp };
    }
    {
        const tmp: u8 = @truncate(AVG3(C, B, A));
        DST(dst, 3, 1)[0], DST(dst, 2, 0)[0] = .{ tmp, tmp };
    }
    DST(dst, 3, 0)[0] = @truncate(AVG3(D, C, B));
}

fn LD4_C(dst: [*c]u8) callconv(.C) void { // Down-Left
    const A = (dst + 0 - BPS)[0];
    const B = (dst + 1 - BPS)[0];
    const C = (dst + 2 - BPS)[0];
    const D = (dst + 3 - BPS)[0];
    const E = (dst + 4 - BPS)[0];
    const F = (dst + 5 - BPS)[0];
    const G = (dst + 6 - BPS)[0];
    const H = (dst + 7 - BPS)[0];
    DST(dst, 0, 0)[0] = @truncate(AVG3(A, B, C));
    {
        const tmp: u8 = @truncate(AVG3(B, C, D));
        DST(dst, 1, 0)[0], DST(dst, 0, 1)[0] = .{ tmp, tmp };
    }
    {
        const tmp: u8 = @truncate(AVG3(C, D, E));
        DST(dst, 2, 0)[0], DST(dst, 1, 1)[0], DST(dst, 0, 2)[0] = .{ tmp, tmp, tmp };
    }
    {
        const tmp: u8 = @truncate(AVG3(D, E, F));
        DST(dst, 3, 0)[0], DST(dst, 2, 1)[0], DST(dst, 1, 2)[0], DST(dst, 0, 3)[0] = .{ tmp, tmp, tmp, tmp };
    }
    {
        const tmp: u8 = @truncate(AVG3(E, F, G));
        DST(dst, 3, 1)[0], DST(dst, 2, 2)[0], DST(dst, 1, 3)[0] = .{ tmp, tmp, tmp };
    }
    {
        const tmp: u8 = @truncate(AVG3(F, G, H));
        DST(dst, 3, 2)[0], DST(dst, 2, 3)[0] = .{ tmp, tmp };
    }
    DST(dst, 3, 3)[0] = @truncate(AVG3(G, H, H));
}

fn VR4_C(dst: [*c]u8) callconv(.C) void { // Vertical-Right
    const I = (dst - 1 + 0 * BPS)[0];
    const J = (dst - 1 + 1 * BPS)[0];
    const K = (dst - 1 + 2 * BPS)[0];
    const X = (dst - 1 - BPS)[0];
    const A = (dst + 0 - BPS)[0];
    const B = (dst + 1 - BPS)[0];
    const C = (dst + 2 - BPS)[0];
    const D = (dst + 3 - BPS)[0];
    {
        const tmp: u8 = @truncate(AVG2(X, A));
        DST(dst, 0, 0)[0], DST(dst, 1, 2)[0] = .{ tmp, tmp };
    }
    {
        const tmp: u8 = @truncate(AVG2(A, B));
        DST(dst, 1, 0)[0], DST(dst, 2, 2)[0] = .{ tmp, tmp };
    }
    {
        const tmp: u8 = @truncate(AVG2(B, C));
        DST(dst, 2, 0)[0], DST(dst, 3, 2)[0] = .{ tmp, tmp };
    }
    DST(dst, 3, 0)[0] = @truncate(AVG2(C, D));
    DST(dst, 0, 3)[0] = @truncate(AVG3(K, J, I));
    DST(dst, 0, 2)[0] = @truncate(AVG3(J, I, X));
    {
        const tmp: u8 = @truncate(AVG3(I, X, A));
        DST(dst, 0, 1)[0], DST(dst, 1, 3)[0] = .{ tmp, tmp };
    }
    {
        const tmp: u8 = @truncate(AVG3(X, A, B));
        DST(dst, 1, 1)[0], DST(dst, 2, 3)[0] = .{ tmp, tmp };
    }
    {
        const tmp: u8 = @truncate(AVG3(A, B, C));
        DST(dst, 2, 1)[0], DST(dst, 3, 3)[0] = .{ tmp, tmp };
    }
    DST(dst, 3, 1)[0] = @truncate(AVG3(B, C, D));
}

fn VL4_C(dst: [*c]u8) callconv(.C) void { // Vertical-Left
    const A = (dst + 0 - BPS)[0];
    const B = (dst + 1 - BPS)[0];
    const C = (dst + 2 - BPS)[0];
    const D = (dst + 3 - BPS)[0];
    const E = (dst + 4 - BPS)[0];
    const F = (dst + 5 - BPS)[0];
    const G = (dst + 6 - BPS)[0];
    const H = (dst + 7 - BPS)[0];
    DST(dst, 0, 0)[0] = @truncate(AVG2(A, B));
    {
        const tmp: u8 = @truncate(AVG2(B, C));
        DST(dst, 1, 0)[0], DST(dst, 0, 2)[0] = .{ tmp, tmp };
    }
    {
        const tmp: u8 = @truncate(AVG2(C, D));
        DST(dst, 2, 0)[0], DST(dst, 1, 2)[0] = .{ tmp, tmp };
    }
    {
        const tmp: u8 = @truncate(AVG2(D, E));
        DST(dst, 3, 0)[0], DST(dst, 2, 2)[0] = .{ tmp, tmp };
    }

    DST(dst, 0, 1)[0] = @truncate(AVG3(A, B, C));
    {
        const tmp: u8 = @truncate(AVG3(B, C, D));
        DST(dst, 1, 1)[0], DST(dst, 0, 3)[0] = .{ tmp, tmp };
    }
    {
        const tmp: u8 = @truncate(AVG3(C, D, E));
        DST(dst, 2, 1)[0], DST(dst, 1, 3)[0] = .{ tmp, tmp };
    }
    {
        const tmp: u8 = @truncate(AVG3(D, E, F));
        DST(dst, 3, 1)[0], DST(dst, 2, 3)[0] = .{ tmp, tmp };
    }
    DST(dst, 3, 2)[0] = @truncate(AVG3(E, F, G));
    DST(dst, 3, 3)[0] = @truncate(AVG3(F, G, H));
}

fn HU4_C(dst: [*c]u8) callconv(.C) void { // Horizontal-Up
    const I = (dst - 1 + 0 * BPS)[0];
    const J = (dst - 1 + 1 * BPS)[0];
    const K = (dst - 1 + 2 * BPS)[0];
    const L = (dst - 1 + 3 * BPS)[0];
    DST(dst, 0, 0)[0] = @truncate(AVG2(I, J));
    {
        const tmp: u8 = @truncate(AVG2(J, K));
        DST(dst, 2, 0)[0], DST(dst, 0, 1)[0] = .{ tmp, tmp };
    }
    {
        const tmp: u8 = @truncate(AVG2(K, L));
        DST(dst, 2, 1)[0], DST(dst, 0, 2)[0] = .{ tmp, tmp };
    }
    DST(dst, 1, 0)[0] = @truncate(AVG3(I, J, K));
    {
        const tmp: u8 = @truncate(AVG3(J, K, L));
        DST(dst, 3, 0)[0], DST(dst, 1, 1)[0] = .{ tmp, tmp };
    }
    {
        const tmp: u8 = @truncate(AVG3(K, L, L));
        DST(dst, 3, 1)[0], DST(dst, 1, 2)[0] = .{ tmp, tmp };
    }
    DST(dst, 3, 2)[0], DST(dst, 2, 2)[0], DST(dst, 0, 3)[0], DST(dst, 1, 3)[0], DST(dst, 2, 3)[0], DST(dst, 3, 3)[0] = .{ L, L, L, L, L, L };
}

fn HD4_C(dst: [*c]u8) callconv(.C) void { // Horizontal-Down
    const I = (dst - 1 + 0 * BPS)[0];
    const J = (dst - 1 + 1 * BPS)[0];
    const K = (dst - 1 + 2 * BPS)[0];
    const L = (dst - 1 + 3 * BPS)[0];
    const X = (dst - 1 - BPS)[0];
    const A = (dst + 0 - BPS)[0];
    const B = (dst + 1 - BPS)[0];
    const C = (dst + 2 - BPS)[0];

    {
        const tmp: u8 = @truncate(AVG2(I, X));
        DST(dst, 0, 0)[0], DST(dst, 2, 1)[0] = .{ tmp, tmp };
    }
    {
        const tmp: u8 = @truncate(AVG2(J, I));
        DST(dst, 0, 1)[0], DST(dst, 2, 2)[0] = .{ tmp, tmp };
    }
    {
        const tmp: u8 = @truncate(AVG2(K, J));
        DST(dst, 0, 2)[0], DST(dst, 2, 3)[0] = .{ tmp, tmp };
    }
    DST(dst, 0, 3)[0] = @truncate(AVG2(L, K));

    DST(dst, 3, 0)[0] = @truncate(AVG3(A, B, C));
    DST(dst, 2, 0)[0] = @truncate(AVG3(X, A, B));
    {
        const tmp: u8 = @truncate(AVG3(I, X, A));
        DST(dst, 1, 0)[0], DST(dst, 3, 1)[0] = .{ tmp, tmp };
    }
    {
        const tmp: u8 = @truncate(AVG3(J, I, X));
        DST(dst, 1, 1)[0], DST(dst, 3, 2)[0] = .{ tmp, tmp };
    }
    {
        const tmp: u8 = @truncate(AVG3(K, J, I));
        DST(dst, 1, 2)[0], DST(dst, 3, 3)[0] = .{ tmp, tmp };
    }
    DST(dst, 1, 3)[0] = @truncate(AVG3(L, K, J));
}

pub var VP8PredLuma4: [webp.NUM_BMODES]VP8PredFunc = .{null} ** webp.NUM_BMODES;
comptime {
    @export(VP8PredLuma4, .{ .name = "VP8PredLuma4" });
}

//------------------------------------------------------------------------------
// Chroma

fn VE8uv_C(dst: [*c]u8) callconv(.C) void { // vertical
    for (0..8) |j| {
        @memcpy(dst[j * BPS ..][0..8], (dst - BPS)[0..8]);
    }
}

fn HE8uv_C(dst_: [*c]u8) callconv(.C) void { // horizontal
    var dst = dst_;
    for (0..8) |j| {
        _ = j;

        @memset(dst[0..8], (dst - 1)[0]);
        dst += BPS;
    }
}

// helper for chroma-DC predictions
inline fn Put8x8uv(value: u8, dst: [*c]u8) void {
    for (0..8) |j| {
        @memset(dst[j * BPS ..][0..8], value);
    }
}

fn DC8uv_C(dst: [*c]u8) callconv(.C) void { // DC
    var dc0: u32 = 8;
    for (0..8) |i| {
        dc0 += @as(u32, (dst + i - BPS)[0]) + (dst - 1 + i * BPS)[0];
    }
    Put8x8uv(@truncate(dc0 >> 4), dst);
}

fn DC8uvNoLeft_C(dst: [*c]u8) callconv(.C) void { // DC with no left samples
    var dc0: u32 = 4;
    for (0..8) |i| {
        dc0 += (dst + i - BPS)[0];
    }
    Put8x8uv(@truncate(dc0 >> 3), dst);
}

fn DC8uvNoTop_C(dst: [*c]u8) callconv(.C) void { // DC with no top samples
    var dc0: u32 = 4;
    for (0..8) |i| {
        dc0 += (dst - 1 + i * BPS)[0];
    }
    Put8x8uv(@truncate(dc0 >> 3), dst);
}

fn DC8uvNoTopLeft_C(dst: [*c]u8) callconv(.C) void { // DC with nothing
    Put8x8uv(0x80, dst);
}

pub var VP8PredChroma8: [webp.NUM_B_DC_MODES]VP8PredFunc = .{null} ** webp.NUM_B_DC_MODES;
comptime {
    @export(VP8PredChroma8, .{ .name = "VP8PredChroma8" });
}

//------------------------------------------------------------------------------
// Edge filtering functions

// 4 pixels in, 2 pixels out
inline fn DoFilter2_C(p: [*c]u8, step: c_int) void {
    const p1: i16 = webp.offsetPtr(p, -2 * step)[0];
    const p0: i16 = webp.offsetPtr(p, -step)[0];
    const q0: i16 = webp.offsetPtr(p, 0)[0];
    const q1: i16 = webp.offsetPtr(p, step)[0];
    const a = 3 * (q0 - p0) + webp.offsetPtr(webp.VP8ksclip1, p1 - q1)[0]; // in [-893,892]
    const a1 = webp.offsetPtr(webp.VP8ksclip2, (a + 4) >> 3)[0]; // in [-16,15]
    const a2 = webp.offsetPtr(webp.VP8ksclip2, (a + 3) >> 3)[0];
    webp.offsetPtr(p, -step)[0] = webp.offsetPtr(webp.VP8kclip1, p0 + a2)[0];
    p[0] = webp.offsetPtr(webp.VP8kclip1, q0 - a1)[0];
}

// 4 pixels in, 4 pixels out
inline fn DoFilter4_C(p: [*c]u8, step: c_int) void {
    const p1: i16 = webp.offsetPtr(p, -2 * step)[0];
    const p0: i16 = webp.offsetPtr(p, -step)[0];
    const q0: i16 = webp.offsetPtr(p, 0)[0];
    const q1: i16 = webp.offsetPtr(p, step)[0];
    const a: i16 = 3 * (q0 - p0);
    const a1: i16 = webp.offsetPtr(webp.VP8ksclip2, (a + 4) >> 3)[0];
    const a2: i16 = webp.offsetPtr(webp.VP8ksclip2, (a + 3) >> 3)[0];
    const a3: i16 = (a1 + 1) >> 1;
    webp.offsetPtr(p, -2 * step)[0] = webp.offsetPtr(webp.VP8kclip1, p1 + a3)[0];
    webp.offsetPtr(p, -step)[0] = webp.offsetPtr(webp.VP8kclip1, p0 + a2)[0];
    webp.offsetPtr(p, 0)[0] = webp.offsetPtr(webp.VP8kclip1, q0 - a1)[0];
    webp.offsetPtr(p, step)[0] = webp.offsetPtr(webp.VP8kclip1, q1 - a3)[0];
}

// 6 pixels in, 6 pixels out
inline fn DoFilter6_C(p: [*c]u8, step: c_int) void {
    const p2: i16 = webp.offsetPtr(p, -3 * step)[0];
    const p1: i16 = webp.offsetPtr(p, -2 * step)[0];
    const p0: i16 = webp.offsetPtr(p, -step)[0];
    const q0: i16 = webp.offsetPtr(p, 0)[0];
    const q1: i16 = webp.offsetPtr(p, step)[0];
    const q2: i16 = webp.offsetPtr(p, 2 * step)[0];
    const a: i16 = webp.offsetPtr(webp.VP8ksclip1, 3 * (q0 - p0) + webp.offsetPtr(webp.VP8ksclip1, p1 - q1)[0])[0];
    // a is in [-128,127], a1 in [-27,27], a2 in [-18,18] and a3 in [-9,9]
    const a1 = (27 * a + 63) >> 7; // eq. to ((3 * a + 7) * 9) >> 7
    const a2 = (18 * a + 63) >> 7; // eq. to ((2 * a + 7) * 9) >> 7
    const a3 = (9 * a + 63) >> 7; // eq. to ((1 * a + 7) * 9) >> 7
    webp.offsetPtr(p, -3 * step)[0] = webp.offsetPtr(webp.VP8kclip1, p2 + a3)[0];
    webp.offsetPtr(p, -2 * step)[0] = webp.offsetPtr(webp.VP8kclip1, p1 + a2)[0];
    webp.offsetPtr(p, -step)[0] = webp.offsetPtr(webp.VP8kclip1, p0 + a1)[0];
    webp.offsetPtr(p, 0)[0] = webp.offsetPtr(webp.VP8kclip1, q0 - a1)[0];
    webp.offsetPtr(p, step)[0] = webp.offsetPtr(webp.VP8kclip1, q1 - a2)[0];
    webp.offsetPtr(p, 2 * step)[0] = webp.offsetPtr(webp.VP8kclip1, q2 - a3)[0];
}

inline fn Hev(p: [*c]const u8, step: c_int, thresh: c_int) bool {
    const p1: i16 = webp.offsetPtr(p, -2 * step)[0];
    const p0: i16 = webp.offsetPtr(p, -step)[0];
    const q0: i16 = webp.offsetPtr(p, 0)[0];
    const q1: i16 = webp.offsetPtr(p, step)[0];
    return (webp.offsetPtr(webp.VP8kabs0, p1 - p0)[0] > thresh) or (webp.offsetPtr(webp.VP8kabs0, q1 - q0)[0] > thresh);
}

inline fn NeedsFilter_C(p: [*c]const u8, step: c_int, t: c_int) bool {
    const p1: i16 = webp.offsetPtr(p, -2 * step)[0];
    const p0: i16 = webp.offsetPtr(p, -step)[0];
    const q0: i16 = p[0];
    const q1: i16 = webp.offsetPtr(p, step)[0];
    return (@as(u16, 4) * webp.offsetPtr(webp.VP8kabs0, p0 - q0)[0] + webp.offsetPtr(webp.VP8kabs0, p1 - q1)[0]) <= t;
}

inline fn NeedsFilter2_C(p: [*c]const u8, step: c_int, t: c_int, it: c_int) bool {
    const p3: i16 = webp.offsetPtr(p, -4 * step)[0];
    const p2: i16 = webp.offsetPtr(p, -3 * step)[0];
    const p1: i16 = webp.offsetPtr(p, -2 * step)[0];
    const p0: i16 = webp.offsetPtr(p, -step)[0];
    const q0: i16 = webp.offsetPtr(p, 0)[0];
    const q1: i16 = webp.offsetPtr(p, step)[0];
    const q2: i16 = webp.offsetPtr(p, 2 * step)[0];
    const q3: i16 = webp.offsetPtr(p, 3 * step)[0];
    if ((@as(u16, 4) * webp.offsetPtr(webp.VP8kabs0, p0 - q0)[0] + webp.offsetPtr(webp.VP8kabs0, p1 - q1)[0]) > t) return false;
    return webp.offsetPtr(webp.VP8kabs0, p3 - p2)[0] <= it and webp.offsetPtr(webp.VP8kabs0, p2 - p1)[0] <= it and
        webp.offsetPtr(webp.VP8kabs0, p1 - p0)[0] <= it and webp.offsetPtr(webp.VP8kabs0, q3 - q2)[0] <= it and
        webp.offsetPtr(webp.VP8kabs0, q2 - q1)[0] <= it and webp.offsetPtr(webp.VP8kabs0, q1 - q0)[0] <= it;
}

//------------------------------------------------------------------------------
// Simple In-loop filtering (Paragraph 15.2)

fn SimpleVFilter16_C(p: [*c]u8, stride: c_int, thresh: c_int) callconv(.C) void {
    const thresh2 = 2 * thresh + 1;
    for (0..16) |i| {
        if (NeedsFilter_C(p + i, stride, thresh2)) {
            DoFilter2_C(p + i, stride);
        }
    }
}

fn SimpleHFilter16_C(p: [*c]u8, stride: c_int, thresh: c_int) callconv(.C) void {
    const thresh2 = 2 * thresh + 1;
    for (0..16) |i| {
        if (NeedsFilter_C(webp.offsetPtr(p, @as(c_int, @intCast(i)) * stride), 1, thresh2)) {
            DoFilter2_C(webp.offsetPtr(p, @as(c_int, @intCast(i)) * stride), 1);
        }
    }
}

fn SimpleVFilter16i_C(p_: [*c]u8, stride: c_int, thresh: c_int) callconv(.C) void {
    var p, var k: u8 = .{ p_, 3 };
    while (k > 0) : (k -= 1) {
        p = webp.offsetPtr(p, 4 * stride);
        SimpleVFilter16_C(p, stride, thresh);
    }
}

fn SimpleHFilter16i_C(p_: [*c]u8, stride: c_int, thresh: c_int) callconv(.C) void {
    var p, var k: u8 = .{ p_, 3 };
    while (k > 0) : (k -= 1) {
        p = webp.offsetPtr(p, 4);
        SimpleHFilter16_C(p, stride, thresh);
    }
}

//------------------------------------------------------------------------------
// Complex In-loop filtering (Paragraph 15.3)

inline fn FilterLoop26_C(p_: [*c]u8, hstride: c_int, vstride: c_int, size_: c_int, thresh: c_int, ithresh: c_int, hev_thresh: c_int) void {
    const thresh2 = 2 * thresh + 1;
    var p, var size = .{ p_, size_ };
    while (size > 0) : (size -= 1) {
        if (NeedsFilter2_C(p, hstride, thresh2, ithresh)) {
            if (Hev(p, hstride, hev_thresh)) {
                DoFilter2_C(p, hstride);
            } else {
                DoFilter6_C(p, hstride);
            }
        }
        p = webp.offsetPtr(p, vstride);
    }
}

inline fn FilterLoop24_C(p_: [*c]u8, hstride: c_int, vstride: c_int, size_: c_int, thresh: c_int, ithresh: c_int, hev_thresh: c_int) void {
    const thresh2 = 2 * thresh + 1;
    var p, var size = .{ p_, size_ };
    while (size > 0) : (size -= 1) {
        if (NeedsFilter2_C(p, hstride, thresh2, ithresh)) {
            if (Hev(p, hstride, hev_thresh)) {
                DoFilter2_C(p, hstride);
            } else {
                DoFilter4_C(p, hstride);
            }
        }
        p = webp.offsetPtr(p, vstride);
    }
}

// on macroblock edges
fn VFilter16_C(p: [*c]u8, stride: c_int, thresh: c_int, ithresh: c_int, hev_thresh: c_int) callconv(.C) void {
    FilterLoop26_C(p, stride, 1, 16, thresh, ithresh, hev_thresh);
}

fn HFilter16_C(p: [*c]u8, stride: c_int, thresh: c_int, ithresh: c_int, hev_thresh: c_int) callconv(.C) void {
    FilterLoop26_C(p, 1, stride, 16, thresh, ithresh, hev_thresh);
}

// on three inner edges
fn VFilter16i_C(p_: [*c]u8, stride: c_int, thresh: c_int, ithresh: c_int, hev_thresh: c_int) callconv(.C) void {
    var p, var k: u8 = .{ p_, 3 };
    while (k > 0) : (k -= 1) {
        p = webp.offsetPtr(p, 4 * stride);
        FilterLoop24_C(p, stride, 1, 16, thresh, ithresh, hev_thresh);
    }
}
// #endif  // !WEBP_NEON_OMIT_C_CODE

fn HFilter16i_C(p_: [*c]u8, stride: c_int, thresh: c_int, ithresh: c_int, hev_thresh: c_int) callconv(.C) void {
    var p, var k: u8 = .{ p_, 3 };
    while (k > 0) : (k -= 1) {
        p += 4;
        FilterLoop24_C(p, 1, stride, 16, thresh, ithresh, hev_thresh);
    }
}

// 8-pixels wide variant, for chroma filtering
fn VFilter8_C(u: [*c]u8, v: [*c]u8, stride: c_int, thresh: c_int, ithresh: c_int, hev_thresh: c_int) callconv(.C) void {
    FilterLoop26_C(u, stride, 1, 8, thresh, ithresh, hev_thresh);
    FilterLoop26_C(v, stride, 1, 8, thresh, ithresh, hev_thresh);
}

fn HFilter8_C(u: [*c]u8, v: [*c]u8, stride: c_int, thresh: c_int, ithresh: c_int, hev_thresh: c_int) callconv(.C) void {
    FilterLoop26_C(u, 1, stride, 8, thresh, ithresh, hev_thresh);
    FilterLoop26_C(v, 1, stride, 8, thresh, ithresh, hev_thresh);
}

fn VFilter8i_C(u: [*c]u8, v: [*c]u8, stride: c_int, thresh: c_int, ithresh: c_int, hev_thresh: c_int) callconv(.C) void {
    FilterLoop24_C(webp.offsetPtr(u, 4 * stride), stride, 1, 8, thresh, ithresh, hev_thresh);
    FilterLoop24_C(webp.offsetPtr(v, 4 * stride), stride, 1, 8, thresh, ithresh, hev_thresh);
}

fn HFilter8i_C(u: [*c]u8, v: [*c]u8, stride: c_int, thresh: c_int, ithresh: c_int, hev_thresh: c_int) callconv(.C) void {
    FilterLoop24_C(u + 4, 1, stride, 8, thresh, ithresh, hev_thresh);
    FilterLoop24_C(v + 4, 1, stride, 8, thresh, ithresh, hev_thresh);
}

//------------------------------------------------------------------------------

fn DitherCombine8x8_C(dither_: [*c]const u8, dst_: [*c]u8, dst_stride: c_int) callconv(.C) void {
    var dither, var dst = .{ dither_, dst_ };
    for (0..8) |_| { // j
        for (0..8) |i| {
            const delta0 = @as(i32, @intCast(dither[i])) - VP8_DITHER_AMP_CENTER;
            const delta1 = (delta0 + VP8_DITHER_DESCALE_ROUNDER) >> VP8_DITHER_DESCALE;
            dst[i] = clip_8b(@as(i32, @intCast(dst[i])) + delta1);
        }
        dst = webp.offsetPtr(dst, dst_stride);
        dither += 8;
    }
}

//------------------------------------------------------------------------------

extern var VP8GetCPUInfo: webp.VP8CPUInfo;
extern fn VP8DspInitSSE2() void;
extern fn VP8DspInitSSE41() void;
extern fn VP8DspInitNEON() void;
extern fn VP8DspInitMIPS32() void;
extern fn VP8DspInitMIPSdspR2() void;
extern fn VP8DspInitMSA() void;

pub const VP8DspInit = webp.WEBP_DSP_INIT_FUNC(struct {
    pub fn _() void {
        webp.VP8InitClipTables();

        if (comptime !webp.neon_omit_c_code) {
            VP8TransformWHT = @ptrCast(&TransformWHT_C);
            VP8Transform = @ptrCast(&TransformTwo_C);
            VP8TransformDC = @ptrCast(&TransformDC_C);
            VP8TransformAC3 = @ptrCast(&TransformAC3_C);
        }
        VP8TransformUV = @ptrCast(&TransformUV_C);
        VP8TransformDCUV = @ptrCast(&TransformDCUV_C);

        if (comptime !webp.neon_omit_c_code) {
            VP8VFilter16 = @ptrCast(&VFilter16_C);
            VP8VFilter16i = @ptrCast(&VFilter16i_C);
            VP8HFilter16 = @ptrCast(&HFilter16_C);
            VP8VFilter8 = @ptrCast(&VFilter8_C);
            VP8VFilter8i = @ptrCast(&VFilter8i_C);
            VP8SimpleVFilter16 = @ptrCast(&SimpleVFilter16_C);
            VP8SimpleHFilter16 = @ptrCast(&SimpleHFilter16_C);
            VP8SimpleVFilter16i = @ptrCast(&SimpleVFilter16i_C);
            VP8SimpleHFilter16i = @ptrCast(&SimpleHFilter16i_C);
        }

        if (comptime !webp.neon_omit_c_code) {
            VP8HFilter16i = @ptrCast(&HFilter16i_C);
            VP8HFilter8 = @ptrCast(&HFilter8_C);
            VP8HFilter8i = @ptrCast(&HFilter8i_C);
        }

        if (comptime !webp.neon_omit_c_code) {
            VP8PredLuma4[0] = @ptrCast(&DC4_C);
            VP8PredLuma4[1] = @ptrCast(&TM4_C);
            VP8PredLuma4[2] = @ptrCast(&VE4_C);
            VP8PredLuma4[4] = @ptrCast(&RD4_C);
            VP8PredLuma4[6] = @ptrCast(&LD4_C);
        }

        VP8PredLuma4[3] = @ptrCast(&HE4_C);
        VP8PredLuma4[5] = @ptrCast(&VR4_C);
        VP8PredLuma4[7] = @ptrCast(&VL4_C);
        VP8PredLuma4[8] = @ptrCast(&HD4_C);
        VP8PredLuma4[9] = @ptrCast(&HU4_C);

        if (comptime !webp.neon_omit_c_code) {
            VP8PredLuma16[0] = @ptrCast(&DC16_C);
            VP8PredLuma16[1] = @ptrCast(&TM16_C);
            VP8PredLuma16[2] = @ptrCast(&VE16_C);
            VP8PredLuma16[3] = @ptrCast(&HE16_C);
            VP8PredLuma16[4] = @ptrCast(&DC16NoTop_C);
            VP8PredLuma16[5] = @ptrCast(&DC16NoLeft_C);
            VP8PredLuma16[6] = @ptrCast(&DC16NoTopLeft_C);

            VP8PredChroma8[0] = @ptrCast(&DC8uv_C);
            VP8PredChroma8[1] = @ptrCast(&TM8uv_C);
            VP8PredChroma8[2] = @ptrCast(&VE8uv_C);
            VP8PredChroma8[3] = @ptrCast(&HE8uv_C);
            VP8PredChroma8[4] = @ptrCast(&DC8uvNoTop_C);
            VP8PredChroma8[5] = @ptrCast(&DC8uvNoLeft_C);
            VP8PredChroma8[6] = @ptrCast(&DC8uvNoTopLeft_C);
        }

        VP8DitherCombine8x8 = @ptrCast(&DitherCombine8x8_C);

        // If defined, use CPUInfo() to overwrite some pointers with faster versions.
        if (VP8GetCPUInfo) |getCpuInfo| {
            if (comptime webp.have_sse2) {
                if (getCpuInfo(.kSSE2) != 0) {
                    // VP8DspInitSSE2();
                    if (comptime webp.have_sse41) {
                        // if (getCpuInfo(.kSSE4_1) != 0) VP8DspInitSSE41();
                    }
                }
            }
            if (comptime webp.use_mips32) {
                if (getCpuInfo(.kMIPS32) != 0) VP8DspInitMIPS32();
            }
            if (comptime webp.use_mips_dsp_r2) {
                if (getCpuInfo(.kMIPSdspR2) != 0) VP8DspInitMIPSdspR2();
            }
            if (comptime webp.use_msa) {
                if (getCpuInfo(.kMSA) != 0) VP8DspInitMSA();
            }
        }

        if (comptime webp.have_neon) {
            if (comptime (webp.neon_omit_c_code or (if (VP8GetCPUInfo) |getCpuInfo| getCpuInfo(.kNEON) != 0 else false))) {
                VP8DspInitNEON();
            }
        }

        assert(VP8TransformWHT != null);
        assert(VP8Transform != null);
        assert(VP8TransformDC != null);
        assert(VP8TransformAC3 != null);
        assert(VP8TransformUV != null);
        assert(VP8TransformDCUV != null);
        assert(VP8VFilter16 != null);
        assert(VP8HFilter16 != null);
        assert(VP8VFilter8 != null);
        assert(VP8HFilter8 != null);
        assert(VP8VFilter16i != null);
        assert(VP8HFilter16i != null);
        assert(VP8VFilter8i != null);
        assert(VP8HFilter8i != null);
        assert(VP8SimpleVFilter16 != null);
        assert(VP8SimpleHFilter16 != null);
        assert(VP8SimpleVFilter16i != null);
        assert(VP8SimpleHFilter16i != null);
        assert(VP8PredLuma4[0] != null);
        assert(VP8PredLuma4[1] != null);
        assert(VP8PredLuma4[2] != null);
        assert(VP8PredLuma4[3] != null);
        assert(VP8PredLuma4[4] != null);
        assert(VP8PredLuma4[5] != null);
        assert(VP8PredLuma4[6] != null);
        assert(VP8PredLuma4[7] != null);
        assert(VP8PredLuma4[8] != null);
        assert(VP8PredLuma4[9] != null);
        assert(VP8PredLuma16[0] != null);
        assert(VP8PredLuma16[1] != null);
        assert(VP8PredLuma16[2] != null);
        assert(VP8PredLuma16[3] != null);
        assert(VP8PredLuma16[4] != null);
        assert(VP8PredLuma16[5] != null);
        assert(VP8PredLuma16[6] != null);
        assert(VP8PredChroma8[0] != null);
        assert(VP8PredChroma8[1] != null);
        assert(VP8PredChroma8[2] != null);
        assert(VP8PredChroma8[3] != null);
        assert(VP8PredChroma8[4] != null);
        assert(VP8PredChroma8[5] != null);
        assert(VP8PredChroma8[6] != null);
        assert(VP8DitherCombine8x8 != null);
    }
}._);

fn VP8DspInit_C() callconv(.C) void {
    VP8DspInit();
}
comptime {
    @export(VP8DspInit_C, .{ .name = "VP8DspInit" });
}
