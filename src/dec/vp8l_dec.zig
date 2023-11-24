const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const webp = struct {
    pub usingnamespace @import("alpha_dec.zig");
    pub usingnamespace @import("vp8_dec.zig");
    pub usingnamespace @import("webp_dec.zig");
    pub usingnamespace @import("../dsp/lossless_common.zig");
    pub usingnamespace @import("../webp/decode.zig");
    pub usingnamespace @import("../webp/format_constants.zig");
    pub usingnamespace @import("../utils/bit_reader_utils.zig");
    pub usingnamespace @import("../utils/color_cache_utils.zig");
    pub usingnamespace @import("../utils/huffman_utils.zig");
    pub usingnamespace @import("../utils/rescaler_utils.zig");
    pub usingnamespace @import("../utils/utils.zig");

    extern fn VP8LHuffmanTablesAllocate(size: c_int, huffman_tables: [*c]@This().HuffmanTables) c_int;
    extern fn VP8LHuffmanTablesDeallocate(huffman_tables: [*c]@This().HuffmanTables) void;
    extern fn VP8LHtreeGroupsNew(num_htree_groups: c_int) [*c]@This().HTreeGroup;
    extern fn VP8LHtreeGroupsFree(htree_groups: [*c]@This().HTreeGroup) void;
    extern fn VP8LBuildHuffmanTable(root_table: [*c]@This().HuffmanTables, root_bits: c_int, code_lengths: [*c]const c_int, code_lengths_size: c_int) c_int;

    extern fn WebPRescalerInit(rescaler: [*c]@This().WebPRescaler, src_width: c_int, src_height: c_int, dst: [*c]u8, dst_width: c_int, dst_height: c_int, dst_stride: c_int, num_channels: c_int, work: [*c]@This().rescaler_t) c_int;
    extern fn VP8LInverseTransform(transform: [*c]const VP8LTransform, row_start: c_int, row_end: c_int, in: [*c]const u32, out: [*c]u32) void;
    extern fn VP8LDspInit() void;
    extern fn VP8LColorIndexInverseTransformAlpha(transform: [*c]const VP8LTransform, y_start: c_int, y_end: c_int, src: [*c]const u8, dst: [*c]u8) void;

    // const WebPFilterFunc = ?*const fn ([*c]const u8, c_int, c_int, c_int, [*c]u8) callconv(.C) void;
    pub const WebPUnfilterFunc = ?*const fn ([*c]const u8, [*c]const u8, [*c]u8, c_int) callconv(.C) void;
    // pub extern var WebPFilters: [4]WebPFilterFunc;
    pub extern var WebPUnfilters: [4]WebPUnfilterFunc;

    extern fn WebPInitAlphaProcessing() void;
    extern fn WebPRescaleNeededLines(rescaler: [*c]const @This().WebPRescaler, max_num_lines: c_int) c_int;
    extern fn VP8LConvertFromBGRA(in_data: [*c]const u32, num_pixels: c_int, out_colorspace: @This().ColorspaceMode, rgba: [*c]u8) void;

    extern var WebPConvertARGBToY: ?*const fn ([*c]const u32, [*c]u8, c_int) callconv(.C) void;
    extern var WebPConvertARGBToUV: ?*const fn ([*c]const u32, [*c]u8, [*c]u8, c_int, c_int) callconv(.C) void;
    extern var WebPConvertRGBA32ToUV: ?*const fn ([*c]const u16, [*c]u8, [*c]u8, c_int) callconv(.C) void;
    extern var WebPConvertRGB24ToY: ?*const fn ([*c]const u8, [*c]u8, c_int) callconv(.C) void;
    extern var WebPConvertBGR24ToY: ?*const fn ([*c]const u8, [*c]u8, c_int) callconv(.C) void;
    extern fn WebPInitConvertARGBToYUV() void;
    extern fn WebPRescalerImport(rescaler: [*c]@This().WebPRescaler, num_rows: c_int, src: [*c]const u8, src_stride: c_int) c_int;
    extern fn WebPRescalerExportRow(wrk: [*c]@This().WebPRescaler) void;

    extern var WebPExtractAlpha: ?*const fn (noalias [*c]const u8, c_int, c_int, c_int, noalias [*c]u8, c_int) callconv(.C) c_int;
    extern var WebPExtractGreen: ?*const fn (noalias [*c]const u32, noalias [*c]u8, c_int) callconv(.C) void;
    extern var WebPMultARGBRow: ?*const fn ([*c]u32, c_int, c_int) callconv(.C) void;
    extern fn WebPMultARGBRows(ptr: [*c]u8, stride: c_int, width: c_int, num_rows: c_int, inverse: c_int) void;
    extern var WebPMultRow: ?*const fn (noalias [*c]u8, noalias [*c]const u8, c_int, c_int) callconv(.C) void;
    extern fn WebPMultRows(noalias ptr: [*c]u8, stride: c_int, noalias alpha: [*c]const u8, alpha_stride: c_int, width: c_int, num_rows: c_int, inverse: c_int) void;
    extern fn WebPMultRow_C(noalias ptr: [*c]u8, noalias alpha: [*c]const u8, width: c_int, inverse: c_int) void;
    extern fn WebPMultARGBRow_C(ptr: [*c]u32, width: c_int, inverse: c_int) void;
};

const assert = std.debug.assert;
const c_bool = webp.c_bool;
const VP8Status = webp.VP8Status;
const VP8Error = webp.VP8Error;
const CspMode = webp.ColorspaceMode;

const BIG_ENDIAN = builtin.cpu.arch.endian() == .big;
const ARM_OR_THUMB = builtin.cpu.arch.isArmOrThumb();
const MIPS_DSP_R2 = webp.have_mips_feat(builtin.cpu, std.Target.mips.Feature.dspr2);
const NUM_ARGB_CACHE_ROWS = 16;

const kCodeLengthLiterals = 16;
const kCodeLengthRepeatCode = 16;
const kCodeLengthExtraBits = [3]u8{ 2, 3, 7 };
const kCodeLengthRepeatOffsets = [3]u8{ 3, 3, 11 };

//  Five Huffman codes are used at each meta code:
//  1. green + length prefix codes + color cache codes,
//  2. alpha,
//  3. red,
//  4. blue, and,
//  5. distance prefix codes.
const HuffIndex = enum(c_uint) {
    GREEN = 0,
    RED = 1,
    BLUE = 2,
    ALPHA = 3,
    DIST = 4,
};

const VP8LDecodeState = enum(c_uint) {
    READ_DATA = 0,
    READ_HDR = 1,
    READ_DIM = 2,
};

pub const VP8LTransform = extern struct {
    /// transform type.
    type_: webp.VP8LImageTransformType,
    /// subsampling bits defining transform window.
    bits_: c_int,
    /// transform window X index.
    xsize_: c_int,
    /// transform window Y index.
    ysize_: c_int,
    /// transform data.
    data_: [*c]u32,
};

pub const VP8LMetadata = extern struct {
    color_cache_size_: c_int,
    color_cache_: webp.VP8LColorCache,
    saved_color_cache_: webp.VP8LColorCache, // for incremental

    huffman_mask_: c_int,
    huffman_subsample_bits_: c_int,
    huffman_xsize_: c_int,
    huffman_image_: [*c]u32,
    num_htree_groups_: c_int,
    htree_groups_: [*c]webp.HTreeGroup,
    huffman_tables_: webp.HuffmanTables,
};

pub const VP8LDecoder = extern struct {
    status_: VP8Status,
    state_: VP8LDecodeState,
    io_: ?*webp.VP8Io,

    /// shortcut to io->opaque->output
    output_: ?*const webp.DecBuffer,

    /// Internal data: either uint8_t* for alpha or uint32_t* for BGRA.
    pixels_: [*c]u32,
    /// Scratch buffer for temporary BGRA storage.
    argb_cache_: [*c]u32,

    br_: webp.VP8LBitReader,
    /// if true, incremental decoding is expected
    incremental_: c_bool,
    /// note: could be local variables too
    saved_br_: webp.VP8LBitReader,
    saved_last_pixel_: c_int,

    width_: c_int,
    height_: c_int,
    /// last input row decoded so far.
    last_row_: c_int,
    /// last pixel decoded so far. However, it may not be transformed, scaled and color-converted yet.
    last_pixel_: c_int,
    /// last row output so far.
    last_out_row_: c_int,

    hdr_: VP8LMetadata,

    next_transform_: c_int,
    transforms_: [webp.NUM_TRANSFORMS]VP8LTransform,
    /// or'd bitset storing the transforms types.
    transforms_seen_: u32,

    /// Working memory for rescaling work.
    rescaler_memory: [*c]u8,
    /// Common rescaler for all channels.
    rescaler: ?*webp.WebPRescaler,
};

//------------------------------------------------------------------------------

const kAlphabetSize = [webp.HUFFMAN_CODES_PER_META_CODE]u16{
    webp.NUM_LITERAL_CODES + webp.NUM_LENGTH_CODES,
    webp.NUM_LITERAL_CODES,
    webp.NUM_LITERAL_CODES,
    webp.NUM_LITERAL_CODES,
    webp.NUM_DISTANCE_CODES,
};

const kLiteralMap = [webp.HUFFMAN_CODES_PER_META_CODE]u16{ 0, 1, 1, 1, 0 };

const NUM_CODE_LENGTH_CODES = 19;
const kCodeLengthCodeOrder = [NUM_CODE_LENGTH_CODES]u8{ 17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };

const CODE_TO_PLANE_CODES = 120;
const kCodeToPlane = [CODE_TO_PLANE_CODES]u8{
    0x18, 0x07, 0x17, 0x19, 0x28, 0x06, 0x27, 0x29, 0x16, 0x1a,
    0x26, 0x2a, 0x38, 0x05, 0x37, 0x39, 0x15, 0x1b, 0x36, 0x3a,
    0x25, 0x2b, 0x48, 0x04, 0x47, 0x49, 0x14, 0x1c, 0x35, 0x3b,
    0x46, 0x4a, 0x24, 0x2c, 0x58, 0x45, 0x4b, 0x34, 0x3c, 0x03,
    0x57, 0x59, 0x13, 0x1d, 0x56, 0x5a, 0x23, 0x2d, 0x44, 0x4c,
    0x55, 0x5b, 0x33, 0x3d, 0x68, 0x02, 0x67, 0x69, 0x12, 0x1e,
    0x66, 0x6a, 0x22, 0x2e, 0x54, 0x5c, 0x43, 0x4d, 0x65, 0x6b,
    0x32, 0x3e, 0x78, 0x01, 0x77, 0x79, 0x53, 0x5d, 0x11, 0x1f,
    0x64, 0x6c, 0x42, 0x4e, 0x76, 0x7a, 0x21, 0x2f, 0x75, 0x7b,
    0x31, 0x3f, 0x63, 0x6d, 0x52, 0x5e, 0x00, 0x74, 0x7c, 0x41,
    0x4f, 0x10, 0x20, 0x62, 0x6e, 0x30, 0x73, 0x7d, 0x51, 0x5f,
    0x40, 0x72, 0x7e, 0x61, 0x6f, 0x50, 0x71, 0x7f, 0x60, 0x70,
};

