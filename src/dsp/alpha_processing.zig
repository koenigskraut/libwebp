const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const webp = struct {
    usingnamespace @import("cpu.zig");
    usingnamespace @import("../utils/utils.zig");
};

const assert = std.debug.assert;
/// Tables can be faster on some platform but incur some extra binary size
/// (~2k), hence default is false.
const use_tables_for_alpha_mult = build_options.use_tables_for_alpha_mult;
const big_endian = builtin.cpu.arch.endian() == .big;
const c_bool = webp.c_bool;

const MFIX = 24; // 24bit fixed-point arithmetic
const HALF = ((1 << MFIX) >> 1);
const KINV_255 = ((1 << MFIX) / 255);

fn Mult(x: u8, mult: u32) u32 {
    const v: u32 = (@as(u32, x) * mult + HALF) >> MFIX;
    assert(v <= 255); // <- 24bit precision is enough to ensure that.
    return v;
}

const kMultTables = [2][256]u32{
    .{ // (255u << MFIX) / alpha
        0x00000000, 0xff000000, 0x7f800000, 0x55000000, 0x3fc00000, 0x33000000,
        0x2a800000, 0x246db6db, 0x1fe00000, 0x1c555555, 0x19800000, 0x172e8ba2,
        0x15400000, 0x139d89d8, 0x1236db6d, 0x11000000, 0x0ff00000, 0x0f000000,
        0x0e2aaaaa, 0x0d6bca1a, 0x0cc00000, 0x0c249249, 0x0b9745d1, 0x0b1642c8,
        0x0aa00000, 0x0a333333, 0x09cec4ec, 0x0971c71c, 0x091b6db6, 0x08cb08d3,
        0x08800000, 0x0839ce73, 0x07f80000, 0x07ba2e8b, 0x07800000, 0x07492492,
        0x07155555, 0x06e45306, 0x06b5e50d, 0x0689d89d, 0x06600000, 0x063831f3,
        0x06124924, 0x05ee23b8, 0x05cba2e8, 0x05aaaaaa, 0x058b2164, 0x056cefa8,
        0x05500000, 0x05343eb1, 0x05199999, 0x05000000, 0x04e76276, 0x04cfb2b7,
        0x04b8e38e, 0x04a2e8ba, 0x048db6db, 0x0479435e, 0x04658469, 0x045270d0,
        0x04400000, 0x042e29f7, 0x041ce739, 0x040c30c3, 0x03fc0000, 0x03ec4ec4,
        0x03dd1745, 0x03ce540f, 0x03c00000, 0x03b21642, 0x03a49249, 0x03976fc6,
        0x038aaaaa, 0x037e3f1f, 0x03722983, 0x03666666, 0x035af286, 0x034fcace,
        0x0344ec4e, 0x033a5440, 0x03300000, 0x0325ed09, 0x031c18f9, 0x0312818a,
        0x03092492, 0x03000000, 0x02f711dc, 0x02ee5846, 0x02e5d174, 0x02dd7baf,
        0x02d55555, 0x02cd5cd5, 0x02c590b2, 0x02bdef7b, 0x02b677d4, 0x02af286b,
        0x02a80000, 0x02a0fd5c, 0x029a1f58, 0x029364d9, 0x028ccccc, 0x0286562d,
        0x02800000, 0x0279c952, 0x0273b13b, 0x026db6db, 0x0267d95b, 0x026217ec,
        0x025c71c7, 0x0256e62a, 0x0251745d, 0x024c1bac, 0x0246db6d, 0x0241b2f9,
        0x023ca1af, 0x0237a6f4, 0x0232c234, 0x022df2df, 0x02293868, 0x02249249,
        0x02200000, 0x021b810e, 0x021714fb, 0x0212bb51, 0x020e739c, 0x020a3d70,
        0x02061861, 0x02020408, 0x01fe0000, 0x01fa0be8, 0x01f62762, 0x01f25213,
        0x01ee8ba2, 0x01ead3ba, 0x01e72a07, 0x01e38e38, 0x01e00000, 0x01dc7f10,
        0x01d90b21, 0x01d5a3e9, 0x01d24924, 0x01cefa8d, 0x01cbb7e3, 0x01c880e5,
        0x01c55555, 0x01c234f7, 0x01bf1f8f, 0x01bc14e5, 0x01b914c1, 0x01b61eed,
        0x01b33333, 0x01b05160, 0x01ad7943, 0x01aaaaaa, 0x01a7e567, 0x01a5294a,
        0x01a27627, 0x019fcbd2, 0x019d2a20, 0x019a90e7, 0x01980000, 0x01957741,
        0x0192f684, 0x01907da4, 0x018e0c7c, 0x018ba2e8, 0x018940c5, 0x0186e5f0,
        0x01849249, 0x018245ae, 0x01800000, 0x017dc11f, 0x017b88ee, 0x0179574e,
        0x01772c23, 0x01750750, 0x0172e8ba, 0x0170d045, 0x016ebdd7, 0x016cb157,
        0x016aaaaa, 0x0168a9b9, 0x0166ae6a, 0x0164b8a7, 0x0162c859, 0x0160dd67,
        0x015ef7bd, 0x015d1745, 0x015b3bea, 0x01596596, 0x01579435, 0x0155c7b4,
        0x01540000, 0x01523d03, 0x01507eae, 0x014ec4ec, 0x014d0fac, 0x014b5edc,
        0x0149b26c, 0x01480a4a, 0x01466666, 0x0144c6af, 0x01432b16, 0x0141938b,
        0x01400000, 0x013e7063, 0x013ce4a9, 0x013b5cc0, 0x0139d89d, 0x01385830,
        0x0136db6d, 0x01356246, 0x0133ecad, 0x01327a97, 0x01310bf6, 0x012fa0be,
        0x012e38e3, 0x012cd459, 0x012b7315, 0x012a150a, 0x0128ba2e, 0x01276276,
        0x01260dd6, 0x0124bc44, 0x01236db6, 0x01222222, 0x0120d97c, 0x011f93bc,
        0x011e50d7, 0x011d10c4, 0x011bd37a, 0x011a98ef, 0x0119611a, 0x01182bf2,
        0x0116f96f, 0x0115c988, 0x01149c34, 0x0113716a, 0x01124924, 0x01112358,
        0x01100000, 0x010edf12, 0x010dc087, 0x010ca458, 0x010b8a7d, 0x010a72f0,
        0x01095da8, 0x01084a9f, 0x010739ce, 0x01062b2e, 0x01051eb8, 0x01041465,
        0x01030c30, 0x01020612, 0x01010204, 0x01000000,
    },
    .{ // alpha * KINV_255
        0x00000000, 0x00010101, 0x00020202, 0x00030303, 0x00040404, 0x00050505,
        0x00060606, 0x00070707, 0x00080808, 0x00090909, 0x000a0a0a, 0x000b0b0b,
        0x000c0c0c, 0x000d0d0d, 0x000e0e0e, 0x000f0f0f, 0x00101010, 0x00111111,
        0x00121212, 0x00131313, 0x00141414, 0x00151515, 0x00161616, 0x00171717,
        0x00181818, 0x00191919, 0x001a1a1a, 0x001b1b1b, 0x001c1c1c, 0x001d1d1d,
        0x001e1e1e, 0x001f1f1f, 0x00202020, 0x00212121, 0x00222222, 0x00232323,
        0x00242424, 0x00252525, 0x00262626, 0x00272727, 0x00282828, 0x00292929,
        0x002a2a2a, 0x002b2b2b, 0x002c2c2c, 0x002d2d2d, 0x002e2e2e, 0x002f2f2f,
        0x00303030, 0x00313131, 0x00323232, 0x00333333, 0x00343434, 0x00353535,
        0x00363636, 0x00373737, 0x00383838, 0x00393939, 0x003a3a3a, 0x003b3b3b,
        0x003c3c3c, 0x003d3d3d, 0x003e3e3e, 0x003f3f3f, 0x00404040, 0x00414141,
        0x00424242, 0x00434343, 0x00444444, 0x00454545, 0x00464646, 0x00474747,
        0x00484848, 0x00494949, 0x004a4a4a, 0x004b4b4b, 0x004c4c4c, 0x004d4d4d,
        0x004e4e4e, 0x004f4f4f, 0x00505050, 0x00515151, 0x00525252, 0x00535353,
        0x00545454, 0x00555555, 0x00565656, 0x00575757, 0x00585858, 0x00595959,
        0x005a5a5a, 0x005b5b5b, 0x005c5c5c, 0x005d5d5d, 0x005e5e5e, 0x005f5f5f,
        0x00606060, 0x00616161, 0x00626262, 0x00636363, 0x00646464, 0x00656565,
        0x00666666, 0x00676767, 0x00686868, 0x00696969, 0x006a6a6a, 0x006b6b6b,
        0x006c6c6c, 0x006d6d6d, 0x006e6e6e, 0x006f6f6f, 0x00707070, 0x00717171,
        0x00727272, 0x00737373, 0x00747474, 0x00757575, 0x00767676, 0x00777777,
        0x00787878, 0x00797979, 0x007a7a7a, 0x007b7b7b, 0x007c7c7c, 0x007d7d7d,
        0x007e7e7e, 0x007f7f7f, 0x00808080, 0x00818181, 0x00828282, 0x00838383,
        0x00848484, 0x00858585, 0x00868686, 0x00878787, 0x00888888, 0x00898989,
        0x008a8a8a, 0x008b8b8b, 0x008c8c8c, 0x008d8d8d, 0x008e8e8e, 0x008f8f8f,
        0x00909090, 0x00919191, 0x00929292, 0x00939393, 0x00949494, 0x00959595,
        0x00969696, 0x00979797, 0x00989898, 0x00999999, 0x009a9a9a, 0x009b9b9b,
        0x009c9c9c, 0x009d9d9d, 0x009e9e9e, 0x009f9f9f, 0x00a0a0a0, 0x00a1a1a1,
        0x00a2a2a2, 0x00a3a3a3, 0x00a4a4a4, 0x00a5a5a5, 0x00a6a6a6, 0x00a7a7a7,
        0x00a8a8a8, 0x00a9a9a9, 0x00aaaaaa, 0x00ababab, 0x00acacac, 0x00adadad,
        0x00aeaeae, 0x00afafaf, 0x00b0b0b0, 0x00b1b1b1, 0x00b2b2b2, 0x00b3b3b3,
        0x00b4b4b4, 0x00b5b5b5, 0x00b6b6b6, 0x00b7b7b7, 0x00b8b8b8, 0x00b9b9b9,
        0x00bababa, 0x00bbbbbb, 0x00bcbcbc, 0x00bdbdbd, 0x00bebebe, 0x00bfbfbf,
        0x00c0c0c0, 0x00c1c1c1, 0x00c2c2c2, 0x00c3c3c3, 0x00c4c4c4, 0x00c5c5c5,
        0x00c6c6c6, 0x00c7c7c7, 0x00c8c8c8, 0x00c9c9c9, 0x00cacaca, 0x00cbcbcb,
        0x00cccccc, 0x00cdcdcd, 0x00cecece, 0x00cfcfcf, 0x00d0d0d0, 0x00d1d1d1,
        0x00d2d2d2, 0x00d3d3d3, 0x00d4d4d4, 0x00d5d5d5, 0x00d6d6d6, 0x00d7d7d7,
        0x00d8d8d8, 0x00d9d9d9, 0x00dadada, 0x00dbdbdb, 0x00dcdcdc, 0x00dddddd,
        0x00dedede, 0x00dfdfdf, 0x00e0e0e0, 0x00e1e1e1, 0x00e2e2e2, 0x00e3e3e3,
        0x00e4e4e4, 0x00e5e5e5, 0x00e6e6e6, 0x00e7e7e7, 0x00e8e8e8, 0x00e9e9e9,
        0x00eaeaea, 0x00ebebeb, 0x00ececec, 0x00ededed, 0x00eeeeee, 0x00efefef,
        0x00f0f0f0, 0x00f1f1f1, 0x00f2f2f2, 0x00f3f3f3, 0x00f4f4f4, 0x00f5f5f5,
        0x00f6f6f6, 0x00f7f7f7, 0x00f8f8f8, 0x00f9f9f9, 0x00fafafa, 0x00fbfbfb,
        0x00fcfcfc, 0x00fdfdfd, 0x00fefefe, 0x00ffffff,
    },
};

