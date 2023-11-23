const std = @import("std");
const builtin = @import("builtin");
const webp = struct {
    usingnamespace @import("utils.zig");
    usingnamespace @import("endian_inl_utils.zig");
};

const assert = std.debug.assert;
const cpu = builtin.cpu;
const c_bool = webp.c_bool;

pub inline fn BT_TRACK(_: anytype) void {}

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

//------------------------------------------------------------------------------
// Bitreader

pub const VP8BitReader = extern struct {
    // boolean decoder  (keep the field ordering as is!)
    /// current value
    value_: bit_t,
    /// current range minus 1. In [127, 254] interval.
    range_: range_t,
    /// number of valid bits left
    bits_: c_int,
    // read buffer
    /// next byte to be read
    buf_: [*c]const u8,
    /// end of read buffer
    buf_end_: [*c]const u8,
    /// max packed-read position on buffer
    buf_max_: [*c]const u8,
    /// true if input is exhausted
    eof_: c_bool,
};

/// Initialize the bit reader and the boolean decoder.
pub export fn VP8InitBitReader(br: *VP8BitReader, start: [*]const u8, size: usize) void {
    assert(size < (1 << 31)); // limit ensured by format and upstream checks
    br.range_ = 255 - 1;
    br.value_ = 0;
    br.bits_ = -8; // to load the very first 8bits
    br.eof_ = 0;
    VP8BitReaderSetBuffer(br, start, size);
    VP8LoadNewBytes(@ptrCast(br));
}

/// Sets the working read buffer.
pub export fn VP8BitReaderSetBuffer(br: *VP8BitReader, start: [*c]const u8, size: usize) void {
    br.buf_ = start;
    br.buf_end_ = start + size;
    br.buf_max_ = if (size >= @sizeOf(lbit_t)) (start + size) - @sizeOf(lbit_t) + 1 else start;
}

/// Update internal pointers to displace the byte buffer by the
/// relative offset 'offset'.
pub export fn VP8RemapBitReader(br: *VP8BitReader, offset: isize) void {
    if (br.buf_ != null) {
        br.buf_ = webp.offsetPtr(br.buf_, offset);
        br.buf_end_ = webp.offsetPtr(br.buf_end_, offset);
        br.buf_max_ = webp.offsetPtr(br.buf_max_, offset);
    }
}

pub const kVP8Log2Range = [128]u8{
    7, 6, 6, 5, 5, 5, 5, 4, 4, 4, 4, 4, 4, 4, 4,
    3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
    3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
    2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 0,
};

// range = ((range - 1) << kVP8Log2Range[range]) + 1
pub const kVP8NewRange = [128]u8{
    127, 127, 191, 127, 159, 191, 223, 127,
    143, 159, 175, 191, 207, 223, 239, 127,
    135, 143, 151, 159, 167, 175, 183, 191,
    199, 207, 215, 223, 231, 239, 247, 127,
    131, 135, 139, 143, 147, 151, 155, 159,
    163, 167, 171, 175, 179, 183, 187, 191,
    195, 199, 203, 207, 211, 215, 219, 223,
    227, 231, 235, 239, 243, 247, 251, 127,
    129, 131, 133, 135, 137, 139, 141, 143,
    145, 147, 149, 151, 153, 155, 157, 159,
    161, 163, 165, 167, 169, 171, 173, 175,
    177, 179, 181, 183, 185, 187, 189, 191,
    193, 195, 197, 199, 201, 203, 205, 207,
    209, 211, 213, 215, 217, 219, 221, 223,
    225, 227, 229, 231, 233, 235, 237, 239,
    241, 243, 245, 247, 249, 251, 253, 127,
};

// special case for the tail byte-reading
pub export fn VP8LoadFinalBytes(br: *VP8BitReader) void {
    assert(br.buf_ != null);
    // Only read 8bits at a time
    if (br.buf_ < br.buf_end_) {
        br.bits_ += 8;
        br.value_ = (br.buf_.*) | (br.value_ << 8);
        br.buf_ += 1;
    } else if (br.eof_ == 0) {
        br.value_ <<= 8;
        br.bits_ += 8;
        br.eof_ = 1;
    } else {
        br.bits_ = 0; // This is to avoid undefined behaviour with shifts.
    }
}

