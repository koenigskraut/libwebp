const std = @import("std");
const webp = struct {
    usingnamespace @import("../webp/format_constants.zig");
    usingnamespace @import("utils.zig");
};

const assert = std.debug.assert;
const c_bool = webp.c_bool;

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
    next: ?*HuffmanTablesSegment,
    size: c_int,
};

/// Chained memory segments of HuffmanCodes.
pub const HuffmanTables = extern struct {
    root: HuffmanTablesSegment,
    /// Currently processed segment. At first, this is `root`.
    curr_segment: ?*HuffmanTablesSegment,
};

/// Allocates a HuffmanTables with 'size' contiguous HuffmanCodes. Returns 0 on
/// memory allocation error, 1 otherwise.
pub export fn VP8LHuffmanTablesAllocate(size: c_int, huffman_tables: *HuffmanTables) c_bool {
    // Have 'segment' point to the first segment for now, 'root'.
    const root = &huffman_tables.root;
    huffman_tables.curr_segment = root;
    root.next = null;
    // Allocate root.
    root.start = @ptrCast(@alignCast(webp.WebPSafeMalloc(@intCast(size), @sizeOf(HuffmanCode)) orelse return 0));
    root.curr_table = root.start;
    root.size = size;
    return 1;
}

pub export fn VP8LHuffmanTablesDeallocate(huffman_tables: ?*HuffmanTables) void {
    const ht = huffman_tables orelse return;
    // HuffmanTablesSegment *current, *next;
    // Free the root node.
    var current: ?*HuffmanTablesSegment = &ht.root;
    var next: ?*HuffmanTablesSegment = current.?.next;
    webp.WebPSafeFree(current.?.start);
    current.?.start = null;
    current.?.next = null;
    current = next;
    // Free the following nodes.
    while (current != null) {
        next = current.?.next;
        webp.WebPSafeFree(current.?.start);
        webp.WebPSafeFree(current);
        current = next;
    }
}

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

const MAX_HTREE_GROUPS = 0x10000;

/// Creates the instance of HTreeGroup with specified number of tree-groups.
pub export fn VP8LHtreeGroupsNew(num_htree_groups: c_int) ?*HTreeGroup {
    const htree_groups: *HTreeGroup = @ptrCast(@alignCast(webp.WebPSafeMalloc(@intCast(num_htree_groups), @sizeOf(HTreeGroup)) orelse return null));
    assert(num_htree_groups <= MAX_HTREE_GROUPS);
    return htree_groups;
}

/// Releases the memory allocated for HTreeGroup.
pub export fn VP8LHtreeGroupsFree(htree_groups: ?*HTreeGroup) void {
    if (htree_groups != null) {
        webp.WebPSafeFree(htree_groups);
    }
}

/// Returns reverse(reverse(key, len) + 1, len), where reverse(key, len) is the
/// bit-wise reversal of the len least significant bits of key.
inline fn GetNextKey(key: u32, len: c_int) u32 {
    var step = @as(u32, 1) << @intCast(len - 1);
    while (key & step != 0) {
        step >>= 1;
    }
    return if (step != 0) (key & (step - 1)) + step else key;
}

/// Stores code in table[0], table[step], table[2*step], ..., table[end].
/// Assumes that end is an integer multiple of step.
inline fn ReplicateValue(table: [*c]HuffmanCode, step: c_int, end_: c_int, code: HuffmanCode) void {
    assert(@mod(end_, step) == 0);
    var end = end_;
    while (true) {
        end -= step;
        webp.offsetPtr(table, end)[0] = code;
        if (end <= 0) break;
    }
}

/// Returns the table width of the next 2nd level table. count is the histogram
/// of bit lengths for the remaining symbols, len is the code length of the next
/// processed symbol
inline fn NextTableBitSize(count: [*]const c_int, len_: c_int, root_bits: c_int) c_int {
    var len = len_;
    var left = @as(c_int, 1) << @intCast(len - root_bits);
    while (len < webp.MAX_ALLOWED_CODE_LENGTH) {
        left -= count[@intCast(len)];
        if (left <= 0) break;
        len += 1;
        left <<= 1;
    }
    return len - root_bits;
}