inline fn GetScale(a: u32, inverse: bool) u32 {
    return if (comptime use_tables_for_alpha_mult)
        kMultTables[@intFromBool(!inverse)][a]
    else
        (if (inverse) (255 << MFIX) / a else a * KINV_255);
}

pub export fn WebPMultARGBRow_C(ptr: [*c]u32, width: c_int, inverse: c_int) void {
    for (0..@intCast(width)) |x| {
        const argb = ptr[x];
        if (argb < 0xff000000) { // alpha < 255
            if (argb <= 0x00ffffff) { // alpha == 0
                ptr[x] = 0;
            } else {
                const alpha = (argb >> 24) & 0xff;
                const scale = GetScale(alpha, inverse != 0);
                var out = argb & 0xff000000;
                out |= Mult(@truncate(argb >> 0), scale) << 0;
                out |= Mult(@truncate(argb >> 8), scale) << 8;
                out |= Mult(@truncate(argb >> 16), scale) << 16;
                ptr[x] = out;
            }
        }
    }
}

pub export fn WebPMultRow_C(noalias ptr: [*c]u8, noalias alpha: [*c]const u8, width: c_int, inverse: c_int) void {
    for (0..@intCast(width)) |x| {
        const a = alpha[x];
        if (a != 255) {
            if (a == 0) {
                ptr[x] = 0;
            } else {
                const scale = GetScale(a, inverse != 0);
                ptr[x] = @truncate(Mult(ptr[x], scale));
            }
        }
    }
}