//------------------------------------------------------------------------------
// Higher-level calls

// return the next value made of 'num_bits' bits
pub export fn VP8GetValue(br: *VP8BitReader, bits_arg: u32, label: [*c]const u8) u32 {
    var v: u32 = 0;
    var bits: u32 = @intCast(bits_arg);
    while (bits > 0) : (bits -= 1) {
        v |= @as(u32, @intFromBool(VP8GetBit(br, 0x80, label))) << @truncate(bits - 1);
    }
    return v;
}

pub export fn VP8GetSignedValue(br: *VP8BitReader, bits: u32, label: [*c]const u8) i32 {
    const value: i32 = @intCast(VP8GetValue(br, bits, label));
    return if (VP8Get(br, label)) -value else value;
}

pub inline fn VP8Get(br: *VP8BitReader, label: [*c]const u8) bool {
    return VP8GetValue(br, 1, label) & 1 != 0;
}

// -----------------------------------------------------------------------------
// Bitreader for lossless format

/// maximum number of bits (inclusive) the bit-reader can handle:
const VP8L_MAX_NUM_BIT_READ = 24;

/// Number of bits prefetched (= bit-size of vp8l_val_t).
const VP8L_LBITS = 64;
/// Minimum number of bytes ready after VP8LFillBitWindow.
const VP8L_WBITS = 32;

/// right now, this bit-reader can only use 64bit.
pub const vp8l_val_t = u64;

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
    eos_: c_bool,
};

const VP8L_LOG8_WBITS = 4; // Number of bytes needed to store VP8L_WBITS bits.
const VP8L_USE_FAST_LOAD = cpu.arch.isAARCH64() or cpu.arch.isArmOrThumb() or cpu.arch.isX86();

const kBitMask = [VP8L_MAX_NUM_BIT_READ + 1]u32{ 0, 0x000001, 0x000003, 0x000007, 0x00000f, 0x00001f, 0x00003f, 0x00007f, 0x0000ff, 0x0001ff, 0x0003ff, 0x0007ff, 0x000fff, 0x001fff, 0x003fff, 0x007fff, 0x00ffff, 0x01ffff, 0x03ffff, 0x07ffff, 0x0fffff, 0x1fffff, 0x3fffff, 0x7fffff, 0xffffff };

pub export fn VP8LInitBitReader(br: *VP8LBitReader, start: [*]const u8, length_arg: usize) void {
    var value: vp8l_val_t = 0;
    var length = length_arg;
    assert(length < 0xfffffff8); // can't happen with a RIFF chunk.

    br.len_ = length;
    br.val_ = 0;
    br.bit_pos_ = 0;
    br.eos_ = 0;

    if (length > @sizeOf(@TypeOf(br.val_))) {
        length = @sizeOf(@TypeOf(br.val_));
    }
    for (0..length) |i| {
        value |= @as(vp8l_val_t, start[i]) << @truncate(8 * i);
    }
    br.val_ = value;
    br.pos_ = length;
    br.buf_ = start;
}

///  Sets a new data buffer.
pub export fn VP8LBitReaderSetBuffer(br: *VP8LBitReader, buf: [*]const u8, len: usize) void {
    assert(len < 0xfffffff8); // can't happen with a RIFF chunk.
    br.buf_ = buf;
    br.len_ = len;
    // pos_ > len_ should be considered a param error.
    br.eos_ = @intFromBool((br.pos_ > br.len_) or VP8LIsEndOfStream(br));
}

// Returns true if there was an attempt at reading bit past the end of
// the buffer. Doesn't set br->eos_ flag.
pub inline fn VP8LIsEndOfStream(br: *const VP8LBitReader) bool {
    assert(br.pos_ <= br.len_);
    return br.eos_ != 0 or ((br.pos_ == br.len_) and (br.bit_pos_ > VP8L_LBITS));
}

