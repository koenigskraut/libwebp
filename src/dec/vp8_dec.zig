const std = @import("std");
const c = @cImport({
    @cInclude("src/utils/random_utils.h");
    @cInclude("src/utils/thread_utils.h");
});
const webp = struct {
    usingnamespace @import("alpha_dec.zig");
    usingnamespace @import("common_dec.zig");
    usingnamespace @import("../utils/bit_reader_utils.zig");
    usingnamespace @import("../utils/utils.zig");
    usingnamespace @import("../webp/decode.zig");
};

const c_bool = webp.c_bool;

pub const VP8Io = extern struct {
    pub const VP8IoPutHook = ?*const fn ([*c]const @This()) callconv(.C) c_int;
    pub const VP8IoSetupHook = ?*const fn ([*c]@This()) callconv(.C) c_int;
    pub const VP8IoTeardownHook = ?*const fn ([*c]const @This()) callconv(.C) void;

    // set by VP8GetHeaders()
    /// picture dimensions, in pixels (invariable).
    /// These are the original, uncropped dimensions.
    /// The actual area passed to put() is stored
    /// in mb_w / mb_h fields.
    width: c_int,
    height: c_int,

    // set before calling put()
    /// position of the current rows (in pixels)
    mb_y: c_int,
    /// number of columns in the sample
    mb_w: c_int,
    /// number of rows in the sample
    mb_h: c_int,
    // rows to copy (in yuv420 format)
    y: [*c]const u8,
    u: [*c]const u8,
    v: [*c]const u8,
    /// row stride for luma
    y_stride: c_int,
    /// row stride for chroma
    uv_stride: c_int,

    /// user data
    @"opaque": ?*anyopaque,

    /// called when fresh samples are available. Currently, samples are in
    /// YUV420 format, and can be up to width x 24 in size (depending on the
    /// in-loop filtering level, e.g.). Should return false in case of error
    /// or abort request. The actual size of the area to update is mb_w x mb_h
    /// in size, taking cropping into account.
    put: VP8IoPutHook,

    /// called just before starting to decode the blocks.
    /// Must return false in case of setup error, true otherwise. If false is
    /// returned, teardown() will NOT be called. But if the setup succeeded
    /// and true is returned, then teardown() will always be called afterward.
    setup: VP8IoSetupHook,

    /// Called just after block decoding is finished (or when an error occurred
    /// during put()). Is NOT called if setup() failed.
    teardown: VP8IoTeardownHook,

    /// this is a recommendation for the user-side yuv->rgb converter. This flag
    /// is set when calling setup() hook and can be overwritten by it. It then
    /// can be taken into consideration during the put() method.
    fancy_upsampling: c_bool,

    // Input buffer.
    data_size: usize,
    data: [*c]const u8,

    /// If true, in-loop filtering will not be performed even if present in the
    /// bitstream. Switching off filtering may speed up decoding at the expense
    /// of more visible blocking. Note that output will also be non-compliant
    /// with the VP8 specifications.
    bypass_filtering: c_int,

    // Cropping parameters.
    use_cropping: c_bool,
    crop_left: c_int,
    crop_right: c_int,
    crop_top: c_int,
    crop_bottom: c_int,

    // Scaling parameters.
    use_scaling: c_bool,
    scaled_width: c_int,
    scaled_height: c_int,

    /// If non `null`, pointer to the alpha data (if present) corresponding to the
    /// start of the current row (That is: it is pre-offset by mb_y and takes
    /// cropping into account).
    a: ?[*]const u8,
};

// Must be called to make sure 'io' is initialized properly.
// Returns false in case of version mismatch. Upon such failure, no other
// decoding function should be called (VP8Decode, VP8GetHeaders, ...)
pub inline fn VP8InitIo(io: ?*VP8Io) bool {
    return VP8InitIoInternal(io, webp.DECODER_ABI_VERSION);
}

// Internal, version-checked, entry point
pub fn VP8InitIoInternal(io: ?*VP8Io, version: c_int) bool { // export
    if (c.WEBP_ABI_IS_INCOMPATIBLE(version, webp.DECODER_ABI_VERSION)) {
        return false; // mismatch error
    }
    if (io) |io_ptr| io_ptr.* = std.mem.zeroes(VP8Io);
    return true;
}

pub const VP8FrameHeader = extern struct {
    key_frame_: u8,
    profile_: u8,
    show_: u8,
    partition_length_: u32,
};