pub var WebPMultARGBRow: ?*const fn (ptr: [*c]u32, width: c_int, inverse: c_int) callconv(.C) void = null;
pub var WebPMultRow: ?*const fn (noalias ptr: [*c]u8, noalias alpha: [*c]const u8, width: c_int, inverse: c_int) callconv(.C) void = null;
comptime {
    @export(WebPMultARGBRow, .{ .name = "WebPMultARGBRow" });
    @export(WebPMultRow, .{ .name = "WebPMultRow" });
}
//------------------------------------------------------------------------------
// Generic per-plane calls

pub export fn WebPMultARGBRows(ptr_: [*c]u8, stride: c_int, width: c_int, num_rows: c_int, inverse: c_int) void {
    var ptr = ptr_;
    for (0..@intCast(num_rows)) |_| {
        WebPMultARGBRow.?(@ptrCast(@alignCast(ptr)), width, inverse);
        ptr = webp.offsetPtr(ptr, stride);
    }
}

pub export fn WebPMultRows(noalias ptr_: [*c]u8, stride: c_int, noalias alpha_: [*c]const u8, alpha_stride: c_int, width: c_int, num_rows: c_int, inverse: c_int) void {
    var ptr, var alpha = .{ ptr_, alpha_ };
    for (0..@intCast(num_rows)) |_| {
        WebPMultRow.?(ptr, alpha, width, inverse);
        ptr = webp.offsetPtr(ptr, stride);
        alpha = webp.offsetPtr(alpha, alpha_stride);
    }
}