const FIXED_TABLE_SIZE = 630 * 3 + 410;
/// Memory needed for lookup tables of one Huffman tree group. Red, blue, alpha
/// and distance alphabets are constant (256 for red, blue and alpha, 40 for
/// distance) and lookup table sizes for them in worst case are 630 and 410
/// respectively. Size of green alphabet depends on color cache size and is
/// equal to 256 (green component values) + 24 (length prefix values)
/// + color_cache_size (between 0 and 2048).
/// All values computed for 8-bit first level lookup with Mark Adler's tool:
/// https://github.com/madler/zlib/blob/v1.2.5/examples/enough.c
const kTableSize = [12]u16{
    FIXED_TABLE_SIZE + 654,
    FIXED_TABLE_SIZE + 656,
    FIXED_TABLE_SIZE + 658,
    FIXED_TABLE_SIZE + 662,
    FIXED_TABLE_SIZE + 670,
    FIXED_TABLE_SIZE + 686,
    FIXED_TABLE_SIZE + 718,
    FIXED_TABLE_SIZE + 782,
    FIXED_TABLE_SIZE + 912,
    FIXED_TABLE_SIZE + 1168,
    FIXED_TABLE_SIZE + 1680,
    FIXED_TABLE_SIZE + 2704,
};

fn VP8LSetError(dec: *VP8LDecoder, @"error": VP8Status) c_bool {
    // The oldest error reported takes precedence over the new one.
    if (dec.status_ == .Ok or dec.status_ == .Suspended) {
        dec.status_ = @"error";
    }
    return 0;
}

// static int DecodeImageStream(int xsize, int ysize,
//                              int is_level0,
//                              VP8LDecoder* const dec,
//                              uint32_t** const decoded_data);

//------------------------------------------------------------------------------

const VP8L_MAGIC_BYTE: u8 = webp.VP8L_MAGIC_BYTE;
const VP8L_FRAME_HEADER_SIZE = webp.VP8L_FRAME_HEADER_SIZE;
const VP8L_IMAGE_SIZE_BITS = webp.VP8L_IMAGE_SIZE_BITS;
const VP8L_VERSION_BITS = webp.VP8L_VERSION_BITS;

/// Returns true if the next byte(s) in data is a VP8L signature.
pub fn VP8LCheckSignature(data: []const u8) bool {
    return (data.len >= VP8L_FRAME_HEADER_SIZE and
        data[0] == VP8L_MAGIC_BYTE and
        (data[4] >> 5) == 0); // version
}

// export
fn VP8LCheckSignatureC(data: [*c]const u8, size: usize) callconv(.C) c_int {
    return @intFromBool(VP8LCheckSignature(data[0..size]));
}
comptime {
    @export(VP8LCheckSignatureC, .{ .name = "VP8LCheckSignature" });
}

fn ReadImageInfo(br: *webp.VP8LBitReader, width: *c_int, height: *c_int, has_alpha: *bool) bool {
    if (webp.VP8LReadBits(br, 8) != VP8L_MAGIC_BYTE) return false;
    width.* = @intCast(webp.VP8LReadBits(br, VP8L_IMAGE_SIZE_BITS) + 1);
    height.* = @intCast(webp.VP8LReadBits(br, VP8L_IMAGE_SIZE_BITS) + 1);
    has_alpha.* = webp.VP8LReadBits(br, 1) != 0;
    if (webp.VP8LReadBits(br, VP8L_VERSION_BITS) != 0) return false;
    return br.eos_ == 0;
}

/// Validates the VP8L data-header and retrieves basic header information viz
/// width, height and alpha. Returns `false` in case of formatting error.
/// width/height/has_alpha can be passed `null`. `data` — data available so
/// far.
/// // export
pub fn VP8LGetInfo(data_arg: ?[]const u8, width: ?*c_int, height: ?*c_int, has_alpha: ?*bool) bool {
    const data = data_arg orelse return false;
    if (data.len < VP8L_FRAME_HEADER_SIZE) {
        return false; // not enough data
    } else if (!VP8LCheckSignature(data)) {
        return false; // bad signature
    } else {
        var w: c_int, var h: c_int, var a: bool, var br: webp.VP8LBitReader = .{undefined} ** 4;
        webp.VP8LInitBitReader(&br, data.ptr, data.len);
        if (!ReadImageInfo(&br, &w, &h, &a)) return false;
        if (width) |wp| wp.* = w;
        if (height) |hp| hp.* = h;
        if (has_alpha) |ap| ap.* = a;
        return true;
    }
}

fn VP8LGetInfoC(data: [*c]const u8, data_size: usize, width: ?*c_int, height: ?*c_int, has_alpha: ?*c_int) callconv(.C) c_int {
    var b: bool = undefined;
    const res = @intFromBool(VP8LGetInfo(if (data) |d| d[0..data_size] else null, width, height, &b));
    if (has_alpha) |ap| ap.* = @intFromBool(b);
    return res;
}
comptime {
    @export(VP8LGetInfoC, .{ .name = "VP8LGetInfo" });
}

//------------------------------------------------------------------------------

inline fn GetCopyDistance(distance_symbol: c_int, br: *webp.VP8LBitReader) c_int {
    if (distance_symbol < 4) {
        return distance_symbol + 1;
    }
    const extra_bits = (distance_symbol - 2) >> 1;
    const offset = (2 + (distance_symbol & 1)) << @intCast(extra_bits);
    return offset + @as(c_int, @intCast(webp.VP8LReadBits(@ptrCast(br), @intCast(extra_bits)))) + 1;
}

inline fn GetCopyLength(length_symbol: c_int, br: *webp.VP8LBitReader) c_int {
    // Length and distance prefixes are encoded the same way.
    return GetCopyDistance(length_symbol, br);
}

inline fn PlaneCodeToDistance(xsize: c_int, plane_code: c_int) c_int {
    if (plane_code > CODE_TO_PLANE_CODES) {
        return plane_code - CODE_TO_PLANE_CODES;
    } else {
        const dist_code: u8 = kCodeToPlane[@intCast(plane_code - 1)];
        const yoffset: c_int = @intCast(dist_code >> 4);
        const xoffset: c_int = 8 - @as(c_int, @intCast(dist_code & 0xf));
        const dist: c_int = yoffset * xsize + xoffset;
        return if (dist >= 1) dist else 1; // dist<1 can happen if xsize is very small
    }
}

//------------------------------------------------------------------------------
// Decodes the next Huffman code from bit-stream.
// VP8LFillBitWindow(br) needs to be called at minimum every second call
// to ReadSymbol, in order to pre-fetch enough bits.
inline fn ReadSymbol(table_arg: [*]const webp.HuffmanCode, br: *webp.VP8LBitReader) c_int {
    var val = webp.VP8LPrefetchBits(br);
    var table = table_arg;
    table += val & webp.HUFFMAN_TABLE_MASK;
    const nbits = @as(i32, table[0].bits) - webp.HUFFMAN_TABLE_BITS;
    if (nbits > 0) {
        webp.VP8LSetBitPos(br, br.bit_pos_ + webp.HUFFMAN_TABLE_BITS);
        val = webp.VP8LPrefetchBits(br);
        table += table[0].value;
        table += val & ((@as(u32, 1) << @truncate(@abs(nbits))) - 1);
    }
    webp.VP8LSetBitPos(br, br.bit_pos_ + table[0].bits);
    return table[0].value;
}

// Reads packed symbol depending on GREEN channel
const BITS_SPECIAL_MARKER = 0x100; // something large enough (and a bit-mask)
const PACKED_NON_LITERAL_CODE = 0; // must be < NUM_LITERAL_CODES

inline fn ReadPackedSymbols(group: *const webp.HTreeGroup, br: *webp.VP8LBitReader, dst: [*c]u32) c_int {
    const val = webp.VP8LPrefetchBits(br) & (webp.HUFFMAN_PACKED_TABLE_SIZE - 1);
    const code: webp.HuffmanCode32 = group.packed_table[val];
    assert(group.use_packed_table != 0);
    if (code.bits < BITS_SPECIAL_MARKER) {
        webp.VP8LSetBitPos(br, br.bit_pos_ + code.bits);
        dst.* = code.value;
        return PACKED_NON_LITERAL_CODE;
    } else {
        webp.VP8LSetBitPos(br, br.bit_pos_ + code.bits - BITS_SPECIAL_MARKER);
        assert(code.value >= webp.NUM_LITERAL_CODES);
        return @intCast(code.value);
    }
}

fn AccumulateHCode(hcode: webp.HuffmanCode, shift: c_int, huff: *webp.HuffmanCode32) c_int {
    huff.bits += hcode.bits;
    huff.value |= @as(u32, hcode.value) << @intCast(shift);
    assert(huff.bits <= webp.HUFFMAN_TABLE_BITS);
    return hcode.bits;
}

fn BuildPackedTable(htree_group: *webp.HTreeGroup) void {
    for (0..webp.HUFFMAN_PACKED_TABLE_SIZE) |code| {
        var bits: u32 = @truncate(code);
        const huff: *webp.HuffmanCode32 = &htree_group.packed_table[bits];
        var hcode: webp.HuffmanCode = htree_group.htrees[@intFromEnum(HuffIndex.GREEN)][bits];
        if (hcode.value >= webp.NUM_LITERAL_CODES) {
            huff.bits = @as(c_int, hcode.bits) + BITS_SPECIAL_MARKER;
            huff.value = hcode.value;
        } else {
            huff.bits = 0;
            huff.value = 0;
            bits >>= @intCast(AccumulateHCode(hcode, 8, huff));
            bits >>= @intCast(AccumulateHCode(htree_group.htrees[@intFromEnum(HuffIndex.RED)][bits], 16, huff));
            bits >>= @intCast(AccumulateHCode(htree_group.htrees[@intFromEnum(HuffIndex.BLUE)][bits], 0, huff));
            bits >>= @intCast(AccumulateHCode(htree_group.htrees[@intFromEnum(HuffIndex.ALPHA)][bits], 24, huff));
        }
    }
}