pub const VP8PictureHeader = extern struct {
    width_: u16,
    height_: u16,
    xscale_: u8,
    yscale_: u8,
    colorspace_: u8, // 0 = YCbCr
    clamp_type_: u8,
};

/// segment features
pub const VP8SegmentHeader = extern struct {
    use_segment_: c_int,
    update_map_: c_int, // whether to update the segment map or not
    absolute_delta_: c_int, // absolute or delta values for quantizer and filter
    quantizer_: [webp.NUM_MB_SEGMENTS]i8, // quantization changes
    filter_strength_: [webp.NUM_MB_SEGMENTS]i8, // filter strength for segments
};

/// probas associated to one of the contexts
pub const VP8ProbaArray = [webp.NUM_PROBAS]u8;

pub const VP8BandProbas = extern struct {
    /// all the probas associated to one band
    probas_: [webp.NUM_CTX]VP8ProbaArray,
};

// Struct collecting all frame-persistent probabilities.
pub const VP8Proba = extern struct {
    segments_: [webp.MB_FEATURE_TREE_PROBS]u8,
    // Type: 0:Intra16-AC  1:Intra16-DC   2:Chroma   3:Intra4
    bands_: [webp.NUM_TYPES][webp.NUM_BANDS]VP8BandProbas,
    bands_ptr_: [webp.NUM_TYPES][16 + 1][*c]const VP8BandProbas,
};

/// Filter parameters
pub const VP8FilterHeader = extern struct {
    /// 0=complex, 1=simple
    simple_: c_bool,
    /// [0..63]
    level_: c_int,
    /// [0..7]
    sharpness_: c_int,
    use_lf_delta_: c_int,
    ref_lf_delta_: [webp.NUM_REF_LF_DELTAS]c_int,
    mode_lf_delta_: [webp.NUM_MODE_LF_DELTAS]c_int,
};

/// filter specs
pub const VP8FInfo = extern struct {
    /// filter limit in [3..189], or 0 if no filtering
    f_limit_: u8,
    /// inner limit in [1..63]
    f_ilevel_: u8,
    /// do inner filtering?
    f_inner_: u8,
    /// high edge variance threshold in [0..2]
    hev_thresh_: u8,
};

/// Top/Left Contexts used for syntax-parsing
pub const VP8MB = extern struct {
    /// non-zero AC/DC coeffs (4bit for luma + 4bit for chroma)
    nz_: u8,
    /// non-zero DC coeff (1bit)
    nz_dc_: u8,
};

/// Dequantization matrices
pub const quant_t = [2]c_int; // [DC / AC].  Can be 'uint16_t[2]' too (~slower).
pub const VP8QuantMatrix = extern struct {
    y1_mat_: quant_t,
    y2_mat_: quant_t,
    uv_mat_: quant_t,
    /// U/V quantizer value
    uv_quant_: c_int,
    /// dithering amplitude (0 = off, max=255)
    dither_: c_int,
};

/// Data needed to reconstruct a macroblock
pub const VP8MBData = extern struct {
    /// 384 coeffs = (16+4+4) * 4*4
    coeffs_: [384]i16,
    /// true if intra4x4
    is_i4x4_: u8,
    /// one 16x16 mode (#0) or sixteen 4x4 modes
    imodes_: [16]u8,
    /// chroma prediction mode
    uvmode_: u8,
    // bit-wise info about the content of each sub-4x4 blocks (in decoding order).
    // Each of the 4x4 blocks for y/u/v is associated with a 2b code according to:
    //   code=0 -> no coefficient
    //   code=1 -> only DC
    //   code=2 -> first three coefficients are non-zero
    //   code=3 -> more than three coefficients are non-zero
    // This allows to call specialized transform functions.
    non_zero_y_: u32,
    non_zero_uv_: u32,
    /// local dithering strength (deduced from non_zero_*)
    dither_: u8,
    skip_: u8,
    segment_: u8,
};

/// Persistent information needed by the parallel processing
pub const VP8ThreadContext = extern struct {
    /// cache row to process (in [0..2])
    id_: c_int,
    /// macroblock position of the row
    mb_y_: c_int,
    /// true if row-filtering is needed
    filter_row_: c_bool,
    /// filter strengths (swapped with dec->f_info_)
    f_info_: [*c]VP8FInfo,
    /// reconstruction data (swapped with dec->mb_data_)
    mb_data_: [*c]VP8MBData,
    /// copy of the VP8Io to pass to put()
    io_: VP8Io,
};

