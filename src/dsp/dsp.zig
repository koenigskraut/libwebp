/// this is the common stride for enc/dec
pub const BPS = 32;

// encoding
pub const VP8WHT = ?*const fn ([*c]const i16, [*c]i16) callconv(.C) void;

//------------------------------------------------------------------------------
// Decoding

pub usingnamespace @import("dec.zig");

//------------------------------------------------------------------------------
// WebP I/O

pub usingnamespace @import("upsampling.zig");

//------------------------------------------------------------------------------
// ARGB -> YUV converters

pub usingnamespace @import("yuv.zig");

//------------------------------------------------------------------------------
// Rescaler

pub usingnamespace @import("rescaler.zig");

//------------------------------------------------------------------------------
// Utilities for processing transparent channel.

pub usingnamespace @import("alpha_processing.zig");

//------------------------------------------------------------------------------
// Filter functions

pub usingnamespace @import("filters.zig");