//------------------------------------------------------------------------------
// Premultiplied modes

// non dithered-modes

// (x * a * 32897) >> 23 is bit-wise equivalent to (int)(x * a / 255.)
// for all 8bit x or a. For bit-wise equivalence to (int)(x * a / 255. + .5),
// one can use instead: (x * a * 65793 + (1 << 23)) >> 24
const plus_half = false;

inline fn MULTIPLIER_ALPHA(a: u32) u32 {
    if (comptime !plus_half) { // (int)(x * a / 255.)
        return a * 32897;
    } else { // (int)(x * a / 255. + .5)
        return a * 65793;
    }
}

inline fn PREMULTIPLY(x: u32, m: u32) u32 {
    if (comptime !plus_half) { // (int)(x * a / 255.)
        return (x * m) >> 23;
    } else { // (int)(x * a / 255. + .5)
        return (x * m + (@as(u32, 1) << 23)) >> 24;
    }
}

fn ApplyAlphaMultiply_C(rgba_: [*c]u8, alpha_first: c_int, w: c_int, h_: c_int, stride: c_int) void {
    var h, var rgba = .{ h_, rgba_ };
    while (h > 0) : (h -= 1) {
        const rgb = rgba + if (alpha_first != 0) @as(usize, 1) else 0;
        const alpha: [*c]const u8 = rgba + if (alpha_first != 0) @as(usize, 0) else 3;
        for (0..@intCast(w)) |i| {
            const a: u32 = alpha[4 * i];
            if (a != 0xff) {
                const mult: u32 = MULTIPLIER_ALPHA(a);
                rgb[4 * i + 0] = @truncate(PREMULTIPLY(rgb[4 * i + 0], mult));
                rgb[4 * i + 1] = @truncate(PREMULTIPLY(rgb[4 * i + 1], mult));
                rgb[4 * i + 2] = @truncate(PREMULTIPLY(rgb[4 * i + 2], mult));
            }
        }
        rgba = webp.offsetPtr(rgba, stride);
    }
}