/// Saved top samples, per macroblock. Fits into a cache-line.
pub const VP8TopSamples = extern struct {
    y: [16]u8,
    u: [8]u8,
    v: [8]u8,
};

pub const VP8Decoder = extern struct {
    status_: webp.VP8Status,
    /// true if ready to decode a picture with VP8Decode()
    ready_: c_bool,
    /// set when status_ is not OK.
    error_msg_: ?[*]const u8,

    // Main data source
    br_: webp.VP8BitReader,
    /// if true, incremental decoding is expected
    incremental_: c_bool,

    // headers
    frm_hdr_: VP8FrameHeader,
    pic_hdr_: VP8PictureHeader,
    filter_hdr_: VP8FilterHeader,
    segment_hdr_: VP8SegmentHeader,

    /// Worker
    worker_: c.WebPWorker,
    /// multi-thread method:
    /// - 0 = off
    /// - 1 = [parse+recon][filter]
    /// - 2 = [parse][recon+filter]
    mt_method_: c_int,
    /// current cache row
    cache_id_: c_int,
    /// number of cached rows of 16 pixels (1, 2 or 3)
    num_caches_: c_int,
    /// Thread context
    thread_ctx_: VP8ThreadContext,

    // dimension, in macroblock units.
    mb_w_: c_int,
    mb_h_: c_int,

    // Macroblock to process/filter, depending on cropping and filter_type.
    tl_mb_x_: c_int, // top-left MB that must be in-loop filtered
    tl_mb_y_: c_int,
    br_mb_x_: c_int, // last bottom-right MB that must be decoded
    br_mb_y_: c_int,

    /// number of partitions minus one.
    num_parts_minus_one_: u32,
    /// per-partition boolean decoders.
    parts_: [webp.MAX_NUM_PARTITIONS]webp.VP8BitReader,

    // Dithering strength, deduced from decoding options
    /// whether to use dithering or not
    dither_: c_int,
    /// random generator for dithering
    dithering_rg_: c.VP8Random,

    /// dequantization (one set of DC/AC dequant factor per segment)
    dqm_: [webp.NUM_MB_SEGMENTS]VP8QuantMatrix,

    // probabilities
    proba_: VP8Proba,
    use_skip_proba_: c_bool,
    skip_p_: u8,

    // Boundary data cache and persistent buffers.
    /// top intra modes values: 4 * mb_w_
    intra_t_: [*c]u8,
    /// left intra modes values
    intra_l_: [4]u8,

    /// top y/u/v samples
    yuv_t_: [*c]VP8TopSamples,

    /// contextual macroblock info (mb_w_ + 1)
    mb_info_: [*c]VP8MB,
    /// filter strength info
    f_info_: [*c]VP8FInfo,
    /// main block for Y/U/V (size = YUV_SIZE)
    yuv_b_: [*c]u8,

    cache_y_: [*c]u8, // macroblock row for storing unfiltered samples
    cache_u_: [*c]u8,
    cache_v_: [*c]u8,
    cache_y_stride_: c_bool,
    cache_uv_stride_: c_bool,

    /// main memory chunk for the above data. Persistent.
    mem_: ?*anyopaque,
    mem_size_: usize,

    // Per macroblock non-persistent infos.
    mb_x_: c_int, // current position, in macroblock units
    mb_y_: c_int,
    mb_data_: [*c]VP8MBData, // parsed reconstruction data

    // Filtering side-info
    ///0=off, 1=simple, 2=complex
    filter_type_: c_int,
    /// precalculated per-segment/type
    fstrengths_: [webp.NUM_MB_SEGMENTS][2]VP8FInfo,

    // Alpha
    /// alpha-plane decoder object
    alph_dec_: ?*webp.ALPHDecoder,
    /// compressed alpha data (if present)
    alpha_data_: [*c]const u8,
    alpha_data_size_: usize,
    /// true if alpha_data_ is decoded in alpha_plane_
    is_alpha_decoded_: c_bool,
    /// memory allocated for alpha_plane_
    alpha_plane_mem_: [*c]u8,
    /// output. Persistent, contains the whole data.
    alpha_plane_: [*c]u8,
    /// last decoded alpha row (or NULL)
    alpha_prev_line_: [*c]const u8,
    /// derived from decoding options (0=off, 100=full)
    alpha_dithering_: c_int,
};