fn ReadHuffmanCodeLengths(dec: *VP8LDecoder, code_length_code_lengths: [*c]const c_int, num_symbols: c_int, code_lengths: [*c]c_int) bool {
    var ok = false;
    const br: *webp.VP8LBitReader = &dec.br_;
    var prev_code_len: c_int = webp.DEFAULT_CODE_LENGTH;
    var tables: webp.HuffmanTables = undefined;

    if (webp.VP8LHuffmanTablesAllocate(1 << webp.LENGTHS_TABLE_BITS, @ptrCast(&tables)) == 0 or
        webp.VP8LBuildHuffmanTable(@ptrCast(&tables), webp.LENGTHS_TABLE_BITS, code_length_code_lengths, NUM_CODE_LENGTH_CODES) == 0)
    {
        webp.VP8LHuffmanTablesDeallocate(@ptrCast(&tables));
        if (!ok) return VP8LSetError(dec, .BitstreamError) != 0;
        return ok;
    }

    var max_symbol: c_int = undefined;
    if (webp.VP8LReadBits(br, 1) != 0) { // use length
        const length_nbits: c_int = @intCast(2 + 2 * webp.VP8LReadBits(br, 3));
        max_symbol = @intCast(2 + webp.VP8LReadBits(br, @intCast(length_nbits)));
        if (max_symbol > num_symbols) {
            webp.VP8LHuffmanTablesDeallocate(@ptrCast(&tables));
            if (!ok) return VP8LSetError(dec, .BitstreamError) != 0;
            return ok;
        }
    } else {
        max_symbol = num_symbols;
    }

    var symbol: c_int = 0;
    while (symbol < num_symbols) {
        if (max_symbol == 0) break;
        max_symbol -= 1;
        webp.VP8LFillBitWindow(br);
        var p: *const webp.HuffmanCode = &tables.curr_segment.?[0].start.?[webp.VP8LPrefetchBits(br) & webp.LENGTHS_TABLE_MASK];
        webp.VP8LSetBitPos(br, br.bit_pos_ + p.bits);
        var code_len: c_int = p.value;
        if (code_len < kCodeLengthLiterals) {
            code_lengths[@intCast(symbol)] = code_len;
            symbol += 1;
            if (code_len != 0) prev_code_len = code_len;
        } else {
            const use_prev = (code_len == kCodeLengthRepeatCode);
            const slot: c_int = code_len - kCodeLengthLiterals;
            const extra_bits: c_int = kCodeLengthExtraBits[@intCast(slot)];
            const repeat_offset: c_int = kCodeLengthRepeatOffsets[@intCast(slot)];
            var repeat: c_int = @as(c_int, @intCast(webp.VP8LReadBits(br, @intCast(extra_bits)))) + repeat_offset;
            if (symbol + repeat > num_symbols) {
                webp.VP8LHuffmanTablesDeallocate(@ptrCast(&tables));
                if (!ok) return VP8LSetError(dec, .BitstreamError) != 0;
                return ok;
            } else {
                const length: c_int = if (use_prev) prev_code_len else 0;
                while (repeat > 0) : ({
                    repeat -= 1;
                    symbol += 1;
                }) code_lengths[@intCast(symbol)] = length;
            }
        }
    }
    ok = true;

    //  End:
    webp.VP8LHuffmanTablesDeallocate(@ptrCast(&tables));
    if (!ok) return VP8LSetError(dec, .BitstreamError) != 0;
    return ok;
}

// 'code_lengths' is pre-allocated temporary buffer, used for creating Huffman
// tree.
fn ReadHuffmanCode(alphabet_size: c_int, dec: *VP8LDecoder, code_lengths: [*c]c_int, table: ?*webp.HuffmanTables) c_int {
    var size: c_int = 0;
    const br = &dec.br_;
    const simple_code = webp.VP8LReadBits(br, 1) != 0;

    @memset(code_lengths[0..@intCast(alphabet_size)], 0);

    var ok = false;
    if (simple_code) { // Read symbols, codes & code lengths directly.
        const num_symbols = webp.VP8LReadBits(br, 1) + 1;
        const first_symbol_len_code = webp.VP8LReadBits(br, 1);
        // The first code is either 1 bit or 8 bit code.
        var symbol = webp.VP8LReadBits(br, if (first_symbol_len_code == 0) 1 else 8);
        code_lengths[symbol] = 1;
        // The second code (if present), is always 8 bits long.
        if (num_symbols == 2) {
            symbol = webp.VP8LReadBits(br, 8);
            code_lengths[symbol] = 1;
        }
        ok = true;
    } else { // Decode Huffman-coded code lengths.
        var code_length_code_lengths = [_]c_int{0} ** NUM_CODE_LENGTH_CODES;
        const num_codes = webp.VP8LReadBits(br, 4) + 4;
        assert(num_codes <= NUM_CODE_LENGTH_CODES);

        for (0..num_codes) |i| {
            code_length_code_lengths[kCodeLengthCodeOrder[i]] = @intCast(webp.VP8LReadBits(br, 3));
        }
        ok = ReadHuffmanCodeLengths(dec, &code_length_code_lengths, alphabet_size, code_lengths);
    }

    ok = ok and br.eos_ == 0;
    if (ok) {
        size = webp.VP8LBuildHuffmanTable(@ptrCast(table), webp.HUFFMAN_TABLE_BITS, code_lengths, alphabet_size);
    }
    if (!ok or size == 0)
        return VP8LSetError(dec, .BitstreamError);

    return size;
}

fn ReadHuffmanCodes(dec: *VP8LDecoder, xsize: c_int, ysize: c_int, color_cache_bits: c_int, allow_recursion: c_int) c_int {
    const br = &dec.br_;
    const hdr = &dec.hdr_;
    var huffman_image: [*c]u32 = null;
    var htree_groups: [*c]webp.HTreeGroup = null;
    var huffman_tables = &hdr.huffman_tables_;
    var num_htree_groups: u32 = 1;
    var num_htree_groups_max: u32 = 1;
    var mapping: [*c]c_int = null;
    var ok = false;

    // Check the table has been 0 initialized (through InitMetadata).
    assert(huffman_tables.root.start == null);
    assert(huffman_tables.curr_segment == null);

    GotoError: {
        if (allow_recursion != 0 and webp.VP8LReadBits(br, 1) != 0) {
            // use meta Huffman codes.
            const huffman_precision = webp.VP8LReadBits(br, 3) + 2;
            const huffman_xsize = webp.VP8LSubSampleSize(@intCast(xsize), huffman_precision);
            const huffman_ysize = webp.VP8LSubSampleSize(@intCast(ysize), huffman_precision);
            const huffman_pixs = huffman_xsize * huffman_ysize;
            if (DecodeImageStream(@intCast(huffman_xsize), @intCast(huffman_ysize), 0, dec, &huffman_image) == 0)
                break :GotoError;

            hdr.huffman_subsample_bits_ = @intCast(huffman_precision);
            for (0..huffman_pixs) |i| {
                // The huffman data is stored in red and green bytes.
                const group = (huffman_image[i] >> 8) & 0xffff;
                huffman_image[i] = group;
                if (group >= num_htree_groups_max) {
                    num_htree_groups_max = group + 1;
                }
            }
            // Check the validity of num_htree_groups_max. If it seems too big, use a
            // smaller value for later. This will prevent big memory allocations to end
            // up with a bad bitstream anyway.
            // The value of 1000 is totally arbitrary. We know that num_htree_groups_max
            // is smaller than (1 << 16) and should be smaller than the number of pixels
            // (though the format allows it to be bigger).
            if (num_htree_groups_max > 1000 or num_htree_groups_max > xsize * ysize) {
                // Create a mapping from the used indices to the minimal set of used
                // values [0, num_htree_groups)
                mapping = @ptrCast(@alignCast(webp.WebPSafeMalloc(num_htree_groups_max, @sizeOf(c_int))));
                if (mapping == null) {
                    _ = VP8LSetError(dec, .OutOfMemory);
                    break :GotoError;
                }

                // -1 means a value is unmapped, and therefore unused in the Huffman
                // image.
                @memset(@as([*c]u8, @ptrCast(@alignCast(mapping)))[0 .. num_htree_groups_max * @sizeOf(c_int)], 0xFF);
                num_htree_groups = 0;
                for (0..huffman_pixs) |i| {
                    // Get the current mapping for the group and remap the Huffman image.
                    const mapped_group: [*c]c_int = &mapping[huffman_image[i]];
                    if (mapped_group[0] == -1) mapped_group[0] = @intCast(num_htree_groups);
                    num_htree_groups += 1;
                    huffman_image[i] = @intCast(mapped_group[0]);
                }
            } else {
                num_htree_groups = num_htree_groups_max;
            }
        }

        if (br.eos_ != 0) break :GotoError;

        if (ReadHuffmanCodesHelper(color_cache_bits, @intCast(num_htree_groups), @intCast(num_htree_groups_max), mapping, dec, huffman_tables, &htree_groups) == 0) {
            break :GotoError;
        }
        ok = true;

        // All OK. Finalize pointers.
        hdr.huffman_image_ = huffman_image;
        hdr.num_htree_groups_ = @intCast(num_htree_groups);
        hdr.htree_groups_ = htree_groups;
    }
    // GotoError:
    webp.WebPSafeFree(mapping);
    if (!ok) {
        webp.WebPSafeFree(huffman_image);
        webp.VP8LHuffmanTablesDeallocate(@ptrCast(huffman_tables));
        webp.VP8LHtreeGroupsFree(@ptrCast(htree_groups));
    }
    return @intFromBool(ok);
}

pub fn ReadHuffmanCodesHelper(color_cache_bits: c_int, num_htree_groups: c_int, num_htree_groups_max: c_int, mapping: [*c]const c_int, dec: *VP8LDecoder, huffman_tables: *webp.HuffmanTables, htree_groups: [*c][*c]webp.HTreeGroup) c_int {
    var ok = false;
    const max_alphabet_size = kAlphabetSize[0] + (if (color_cache_bits > 0) @as(u16, 1) << @intCast(color_cache_bits) else 0);
    const table_size = kTableSize[@intCast(color_cache_bits)];
    var code_lengths: [*c]c_int = null;

    GotoError: {
        if ((mapping == null and num_htree_groups != num_htree_groups_max) or
            num_htree_groups > num_htree_groups_max)
        {
            break :GotoError;
        }

        code_lengths = @ptrCast(@alignCast(webp.WebPSafeCalloc(@intCast(max_alphabet_size), @sizeOf(c_int))));
        htree_groups.* = @ptrCast(webp.VP8LHtreeGroupsNew(num_htree_groups));

        if (htree_groups.* == null or code_lengths == null or
            webp.VP8LHuffmanTablesAllocate(num_htree_groups * table_size, @ptrCast(huffman_tables)) == 0)
        {
            _ = VP8LSetError(dec, .OutOfMemory);
            break :GotoError;
        }

        for (0..if (num_htree_groups_max > 0) @abs(num_htree_groups_max) else 0) |i| {
            // If the index "i" is unused in the Huffman image, just make sure the
            // coefficients are valid but do not store them.
            if (mapping != null and mapping[i] == -1) {
                for (0..webp.HUFFMAN_CODES_PER_META_CODE) |j| {
                    var alphabet_size: u32 = kAlphabetSize[j];
                    if (j == 0 and color_cache_bits > 0) {
                        alphabet_size += (@as(u32, 1) << @intCast(color_cache_bits));
                    }
                    // Passing in NULL so that nothing gets filled.
                    if (ReadHuffmanCode(@intCast(alphabet_size), dec, code_lengths, null) == 0) {
                        break :GotoError;
                    }
                }
            } else {
                const htree_group: *webp.HTreeGroup = @ptrCast(&(htree_groups.*[if (mapping == null) i else @intCast(mapping[i])]));
                const htrees: [*c][*c]webp.HuffmanCode = &htree_group.htrees;
                var is_trivial_literal = true;
                var total_size: u32 = 0;
                var max_bits: c_int = 0;
                for (0..webp.HUFFMAN_CODES_PER_META_CODE) |j| {
                    var alphabet_size: u32 = kAlphabetSize[j];
                    if (j == 0 and color_cache_bits > 0) {
                        alphabet_size += (@as(u32, 1) << @intCast(color_cache_bits));
                    }
                    const size = ReadHuffmanCode(@intCast(alphabet_size), dec, code_lengths, huffman_tables);
                    htrees[j] = huffman_tables.curr_segment.?[0].curr_table;
                    if (size == 0) break :GotoError;

                    if (is_trivial_literal and kLiteralMap[j] == 1) {
                        is_trivial_literal = (htrees[j].*.bits == 0);
                    }
                    total_size += htrees[j].*.bits;
                    huffman_tables.curr_segment.?[0].curr_table = webp.offsetPtr(huffman_tables.curr_segment.?[0].curr_table.?, size);
                    if (j <= @intFromEnum(HuffIndex.ALPHA)) {
                        var local_max_bits = code_lengths[0];
                        for (1..alphabet_size) |k| {
                            if (code_lengths[k] > local_max_bits) {
                                local_max_bits = code_lengths[k];
                            }
                        }
                        max_bits += local_max_bits;
                    }
                }
                htree_group.is_trivial_literal = @intFromBool(is_trivial_literal);
                htree_group.is_trivial_code = 0;
                if (is_trivial_literal) {
                    const red: u32 = htrees[@intFromEnum(HuffIndex.RED)][0].value;
                    const blue: u32 = htrees[@intFromEnum(HuffIndex.BLUE)][0].value;
                    const alpha: u32 = htrees[@intFromEnum(HuffIndex.ALPHA)][0].value;
                    htree_group.literal_arb = (alpha << 24) | (red << 16) | blue;
                    if (total_size == 0 and htrees[@intFromEnum(HuffIndex.GREEN)][0].value < webp.NUM_LITERAL_CODES) {
                        htree_group.is_trivial_code = 1;
                        htree_group.literal_arb |= @as(u32, htrees[@intFromEnum(HuffIndex.GREEN)][0].value) << 8;
                    }
                }
                htree_group.use_packed_table =
                    @intFromBool(htree_group.is_trivial_code == 0 and (max_bits < webp.HUFFMAN_PACKED_BITS));
                if (htree_group.use_packed_table != 0) BuildPackedTable(htree_group);
            }
        }
        ok = true;
    }

    //  GotoError:
    webp.WebPSafeFree(code_lengths);
    if (!ok) {
        webp.VP8LHuffmanTablesDeallocate(@ptrCast(huffman_tables));
        webp.VP8LHtreeGroupsFree(@ptrCast(htree_groups.*));
        htree_groups.* = null;
    }
    return @intFromBool(ok);
}

