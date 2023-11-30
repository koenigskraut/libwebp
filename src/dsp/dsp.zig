/// this is the common stride for enc/dec
pub const BPS = 32;

// encoding
pub const VP8WHT = ?*const fn ([*c]const i16, [*c]i16) callconv(.C) void;

//------------------------------------------------------------------------------
// Decoding

pub usingnamespace @import("dec.zig");

//------------------------------------------------------------------------------
// WebP I/O

/// Convert a pair of y/u/v lines together to the output rgb/a colorspace.
/// bottom_y can be NULL if only one line of output is needed (at top/bottom).
pub const WebPUpsampleLinePairFunc = ?*const fn (top_y: [*c]const u8, bottom_y: [*c]const u8, top_u: [*c]const u8, top_v: [*c]const u8, cur_u: [*c]const u8, cur_v: [*c]const u8, top_dst: [*c]u8, bottom_dst: [*c]u8, len: c_int) callconv(.C) void;

/// Fancy upsampling functions to convert YUV to RGB(A) modes
pub const WebPUpsamplers: [*c]WebPUpsampleLinePairFunc = @extern([*c]WebPUpsampleLinePairFunc, .{ .name = "WebPUpsamplers" });

pub usingnamespace @import("yuv.zig");

/// General function for converting two lines of ARGB or RGBA.
/// 'alpha_is_last' should be true if 0xff000000 is stored in memory as
/// as 0x00, 0x00, 0x00, 0xff (little endian).
pub extern fn WebPGetLinePairConverter(alpha_is_last: c_int) callconv(.C) WebPUpsampleLinePairFunc;

/// YUV444->RGB converters
pub const WebPYUV444Converter = ?*const fn (y: [*c]const u8, u: [*c]const u8, v: [*c]const u8, dst: [*c]u8, len: c_int) callconv(.C) void;
pub const WebPYUV444Converters: [*c]WebPYUV444Converter = @extern([*c]WebPYUV444Converter, .{ .name = "WebPYUV444Converters" });

/// Must be called before using the WebPUpsamplers[] (and for premultiplied
/// colorspaces like rgbA, rgbA4444, etc)
pub extern fn WebPInitUpsamplers() callconv(.C) void;

/// Must be called before using WebPYUV444Converters[]
pub extern fn WebPInitYUV444Converters() callconv(.C) void;

//------------------------------------------------------------------------------

//------------------------------------------------------------------------------
// Filter functions

/// Filter types.
pub const FilterType = enum(c_uint) {
    NONE = 0,
    HORIZONTAL,
    VERTICAL,
    GRADIENT,
    /// end marker
    LAST,

    /// meta-types
    BEST,
    FAST,
};

pub const WebPFilterFunc = ?*const fn (in: [*c]const u8, width: c_int, height: c_int, stride: c_int, out: [*c]u8) callconv(.C) void;

/// In-place un-filtering.
/// Warning! `prev_line` pointer can be equal to `cur_line` or `preds`.
pub const WebPUnfilterFunc = ?*const fn (prev_line: [*c]const u8, preds: [*c]const u8, cur_line: [*c]u8, width: c_int) callconv(.C) void;

/// Filter the given data using the given predictor.
/// 'in' corresponds to a 2-dimensional pixel array of size (stride * height)
/// in raster order.
/// 'stride' is number of bytes per scan line (with possible padding).
/// 'out' should be pre-allocated.
pub extern var WebPFilters: [@intFromEnum(FilterType.LAST)]WebPFilterFunc;

/// In-place reconstruct the original data from the given filtered data.
/// The reconstruction will be done for 'num_rows' rows starting from 'row'
/// (assuming rows upto 'row - 1' are already reconstructed).
pub extern var WebPUnfilters: [@intFromEnum(FilterType.LAST)]WebPUnfilterFunc;

/// To be called first before using the above.
pub extern fn VP8FiltersInit() void;