/// sorted[code_lengths_size] is a pre-allocated array for sorting symbols
/// by code length.
fn BuildHuffmanTable(root_table: [*c]HuffmanCode, root_bits: c_int, code_lengths: [*c]const c_int, code_lengths_size: c_int, sorted: [*c]u16) c_int {
    var table = root_table; // next available space in table
    var total_size: c_int = @as(c_int, 1) << @intCast(root_bits); // total size root table + 2nd level table
    // number of codes of each length:
    var count = [_]c_int{0} ** (webp.MAX_ALLOWED_CODE_LENGTH + 1);
    // offsets in sorted table for each length:
    var offset: [webp.MAX_ALLOWED_CODE_LENGTH + 1]c_int = undefined;

    assert(code_lengths_size != 0);
    assert(code_lengths != null);
    assert((root_table != null and sorted != null) or
        (root_table == null and sorted == null));
    assert(root_bits > 0);

    // Build histogram of code lengths.
    for (0..@intCast(code_lengths_size)) |symbol| {
        if (code_lengths[symbol] > webp.MAX_ALLOWED_CODE_LENGTH) {
            return 0;
        }
        count[@intCast(code_lengths[symbol])] += 1;
    }

    // Error, all code lengths are zeros.
    if (count[0] == code_lengths_size) {
        return 0;
    }

    // Generate offsets into sorted symbol table by code length.
    offset[1] = 0;
    for (1..webp.MAX_ALLOWED_CODE_LENGTH) |len| {
        if (count[len] > (@as(c_int, 1) << @truncate(len))) {
            return 0;
        }
        offset[len + 1] = offset[len] + count[len];
    }

    // Sort symbols by length, by symbol order within each length.
    for (0..@intCast(code_lengths_size)) |symbol| {
        const symbol_code_length: usize = @intCast(code_lengths[symbol]);
        if (code_lengths[symbol] > 0) {
            if (sorted != null) {
                sorted[@intCast(offset[symbol_code_length])] = @truncate(symbol);
                offset[symbol_code_length] += 1;
            } else {
                offset[symbol_code_length] += 1;
            }
        }
    }

    // Special case code with only one value.
    if (offset[webp.MAX_ALLOWED_CODE_LENGTH] == 1) {
        if (sorted != null) {
            const code = HuffmanCode{
                .bits = 0,
                .value = sorted[0],
            };
            ReplicateValue(table.?, 1, total_size, code);
        }
        return total_size;
    }

    {
        var len: usize = undefined; // current code length
        var step: c_int = undefined; // step size to replicate values in current table
        var low: u32 = 0xffffffff; // low bits for current root entry
        const mask: u32 = @bitCast(@as(i32, total_size - 1)); // mask for low bits
        var key: u32 = 0; // reversed prefix code
        var num_nodes: c_int = 1; // number of Huffman tree nodes
        var num_open: c_int = 1; // number of open branches in current tree level
        var table_bits: c_int = root_bits; // key length of current table
        var table_size: c_int = @as(c_int, 1) << @intCast(table_bits); // size of current table
        var symbol: u32 = 0; // symbol index in original or sorted table
        // Fill in root table.
        len, step = .{ 1, 2 };
        while (len <= root_bits) : ({
            len += 1;
            step <<= 1;
        }) {
            num_open <<= 1;
            num_nodes += num_open;
            num_open -= count[len];
            if (num_open < 0) {
                return 0;
            }
            if (root_table == null) continue;
            while (count[len] > 0) : (count[len] -= 1) {
                const code = HuffmanCode{
                    .bits = @truncate(len),
                    .value = sorted[symbol],
                };
                symbol += 1;
                ReplicateValue(@ptrCast(&table[key]), step, table_size, code);
                key = GetNextKey(key, @intCast(len));
            }
        }

        // Fill in 2nd level tables and add pointers to root table.
        len, step = .{ @intCast(root_bits + 1), 2 };
        while (len <= webp.MAX_ALLOWED_CODE_LENGTH) : ({
            len += 1;
            step <<= 1;
        }) {
            num_open <<= 1;
            num_nodes += num_open;
            num_open -= count[len];
            if (num_open < 0) {
                return 0;
            }
            while (count[len] > 0) : (count[len] -= 1) {
                if ((key & mask) != low) {
                    if (root_table != null) table = webp.offsetPtr(table, table_size);
                    table_bits = NextTableBitSize(&count, @intCast(len), root_bits);
                    table_size = @as(c_int, 1) << @intCast(table_bits);
                    total_size += table_size;
                    low = key & mask;
                    if (root_table != null) {
                        root_table[low].bits = @intCast(table_bits + root_bits);
                        root_table[low].value = @truncate(@as(u32, @intCast(webp.diffPtr(table, root_table))) - low);
                    }
                }
                if (root_table != null) {
                    const code = HuffmanCode{
                        .bits = @truncate(len - @as(usize, @intCast(root_bits))),
                        .value = sorted[symbol],
                    };
                    symbol += 1;
                    ReplicateValue(&table[key >> @intCast(root_bits)], step, table_size, code);
                }
                key = GetNextKey(key, @intCast(len));
            }
        }

        // Check if tree is full.
        if (num_nodes != 2 * offset[webp.MAX_ALLOWED_CODE_LENGTH] - 1) {
            return 0;
        }
    }

    return total_size;
}