//------------------------------------------------------------------------------
// Scaling.

fn AllocateAndInitRescaler(dec: *VP8LDecoder, io: *webp.VP8Io) c_int {
    const num_channels: c_int = 4;
    const in_width: c_int = io.mb_w;
    const out_width: c_int = io.scaled_width;
    const in_height: c_int = io.mb_h;
    const out_height: c_int = io.scaled_height;
    const work_size: u64 = @intCast(2 * num_channels * out_width);
    var work: [*c]webp.rescaler_t = undefined; // Rescaler work area.
    const scaled_data_size: u64 = @intCast(out_width);
    var scaled_data: [*c]u32 = undefined; // Temporary storage for scaled BGRA data.
    const memory_size: u64 = @sizeOf(@TypeOf(dec.rescaler.?.*)) +
        work_size * @sizeOf(@TypeOf(work.*)) +
        scaled_data_size * @sizeOf(@TypeOf(scaled_data.*));
    var memory: [*c]u8 = @ptrCast(@alignCast(webp.WebPSafeMalloc(memory_size, @sizeOf(u8))));
    if (memory == null) {
        return VP8LSetError(dec, .OutOfMemory);
    }
    assert(dec.rescaler_memory == null);
    dec.rescaler_memory = memory;

    dec.rescaler = @ptrCast(@alignCast(memory));
    memory += @sizeOf(@TypeOf(dec.rescaler.?.*));
    work = @ptrCast(@alignCast(memory));
    memory += work_size * @sizeOf(@TypeOf(work.*));
    scaled_data = @ptrCast(@alignCast(memory));

    if (webp.WebPRescalerInit(@ptrCast(dec.rescaler), in_width, in_height, @ptrCast(scaled_data), out_width, out_height, 0, num_channels, @ptrCast(work)) == 0) {
        return 0;
    }
    return 1;
}

//------------------------------------------------------------------------------
// Export to ARGB

// #if !defined(WEBP_REDUCE_SIZE)

// We have special "export" function since we need to convert from BGRA
fn Export(rescaler: *webp.WebPRescaler, colorspace: CspMode, rgba_stride: c_int, rgba: [*c]u8) c_int {
    const src: [*c]u32 = @ptrCast(@alignCast(rescaler.dst));
    var dst = rgba;
    const dst_width: c_int = rescaler.dst_width;
    var num_lines_out: c_int = 0;
    while (webp.WebPRescalerHasPendingOutput(@ptrCast(rescaler))) {
        webp.WebPRescalerExportRow(@ptrCast(rescaler));
        webp.WebPMultARGBRow.?(src, dst_width, 1);
        webp.VP8LConvertFromBGRA(src, dst_width, colorspace, dst);
        dst = webp.offsetPtr(dst, rgba_stride);
        num_lines_out += 1;
    }
    return num_lines_out;
}

// Emit scaled rows.
fn EmitRescaledRowsRGBA(dec: *const VP8LDecoder, in: [*c]u8, in_stride: c_int, mb_h: c_int, out: [*c]u8, out_stride: c_int) c_int {
    const colorspace = dec.output_.?.colorspace;
    var num_lines_in: c_int = 0;
    var num_lines_out: c_int = 0;
    while (num_lines_in < mb_h) {
        const row_in: [*c]u8 = in + @as(u64, @intCast(num_lines_in)) * @as(u64, @intCast(in_stride));
        const row_out: [*c]u8 = out + @as(u64, @intCast(num_lines_out)) * @as(u64, @intCast(out_stride));
        const lines_left: c_int = mb_h - num_lines_in;
        const needed_lines: c_int = webp.WebPRescaleNeededLines(@ptrCast(dec.rescaler), lines_left);

        assert(needed_lines > 0 and needed_lines <= lines_left);
        webp.WebPMultARGBRows(row_in, in_stride, dec.rescaler.?.src_width, needed_lines, 0);
        const lines_imported =
            webp.WebPRescalerImport(@ptrCast(dec.rescaler), lines_left, row_in, in_stride);
        assert(lines_imported == needed_lines);
        num_lines_in += lines_imported;
        num_lines_out += Export(@ptrCast(dec.rescaler), colorspace, out_stride, row_out);
    }
    return num_lines_out;
}

// #endif   // WEBP_REDUCE_SIZE

// Emit rows without any scaling.
fn EmitRows(colorspace: CspMode, row_in_arg: [*c]const u8, in_stride: c_int, mb_w: c_int, mb_h: c_int, out: [*c]u8, out_stride: c_int) c_int {
    var row_in = row_in_arg;
    var row_out = out;
    var lines = mb_h;
    while (lines > 0) : (lines -= 1) {
        webp.VP8LConvertFromBGRA(@ptrCast(@alignCast(row_in)), mb_w, colorspace, row_out);
        row_in = webp.offsetPtr(row_in, in_stride);
        row_out = webp.offsetPtr(row_out, out_stride);
    }
    return mb_h; // Num rows out == num rows in.
}

//------------------------------------------------------------------------------
// Export to YUVA

fn ConvertToYUVA(src: [*c]const u32, width: c_int, y_pos: c_int, output: *const webp.DecBuffer) void {
    const buf: *const webp.YUVABuffer = &output.u.YUVA;

    // first, the luma plane
    webp.WebPConvertARGBToY.?(src, webp.offsetPtr(buf.y, y_pos * buf.y_stride), width);

    // then U/V planes
    {
        const u = webp.offsetPtr(buf.u, (y_pos >> 1) * buf.u_stride);
        const v = webp.offsetPtr(buf.v, (y_pos >> 1) * buf.v_stride);
        // even lines: store values
        // odd lines: average with previous values
        webp.WebPConvertARGBToUV.?(src, u, v, width, @intFromBool(y_pos & 1 == 0));
    }
    // Lastly, store alpha if needed.
    if (buf.a != null) {
        const a = webp.offsetPtr(buf.a, y_pos * buf.a_stride);
        if (BIG_ENDIAN)
            _ = webp.WebPExtractAlpha.?(@as([*c]const u8, @ptrCast(src)) + 0, 0, width, 1, a, 0)
        else
            _ = webp.WebPExtractAlpha.?(@as([*c]const u8, @ptrCast(src)) + 3, 0, width, 1, a, 0);
    }
}

fn ExportYUVA(dec: *const VP8LDecoder, y_pos_arg: c_int) c_int {
    const rescaler: *webp.WebPRescaler = dec.rescaler.?;
    const src: [*c]u32 = @ptrCast(@alignCast(rescaler.dst));
    const dst_width = rescaler.dst_width;
    var num_lines_out: c_int = 0;
    var y_pos = y_pos_arg;
    while (webp.WebPRescalerHasPendingOutput(@ptrCast(rescaler))) {
        webp.WebPRescalerExportRow(@ptrCast(rescaler));
        webp.WebPMultARGBRow.?(src, dst_width, 1);
        ConvertToYUVA(src, dst_width, y_pos, dec.output_.?);
        y_pos += 1;
        num_lines_out += 1;
    }
    return num_lines_out;
}

fn EmitRescaledRowsYUVA(dec: *const VP8LDecoder, in_arg: [*c]u8, in_stride: c_int, mb_h: c_int) c_int {
    var num_lines_in: c_int = 0;
    var y_pos: c_int = dec.last_out_row_;
    var in = in_arg;
    while (num_lines_in < mb_h) {
        const lines_left: c_int = mb_h - num_lines_in;
        const needed_lines = webp.WebPRescaleNeededLines(@ptrCast(dec.rescaler), lines_left);
        webp.WebPMultARGBRows(in, in_stride, dec.rescaler.?.src_width, needed_lines, 0);
        var lines_imported: c_int = webp.WebPRescalerImport(@ptrCast(dec.rescaler), lines_left, in, in_stride);
        assert(lines_imported == needed_lines);
        num_lines_in += lines_imported;
        in = webp.offsetPtr(in, needed_lines * in_stride);
        y_pos += ExportYUVA(dec, y_pos);
    }
    return y_pos;
}

fn EmitRowsYUVA(dec: *const VP8LDecoder, in_arg: [*c]const u8, in_stride: c_int, mb_w: c_int, num_rows_arg: c_int) c_int {
    var y_pos: c_int = dec.last_out_row_;
    var in = in_arg;
    var num_rows = num_rows_arg;
    while (num_rows > 0) : (num_rows -= 1) {
        ConvertToYUVA(@ptrCast(@alignCast(in)), mb_w, y_pos, dec.output_.?);
        in = webp.offsetPtr(in, in_stride);
        y_pos += 1;
    }
    return y_pos;
}

//------------------------------------------------------------------------------
// Cropping.

