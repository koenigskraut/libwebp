const webp = struct {
    usingnamespace @import("vp8_dec.zig");
    usingnamespace @import("../utils/rescaler_utils.zig");
    usingnamespace @import("../utils/utils.zig");
    usingnamespace @import("../webp/decode.zig");
};

const c_bool = webp.c_bool;

const OutputFunc = ?*const fn ([*c]const webp.VP8Io, [*c]DecParams) callconv(.C) c_int;
const OutputAlphaFunc = ?*const fn ([*c]const webp.VP8Io, [*c]DecParams, c_int) callconv(.C) c_int;
const OutputRowFunc = ?*const fn ([*c]DecParams, c_int, c_int) callconv(.C) c_int;

pub const DecParams = extern struct {
    /// output buffer.
    output: ?*webp.DecBuffer,
    // cache for the fancy upsampler
    // or used for tmp rescaling
    tmp_y: [*c]u8,
    tmp_u: [*c]u8,
    tmp_v: [*c]u8,

    /// coordinate of the line that was last output
    last_y: c_int,
    /// if not `null`, use alt decoding features
    options: ?*const webp.DecoderOptions,

    //rescalers
    scaler_y: ?*webp.WebPRescaler,
    scaler_u: ?*webp.WebPRescaler,
    scaler_v: ?*webp.WebPRescaler,
    scaler_a: ?*webp.WebPRescaler,
    /// overall scratch memory for the output work.
    memory: ?*anyopaque,

    /// output RGB or YUV samples
    emit: OutputFunc,
    /// output alpha channel
    emit_alpha: OutputAlphaFunc,
    /// output one line of rescaled alpha values
    emit_alpha_row: OutputRowFunc,
};

/// Returns true if crop dimensions are within image bounds.
pub fn WebPCheckCropDimensions(image_width: c_int, image_height: c_int, x: c_int, y: c_int, w: c_int, h: c_int) bool {
    return !(x < 0 or y < 0 or w <= 0 or h <= 0 or
        x >= image_width or w > image_width or w > image_width - x or
        y >= image_height or h > image_height or h > image_height - y);
}