fn VP8LSetEndOfStream(br: *VP8LBitReader) void {
    br.eos_ = 1;
    br.bit_pos_ = 0; // To avoid undefined behaviour with shifts.
}

/// If not at EOS, reload up to VP8L_LBITS byte-by-byte
fn ShiftBytes(br: *VP8LBitReader) void {
    while (br.bit_pos_ >= 8 and br.pos_ < br.len_) {
        br.val_ >>= 8;
        br.val_ |= (@as(vp8l_val_t, br.buf_[br.pos_])) << (VP8L_LBITS - 8);
        br.pos_ +%= 1;
        br.bit_pos_ -= 8;
    }

    if (VP8LIsEndOfStream(br)) VP8LSetEndOfStream(br);
}

// Return the prefetched bits, so they can be looked up.
pub inline fn VP8LPrefetchBits(br: *VP8LBitReader) u32 {
    return @truncate(br.val_ >> @intCast(br.bit_pos_ & (VP8L_LBITS - 1)));
}

// For jumping over a number of bits in the bit stream when accessed with
// VP8LPrefetchBits and VP8LFillBitWindow.
// This function does *not* set br->eos_, since it's speed-critical.
// Use with extreme care!
pub inline fn VP8LSetBitPos(br: *VP8LBitReader, val: c_int) void {
    br.bit_pos_ = val;
}

export fn VP8LDoFillBitWindow(br: *VP8LBitReader) void {
    assert(br.bit_pos_ >= VP8L_WBITS);
    if (comptime VP8L_USE_FAST_LOAD) {
        if (br.pos_ + @sizeOf(@TypeOf(br.val_)) < br.len_) {
            br.val_ >>= VP8L_WBITS;
            br.bit_pos_ -= VP8L_WBITS;
            br.val_ |= @as(vp8l_val_t, webp.HToLE32(webp.WebPMemToUint32(br.buf_ + br.pos_))) <<
                (VP8L_LBITS - VP8L_WBITS);
            br.pos_ +%= VP8L_LOG8_WBITS;
            return;
        }
    }
    ShiftBytes(br); // Slow path.
}

// Advances the read buffer by 4 bytes to make room for reading next 32 bits.
// Speed critical, but infrequent part of the code can be non-inlined.
pub inline fn VP8LFillBitWindow(br: *VP8LBitReader) void {
    if (br.bit_pos_ >= VP8L_WBITS) VP8LDoFillBitWindow(br);
}

// Reads the specified number of bits from read buffer.
// Flags an error in case end_of_stream or n_bits is more than the allowed limit
// of VP8L_MAX_NUM_BIT_READ (inclusive).
// Flags eos_ if this read attempt is going to cross the read buffer.
pub export fn VP8LReadBits(br: *VP8LBitReader, n_bits: c_uint) u32 {
    // Flag an error if end_of_stream or n_bits is more than allowed limit.
    if (br.eos_ == 0 and n_bits <= VP8L_MAX_NUM_BIT_READ) {
        const val: u32 = VP8LPrefetchBits(br) & kBitMask[n_bits];
        const new_bits: c_int = br.bit_pos_ + @as(c_int, @intCast(n_bits));
        br.bit_pos_ = new_bits;
        ShiftBytes(br);
        return val;
    } else {
        VP8LSetEndOfStream(br);
        return 0;
    }
}

//------------------------------------------------------------------------------
// Inlined critical functions

// makes sure br->value_ has at least BITS bits worth of data
inline fn VP8LoadNewBytes(noalias br: *VP8BitReader) void {
    assert(br.buf_ != null);
    // Read 'BITS' bits at a time if possible.
    if (br.buf_ < br.buf_max_) {
        // convert memory type to register type (with some zero'ing!)
        // #if defined(WEBP_USE_MIPS32)
        //     // This is needed because of un-aligned read.
        //     lbit_t in_bits;
        //     lbit_t* p_buf_ = (lbit_t*)br->buf_;
        //     __asm__ volatile(
        //     ".set   push                             \n\t"
        //     ".set   at                               \n\t"
        //     ".set   macro                            \n\t"
        //     "ulw    %[in_bits], 0(%[p_buf_])         \n\t"
        //     ".set   pop                              \n\t"
        //     : [in_bits]"=r"(in_bits)
        //     : [p_buf_]"r"(p_buf_)
        //     : "memory", "at"
        //     );
        // #else
        var in_bits = std.mem.readInt(lbit_t, br.buf_[0..@sizeOf(lbit_t)], .big);
        // #endif
        br.buf_ += BITS >> 3;
        var bits: bit_t = @intCast(in_bits);
        if (BITS != 8 * @sizeOf(bit_t)) bits >>= (8 * @sizeOf(bit_t) - BITS);
        br.value_ = bits | (br.value_ << BITS);
        br.bits_ += BITS;
    } else {
        VP8LoadFinalBytes(br); // no need to be inlined
    }
}

