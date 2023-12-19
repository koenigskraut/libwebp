const std = @import("std");
const webp = struct {
    usingnamespace @import("intrinzic");
    usingnamespace @import("../utils/utils.zig");
};
const alpha_processing = @import("alpha_processing.zig");

const c_bool = webp.c_bool;
const __m128i = webp.__m128i;

//------------------------------------------------------------------------------

fn DispatchAlpha_SSE2(noalias alpha_: [*c]const u8, alpha_stride: c_int, width: c_int, height: c_int, noalias dst_: [*c]u8, dst_stride: c_int) callconv(.C) c_bool {
    var alpha, var dst = .{ alpha_, dst_ };

    // alpha_and stores an 'and' operation of all the alpha[] values. The final
    // value is not 0xff if any of the alpha[] is not equal to 0xff.
    var alpha_and: u32 = 0xff;

    const rgb_mask: @Vector(16, u8) = @bitCast(@as(@Vector(4, u32), @splat(0xFFFFFF00))); // to preserve RGB
    const all_0xff: @Vector(16, u8) = @bitCast(@Vector(4, u32){ ~@as(u32, 0), ~@as(u32, 0), 0, 0 });
    var all_alphas = all_0xff;

    // We must be able to access 3 extra bytes after the last written byte
    // 'dst[4 * width - 4]', because we don't know if alpha is the first or the
    // last byte of the quadruplet.
    const limit: usize = (@as(u32, @intCast(width)) -% 1) & ~@as(u32, 7);

    for (0..@intCast(height)) |_| { // j
        var i: usize = 0;
        var out = dst;
        while (i < limit) : (i += 8) {
            // load 8 alpha bytes
            const a0: @Vector(16, u8) = alpha[i..][0..8].* ++ .{0} ** 8;
            const a1: @Vector(16, u8) = std.simd.interlace(.{ @as([16]u8, a0)[0..8].*, [_]u8{0} ** 8 });
            const a2_lo: @Vector(16, u8) = @bitCast(std.simd.interlace(.{ @as([8]u16, @bitCast(a1))[0..4].*, [_]u16{0} ** 4 }));
            const a2_hi: @Vector(16, u8) = @bitCast(std.simd.interlace(.{ @as([8]u16, @bitCast(a1))[4..8].*, [_]u16{0} ** 4 }));
            // load 8 dst pixels (32 bytes)
            const b0_lo: @Vector(16, u8) = @bitCast(out[0..16].*);
            const b0_hi: @Vector(16, u8) = @bitCast(out[16..32].*);
            // mask dst alpha values
            const b1_lo = b0_lo & rgb_mask;
            const b1_hi = b0_hi & rgb_mask;
            // combine
            const b2_lo = b1_lo | a2_lo;
            const b2_hi = b1_hi | a2_hi;
            // store
            out[0..16].* = @bitCast(b2_lo);
            out[16..32].* = @bitCast(b2_hi);
            // accumulate eight alpha 'and' in parallel
            all_alphas &= a0;
            out += 32;
        }
        while (i < width) : (i += 1) {
            const alpha_value: u32 = alpha[i];
            dst[4 * i] = @truncate(alpha_value);
            alpha_and &= alpha_value;
        }
        alpha = webp.offsetPtr(alpha, alpha_stride);
        dst = webp.offsetPtr(dst, dst_stride);
    }
    // Combine the eight alpha 'and' into a 8-bit mask.
    //   alpha_and &= _mm_movemask_epi8(_mm_cmpeq_epi8(all_alphas, all_0xff));
    alpha_and &= @as(u16, @bitCast(all_alphas == all_0xff));
    return @intFromBool(alpha_and != 0xff);
}