// rgbA4444

inline fn MULTIPLIER4444(a: u32) u32 {
    return a * 0x1111; // 0x1111 ~= (1 << 16) / 15
}

inline fn dither_hi(x: u8) u8 {
    return (x & 0xf0) | (x >> 4);
}

inline fn dither_lo(x: u8) u8 {
    return (x & 0x0f) | (x << 4);
}

inline fn multiply(x: u8, m: u32) u8 {
    return @truncate((@as(u32, x) * m) >> 16);
}

inline fn ApplyAlphaMultiply4444_C(rgba4444_: [*c]u8, w: c_int, h_: c_int, stride: c_int, rg_byte_pos: u1) void {
    var rgba4444, var h = .{ rgba4444_, h_ };
    while (h > 0) : (h -= 1) {
        for (0..@intCast(w)) |i| {
            const rg = rgba4444[2 * i + rg_byte_pos];
            const ba = rgba4444[2 * i + (rg_byte_pos ^ 1)];
            const a: u8 = ba & 0x0f;
            const mult: u32 = MULTIPLIER4444(a);
            const r: u8 = multiply(dither_hi(rg), mult);
            const g: u8 = multiply(dither_lo(rg), mult);
            const b: u8 = multiply(dither_hi(ba), mult);
            rgba4444[2 * i + rg_byte_pos] = (r & 0xf0) | ((g >> 4) & 0x0f);
            rgba4444[2 * i + (rg_byte_pos ^ 1)] = (b & 0xf0) | a;
        }
        rgba4444 = webp.offsetPtr(rgba4444, stride);
    }
}

fn ApplyAlphaMultiply_16b_C(rgba4444: [*c]u8, w: c_int, h: c_int, stride: c_int) void {
    if (comptime build_options.swap_16bit_csp)
        ApplyAlphaMultiply4444_C(rgba4444, w, h, stride, 1)
    else
        ApplyAlphaMultiply4444_C(rgba4444, w, h, stride, 0);
}

fn DispatchAlpha_C(noalias alpha_: [*c]const u8, alpha_stride: c_int, width: c_int, height: c_int, noalias dst_: [*c]u8, dst_stride: c_int) c_bool {
    if (comptime webp.neon_omit_c_code) return;
    var alpha, var dst = .{ alpha_, dst_ };
    var alpha_mask: u32 = 0xff;
    for (0..@intCast(height)) |_| {
        for (0..@intCast(width)) |i| {
            const alpha_value: u32 = alpha[i];
            dst[4 * i] = @truncate(alpha_value);
            alpha_mask &= alpha_value;
        }
        alpha = webp.offsetPtr(alpha, alpha_stride);
        dst = webp.offsetPtr(dst, dst_stride);
    }

    return @intFromBool(alpha_mask != 0xff);
}

fn DispatchAlphaToGreen_C(noalias alpha_: [*c]const u8, alpha_stride: c_int, width: c_int, height: c_int, noalias dst_: [*c]u32, dst_stride: c_int) void {
    var alpha, var dst = .{ alpha_, dst_ };

    for (0..@intCast(height)) |_| {
        for (0..@intCast(width)) |i| {
            dst[i] = @as(u32, alpha[i]) << 8; // leave A/R/B channels zero'd.
        }
        alpha = webp.offsetPtr(alpha, alpha_stride);
        dst = webp.offsetPtr(dst, dst_stride);
    }
}

fn ExtractAlpha_C(noalias argb_: [*c]const u8, argb_stride: c_int, width: c_int, height: c_int, noalias alpha_: [*c]u8, alpha_stride: c_int) c_bool {
    var alpha, var argb = .{ alpha_, argb_ };
    var alpha_mask: u8 = 0xff;

    for (0..@intCast(height)) |_| {
        for (0..@intCast(width)) |i| {
            const alpha_value = argb[4 * i];
            alpha[i] = alpha_value;
            alpha_mask &= alpha_value;
        }
        argb = webp.offsetPtr(argb, argb_stride);
        alpha = webp.offsetPtr(alpha, alpha_stride);
    }
    return @intFromBool(alpha_mask == 0xff);
}