// Sets io->mb_y, io->mb_h & io->mb_w according to start row, end row and
// crop options. Also updates the input data pointer, so that it points to the
// start of the cropped window. Note that pixels are in ARGB format even if
// 'in_data' is uint8_t*.
// Returns true if the crop window is not empty.
fn SetCropWindow(io: *webp.VP8Io, y_start_arg: c_int, y_end_arg: c_int, in_data: [*c][*c]u8, pixel_stride: c_int) c_bool {
    var y_end, var y_start = .{ y_end_arg, y_start_arg };
    assert(y_start < y_end);
    assert(io.crop_left < io.crop_right);
    if (y_end > io.crop_bottom) {
        y_end = io.crop_bottom; // make sure we don't overflow on last row.
    }
    if (y_start < io.crop_top) {
        const delta: c_int = io.crop_top - y_start;
        y_start = io.crop_top;
        in_data.* = webp.offsetPtr(in_data.*, delta * pixel_stride);
    }
    if (y_start >= y_end) return 0; // Crop window is empty.

    in_data.* = webp.offsetPtr(in_data.*, io.crop_left * @sizeOf(u32));

    io.mb_y = y_start - io.crop_top;
    io.mb_w = io.crop_right - io.crop_left;
    io.mb_h = y_end - y_start;
    return 1; // Non-empty crop window.
}

//------------------------------------------------------------------------------

inline fn GetMetaIndex(image: [*c]const u32, xsize: c_int, bits: c_int, x: c_int, y: c_int) c_int {
    if (bits == 0) return 0;
    return @intCast(webp.offsetPtr(image, xsize * (y >> @intCast(bits)) + (x >> @intCast(bits))).*);
}

inline fn GetHtreeGroupForPos(hdr: *VP8LMetadata, x: c_int, y: c_int) [*c]webp.HTreeGroup {
    const meta_index = GetMetaIndex(hdr.huffman_image_, hdr.huffman_xsize_, hdr.huffman_subsample_bits_, x, y);
    assert(meta_index < hdr.num_htree_groups_);
    return webp.offsetPtr(hdr.htree_groups_, meta_index);
}

//------------------------------------------------------------------------------
// Main loop, with custom row-processing function

const ProcessRowsFunc = ?*const fn (dec: ?*VP8LDecoder, row: c_int) callconv(.C) void;

fn ApplyInverseTransforms(dec: *VP8LDecoder, start_row: c_int, num_rows: c_int, rows: [*c]const u32) void {
    var n = dec.next_transform_;
    const cache_pixs: usize = @intCast(dec.width_ * num_rows);
    const end_row = start_row + num_rows;
    var rows_in = rows;
    const rows_out = dec.argb_cache_;

    // Inverse transforms.
    while (n > 0) {
        n -= 1;
        const transform = &dec.transforms_[@abs(n)];
        webp.VP8LInverseTransform(@ptrCast(transform), start_row, end_row, rows_in, rows_out);
        rows_in = rows_out;
    }

    if (@intFromPtr(rows_in) != @intFromPtr(rows_out)) {
        // No transform called, hence just copy.
        @memcpy(rows_out[0..cache_pixs], rows_in[0..cache_pixs]);
    }
}

fn ProcessRows(dec: *VP8LDecoder, row: c_int) void {
    const rows: [*c]const u32 = webp.offsetPtr(dec.pixels_, dec.width_ * dec.last_row_);
    const num_rows = row - dec.last_row_;

    assert(row <= dec.io_.?.crop_bottom);
    // We can't process more than NUM_ARGB_CACHE_ROWS at a time (that's the size
    // of argb_cache_), but we currently don't need more than that.
    assert(num_rows <= NUM_ARGB_CACHE_ROWS);
    if (num_rows > 0) { // Emit output.
        const io = dec.io_.?;
        var rows_data: [*c]u8 = @ptrCast(dec.argb_cache_);
        const in_stride: c_int = io.width * @as(c_int, @intCast(@sizeOf(u32))); // in unit of RGBA
        ApplyInverseTransforms(dec, dec.last_row_, num_rows, rows);
        if (SetCropWindow(io, dec.last_row_, row, &rows_data, in_stride) == 0) {
            // Nothing to output (this time).
        } else {
            const output = dec.output_;
            if (output.?.colorspace.isRGBMode()) { // convert to RGBA
                const buf: *const webp.RGBABuffer = &output.?.u.RGBA;
                const rgba: [*c]u8 = webp.offsetPtr(buf.rgba, @as(i64, dec.last_out_row_) * buf.stride);
                const num_rows_out = if (!build_options.reduce_size and io.use_scaling != 0)
                    EmitRescaledRowsRGBA(dec, rows_data, in_stride, io.mb_h, rgba, buf.stride)
                else
                    EmitRows(output.?.colorspace, rows_data, in_stride, io.mb_w, io.mb_h, rgba, buf.stride);
                // Update 'last_out_row_'.
                dec.last_out_row_ += num_rows_out;
            } else { // convert to YUVA
                dec.last_out_row_ = if (io.use_scaling != 0)
                    EmitRescaledRowsYUVA(dec, rows_data, in_stride, io.mb_h)
                else
                    EmitRowsYUVA(dec, rows_data, in_stride, io.mb_w, io.mb_h);
            }
            assert(dec.last_out_row_ <= output.?.height);
        }
    }

    // Update 'last_row_'.
    dec.last_row_ = row;
    assert(dec.last_row_ <= dec.height_);
}

fn Is8bOptimizable(hdr: *const VP8LMetadata) bool {
    if (hdr.color_cache_size_ > 0) return false;
    // When the Huffman tree contains only one symbol, we can skip the
    // call to ReadSymbol() for red/blue/alpha channels.
    const num_htree_groups_: usize = if (hdr.num_htree_groups_ > 0) @abs(hdr.num_htree_groups_) else 0;
    for (hdr.htree_groups_[0..num_htree_groups_]) |group| {
        const htrees = &group.htrees;
        if (htrees[@intFromEnum(HuffIndex.RED)][0].bits > 0) return false;
        if (htrees[@intFromEnum(HuffIndex.BLUE)][0].bits > 0) return false;
        if (htrees[@intFromEnum(HuffIndex.ALPHA)][0].bits > 0) return false;
    }
    return true;
}

fn AlphaApplyFilter(alph_dec: *webp.ALPHDecoder, first_row: c_int, last_row: c_int, out_arg: [*c]u8, stride: c_int) void {
    if (alph_dec.filter_ == .NONE) return;
    var out = out_arg;
    var prev_line: [*c]const u8 = alph_dec.prev_line_;
    assert(webp.WebPUnfilters[@intFromEnum(alph_dec.filter_)] != null);
    var y: c_int = first_row;
    while (y < last_row) : (y += 1) {
        webp.WebPUnfilters[@intFromEnum(alph_dec.filter_)].?(prev_line, out, out, stride);
        prev_line = out;
        out = webp.offsetPtr(out, stride);
    }
    alph_dec.prev_line_ = prev_line;
}

fn ExtractPalettedAlphaRows(dec: *VP8LDecoder, last_row: c_int) void {
    // For vertical and gradient filtering, we need to decode the part above the
    // crop_top row, in order to have the correct spatial predictors.
    const alph_dec: *webp.ALPHDecoder = @ptrCast(@alignCast(dec.io_.?.@"opaque".?));
    const top_row: c_int = if (alph_dec.filter_ == .NONE or alph_dec.filter_ == .HORIZONTAL) dec.io_.?.crop_top else dec.last_row_;
    const first_row = if (dec.last_row_ < top_row) top_row else dec.last_row_;
    assert(last_row <= dec.io_.?.crop_bottom);
    if (last_row > first_row) {
        // Special method for paletted alpha data. We only process the cropped area.
        const width = dec.io_.?.width;
        var out: [*c]u8 = webp.offsetPtr(alph_dec.output_, width * first_row);
        const in = webp.offsetPtr(@as([*c]const u8, @ptrCast(dec.pixels_)), dec.width_ * first_row);
        const transform = &dec.transforms_[0];
        assert(dec.next_transform_ == 1);
        assert(transform.*.type_ == .COLOR_INDEXING_TRANSFORM);
        webp.VP8LColorIndexInverseTransformAlpha(@ptrCast(transform), first_row, last_row, in, out);
        AlphaApplyFilter(alph_dec, first_row, last_row, out, width);
    }
    dec.last_row_, dec.last_out_row_ = .{ last_row, last_row };
}

//------------------------------------------------------------------------------
// Helper functions for fast pattern copy (8b and 32b)

// cyclic rotation of pattern word
inline fn Rotate8b(V: u32) u32 {
    return if (BIG_ENDIAN)
        ((V & 0xff000000) >> 24) | (V << 8)
    else
        ((V & 0xff) << 24) | (V >> 8);
}

// copy 1, 2 or 4-bytes pattern
inline fn CopySmallPattern8b(src_arg: [*]const u8, dst_arg: [*]u8, length_arg: c_int, pattern_arg: u32) void {
    var src, var dst, var length, var pattern = .{ src_arg, dst_arg, length_arg, pattern_arg };
    var i: usize = 0;
    // align 'dst' to 4-bytes boundary. Adjust the pattern along the way.
    while (@intFromPtr(dst) & 3 != 0) {
        dst[0] = src[0];
        dst += 1;
        src += 1;
        pattern = Rotate8b(pattern);
        length -= 1;
    }
    // Copy the pattern 4 bytes at a time.
    while (i < (length >> 2)) : (i += 1) {
        @as([*c]u32, @ptrCast(@alignCast(dst)))[i] = pattern;
    }
    // Finish with left-overs. 'pattern' is still correctly positioned,
    // so no Rotate8b() call is needed.
    i <<= 2;
    while (i < length) : (i += 1) {
        dst[i] = src[i];
    }
}

inline fn CopyBlock8b(dst: [*]u8, dist: c_int, length: c_int) void {
    var src: [*c]const u8 = webp.offsetPtr(dst, -dist);
    if (length >= 8) {
        var pattern: u32 = 0;
        switch (dist) {
            1 => {
                pattern = src[0];
                if (ARM_OR_THUMB) { // arm doesn't like multiply that much
                    pattern |= pattern << 8;
                    pattern |= pattern << 16;
                } else if (MIPS_DSP_R2) {
                    asm volatile (
                        \\replv.qb $0, $0
                        : [pattern] "+r" (pattern),
                    );
                } else {
                    pattern = 0x01010101 * pattern;
                }
            },
            2 => {
                if (!BIG_ENDIAN) {
                    pattern = @as(u16, @bitCast(src[0..2].*));
                } else {
                    pattern = @as(u32, src[0]) << 8 | src[1];
                }

                if (ARM_OR_THUMB) {
                    pattern |= pattern << 16;
                } else if (MIPS_DSP_R2) {
                    asm volatile (
                        \\replv.ph $0, $0
                        : [pattern] "+r" (pattern),
                    );
                } else {
                    pattern = 0x00010001 * pattern;
                }
            },
            4 => {
                pattern = @bitCast(src[0..4].*);
            },
            else => {
                if (dist >= length) { // no overlap -> use memcpy()
                    const l = @abs(length);
                    @memcpy(dst[0..l], src[0..l]);
                } else {
                    for (0..@abs(length)) |i| dst[i] = src[i];
                }
                return;
            },
        }
        CopySmallPattern8b(src, dst, length, pattern);
        return;
    }
    // Copy:
    if (dist >= length) { // no overlap -> use memcpy()
        const l = @abs(length);
        @memcpy(dst[0..l], src[0..l]);
    } else {
        for (0..@abs(length)) |i| dst[i] = src[i];
    }
}

