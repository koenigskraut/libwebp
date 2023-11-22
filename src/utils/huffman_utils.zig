const std = @import("std");
const webp = struct {
    usingnamespace @import("../webp/format_constants.zig");
    usingnamespace @import("utils.zig");
};

pub const c_bool = c_int;

pub const HUFFMAN_TABLE_BITS = 8;
pub const HUFFMAN_TABLE_MASK = ((1 << HUFFMAN_TABLE_BITS) - 1);

pub const LENGTHS_TABLE_BITS = 7;
pub const LENGTHS_TABLE_MASK = ((1 << LENGTHS_TABLE_BITS) - 1);

/// Huffman lookup table entry
pub const HuffmanCode = extern struct {
    /// number of bits used for this symbol
    bits: u8,
    /// symbol value or table offset
    value: u16,
};

/// long version for holding 32b values
pub const HuffmanCode32 = extern struct {
    /// number of bits used for this symbol, or an impossible value if not a
    /// literal code.
    bits: c_int,
    /// 32b packed ARGB value if literal, or non-literal symbol otherwise
    value: u32,
};

/// Contiguous memory segment of HuffmanCodes.
pub const HuffmanTablesSegment = extern struct {
    start: ?[*]HuffmanCode,
    /// Pointer to where we are writing into the segment. Starts at `start` and
    /// cannot go beyond `start` + `size`.
    curr_table: ?[*]HuffmanCode,
    /// Pointer to the next segment in the chain.
    next: ?[*]HuffmanTablesSegment,
    size: c_int,
};

/// Chained memory segments of HuffmanCodes.
pub const HuffmanTables = extern struct {
    root: HuffmanTablesSegment,
    /// Currently processed segment. At first, this is `root`.
    curr_segment: ?[*]HuffmanTablesSegment,
};

pub const HUFFMAN_PACKED_BITS = 6;
pub const HUFFMAN_PACKED_TABLE_SIZE = (@as(u32, 1) << HUFFMAN_PACKED_BITS);

/// Huffman table group.
/// Includes special handling for the following cases:
///  - is_trivial_literal: one common literal base for RED/BLUE/ALPHA (not
/// GREEN)
///  - is_trivial_code: only 1 code (no bit is read from bitstream)
///  - use_packed_table: few enough literal symbols, so all the bit codes
///    can fit into a small look-up table packed_table[]
/// The common literal base, if applicable, is stored in 'literal_arb'.
pub const HTreeGroup = extern struct {
    htrees: [webp.HUFFMAN_CODES_PER_META_CODE][*c]HuffmanCode,
    /// True, if huffman trees for Red, Blue & Alpha Symbols are trivial (have
    /// a single code).
    is_trivial_literal: c_bool,
    /// If is_trivial_literal is true, this is the ARGB value of the pixel,
    /// with Green channel being set to zero.
    literal_arb: u32,
    /// true if is_trivial_literal with only one code
    is_trivial_code: c_int,
    /// use packed table below for short literal code
    use_packed_table: c_int,
    /// table mapping input bits to a packed values, or escape case to literal
    /// code
    packed_table: [HUFFMAN_PACKED_TABLE_SIZE]HuffmanCode32,
};