fn ExtractGreen_C(noalias argb: [*c]const u32, noalias alpha: [*c]u8, size: c_int) void {
    for (0..@intCast(size)) |i| alpha[i] = @truncate(argb[i] >> 8);
}

//------------------------------------------------------------------------------

fn HasAlpha8b_C(src_: [*c]const u8, length_: c_int) c_int {
    var src, var length = .{ src_, length_ };
    while (length > 0) : (length -= 1) {
        if (src.* != 0xff) return 1;
        src += 1;
    }
    return 0;
}

fn HasAlpha32b_C(src: [*c]const u8, length_: c_int) c_int {
    var x: usize, var length = .{ 0, length_ };
    while (length > 0) : ({
        length -= 1;
        x += 4;
    }) if (src[x] != 0xff) return 1;
    return 0;
}

fn AlphaReplace_C(src: [*c]u32, length: c_int, color: u32) void {
    for (0..@intCast(length)) |x| {
        if ((src[x] >> 24) == 0) src[x] = color;
    }
}

//------------------------------------------------------------------------------
// Simple channel manipulations.

inline fn MakeARGB32(a: u8, r: u8, g: u8, b: u8) u32 {
    return ((@as(u32, a) << 24) | (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b));
}

fn PackARGB_C(noalias a: [*c]const u8, noalias r: [*c]const u8, noalias g: [*c]const u8, noalias b: [*c]const u8, len: c_int, noalias out: [*c]u32) void {
    if (comptime big_endian) {
        for (0..@intCast(len)) |i| {
            out[i] = MakeARGB32(a[4 * i], r[4 * i], g[4 * i], b[4 * i]);
        }
    }
}

fn PackRGB_C(noalias r: [*c]const u8, noalias g: [*c]const u8, noalias b: [*c]const u8, len: c_int, step: c_int, noalias out: [*c]u32) void {
    var offset: usize = 0;
    for (0..@intCast(len)) |i| {
        out[i] = MakeARGB32(0xff, r[offset], g[offset], b[offset]);
        offset += @intCast(step);
    }
}

pub var WebPApplyAlphaMultiply: ?*const fn ([*c]u8, c_int, c_int, c_int, c_int) callconv(.C) void = null;
pub var WebPApplyAlphaMultiply4444: ?*const fn ([*c]u8, c_int, c_int, c_int) callconv(.C) void = null;
pub var WebPDispatchAlpha: ?*const fn (noalias [*c]const u8, c_int, c_int, c_int, noalias [*c]u8, c_int) callconv(.C) c_int = null;
pub var WebPDispatchAlphaToGreen: ?*const fn (noalias [*c]const u8, c_int, c_int, c_int, noalias [*c]u32, c_int) callconv(.C) void = null;
pub var WebPExtractAlpha: ?*const fn (noalias [*c]const u8, c_int, c_int, c_int, noalias [*c]u8, c_int) callconv(.C) c_int = null;
pub var WebPExtractGreen: ?*const fn (noalias [*c]const u32, noalias [*c]u8, c_int) callconv(.C) void = null;
/// is endian == .big
pub var WebPPackARGB: ?*const fn (a: [*c]const u8, r: [*c]const u8, g: [*c]const u8, b: [*c]const u8, c_int, [*c]u32) callconv(.C) void = null;
pub var WebPPackRGB: ?*const fn (noalias [*c]const u8, noalias [*c]const u8, noalias [*c]const u8, c_int, c_int, noalias [*c]u32) callconv(.C) void = null;
pub var WebPHasAlpha8b: ?*const fn ([*c]const u8, c_int) callconv(.C) c_int = null;
pub var WebPHasAlpha32b: ?*const fn ([*c]const u8, c_int) callconv(.C) c_int = null;
pub var WebPAlphaReplace: ?*const fn ([*c]u32, c_int, u32) callconv(.C) void = null;