// copy pattern of 1 or 2 uint32_t's
inline fn CopySmallPattern32b(src_arg: [*]const u32, dst_arg: [*]u32, length_arg: c_int, pattern_arg: u64) void {
    var src, var dst, var length, var pattern = .{ src_arg, dst_arg, length_arg, pattern_arg };
    var i: usize = 0;
    if (@intFromPtr(dst) & 4 != 0) { // Align 'dst' to 8-bytes boundary.
        dst[0] = src[0];
        dst += 1;
        src += 1;
        pattern = (pattern >> 32) | (pattern << 32);
        length -= 1;
    }
    assert(0 == (@intFromPtr(dst) & 7));
    while (i < (length >> 1)) : (i += 1) {
        @as([*c]u64, @ptrCast(@alignCast(dst)))[i] = pattern; // Copy the pattern 8 bytes at a time.
    }
    if (length & 1 != 0) { // Finish with left-over.
        dst[i << 1] = src[i << 1];
    }
}

inline fn CopyBlock32b(dst: [*c]u32, dist: c_int, length: c_int) void {
    const src: [*c]const u32 = webp.offsetPtr(dst, -dist);
    if (dist <= 2 and length >= 4 and (@intFromPtr(dst) & 3) == 0) {
        var pattern: u64 = undefined;
        if (dist == 1) {
            pattern = src[0];
            pattern |= pattern << 32;
        } else {
            pattern = @bitCast(src[0..2].*);
        }
        CopySmallPattern32b(src, dst, length, pattern);
    } else if (dist >= length) { // no overlap
        const l = @abs(length);
        @memcpy(dst[0..l], src[0..l]);
    } else {
        for (0..@abs(length)) |i| dst[i] = src[i];
    }
}

//------------------------------------------------------------------------------

fn DecodeAlphaData(dec: *VP8LDecoder, data: [*c]u8, width: c_int, height: c_int, last_row: c_int) c_int {
    var ok = true;
    var row: c_int = @divTrunc(dec.last_pixel_, width);
    var col: c_int = @mod(dec.last_pixel_, width);
    const br = &dec.br_;
    const hdr = &dec.hdr_;
    var pos = dec.last_pixel_; // current position
    const end = width * height; // End of data
    const last = width * last_row; // Last pixel to decode
    const len_code_limit = webp.NUM_LITERAL_CODES + webp.NUM_LENGTH_CODES;
    const mask = hdr.huffman_mask_;
    var htree_group: [*c]const webp.HTreeGroup = if (pos < last) GetHtreeGroupForPos(hdr, col, row) else null;
    assert(pos <= end);
    assert(last_row <= height);
    assert(Is8bOptimizable(hdr));

    GotoEnd: {
        while (br.eos_ == 0 and pos < last) {
            // Only update when changing tile.
            if ((col & mask) == 0) {
                htree_group = GetHtreeGroupForPos(hdr, col, row);
            }
            assert(htree_group != null);
            webp.VP8LFillBitWindow(br);
            var code = ReadSymbol(htree_group.*.htrees[@intFromEnum(HuffIndex.GREEN)], br);
            if (code < webp.NUM_LITERAL_CODES) { // Literal
                data[@intCast(pos)] = @intCast(code);
                pos += 1;
                col += 1;
                if (col >= width) {
                    col = 0;
                    row += 1;
                    if (row <= last_row and (@mod(row, NUM_ARGB_CACHE_ROWS) == 0))
                        ExtractPalettedAlphaRows(dec, row);
                }
            } else if (code < len_code_limit) { // Backward reference
                const length_sym = code - webp.NUM_LITERAL_CODES;
                const length = GetCopyLength(length_sym, br);
                const dist_symbol = ReadSymbol(htree_group.*.htrees[@intFromEnum(HuffIndex.DIST)], br);
                webp.VP8LFillBitWindow(br);
                var dist_code = GetCopyDistance(dist_symbol, br);
                var dist = PlaneCodeToDistance(width, dist_code);
                if (pos >= dist and end - pos >= length) {
                    CopyBlock8b(webp.offsetPtr(data, pos), dist, length);
                } else {
                    ok = false;
                    break :GotoEnd;
                }
                pos += length;
                col += length;
                while (col >= width) {
                    col -= width;
                    row += 1;
                    if (row <= last_row and (@mod(row, NUM_ARGB_CACHE_ROWS) == 0))
                        ExtractPalettedAlphaRows(dec, row);
                }
                if (pos < last and (col & mask != 0)) {
                    htree_group = GetHtreeGroupForPos(hdr, col, row);
                }
            } else { // Not reached
                ok = false;
                break :GotoEnd;
            }
            br.eos_ = @intFromBool(webp.VP8LIsEndOfStream(br));
        }
        // Process the remaining rows corresponding to last row-block.
        ExtractPalettedAlphaRows(dec, if (row > last_row) last_row else row);
    }
    // End:
    br.eos_ = @intFromBool(webp.VP8LIsEndOfStream(br));
    if (!ok or (br.eos_ != 0 and pos < end)) {
        return VP8LSetError(dec, if (br.eos_ != 0) .Suspended else .BitstreamError);
    }
    dec.last_pixel_ = pos;
    return @intFromBool(ok);
}

fn SaveState(dec: *VP8LDecoder, last_pixel: c_int) void {
    assert(dec.incremental_ != 0);
    dec.saved_br_ = dec.br_;
    dec.saved_last_pixel_ = last_pixel;
    if (dec.hdr_.color_cache_size_ > 0) {
        webp.VP8LColorCacheCopy(@ptrCast(&dec.hdr_.color_cache_), @ptrCast(&dec.hdr_.saved_color_cache_));
    }
}

fn RestoreState(dec: *VP8LDecoder) void {
    assert(dec.br_.eos_ != 0);
    dec.status_ = .Suspended;
    dec.br_ = dec.saved_br_;
    dec.last_pixel_ = dec.saved_last_pixel_;
    if (dec.hdr_.color_cache_size_ > 0) {
        webp.VP8LColorCacheCopy(@ptrCast(&dec.hdr_.saved_color_cache_), @ptrCast(&dec.hdr_.color_cache_));
    }
}

const SYNC_EVERY_N_ROWS = 8;

fn DecodeImageData(dec: *VP8LDecoder, data: [*c]u32, width: c_int, height: c_int, last_row: c_int, process_func: ProcessRowsFunc) callconv(.C) c_int {
    var row: c_int = @divTrunc(dec.last_pixel_, width);
    var col: c_int = @mod(dec.last_pixel_, width);
    const br = &dec.br_;
    const hdr = &dec.hdr_;
    var src: [*c]u32 = webp.offsetPtr(data, dec.last_pixel_);
    var last_cached: [*c]u32 = src;
    const src_end: [*c]u32 = webp.offsetPtr(data, width * height); // End of data
    const src_last: [*c]u32 = webp.offsetPtr(data, width * last_row); // Last pixel to decode
    const len_code_limit: c_int = webp.NUM_LITERAL_CODES + webp.NUM_LENGTH_CODES;
    const color_cache_limit: c_int = len_code_limit + hdr.color_cache_size_;
    var next_sync_row: c_int = if (dec.incremental_ != 0) row else 1 << 24;
    const color_cache: ?*webp.VP8LColorCache = if (hdr.color_cache_size_ > 0) &hdr.color_cache_ else null;
    const mask: c_int = hdr.huffman_mask_;
    var htree_group: [*c]const webp.HTreeGroup = if (src < src_last) GetHtreeGroupForPos(hdr, col, row) else null;
    assert(dec.last_row_ < last_row);
    assert(src_last <= src_end);

    while (src < src_last) {
        var code: c_int = undefined;
        if (row >= next_sync_row) {
            SaveState(dec, @intCast(webp.diffPtr(src, data)));
            next_sync_row = row + SYNC_EVERY_N_ROWS;
        }
        // Only update when changing tile. Note we could use this test:
        // if "((((prev_col ^ col) | prev_row ^ row)) > mask)" -> tile changed
        // but that's actually slower and needs storing the previous col/row.
        if ((col & mask) == 0) {
            htree_group = GetHtreeGroupForPos(hdr, col, row);
        }
        assert(htree_group != null);
        if (htree_group.*.is_trivial_code != 0) {
            src[0] = htree_group.*.literal_arb;
            // goto AdvanceByOne;
            {
                src += 1;
                col += 1;
                if (col >= width) {
                    col = 0;
                    row += 1;
                    if (process_func) |func| {
                        if (row <= last_row and (@mod(row, NUM_ARGB_CACHE_ROWS) == 0)) func(dec, row);
                    }
                    if (color_cache) |cc| {
                        while (last_cached < src) {
                            webp.VP8LColorCacheInsert(@ptrCast(cc), last_cached[0]);
                            last_cached += 1;
                        }
                    }
                }
                continue;
            }
        }
        webp.VP8LFillBitWindow(br);
        if (htree_group.*.use_packed_table != 0) {
            code = ReadPackedSymbols(htree_group, br, src);
            if (webp.VP8LIsEndOfStream(br)) break;
            if (code == PACKED_NON_LITERAL_CODE) { // goto AdvanceByOne;
                src += 1;
                col += 1;
                if (col >= width) {
                    col = 0;
                    row += 1;
                    if (process_func) |func| {
                        if (row <= last_row and (@mod(row, NUM_ARGB_CACHE_ROWS) == 0)) func(dec, row);
                    }
                    if (color_cache) |cc| {
                        while (last_cached < src) {
                            webp.VP8LColorCacheInsert(@ptrCast(cc), last_cached[0]);
                            last_cached += 1;
                        }
                    }
                }
                continue;
            }
        } else {
            code = ReadSymbol(htree_group.*.htrees[@intFromEnum(HuffIndex.GREEN)], br);
        }
        if (webp.VP8LIsEndOfStream(br)) break;
        if (code < webp.NUM_LITERAL_CODES) { // Literal
            if (htree_group.*.is_trivial_literal != 0) {
                src.* = htree_group.*.literal_arb | (@as(u32, @intCast(code)) << 8);
            } else {
                const red: u32 = @intCast(ReadSymbol(htree_group.*.htrees[@intFromEnum(HuffIndex.RED)], br));
                webp.VP8LFillBitWindow(br);
                const blue: u32 = @intCast(ReadSymbol(htree_group.*.htrees[@intFromEnum(HuffIndex.BLUE)], br));
                const alpha: u32 = @intCast(ReadSymbol(htree_group.*.htrees[@intFromEnum(HuffIndex.ALPHA)], br));
                if (webp.VP8LIsEndOfStream(br)) break;
                src[0] = alpha << 24 | red << 16 | @as(u32, @intCast(code)) << 8 | blue;
            }
            // AdvanceByOne:
            {
                src += 1;
                col += 1;
                if (col >= width) {
                    col = 0;
                    row += 1;
                    if (process_func) |func| {
                        if (row <= last_row and (@mod(row, NUM_ARGB_CACHE_ROWS) == 0)) func(dec, row);
                    }
                    if (color_cache) |cc| {
                        while (last_cached < src) {
                            webp.VP8LColorCacheInsert(@ptrCast(cc), last_cached[0]);
                            last_cached += 1;
                        }
                    }
                }
                continue;
            }
        } else if (code < len_code_limit) { // Backward reference
            const length_sym: c_int = code - webp.NUM_LITERAL_CODES;
            const length: c_int = GetCopyLength(length_sym, br);
            const dist_symbol = ReadSymbol(htree_group.*.htrees[@intFromEnum(HuffIndex.DIST)], br);
            webp.VP8LFillBitWindow(br);
            const dist_code = GetCopyDistance(dist_symbol, br);
            const dist = PlaneCodeToDistance(width, dist_code);

            if (webp.VP8LIsEndOfStream(br)) break;
            if (webp.diffPtr(src, data) < dist or webp.diffPtr(src_end, src) < length) {
                return VP8LSetError(dec, .BitstreamError);
            } else {
                CopyBlock32b(src, dist, length);
            }
            src = webp.offsetPtr(src, length);
            col += length;
            while (col >= width) {
                col -= width;
                row += 1;
                if (process_func) |func| {
                    if (row <= last_row and (@mod(row, NUM_ARGB_CACHE_ROWS) == 0)) func(dec, row);
                }
            }
            // Because of the check done above (before 'src' was incremented by
            // 'length'), the following holds true.
            assert(src <= src_end);
            if (col & mask != 0) htree_group = GetHtreeGroupForPos(hdr, col, row);
            if (color_cache != null) {
                while (last_cached < src) {
                    webp.VP8LColorCacheInsert(@ptrCast(color_cache), last_cached[0]);
                    last_cached += 1;
                }
            }
        } else if (code < color_cache_limit) { // Color cache
            const key = code - len_code_limit;
            assert(color_cache != null);
            while (last_cached < src) {
                webp.VP8LColorCacheInsert(@ptrCast(color_cache), last_cached[0]);
                last_cached += 1;
            }
            src.* = webp.VP8LColorCacheLookup(@ptrCast(color_cache), @intCast(key));
            // goto AdvanceByOne;
            {
                src += 1;
                col += 1;
                if (col >= width) {
                    col = 0;
                    row += 1;
                    if (process_func) |func| {
                        if (row <= last_row and (@mod(row, NUM_ARGB_CACHE_ROWS) == 0)) func(dec, row);
                    }
                    if (color_cache) |cc| {
                        while (last_cached < src) {
                            webp.VP8LColorCacheInsert(@ptrCast(cc), last_cached[0]);
                            last_cached += 1;
                        }
                    }
                }
            }
        } else { // Not reached
            return VP8LSetError(dec, .BitstreamError);
        }
    }

    br.eos_ = @intFromBool(webp.VP8LIsEndOfStream(br));
    // In incremental decoding:
    // br->eos_ && src < src_last: if 'br' reached the end of the buffer and
    // 'src_last' has not been reached yet, there is not enough data. 'dec' has to
    // be reset until there is more data.
    // !br->eos_ && src < src_last: this cannot happen as either the buffer is
    // fully read, either enough has been read to reach 'src_last'.
    // src >= src_last: 'src_last' is reached, all is fine. 'src' can actually go
    // beyond 'src_last' in case the image is cropped and an LZ77 goes further.
    // The buffer might have been enough or there is some left. 'br->eos_' does
    // not matter.
    assert(dec.incremental_ == 0 or (br.eos_ != 0 and src < src_last) or src >= src_last);
    if (dec.incremental_ != 0 and br.eos_ != 0 and src < src_last) {
        RestoreState(dec);
    } else if ((dec.incremental_ != 0 and src >= src_last) or br.eos_ == 0) {
        // Process the remaining rows corresponding to last row-block.
        if (process_func) |func| func(dec, if (row > last_row) last_row else row);
        dec.status_ = .Ok;
        dec.last_pixel_ = @intCast(webp.diffPtr(src, data)); // end-of-scan marker
    } else {
        // if not incremental, and we are past the end of buffer (eos_=1), then this
        // is a real bitstream error.
        return VP8LSetError(dec, .BitstreamError);
    }
    return 1;
}

