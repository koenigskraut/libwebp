const std = @import("std");
const builtin = @import("builtin");
const webp = struct {
    usingnamespace @import("utils.zig");
};

const cpu = builtin.cpu;

// The Boolean decoder needs to maintain infinite precision on the value_ field.
// However, since range_ is only 8bit, we only need an active window of 8 bits
// for value_. Left bits (MSB) gets zeroed and shifted away when value_ falls
// below 128, range_ is updated, and fresh bits read from the bitstream are
// brought in as LSB. To avoid reading the fresh bits one by one (slow), we
// cache BITS of them ahead. The total of (BITS + 8) bits must fit into a
// natural register (with type bit_t). To fetch BITS bits from bitstream we
// use a type lbit_t.
//
// BITS can be any multiple of 8 from 8 to 56 (inclusive).
// Pick values that fit natural register size.

const BITS =
    if (webp.have_x86_feat(cpu, .@"64bit"))
    56 // x86 64bit
else if (webp.have_x86_feat(cpu, .@"32bit_mode"))
    24 // x86 32bit
else if (cpu.arch.isAARCH64())
    56 // ARM 64bit
else if (cpu.arch.isArmOrThumb())
    24 // ARM
else if (cpu.arch.isMIPS())
    24 // MIPS
else
    24; // reasonable default

//------------------------------------------------------------------------------
// Derived types and constants:
//   bit_t = natural register type for storing 'value_' (which is BITS+8 bits)
//   range_t = register for 'range_' (which is 8bits only)

pub const bit_t = if (BITS > 24) u64 else u32;
pub const range_t = u32;

// Derived type lbit_t = natural type for memory I/O
pub const lbit_t = if (BITS > 32) u64 else if (BITS > 16) u32 else if (BITS > 8) u64 else u8;

pub const VP8BitReader = extern struct {
    // boolean decoder  (keep the field ordering as is!)
    value_: bit_t, // current value
    range_: range_t, // current range minus 1. In [127, 254] interval.
    bits_: c_int, // number of valid bits left
    // read buffer
    buf_: [*c]const u8, // next byte to be read
    buf_end_: [*c]const u8, // end of read buffer
    buf_max_: [*c]const u8, // max packed-read position on buffer
    eof_: c_int, // true if input is exhausted
};

/// right now, this bit-reader can only use 64bit.
const vp8l_val_t = u64;

pub const VP8LBitReader = extern struct {
    /// pre-fetched bits
    val_: vp8l_val_t,
    /// input byte buffer
    buf_: [*c]const u8,
    /// buffer length
    len_: usize,
    /// byte position in buf_
    pos_: usize,
    /// current bit-reading position in val_
    bit_pos_: c_int,
    /// true if a bit was read past the end of buffer
    eos_: c_int,
};