comptime {
    @export(WebPApplyAlphaMultiply, .{ .name = "WebPApplyAlphaMultiply" });
    @export(WebPApplyAlphaMultiply4444, .{ .name = "WebPApplyAlphaMultiply4444" });
    @export(WebPDispatchAlpha, .{ .name = "WebPDispatchAlpha" });
    @export(WebPDispatchAlphaToGreen, .{ .name = "WebPDispatchAlphaToGreen" });
    @export(WebPExtractAlpha, .{ .name = "WebPExtractAlpha" });
    @export(WebPExtractGreen, .{ .name = "WebPExtractGreen" });
    @export(WebPPackARGB, .{ .name = "WebPPackARGB" });
    @export(WebPPackRGB, .{ .name = "WebPPackRGB" });
    @export(WebPHasAlpha8b, .{ .name = "WebPHasAlpha8b" });
    @export(WebPHasAlpha32b, .{ .name = "WebPHasAlpha32b" });
    @export(WebPAlphaReplace, .{ .name = "WebPAlphaReplace" });
}

//------------------------------------------------------------------------------
// Init function

extern var VP8GetCPUInfo: webp.VP8CPUInfo;
extern fn WebPInitAlphaProcessingMIPSdspR2() void;
extern fn WebPInitAlphaProcessingSSE2() void;
extern fn WebPInitAlphaProcessingSSE41() void;
extern fn WebPInitAlphaProcessingNEON() void;

pub const WebPInitAlphaProcessing: fn () void = webp.WEBP_DSP_INIT_FUNC(struct {
    pub fn _() void {
        WebPMultARGBRow = @ptrCast(&WebPMultARGBRow_C);
        WebPMultRow = @ptrCast(&WebPMultRow_C);
        WebPApplyAlphaMultiply4444 = @ptrCast(&ApplyAlphaMultiply_16b_C);
        if (comptime big_endian)
            WebPPackARGB = @ptrCast(&PackARGB_C);
        WebPPackRGB = @ptrCast(&PackRGB_C);
        if (!comptime webp.neon_omit_c_code) {
            WebPApplyAlphaMultiply = @ptrCast(&ApplyAlphaMultiply_C);
            WebPDispatchAlpha = @ptrCast(&DispatchAlpha_C);
            WebPDispatchAlphaToGreen = @ptrCast(&DispatchAlphaToGreen_C);
            WebPExtractAlpha = @ptrCast(&ExtractAlpha_C);
            WebPExtractGreen = @ptrCast(&ExtractGreen_C);
        }

        WebPHasAlpha8b = @ptrCast(&HasAlpha8b_C);
        WebPHasAlpha32b = @ptrCast(&HasAlpha32b_C);
        WebPAlphaReplace = @ptrCast(&AlphaReplace_C);

        // If defined, use CPUInfo() to overwrite some pointers with faster versions.
        if (VP8GetCPUInfo) |GetCPUInfo| {
            if (comptime webp.have_sse2) {
                if (GetCPUInfo(.kSSE2) != 0) {
                    WebPInitAlphaProcessingSSE2();
                    if (comptime webp.have_sse41) {
                        if (GetCPUInfo(.kSSE4_1) != 0) {
                            WebPInitAlphaProcessingSSE41();
                        }
                    }
                }
            }
            if (comptime webp.use_mips_dsp_r2) {
                if (GetCPUInfo(.kMIPSdspR2) != 0) {
                    WebPInitAlphaProcessingMIPSdspR2();
                }
            }
        }

        if (comptime webp.have_neon) {
            if (webp.neon_omit_c_code or (if (VP8GetCPUInfo) |getInfo| getInfo(.kNEON) != 0 else false)) {
                WebPInitAlphaProcessingNEON();
            }
        }

        assert(WebPMultARGBRow != null);
        assert(WebPMultRow != null);
        assert(WebPApplyAlphaMultiply != null);
        assert(WebPApplyAlphaMultiply4444 != null);
        assert(WebPDispatchAlpha != null);
        assert(WebPDispatchAlphaToGreen != null);
        assert(WebPExtractAlpha != null);
        assert(WebPExtractGreen != null);
        if (comptime big_endian)
            assert(WebPPackARGB != null);
        assert(WebPPackRGB != null);
        assert(WebPHasAlpha8b != null);
        assert(WebPHasAlpha32b != null);
        assert(WebPAlphaReplace != null);
    }
}._);