// -----------------------------------------------------------------------------
// VP8LTransform

fn ClearTransform(transform: *VP8LTransform) void {
    webp.WebPSafeFree(transform.data_);
    transform.data_ = null;
}

// For security reason, we need to remap the color map to span
// the total possible bundled values, and not just the num_colors.
fn ExpandColorMap(num_colors: c_int, transform: *VP8LTransform) c_int {
    const final_num_colors: c_int = @as(c_int, 1) << @truncate(@as(u32, 8) >> @intCast(transform.bits_));
    const new_color_map: [*c]u32 = @ptrCast(@alignCast(webp.WebPSafeMalloc(@intCast(final_num_colors), @sizeOf(u32)) orelse return 0));

    const data: [*c]u8 = @ptrCast(transform.data_);
    const new_data: [*c]u8 = @ptrCast(new_color_map);
    new_color_map[0] = transform.data_[0];
    var i: usize = 4;
    while (i < 4 * num_colors) : (i += 1) {
        // Equivalent to VP8LAddPixels(), on a byte-basis.
        new_data[i] = (data[i] +% new_data[i - 4]) & 0xff;
    }
    while (i < 4 * final_num_colors) : (i += 1) {
        new_data[i] = 0; // black tail.
    }
    webp.WebPSafeFree(transform.data_);
    transform.data_ = new_color_map;
    return 1;
}

fn ReadTransform(xsize: *c_int, ysize: *c_int, dec: *VP8LDecoder) c_int {
    var ok: c_int = 1;
    const br = &dec.br_;
    var transform = &dec.transforms_[@intCast(dec.next_transform_)];
    const @"type": webp.VP8LImageTransformType = @enumFromInt(webp.VP8LReadBits(br, 2));

    // Each transform type can only be present once in the stream.
    if (dec.transforms_seen_ & (@as(u32, 1) << @truncate(@intFromEnum(@"type"))) != 0) {
        return 0; // Already there, let's not accept the second same transform.
    }
    dec.transforms_seen_ |= (@as(u32, 1) << @truncate(@intFromEnum(@"type")));

    transform.type_ = @"type";
    transform.xsize_ = xsize.*;
    transform.ysize_ = ysize.*;
    transform.data_ = null;
    dec.next_transform_ += 1;
    assert(dec.next_transform_ <= webp.NUM_TRANSFORMS);

    switch (@"type") {
        .PREDICTOR_TRANSFORM, .CROSS_COLOR_TRANSFORM => {
            transform.bits_ = @intCast(webp.VP8LReadBits(br, 3) + 2);
            ok = DecodeImageStream(
                @bitCast(webp.VP8LSubSampleSize(@bitCast(transform.xsize_), @bitCast(transform.bits_))),
                @bitCast(webp.VP8LSubSampleSize(@bitCast(transform.ysize_), @bitCast(transform.bits_))),
                0,
                @ptrCast(dec),
                &transform.data_,
            );
        },
        .COLOR_INDEXING_TRANSFORM => {
            const num_colors = webp.VP8LReadBits(br, 8) + 1;
            const bits: u32 = if (num_colors > 16) 0 else if (num_colors > 4) 1 else if (num_colors > 2) 2 else 3;
            xsize.* = @bitCast(webp.VP8LSubSampleSize(@bitCast(transform.xsize_), bits));
            transform.bits_ = @intCast(bits);
            ok = DecodeImageStream(@intCast(num_colors), 1, 0, @ptrCast(dec), &transform.data_);
            if (ok != 0 and ExpandColorMap(@intCast(num_colors), transform) == 0) {
                return VP8LSetError(dec, .OutOfMemory);
            }
        },
        .SUBTRACT_GREEN_TRANSFORM => {},
    }

    return ok;
}

// -----------------------------------------------------------------------------
// VP8LMetadata

fn InitMetadata(hdr: *VP8LMetadata) void {
    hdr.* = std.mem.zeroes(VP8LMetadata);
}

fn ClearMetadata(hdr: *VP8LMetadata) void {
    webp.WebPSafeFree(hdr.huffman_image_);
    webp.VP8LHuffmanTablesDeallocate(@ptrCast(&hdr.huffman_tables_));
    webp.VP8LHtreeGroupsFree(@ptrCast(hdr.htree_groups_));
    webp.VP8LColorCacheClear(@ptrCast(&hdr.color_cache_));
    webp.VP8LColorCacheClear(@ptrCast(&hdr.saved_color_cache_));
    InitMetadata(hdr);
}

// -----------------------------------------------------------------------------
// VP8LDecoder

pub fn VP8LNew() ?*VP8LDecoder {
    const dec: *VP8LDecoder = @ptrCast(@alignCast(webp.WebPSafeCalloc(1, @sizeOf(VP8LDecoder)) orelse return null));
    dec.status_ = .Ok;
    dec.state_ = .READ_DIM;

    webp.VP8LDspInit(); // Init critical function pointers.

    return dec;
}

pub fn VP8LClear(dec_arg: ?*VP8LDecoder) void {
    const dec = dec_arg orelse return;
    ClearMetadata(&dec.hdr_);

    webp.WebPSafeFree(dec.pixels_);
    dec.pixels_ = null;
    for (0..@abs(dec.next_transform_)) |i| {
        ClearTransform(&dec.transforms_[i]);
    }
    dec.next_transform_ = 0;
    dec.transforms_seen_ = 0;

    webp.WebPSafeFree(dec.rescaler_memory);
    dec.rescaler_memory = null;

    dec.output_ = null; // leave no trace behind
}

pub fn VP8LDelete(dec: ?*VP8LDecoder) void {
    if (dec) |d| {
        VP8LClear(d);
        webp.WebPSafeFree(d);
    }
}

fn UpdateDecoder(dec: *VP8LDecoder, width: c_int, height: c_int) void {
    const hdr: *VP8LMetadata = &dec.hdr_;
    const num_bits = hdr.huffman_subsample_bits_;
    dec.width_ = width;
    dec.height_ = height;

    hdr.huffman_xsize_ = @intCast(webp.VP8LSubSampleSize(@intCast(width), @intCast(num_bits)));
    hdr.huffman_mask_ = if (num_bits == 0) ~@as(c_int, 0) else (@as(c_int, 1) << @intCast(num_bits)) - 1;
}

