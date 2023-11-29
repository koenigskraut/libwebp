const std = @import("std");
const webp = struct {
    usingnamespace @import("alpha_processing.zig");
    usingnamespace @import("../utils/utils.zig");
};

const c_bool = webp.c_bool;

export fn ExtractAlpha_SSE41(noalias argb_: [*c]const u8, argb_stride: c_int, width: c_int, height: c_int, noalias alpha_: [*c]u8, alpha_stride: c_int) callconv(.C) c_bool {
    var argb, var alpha = .{ argb_, alpha_ };

    // alpha_and stores an 'and' operation of all the alpha[] values. The final
    // value is not 0xff if any of the alpha[] is not equal to 0xff.
    var alpha_and: u32 = 0xff;
    const all_0xff: @Vector(16, u8) = @splat(0xff);
    var all_alphas = all_0xff;

    // We must be able to access 3 extra bytes after the last written byte
    // 'src[4 * width - 4]', because we don't know if alpha is the first or the
    // last byte of the quadruplet.
    const limit = (width - 1) & ~@as(c_int, 15);

    const kCstAlpha0: @Vector(16, i32) = .{ 0, 4, 8, 12, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1 };
    const kCstAlpha1: @Vector(16, i32) = .{ -1, -1, -1, -1, 0, 4, 8, 12, -1, -1, -1, -1, -1, -1, -1, -1 };
    const kCstAlpha2: @Vector(16, i32) = .{ -1, -1, -1, -1, -1, -1, -1, -1, 0, 4, 8, 12, -1, -1, -1, -1 };
    const kCstAlpha3: @Vector(16, i32) = .{ -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, 0, 4, 8, 12 };
    for (0..@intCast(height)) |_| { // j
        var src = argb;
        var i: usize = 0;
        while (i < limit) : (i += 16) {
            // load 64 argb bytes
            const a0: @Vector(16, u8) = @bitCast(src[0 * 16 ..][0..16].*);
            const a1: @Vector(16, u8) = @bitCast(src[1 * 16 ..][0..16].*);
            const a2: @Vector(16, u8) = @bitCast(src[2 * 16 ..][0..16].*);
            const a3: @Vector(16, u8) = @bitCast(src[3 * 16 ..][0..16].*);
            const b0: @Vector(16, u8) = @shuffle(u8, a0, @Vector(1, u8){0}, kCstAlpha0);
            const b1: @Vector(16, u8) = @shuffle(u8, a1, @Vector(1, u8){0}, kCstAlpha1);
            const b2: @Vector(16, u8) = @shuffle(u8, a2, @Vector(1, u8){0}, kCstAlpha2);
            const b3: @Vector(16, u8) = @shuffle(u8, a3, @Vector(1, u8){0}, kCstAlpha3);
            const c0: @Vector(16, u8) = b0 | b1 | b2 | b3;
            // store
            alpha[i..][0..16].* = @bitCast(c0);
            // accumulate sixteen alpha 'and' in parallel
            all_alphas = all_alphas | c0;
            src += 4 * 16;
        }
        while (i < width) : (i += 1) {
            const alpha_value: u32 = argb[4 * i];
            alpha[i] = @truncate(alpha_value);
            alpha_and &= alpha_value;
        }
        argb = webp.offsetPtr(argb, argb_stride);
        alpha = webp.offsetPtr(alpha, alpha_stride);
    }
    // Combine the sixteen alpha 'and' into an 8-bit mask.
    alpha_and |= 0xff00; // pretend the upper bits [8..15] were tested ok.
    alpha_and &= @as(u16, @bitCast(all_alphas == all_0xff));
    return @intFromBool(alpha_and == 0xFFFF);
}

pub fn WebPInitAlphaProcessingSSE41() void {
    webp.WebPExtractAlpha = @ptrCast(&ExtractAlpha_SSE41);
}
