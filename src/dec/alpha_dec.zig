const std = @import("std");
const webp = struct {
    usingnamespace @import("vp8_dec.zig");
    usingnamespace @import("vp8l_dec.zig");
    usingnamespace @import("../dsp/dsp.zig");
    usingnamespace @import("../utils/utils.zig");
};

const c_bool = webp.c_bool;

pub const ALPHDecoder = extern struct {
    width_: c_int,
    height_: c_int,
    method_: c_int,
    filter_: webp.FilterType,
    pre_processing_: c_int,
    vp8l_dec_: ?*webp.VP8LDecoder,
    io_: webp.VP8Io,
    /// Although alpha channel requires only 1 byte per pixel, sometimes
    /// `VP8LDecoder` may need to allocate 4 bytes per pixel internally during
    /// decode.
    use_8b_decode_: c_bool,
    output_: [*c]u8,
    /// last output row (or `null`)
    prev_line_: [*c]const u8,
};