fn DecodeImageStream(xsize: c_int, ysize: c_int, is_level0: c_int, dec: *VP8LDecoder, decoded_data: [*c][*c]u32) c_int {
    var ok = true;
    var transform_xsize: c_int = xsize;
    var transform_ysize: c_int = ysize;
    const br = &dec.br_;
    const hdr = &dec.hdr_;
    var data: [*c]u32 = null;
    var color_cache_bits: c_int = 0;

    // Read the transforms (may recurse).
    if (is_level0 != 0) {
        while (ok and webp.VP8LReadBits(br, 1) != 0)
            ok = ReadTransform(&transform_xsize, &transform_ysize, dec) != 0;
    }

    blk: {
        // Color cache
        if (ok and webp.VP8LReadBits(br, 1) != 0) {
            color_cache_bits = @intCast(webp.VP8LReadBits(br, 4));
            ok = (color_cache_bits >= 1 and color_cache_bits <= webp.MAX_CACHE_BITS);
            if (!ok) {
                _ = VP8LSetError(dec, .BitstreamError);
                break :blk;
            }
        }

        // Read the Huffman codes (may recurse).
        ok = ok and ReadHuffmanCodes(dec, transform_xsize, transform_ysize, color_cache_bits, is_level0) != 0;
        if (!ok) {
            _ = VP8LSetError(dec, .BitstreamError);
            break :blk;
        }

        // Finish setting up the color-cache
        if (color_cache_bits > 0) {
            hdr.color_cache_size_ = @as(c_int, 1) << @intCast(color_cache_bits);
            if (webp.VP8LColorCacheInit(@ptrCast(&hdr.color_cache_), color_cache_bits) == 0) {
                ok = VP8LSetError(dec, .OutOfMemory) != 0;
                break :blk;
            }
        } else {
            hdr.color_cache_size_ = 0;
        }
        UpdateDecoder(dec, transform_xsize, transform_ysize);

        if (is_level0 != 0) { // level 0 complete
            dec.state_ = .READ_HDR;
            break :blk;
        }

        {
            const total_size: u64 = @as(u64, @intCast(transform_xsize)) * @as(u64, @intCast(transform_ysize));
            data = @ptrCast(@alignCast(webp.WebPSafeMalloc(total_size, @sizeOf(u32))));
            if (data == null) {
                ok = VP8LSetError(dec, .OutOfMemory) != 0;
                break :blk;
            }
        }

        // Use the Huffman trees to decode the LZ77 encoded data.
        ok = DecodeImageData(dec, data, transform_xsize, transform_ysize, transform_ysize, null) != 0;
        ok = ok and br.eos_ == 0;
    }
    // End:
    {
        if (!ok) {
            webp.WebPSafeFree(data);
            ClearMetadata(hdr);
        } else {
            if (decoded_data != null) {
                decoded_data.* = data;
            } else {
                // We allocate image data in this function only for transforms. At level 0
                // (that is: not the transforms), we shouldn't have allocated anything.
                assert(data == null);
                assert(is_level0 != 0);
            }
            dec.last_pixel_ = 0; // Reset for future DECODE_DATA_FUNC() calls.
            if (is_level0 == 0) ClearMetadata(hdr); // Clean up temporary data behind.
        }
    }
    return @intFromBool(ok);
}

//------------------------------------------------------------------------------

// Allocate internal buffers dec->pixels_ and dec->argb_cache_.
fn AllocateInternalBuffers32b(dec: *VP8LDecoder, final_width: c_int) c_int {
    const num_pixels: u64 = @as(u64, @intCast(dec.width_)) * @as(u64, @intCast(dec.height_));
    // Scratch buffer corresponding to top-prediction row for transforming the
    // first row in the row-blocks. Not needed for paletted alpha.
    const cache_top_pixels: u16 = @intCast(final_width);
    // Scratch buffer for temporary BGRA storage. Not needed for paletted alpha.
    const cache_pixels: u64 = @as(u64, @intCast(final_width)) * NUM_ARGB_CACHE_ROWS;
    const total_num_pixels: u64 = num_pixels + @as(u64, cache_top_pixels) + cache_pixels;

    assert(dec.width_ <= final_width);
    dec.pixels_ = @ptrCast(@alignCast(webp.WebPSafeMalloc(total_num_pixels, @sizeOf(u32))));
    if (dec.pixels_ == null) {
        dec.argb_cache_ = null; // for soundness
        return VP8LSetError(dec, .OutOfMemory);
    }
    dec.argb_cache_ = dec.pixels_ + num_pixels + cache_top_pixels;
    return 1;
}

fn AllocateInternalBuffers8b(dec: *VP8LDecoder) c_int {
    const total_num_pixels: u64 = @as(u64, @intCast(dec.width_)) * @as(u64, @intCast(dec.height_));
    dec.argb_cache_ = null; // for soundness
    dec.pixels_ = @ptrCast(@alignCast(webp.WebPSafeMalloc(total_num_pixels, @sizeOf(u8))));
    if (dec.pixels_ == null) return VP8LSetError(dec, .OutOfMemory);
    return 1;
}

//------------------------------------------------------------------------------

// Special row-processing that only stores the alpha data.
fn ExtractAlphaRows(dec: *VP8LDecoder, last_row: c_int) callconv(.C) void {
    var cur_row = dec.last_row_;
    var num_rows = last_row - cur_row;
    var in: [*c]const u32 = webp.offsetPtr(dec.pixels_, dec.width_ * cur_row);
    assert(last_row <= dec.io_.?.crop_bottom);
    while (num_rows > 0) {
        const num_rows_to_process: c_int = if (num_rows > NUM_ARGB_CACHE_ROWS) NUM_ARGB_CACHE_ROWS else num_rows;
        // Extract alpha (which is stored in the green plane).
        const alph_dec: *webp.ALPHDecoder = @ptrCast(@alignCast(dec.io_.?.@"opaque".?));
        const output = alph_dec.output_;
        const width = dec.io_.?.width; // the final width (!= dec.width_)
        const cache_pixs = width * num_rows_to_process;
        const dst = webp.offsetPtr(output, width * cur_row);
        const src = dec.argb_cache_;
        ApplyInverseTransforms(dec, cur_row, num_rows_to_process, in);
        webp.WebPExtractGreen.?(src, dst, cache_pixs);
        AlphaApplyFilter(alph_dec, cur_row, cur_row + num_rows_to_process, dst, width);
        num_rows -= num_rows_to_process;
        in = webp.offsetPtr(in, num_rows_to_process * dec.width_);
        cur_row += num_rows_to_process;
    }
    assert(cur_row == last_row);
    dec.last_row_, dec.last_out_row_ = .{ last_row, last_row };
}

pub fn VP8LDecodeAlphaHeader(alph_dec: *webp.ALPHDecoder, data: [*c]const u8, data_size: usize) c_bool {
    var dec = VP8LNew() orelse return 0;

    dec.width_ = alph_dec.width_;
    dec.height_ = alph_dec.height_;
    dec.io_ = &alph_dec.io_;
    dec.io_.?.@"opaque" = alph_dec;
    dec.io_.?.width = alph_dec.width_;
    dec.io_.?.height = alph_dec.height_;

    dec.status_ = .Ok;
    webp.VP8LInitBitReader(&dec.br_, data, data_size);

    GotoErr: {
        if (DecodeImageStream(alph_dec.width_, alph_dec.height_, 1, dec, null) == 0) break :GotoErr;

        // Special case: if alpha data uses only the color indexing transform and
        // doesn't use color cache (a frequent case), we will use DecodeAlphaData()
        // method that only needs allocation of 1 byte per pixel (alpha channel).
        var ok = false;
        if (dec.next_transform_ == 1 and
            dec.transforms_[0].type_ == .COLOR_INDEXING_TRANSFORM and
            Is8bOptimizable(&dec.hdr_))
        {
            alph_dec.use_8b_decode_ = 1;
            ok = AllocateInternalBuffers8b(dec) != 0;
        } else {
            // Allocate internal buffers (note that dec->width_ may have changed here).
            alph_dec.use_8b_decode_ = 0;
            ok = AllocateInternalBuffers32b(dec, alph_dec.width_) != 0;
        }
        if (!ok) break :GotoErr;

        // Only set here, once we are sure it is valid (to avoid thread races).
        alph_dec.vp8l_dec_ = @ptrCast(dec);
        return 1;
    }

    VP8LDelete(dec);
    return 0;
}

pub fn VP8LDecodeAlphaImageStream(alph_dec: *webp.ALPHDecoder, last_row: c_int) c_int {
    const dec: *VP8LDecoder = @ptrCast(alph_dec.vp8l_dec_.?);
    assert(last_row <= dec.height_);

    if (dec.last_row_ >= last_row) return 1; // done

    if (!(alph_dec.use_8b_decode_ != 0)) webp.WebPInitAlphaProcessing();

    // Decode (with special row processing).
    return if (alph_dec.use_8b_decode_ != 0)
        DecodeAlphaData(dec, @ptrCast(dec.pixels_), dec.width_, dec.height_, last_row)
    else
        DecodeImageData(dec, dec.pixels_, dec.width_, dec.height_, last_row, @ptrCast(&ExtractAlphaRows));
}

//------------------------------------------------------------------------------

pub fn VP8LDecodeHeader(dec_arg: ?*VP8LDecoder, io_arg: ?*webp.VP8Io) c_int {
    const dec = dec_arg orelse return 0;
    const io = io_arg orelse return VP8LSetError(dec, .InvalidParam);

    dec.io_ = io;
    dec.status_ = .Ok;
    webp.VP8LInitBitReader(&dec.br_, io.data, io.data_size);
    GotoError: {
        var width: c_int = undefined;
        var height: c_int = undefined;
        var has_alpha: bool = undefined;
        if (!ReadImageInfo(&dec.br_, &width, &height, &has_alpha)) {
            _ = VP8LSetError(dec, .BitstreamError);
            break :GotoError;
        }
        dec.state_ = .READ_DIM;
        io.width = width;
        io.height = height;

        if (DecodeImageStream(width, height, 1, dec, null) == 0) {
            break :GotoError;
        }
        return 1;
    }
    // GotoError:
    VP8LClear(dec);
    assert(dec.status_ != .Ok);
    return 0;
}

pub fn VP8LDecodeImage(dec_arg: ?*VP8LDecoder) c_int {
    const dec = dec_arg orelse return 0;

    assert(dec.hdr_.huffman_tables_.root.start != null);
    assert(dec.hdr_.htree_groups_ != null);
    assert(dec.hdr_.num_htree_groups_ > 0);

    var io = dec.io_.?;
    var params: *webp.DecParams = @ptrCast(@alignCast(io.@"opaque".?));

    GotoErr: {
        // Initialization.
        if (dec.state_ != .READ_DATA) {
            dec.output_ = params.output;
            assert(dec.output_ != null);

            if (webp.WebPIoInitFromOptions(params.options, io, .BGRA) == 0) {
                _ = VP8LSetError(dec, .InvalidParam);
                break :GotoErr;
            }

            if (AllocateInternalBuffers32b(dec, io.width) == 0) break :GotoErr;

            if (comptime !build_options.reduce_size) {
                if (io.use_scaling != 0 and AllocateAndInitRescaler(dec, io) == 0) break :GotoErr;
            } else {
                if (io.use_scaling != 0) {
                    _ = VP8LSetError(dec, .InvalidParam);
                    break :GotoErr;
                }
            }
            if (io.use_scaling != 0 or dec.output_.?.colorspace.isPremultipliedMode()) {
                // need the alpha-multiply functions for premultiplied output or rescaling
                webp.WebPInitAlphaProcessing();
            }

            if (!dec.output_.?.colorspace.isRGBMode()) {
                webp.WebPInitConvertARGBToYUV();
                if (dec.output_.?.u.YUVA.a != null) webp.WebPInitAlphaProcessing();
            }
            if (dec.incremental_ != 0) {
                if (dec.hdr_.color_cache_size_ > 0 and dec.hdr_.saved_color_cache_.colors_ == null) {
                    if (webp.VP8LColorCacheInit(@ptrCast(&dec.hdr_.saved_color_cache_), dec.hdr_.color_cache_.hash_bits_) == 0) {
                        _ = VP8LSetError(dec, .OutOfMemory);
                        break :GotoErr;
                    }
                }
            }
            dec.state_ = .READ_DATA;
        }

        // Decode.
        if (DecodeImageData(dec, dec.pixels_, dec.width_, dec.height_, io.crop_bottom, @ptrCast(&ProcessRows)) == 0)
            break :GotoErr;

        params.last_y = dec.last_out_row_;
        return 1;
    }

    // GotoErr:
    VP8LClear(dec);
    assert(dec.status_ != .Ok);
    return 0;
}

//------------------------------------------------------------------------------
