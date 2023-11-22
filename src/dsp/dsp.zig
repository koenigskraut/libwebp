/// this is the common stride for enc/dec
pub const BPS = 32;

pub const FilterType = enum(c_uint) { // Filter types.
    NONE = 0,
    HORIZONTAL,
    VERTICAL,
    GRADIENT,
    LAST, // end marker

    BEST, // meta-types
    FAST,
};

// encoding
pub const VP8WHT = ?*const fn ([*c]const i16, [*c]i16) callconv(.C) void;

//------------------------------------------------------------------------------
// Decoding

pub const VP8DecIdct = ?*const fn ([*c]const i16, [*c]u8) callconv(.C) void;
// when doing two transforms, coeffs is actually int16_t[2][16].
pub const VP8DecIdct2 = ?*const fn ([*c]const i16, [*c]u8, c_int) callconv(.C) void;
pub extern var VP8Transform: VP8DecIdct2;
pub extern var VP8TransformAC3: VP8DecIdct;
pub extern var VP8TransformUV: VP8DecIdct;
pub extern var VP8TransformDC: VP8DecIdct;
pub extern var VP8TransformDCUV: VP8DecIdct;
pub extern var VP8TransformWHT: VP8WHT;

// *dst is the destination block, with stride BPS. Boundary samples are
// assumed accessible when needed.
pub const VP8PredFunc = ?*const fn ([*c]u8) callconv(.C) void;
pub const VP8PredLuma16: [*c]VP8PredFunc = @extern([*c]VP8PredFunc, .{ .name = "VP8PredLuma16" }); // [NUM_B_DC_MODES]
pub const VP8PredChroma8: [*c]VP8PredFunc = @extern([*c]VP8PredFunc, .{ .name = "VP8PredChroma8" }); // [NUM_B_DC_MODES]
pub const VP8PredLuma4: [*c]VP8PredFunc = @extern([*c]VP8PredFunc, .{ .name = "VP8PredLuma4" }); // [NUM_BMODES]

// clipping tables (for filtering)
pub extern const VP8ksclip1: [*c]const i8; // clips [-1020, 1020] to [-128, 127]
pub extern const VP8ksclip2: [*c]const i8; // clips [-112, 112] to [-16, 15]
pub extern const VP8kclip1: [*c]const u8; // clips [-255,511] to [0,255]
pub extern const VP8kabs0: [*c]const u8; // abs(x) for x in [-255,255]
// must be called first
pub extern fn VP8InitClipTables() void;

// simple filter (only for luma)
pub const VP8SimpleFilterFunc = ?*const fn ([*c]u8, c_int, c_int) callconv(.C) void;
pub extern var VP8SimpleVFilter16: VP8SimpleFilterFunc;
pub extern var VP8SimpleHFilter16: VP8SimpleFilterFunc;
pub extern var VP8SimpleVFilter16i: VP8SimpleFilterFunc; // filter 3 inner edges
pub extern var VP8SimpleHFilter16i: VP8SimpleFilterFunc;

// regular filter (on both macroblock edges and inner edges)
pub const VP8LumaFilterFunc = ?*const fn ([*c]u8, c_int, c_int, c_int, c_int) callconv(.C) void;
pub const VP8ChromaFilterFunc = ?*const fn ([*c]u8, [*c]u8, c_int, c_int, c_int, c_int) callconv(.C) void;

// on outer edge
pub extern var VP8VFilter16: VP8LumaFilterFunc;
pub extern var VP8HFilter16: VP8LumaFilterFunc;
pub extern var VP8VFilter8: VP8ChromaFilterFunc;
pub extern var VP8HFilter8: VP8ChromaFilterFunc;

// on inner edge
pub extern var VP8VFilter16i: VP8LumaFilterFunc; // filtering 3 inner edges altogether
pub extern var VP8HFilter16i: VP8LumaFilterFunc;
pub extern var VP8VFilter8i: VP8ChromaFilterFunc; // filtering u and v altogether
pub extern var VP8HFilter8i: VP8ChromaFilterFunc;

// Dithering. Combines dithering values (centered around 128) with dst[],
// according to: dst[] = clip(dst[] + (((dither[]-128) + 8) >> 4)
pub const VP8_DITHER_DESCALE = 4;
pub const VP8_DITHER_DESCALE_ROUNDER = (1 << (VP8_DITHER_DESCALE - 1));
pub const VP8_DITHER_AMP_BITS = 7;
pub const VP8_DITHER_AMP_CENTER = (1 << VP8_DITHER_AMP_BITS);
pub extern var VP8DitherCombine8x8: ?*const fn ([*c]const u8, [*c]u8, c_int) callconv(.C) void;