fn DispatchAlphaToGreen_SSE2(noalias alpha_: [*c]const u8, alpha_stride: c_int, width: c_int, height: c_int, noalias dst_: [*c]u32, dst_stride: c_int) callconv(.C) void {
    var alpha, var dst = .{ alpha_, dst_ };
    const limit = @as(u32, @intCast(width)) & ~@as(u32, 15);
    for (0..@intCast(height)) |_| { // j
        var i: usize = 0;
        while (i < limit) : (i += 16) { // process 16 alpha bytes
            const a0: @Vector(16, u8) = @bitCast(alpha[i..][0..16].*);
            const a1: @Vector(16, u8) = std.simd.interlace(.{ [_]u8{0} ** 8, @as([16]u8, a0)[0..8].* }); // note the 'zero' first!
            const b1: @Vector(16, u8) = std.simd.interlace(.{ [_]u8{0} ** 8, @as([16]u8, a0)[8..16].* });
            const a2_lo: @Vector(16, u8) = @bitCast(std.simd.interlace(.{ @as([8]u16, @bitCast(a1))[0..4].*, [_]u16{0} ** 4 }));
            const b2_lo: @Vector(16, u8) = @bitCast(std.simd.interlace(.{ @as([8]u16, @bitCast(b1))[0..4].*, [_]u16{0} ** 4 }));
            const a2_hi: @Vector(16, u8) = @bitCast(std.simd.interlace(.{ @as([8]u16, @bitCast(a1))[4..8].*, [_]u16{0} ** 4 }));
            const b2_hi: @Vector(16, u8) = @bitCast(std.simd.interlace(.{ @as([8]u16, @bitCast(b1))[4..8].*, [_]u16{0} ** 4 }));
            dst[i + 0 ..][0..4].* = @bitCast(a2_lo);
            dst[i + 4 ..][0..4].* = @bitCast(a2_hi);
            dst[i + 8 ..][0..4].* = @bitCast(b2_lo);
            dst[i + 12 ..][0..4].* = @bitCast(b2_hi);
        }
        while (i < width) : (i += 1) dst[i] = @as(u32, alpha[i]) << 8;
        alpha = webp.offsetPtr(alpha, alpha_stride);
        dst = webp.offsetPtr(dst, dst_stride);
    }
}

fn ExtractAlpha_SSE2(noalias argb_: [*c]const u8, argb_stride: c_int, width: c_int, height: c_int, noalias alpha_: [*c]u8, alpha_stride: c_int) callconv(.C) c_bool {
    var argb, var alpha = .{ argb_, alpha_ };
    // alpha_and stores an 'and' operation of all the alpha[] values. The final
    // value is not 0xff if any of the alpha[] is not equal to 0xff.
    var alpha_and: u32 = 0xff;
    const all_0xff: @Vector(16, u8) = @bitCast(@Vector(2, u64){ ~@as(u64, 0), 0 });
    var all_alphas = all_0xff;

    // We must be able to access 3 extra bytes after the last written byte
    // 'src[4 * width - 4]', because we don't know if alpha is the first or the
    // last byte of the quadruplet.
    const limit = (@as(u32, @intCast(width)) - 1) & ~@as(u32, 7);

    for (0..@intCast(height)) |_| { // j
        // const __m128i* src = (const __m128i*)argb;
        var src = argb;
        var i: usize = 0;
        while (i < limit) : (i += 8) {
            // load 32 argb bytes
            const a0: @Vector(16, u8) = @bitCast(src[0..16].*);
            const a1: @Vector(16, u8) = @bitCast(src[16..32].*);
            const mask = @Vector(8, i32){ 0, 4, 8, 12, ~@as(i32, 0), ~@as(i32, 4), ~@as(i32, 8), ~@as(i32, 12) };
            const c0 = @shuffle(u8, a0, a1, mask);
            const d0 = std.simd.join(c0, c0);
            // store
            alpha[i..][0..16].* = @bitCast(d0);
            // accumulate eight alpha 'and' in parallel
            all_alphas &= d0;
            src += 32;
        }
        while (i < width) : (i += 1) {
            const alpha_value: u32 = argb[4 * i];
            alpha[i] = @truncate(alpha_value);
            alpha_and &= alpha_value;
        }
        argb = webp.offsetPtr(argb, argb_stride);
        alpha = webp.offsetPtr(alpha, alpha_stride);
    }
    // Combine the eight alpha 'and' into a 8-bit mask.
    alpha_and &= @as(u16, @bitCast(all_alphas == all_0xff));
    return @intFromBool(alpha_and == 0xff);
}

