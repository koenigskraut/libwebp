const webp = struct {
    usingnamespace @import("dec.zig");
    usingnamespace @import("../utils/utils.zig");

    const BPS = @import("dsp.zig").BPS;
};

fn HE16_SSE41(dst_: [*c]u8) callconv(.C) void { // horizontal
    var dst = dst_;
    const kShuffle3: @Vector(16, u8) = @splat(3);
    var j: usize = 16;
    while (j > 0) : (j -= 1) {
        const in: @Vector(16, u8) = @bitCast(@Vector(2, i64){ webp.WebPMemToInt32(dst - 4), 0 });
        const values: @Vector(16, u8) = @shuffle(u8, in, undefined, kShuffle3);
        dst[0..16].* = @bitCast(values);
        dst += webp.BPS;
    }
}

//------------------------------------------------------------------------------
// Entry point

pub fn VP8DspInitSSE41() void {
    webp.VP8PredLuma16[3] = &HE16_SSE41;
}
