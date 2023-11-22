const c = @cImport({
    @cInclude("src/utils/rescaler_utils.h");
});
const webp = struct {
    pub usingnamespace @import("vp8_dec.zig");
    pub usingnamespace @import("../webp/decode.zig");
    pub usingnamespace @import("../webp/format_constants.zig");
    pub usingnamespace @import("../utils/bit_reader_utils.zig");
    pub usingnamespace @import("../utils/color_cache_utils.zig");
    pub usingnamespace @import("../utils/huffman_utils.zig");
    pub usingnamespace @import("../utils/utils.zig");
};

const c_bool = webp.c_bool;
const VP8Status = webp.VP8Status;
const VP8Error = webp.VP8Error;
const CspMode = webp.ColorspaceMode;

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
    rescaler: ?*c.WebPRescaler,
};