fn ExtractGreen_SSE2(noalias argb: [*c]const u32, noalias alpha: [*c]u8, size: c_int) callconv(.C) void {
    const mask = @Vector(8, i32){ 0, 4, 8, 12, ~@as(i32, 0), ~@as(i32, 4), ~@as(i32, 8), ~@as(i32, 12) };
    var src = argb;

    var i: usize = 0;
    while (i + 16 <= size) : ({
        i += 16;
        src += 4 * 4;
    }) {
        const a0: @Vector(4, u32) = @bitCast(src[0 * 4 ..][0..4].*);
        const a1: @Vector(4, u32) = @bitCast(src[1 * 4 ..][0..4].*);
        const a2: @Vector(4, u32) = @bitCast(src[2 * 4 ..][0..4].*);
        const a3: @Vector(4, u32) = @bitCast(src[3 * 4 ..][0..4].*);
        const b0: @Vector(16, u8) = @bitCast(a0 >> @splat(8));
        const b1: @Vector(16, u8) = @bitCast(a1 >> @splat(8));
        const b2: @Vector(16, u8) = @bitCast(a2 >> @splat(8));
        const b3: @Vector(16, u8) = @bitCast(a3 >> @splat(8));
        const c0 = @shuffle(u8, b0, b1, mask);
        const c1 = @shuffle(u8, b2, b3, mask);
        const d = std.simd.join(c0, c1);
        // store
        alpha[i..][0..16].* = @bitCast(d);
    }
    if (i + 8 <= size) {
        const a0: @Vector(4, u32) = @bitCast(src[0 * 4 ..][0..4].*);
        const a1: @Vector(4, u32) = @bitCast(src[1 * 4 ..][0..4].*);
        const b0: @Vector(16, u8) = @bitCast(a0 >> @splat(8));
        const b1: @Vector(16, u8) = @bitCast(a1 >> @splat(8));
        const c0 = @shuffle(u8, b0, b1, mask);
        const d = std.simd.join(c0, c0);
        alpha[i..][0..16].* = @bitCast(d);
        i += 8;
    }
    while (i < size) : (i += 1) alpha[i] = @truncate(argb[i] >> 8);
}

//------------------------------------------------------------------------------
// Non-dither premultiplied modes

inline fn MULTIPLIER(a: u32) u32 {
    return a *% 0x8081;
}

inline fn PREMULTIPLY(x: u32, m: u32) u32 {
    return (x *% m) >> 23;
}

inline fn wideCast(v: @Vector(4, u16)) @Vector(4, u32) {
    const widening_mask = @Vector(8, i32){ 0, -1, 1, -1, 2, -1, 3, -1 };
    return @bitCast(@shuffle(u16, v, @Vector(1, u16){0}, widening_mask));
}

inline fn hi16(v: @Vector(4, u32)) @Vector(4, u16) {
    const hi_mask = @Vector(4, i32){ 1, 3, 5, 7 };
    return @shuffle(u16, @as(@Vector(8, u16), @bitCast(v)), undefined, hi_mask);
}

inline fn lo16(v: @Vector(4, u32)) @Vector(4, u16) {
    const lo_mask = @Vector(4, i32){ 0, 2, 4, 6 };
    return @shuffle(u16, @as(@Vector(8, u16), @bitCast(v)), undefined, lo_mask);
}

inline fn loMul(a: @Vector(8, u16), b: @Vector(8, u16)) @Vector(8, u16) {
    return a *% b;
}

inline fn hiMul(a: @Vector(8, u16), b: @Vector(8, u16)) @Vector(8, u16) {
    const c0 = wideCast(@as([8]u16, a)[0..4].*) * wideCast(@as([8]u16, b)[0..4].*);
    const c1 = wideCast(@as([8]u16, a)[4..8].*) * wideCast(@as([8]u16, b)[4..8].*);
    return std.simd.join(hi16(c0), hi16(c1));
}

inline fn hi8(v: @Vector(8, u16)) @Vector(8, u8) {
    const hi_mask = @Vector(8, i32){ 1, 3, 5, 7, 9, 11, 13, 15 };
    return @shuffle(u8, @as(@Vector(16, u8), @bitCast(v)), undefined, hi_mask);
}

inline fn lo8(v: @Vector(8, u16)) @Vector(8, u8) {
    const lo_mask = @Vector(8, i32){ 0, 2, 4, 6, 8, 10, 12, 14 };
    return @shuffle(u8, @as(@Vector(16, u8), @bitCast(v)), undefined, lo_mask);
}