// Read a bit with proba 'prob'. Speed-critical function!
pub inline fn VP8GetBit(noalias br: *VP8BitReader, prob: u32, label: [*c]const u8) bool {
    _ = label;
    // Don't move this declaration! It makes a big speed difference to store
    // 'range' *before* calling VP8LoadNewBytes(), even if this function doesn't
    // alter br->range_ value.
    var range = br.range_;
    if (br.bits_ < 0)
        VP8LoadNewBytes(br);

    {
        const pos = br.bits_;
        const split: range_t = (range *% prob) >> 8;
        const value: range_t = @truncate(br.value_ >> @truncate(@abs(pos)));
        const bit = (value > split);
        if (bit) {
            range -%= split;
            br.value_ -%= @as(bit_t, split +% 1) << @truncate(@abs(pos));
        } else {
            range = split +% 1;
        }
        {
            const shift: c_int = @bitCast(7 ^ webp.BitsLog2Floor(range));
            range <<= @truncate(@abs(shift));
            br.bits_ -= shift;
        }
        br.range_ = range -% 1;
        BT_TRACK(br);
        return bit;
    }
}

/// simplified version of VP8GetBit() for prob=0x80 (note shift is always 1 here)
pub inline fn VP8GetSigned(noalias br: *VP8BitReader, v: c_int, label: [*c]const u8) c_int {
    _ = label;

    if (br.bits_ < 0) {
        VP8LoadNewBytes(br);
    }
    {
        const pos: u6 = @intCast(br.bits_);
        const split: range_t = br.range_ >> 1;
        const value: range_t = @truncate(br.value_ >> pos);
        const mask: i32 = (@as(i32, @bitCast(split)) - @as(i32, @bitCast(value))) >> 31; // -1 or 0
        br.bits_ -= 1;
        br.range_ +%= @bitCast(mask);
        br.range_ |= 1;
        br.value_ -= @as(bit_t, @intCast(((split + 1) & @as(u32, @bitCast(mask))))) << pos;
        BT_TRACK(br);
        return (v ^ mask) - mask;
    }
}

// static WEBP_INLINE
pub fn VP8GetBitAlt(noalias br: *VP8BitReader, prob: u32, label: [*c]const u8) bool {
    _ = label;

    // Don't move this declaration! It makes a big speed difference to store
    // 'range' *before* calling VP8LoadNewBytes(), even if this function doesn't
    // alter br.range_ value.
    var range: range_t = br.range_;
    if (br.bits_ < 0) {
        VP8LoadNewBytes(br);
    }
    {
        const pos = br.bits_;
        const split: range_t = (range * prob) >> 8;
        const value: range_t = @truncate(br.value_ >> @truncate(@abs(pos)));
        // int bit;  // Don't use 'const int bit = (value > split);", it's slower.
        // TODO:                                                 ???  ^^^^^^^^^^^
        var bit: bool = undefined;
        if (value > split) {
            range -%= split +% 1;
            br.value_ -%= (split +% 1) << @truncate(@abs(pos));
            bit = true;
        } else {
            range = split;
            bit = false;
        }
        if (range <= 0x7e) {
            const shift = kVP8Log2Range[range];
            range = kVP8NewRange[range];
            br.bits_ -= shift;
        }
        br.range_ = range;
        BT_TRACK(br);
        return bit;
    }
}
