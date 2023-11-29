/// this is the common stride for enc/dec
pub const BPS = 32;

// encoding
pub const VP8WHT = ?*const fn ([*c]const i16, [*c]i16) callconv(.C) void;

//------------------------------------------------------------------------------
// Decoding

pub usingnamespace @import("dec.zig");

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