// We can't use a 'const int' for the SHUFFLE value, because it has to be an
// immediate in the _mm_shufflexx_epi16() instruction. We really need a macro.
// We use: v / 255 = (v * 0x8081) >> 23, where v = alpha * {r,g,b} is a 16bit
// value.
inline fn APPLY_ALPHA(rgbx: [*c]u32, comptime shuffle: [4]u8) void {
    const kMult: @Vector(8, u16) = @splat(0x8081);
    const kMask: @Vector(16, u8) = @bitCast(@Vector(8, u16){ 0, 0xff, 0xff, 0, 0, 0xff, 0xff, 0 });
    const argb0: __m128i = @bitCast(rgbx[0..4].*);
    const argb1_lo = webp._mm_unpacklo_epi8(argb0, .{ 0, 0 });
    const argb1_hi = webp._mm_unpackhi_epi8(argb0, .{ 0, 0 });
    const alpha0_lo = webp._mm_or_si128(argb1_lo, @bitCast(kMask));
    const alpha0_hi = webp._mm_or_si128(argb1_hi, @bitCast(kMask));
    const alpha1_lo = webp._mm_shufflelo_epi16(alpha0_lo, webp._mm_shuffle(shuffle));
    const alpha1_hi = webp._mm_shufflelo_epi16(alpha0_hi, webp._mm_shuffle(shuffle));
    const alpha2_lo = webp._mm_shufflehi_epi16(alpha1_lo, webp._mm_shuffle(shuffle));
    const alpha2_hi = webp._mm_shufflehi_epi16(alpha1_hi, webp._mm_shuffle(shuffle));
    // alpha2 = [ff a0 a0 a0][ff a1 a1 a1]
    const A0_lo = webp._mm_mullo_epi16(alpha2_lo, argb1_lo);
    const A0_hi = webp._mm_mullo_epi16(alpha2_hi, argb1_hi);
    const A1_lo = webp._mm_mulhi_epu16(A0_lo, @bitCast(kMult));
    const A1_hi = webp._mm_mulhi_epu16(A0_hi, @bitCast(kMult));
    const A2_lo = @as(@Vector(8, u16), @bitCast(A1_lo)) >> @splat(7);
    const A2_hi = @as(@Vector(8, u16), @bitCast(A1_hi)) >> @splat(7);
    const A3 = webp._mm_packus_epi16(@bitCast(A2_lo), @bitCast(A2_hi));
    rgbx[0..4].* = @bitCast(A3);
}

fn ApplyAlphaMultiply_SSE2(rgba_: [*c]u8, alpha_first: c_bool, w: c_int, h_: c_int, stride: c_int) callconv(.C) void {
    var rgba, var h = .{ rgba_, h_ };
    const kSpan = 4;
    while (h > 0) : (h -= 1) {
        const rgbx: [*c]u32 = @ptrCast(@alignCast(rgba));
        var i: usize = 0;
        if (!(alpha_first != 0)) {
            while (i + kSpan <= w) : (i += kSpan) {
                APPLY_ALPHA(rgbx[i..], .{ 2, 3, 3, 3 }); // mask reversed
            }
        } else {
            while (i + kSpan <= w) : (i += kSpan) {
                APPLY_ALPHA(rgbx[i..], .{ 0, 0, 0, 1 }); // mask reversed
            }
        }
        // Finish with left-overs.
        while (i < w) : (i += 1) {
            const rgb: [*c]u8 = rgba + (if (alpha_first != 0) @as(usize, 1) else 0);
            const alpha: [*c]const u8 = rgba + (if (alpha_first != 0) @as(usize, 0) else 3);
            const a: u32 = alpha[4 * i];
            if (a != 0xff) {
                const mult: u32 = MULTIPLIER(a);
                rgb[4 * i + 0] = @truncate(PREMULTIPLY(rgb[4 * i + 0], mult));
                rgb[4 * i + 1] = @truncate(PREMULTIPLY(rgb[4 * i + 1], mult));
                rgb[4 * i + 2] = @truncate(PREMULTIPLY(rgb[4 * i + 2], mult));
            }
        }
        rgba = webp.offsetPtr(rgba, stride);
    }
}