/// Maximum code_lengths_size is 2328 (reached for 11-bit color_cache_bits).
/// More commonly, the value is around ~280.
const MAX_CODE_LENGTHS_SIZE = ((1 << webp.MAX_CACHE_BITS) + webp.NUM_LITERAL_CODES + webp.NUM_LENGTH_CODES);
/// Cut-off value for switching between heap and stack allocation.
const SORTED_SIZE_CUTOFF = 512;

// Builds Huffman lookup table assuming code lengths are in symbol order.
// The 'code_lengths' is pre-allocated temporary memory buffer used for creating
// the huffman table.
// Returns built table size or 0 in case of error (invalid tree or
// memory error).
pub export fn VP8LBuildHuffmanTable(root_table: [*c]HuffmanTables, root_bits: c_int, code_lengths: [*c]const c_int, code_lengths_size: c_int) c_int {
    const total_size = BuildHuffmanTable(null, root_bits, code_lengths, code_lengths_size, null);
    assert(code_lengths_size <= MAX_CODE_LENGTHS_SIZE);
    if (total_size == 0 or root_table == null) return total_size;

    if (@intFromPtr(webp.offsetPtr(root_table.*.curr_segment.?.curr_table.?, total_size)) >=
        @intFromPtr(webp.offsetPtr(root_table.*.curr_segment.?.start.?, root_table.*.curr_segment.?.size)))
    {
        // If 'root_table' does not have enough memory, allocate a new segment.
        // The available part of root_table.curr_segment is left unused because we
        // need a contiguous buffer.
        const segment_size = root_table.*.curr_segment.?.size;
        var next: *HuffmanTablesSegment = @ptrCast(@alignCast(webp.WebPSafeMalloc(1, @sizeOf(HuffmanTablesSegment)) orelse return 0));
        // Fill the new segment.
        // We need at least 'total_size' but if that value is small, it is better to
        // allocate a big chunk to prevent more allocations later. 'segment_size' is
        // therefore chosen (any other arbitrary value could be chosen).
        next.size = if (total_size > segment_size) total_size else segment_size;
        next.start = @ptrCast(@alignCast(webp.WebPSafeMalloc(@intCast(next.size), @sizeOf(HuffmanCode))));
        if (next.start == null) {
            webp.WebPSafeFree(next);
            return 0;
        }
        next.curr_table = next.start;
        next.next = null;
        // Point to the new segment.
        root_table.*.curr_segment.?.next = next;
        root_table.*.curr_segment = next;
    }
    if (code_lengths_size <= SORTED_SIZE_CUTOFF) {
        // use local stack-allocated array.
        var sorted: [SORTED_SIZE_CUTOFF]u16 = undefined;
        _ = BuildHuffmanTable(root_table.*.curr_segment.?.curr_table, root_bits, code_lengths, code_lengths_size, &sorted);
    } else { // rare case. Use heap allocation.
        const sorted: [*c]u16 = @ptrCast(@alignCast(webp.WebPSafeMalloc(@intCast(code_lengths_size), @sizeOf(u16)) orelse return 0));
        defer webp.WebPSafeFree(sorted);
        if (sorted == null) return 0;
        _ = BuildHuffmanTable(root_table.*.curr_segment.?.curr_table, root_bits, code_lengths, code_lengths_size, sorted);
    }
    return total_size;
}