//------------------------------------------------------------------------------
// Alpha detection

fn HasAlpha8b_SSE2(src: [*c]const u8, length: c_int) callconv(.C) c_bool {
    const all_0xff: @Vector(16, u8) = @splat(0xff);
    var i: usize = 0;
    while (i + 16 <= length) : (i += 16) {
        const v: @Vector(16, u8) = @bitCast(src[i..][0..16].*);
        if (@reduce(.And, v != all_0xff)) return 1;
    }
    while (i < length) : (i += 1) if (src[i] != 0xff) return 1;
    return 0;
}

fn HasAlpha32b_SSE2(src: [*c]const u8, length_: c_int) callconv(.C) c_bool {
    const alpha_mask: @Vector(4, u32) = @splat(0xff);
    const all_0xff: @Vector(16, u8) = @splat(0xff);
    var i: usize = 0;
    // We don't know if we can access the last 3 bytes after the last alpha
    // value 'src[4 * length - 4]' (because we don't know if alpha is the first
    // or the last byte of the quadruplet). Hence the '-3' protection below.
    const length = length_ * 4 - 3; // size in bytes
    while (i + 64 <= length) : (i += 64) {
        const a0: @Vector(4, u32) = @bitCast(src[i + 0 ..][0..16].*);
        const a1: @Vector(4, u32) = @bitCast(src[i + 16 ..][0..16].*);
        const a2: @Vector(4, u32) = @bitCast(src[i + 32 ..][0..16].*);
        const a3: @Vector(4, u32) = @bitCast(src[i + 48 ..][0..16].*);
        const b0 = a0 & alpha_mask;
        const b1 = a1 & alpha_mask;
        const b2 = a2 & alpha_mask;
        const b3 = a3 & alpha_mask;
        const c0: @Vector(8, u16) = std.simd.join(lo16(b0), lo16(b1));
        const c1: @Vector(8, u16) = std.simd.join(lo16(b2), lo16(b3));
        const d: @Vector(16, u8) = std.simd.join(lo8(c0), lo8(c1));
        if (@reduce(.And, d != all_0xff)) return 1;
    }
    while (i + 32 <= length) : (i += 32) {
        const a0: @Vector(4, u32) = @bitCast(src[i + 0 ..][0..16].*);
        const a1: @Vector(4, u32) = @bitCast(src[i + 16 ..][0..16].*);
        const b0 = a0 & alpha_mask;
        const b1 = a1 & alpha_mask;
        const c0 = std.simd.join(lo16(b0), lo16(b1));
        const d = std.simd.join(lo8(c0), lo8(c0));
        if (@reduce(.And, d != all_0xff)) return 1;
    }
    while (i <= length) : (i += 4) if (src[i] != 0xff) return 1;
    return 0;
}

fn AlphaReplace_SSE2(src: [*c]u32, length: c_int, color: u32) callconv(.C) void {
    const m_color: @Vector(4, u32) = @splat(color);
    const zero: @Vector(128, u1) = @splat(0);
    var i: usize = 0;
    while (i + 8 <= length) : (i += 8) {
        const a0: @Vector(4, u32) = src[i + 0 ..][0..4].*;
        const a1: @Vector(4, u32) = src[i + 4 ..][0..4].*;
        const b0 = a0 >> @splat(24);
        const b1 = a1 >> @splat(24);
        const c0: @Vector(4, u32) = @bitCast(@as(@Vector(128, u1), @bitCast(b0)) == zero);
        const c1: @Vector(4, u32) = @bitCast(@as(@Vector(128, u1), @bitCast(b1)) == zero);
        const d0 = c0 & m_color;
        const d1 = c1 & m_color;
        const e0 = c0 & ~a0;
        const e1 = c1 & ~a1;
        src[i + 0 ..][0..4].* = d0 | e0;
        src[i + 4 ..][0..4].* = d1 | e1;
    }
    while (i < length) : (i += 1) {
        if ((src[i] >> 24) == 0) src[i] = color;
    }
}

// -----------------------------------------------------------------------------
// Apply alpha value to row

const WebPMultARGBRow_C = alpha_processing.WebPMultARGBRow_C;
const WebPMultRow_C = alpha_processing.WebPMultRow_C;

fn MultARGBRow_SSE2(ptr: [*c]u32, width_: c_int, inverse: c_bool) callconv(.C) void {
    var width: usize = @intCast(width_);
    var x: usize = 0;
    if (!(inverse != 0)) {
        const kSpan = 2;
        const zero = webp._mm_setzero_si128();
        const k128 = webp._mm_set1_epi16(128);
        const kMult = webp._mm_set1_epi16(0x0101);
        const kMask = webp._mm_set_epi16(0, 0xff, 0, 0, 0, 0xff, 0, 0);
        while (x + kSpan <= width) : (x += kSpan) {
            // To compute 'result = (int)(a * x / 255. + .5)', we use:
            //   tmp = a * v + 128, result = (tmp * 0x0101u) >> 16
            const A0 = webp._mm_loadl_epi64(@ptrCast(@alignCast(ptr[x..])));
            const A1 = webp._mm_unpacklo_epi8(A0, zero);
            const A2 = webp._mm_or_si128(A1, kMask);
            const A3 = webp._mm_shufflelo_epi16(A2, webp._mm_shuffle(.{ 2, 3, 3, 3 }));
            const A4 = webp._mm_shufflehi_epi16(A3, webp._mm_shuffle(.{ 2, 3, 3, 3 }));
            // here, A4 = [ff a0 a0 a0][ff a1 a1 a1]
            const A5 = webp._mm_mullo_epi16(A4, A1);
            const A6 = webp._mm_add_epi16(A5, k128);
            const A7 = webp._mm_mulhi_epu16(A6, kMult);
            const A10 = webp._mm_packus_epi16(A7, zero);
            webp._mm_storel_epi64(@ptrCast(@alignCast(ptr[x..])), A10);
        }
    }
    width -|= x;
    if (width > 0) WebPMultARGBRow_C(ptr[x..], @intCast(width), inverse);
}

fn MultRow_SSE2(noalias ptr: [*c]u8, noalias alpha: [*c]const u8, width_: c_int, inverse: c_bool) callconv(.C) void {
    var width: usize = @intCast(width_);
    var x: usize = 0;
    if (!(inverse != 0)) {
        const zero = webp._mm_setzero_si128();
        const k128 = webp._mm_set1_epi16(128);
        const kMult = webp._mm_set1_epi16(0x0101);
        while (x + 8 <= width) : (x += 8) {
            const v0 = webp._mm_loadl_epi64(@ptrCast(@alignCast(ptr[x..])));
            const a0 = webp._mm_loadl_epi64(@ptrCast(@alignCast(alpha[x..])));
            const v1 = webp._mm_unpacklo_epi8(v0, zero);
            const a1 = webp._mm_unpacklo_epi8(a0, zero);
            const v2 = webp._mm_mullo_epi16(v1, a1);
            const v3 = webp._mm_add_epi16(v2, k128);
            const v4 = webp._mm_mulhi_epu16(v3, kMult);
            const v5 = webp._mm_packus_epi16(v4, zero);
            webp._mm_storel_epi64(@ptrCast(@alignCast(ptr[x..])), v5);
        }
    }
    width -= x;
    if (width > 0) WebPMultRow_C(ptr[x..], alpha[x..], @intCast(width), inverse);
}

//------------------------------------------------------------------------------
// Entry point

pub fn WebPInitAlphaProcessingSSE2() void {
    alpha_processing.WebPMultARGBRow = &MultARGBRow_SSE2;
    alpha_processing.WebPMultRow = &MultRow_SSE2;
    alpha_processing.WebPApplyAlphaMultiply = &ApplyAlphaMultiply_SSE2;
    alpha_processing.WebPDispatchAlpha = &DispatchAlpha_SSE2;
    alpha_processing.WebPDispatchAlphaToGreen = &DispatchAlphaToGreen_SSE2;
    alpha_processing.WebPExtractAlpha = &ExtractAlpha_SSE2;
    alpha_processing.WebPExtractGreen = &ExtractGreen_SSE2;

    alpha_processing.WebPHasAlpha8b = &HasAlpha8b_SSE2;
    alpha_processing.WebPHasAlpha32b = &HasAlpha32b_SSE2;
    alpha_processing.WebPAlphaReplace = &AlphaReplace_SSE2;
}
