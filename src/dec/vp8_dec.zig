const std = @import("std");
const webp = struct {
    usingnamespace @import("alpha_dec.zig");
    usingnamespace @import("common_dec.zig");
    usingnamespace @import("frame_dec.zig");
    usingnamespace @import("tree_dec.zig");
    usingnamespace @import("quant_dec.zig");
    usingnamespace @import("../dsp/cpu.zig");
    usingnamespace @import("../dsp/dsp.zig");
    usingnamespace @import("../utils/bit_reader_utils.zig");
    usingnamespace @import("../utils/random_utils.zig");
    usingnamespace @import("../utils/thread_utils.zig");
    usingnamespace @import("../utils/utils.zig");
    usingnamespace @import("../webp/decode.zig");
    usingnamespace @import("../webp/format_constants.zig");
};

const assert = std.debug.assert;
const c_bool = webp.c_bool;

//------------------------------------------------------------------------------
// Various defines and enums

// version numbers
const DEC_MAJ_VERSION = 1;
const DEC_MIN_VERSION = 3;
const DEC_REV_VERSION = 2;

pub export fn WebPGetDecoderVersion() c_int {
    return (DEC_MAJ_VERSION << 16) | (DEC_MIN_VERSION << 8) | DEC_REV_VERSION;
}

// YUV-cache parameters. Cache is 32-bytes wide (= one cacheline).
// Constraints are: We need to store one 16x16 block of luma samples (y),
// and two 8x8 chroma blocks (u/v). These are better be 16-bytes aligned,
// in order to be SIMD-friendly. We also need to store the top, left and
// top-left samples (from previously decoded blocks), along with four
// extra top-right samples for luma (intra4x4 prediction only).
// One possible layout is, using 32 * (17 + 9) bytes:
//
//   .+------   <- only 1 pixel high
//   .|yyyyt.
//   .|yyyyt.
//   .|yyyyt.
//   .|yyyy..
//   .+--.+--   <- only 1 pixel high
//   .|uu.|vv
//   .|uu.|vv
//
// Every character is a 4x4 block, with legend:
//  '.' = unused
//  'y' = y-samples   'u' = u-samples     'v' = u-samples
//  '|' = left sample,   '-' = top sample,    '+' = top-left sample
//  't' = extra top-right sample for 4x4 modes
pub const YUV_SIZE = (webp.BPS * 17 + webp.BPS * 9);
pub const Y_OFF = (webp.BPS * 1 + 8);
pub const U_OFF = (Y_OFF + webp.BPS * 16 + webp.BPS);
pub const V_OFF = (U_OFF + 16);

/// minimal width under which lossy multi-threading is always disabled
pub const MIN_WIDTH_FOR_THREADS = 512;

//------------------------------------------------------------------------------
// Headers

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
    use_segment_: c_int, // c_bool
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
    use_lf_delta_: c_bool,
    ref_lf_delta_: [webp.NUM_REF_LF_DELTAS]c_int,
    mode_lf_delta_: [webp.NUM_MODE_LF_DELTAS]c_int,
};

//------------------------------------------------------------------------------
// Informations about the macroblocks.

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

//------------------------------------------------------------------------------
// VP8Decoder: the main opaque structure handed over to user

/// Main decoding object. This is an opaque structure.
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
    worker_: webp.Worker,
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
    dithering_rg_: webp.VP8Random,

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
    cache_y_stride_: c_int,
    cache_uv_stride_: c_int,

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

fn SetOk(dec: *VP8Decoder) void {
    dec.status_ = .Ok;
    dec.error_msg_ = "OK";
}

// Return current status of the decoder:
export fn VP8Status(dec: ?*VP8Decoder) webp.VP8Status {
    if (dec == null) return .InvalidParam;
    return dec.?.status_;
}

// return readable string corresponding to the last status.
export fn VP8StatusMessage(dec: ?*VP8Decoder) [*c]const u8 {
    if (dec == null) return "no object";
    if (dec.?.error_msg_ == null) return "OK";
    return dec.?.error_msg_;
}

// Resets the decoder in its initial state, reclaiming memory.
// Not a mandatory call between calls to VP8Decode().
pub export fn VP8Clear(dec_arg: ?*VP8Decoder) void {
    const dec = dec_arg orelse return;
    webp.WebPGetWorkerInterface().?.End.?(&dec.worker_);
    webp.WebPDeallocateAlphaMemory(dec);
    webp.WebPSafeFree(dec.mem_);
    dec.mem_ = null;
    dec.mem_size_ = 0;
    dec.br_ = std.mem.zeroes(@TypeOf(dec.br_));
    dec.ready_ = 0;
}

// Destroy the decoder object.
pub export fn VP8Delete(dec: ?*VP8Decoder) void {
    if (dec) |d| {
        VP8Clear(d);
        webp.WebPSafeFree(d);
    }
}

pub export fn VP8SetError(dec: *VP8Decoder, @"error": webp.VP8Status, msg: [*c]const u8) c_bool {
    // VP8Status.Suspended is only meaningful in incremental decoding.
    assert(dec.incremental_ != 0 or @"error" != .Suspended);
    // The oldest error reported takes precedence over the new one.
    if (dec.status_ == .Ok) {
        dec.status_ = @"error";
        dec.error_msg_ = msg;
        dec.ready_ = 0;
    }
    return 0;
}

//------------------------------------------------------------------------------
// Lower-level API
//
// These functions provide fine-grained control of the decoding process.
// The call flow should resemble:
//
//   VP8Io io;
//   VP8InitIo(&io);
//   io.data = data;
//   io.data_size = size;
//   /* customize io's functions (setup()/put()/teardown()) if needed. */
//
//   VP8Decoder* dec = VP8New();
//   int ok = VP8Decode(dec, &io);
//   if (!ok) printf("Error: %s\n", VP8StatusMessage(dec));
//   VP8Delete(dec);
//   return ok;

// Input / Output
pub const VP8Io = extern struct {
    pub const PutHook = ?*const fn ([*c]const @This()) callconv(.C) c_int;
    pub const SetupHook = ?*const fn ([*c]@This()) callconv(.C) c_int;
    pub const TeardownHook = ?*const fn ([*c]const @This()) callconv(.C) void;

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
    put: PutHook,

    /// called just before starting to decode the blocks.
    /// Must return false in case of setup error, true otherwise. If false is
    /// returned, teardown() will NOT be called. But if the setup succeeded
    /// and true is returned, then teardown() will always be called afterward.
    setup: SetupHook,

    /// Called just after block decoding is finished (or when an error occurred
    /// during put()). Is NOT called if setup() failed.
    teardown: TeardownHook,

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

/// Internal, version-checked, entry point
pub fn VP8InitIoInternal(io: ?*VP8Io, version: c_int) bool { // export
    if (webp.WEBP_ABI_IS_INCOMPATIBLE(version, webp.DECODER_ABI_VERSION)) {
        return false; // mismatch error
    }
    if (io) |io_ptr| io_ptr.* = std.mem.zeroes(VP8Io);
    return true;
}

/// Create a new decoder object.
pub fn VP8New() ?*VP8Decoder {
    const dec_: ?*VP8Decoder = @ptrCast(@alignCast(webp.WebPSafeCalloc(1, @sizeOf(VP8Decoder))));
    if (dec_) |dec| {
        SetOk(dec);
        webp.WebPGetWorkerInterface().?.Init.?(&dec.worker_);
        dec.ready_ = 0;
        dec.num_parts_minus_one_ = 0;
        InitGetCoeffs();
    }
    return dec_;
}

/// Must be called to make sure `io` is initialized properly.
/// Returns false in case of version mismatch. Upon such failure, no other
/// decoding function should be called (VP8Decode, VP8GetHeaders, ...)
pub inline fn VP8InitIo(io: ?*VP8Io) bool {
    return VP8InitIoInternal(io, webp.DECODER_ABI_VERSION);
}

//------------------------------------------------------------------------------
// Miscellaneous VP8/VP8L bitstream probing functions.

/// Returns true if the next 3 bytes in data contain the VP8 signature.
pub fn VP8CheckSignature(data: []const u8) bool {
    return (data.len >= 3 and
        data[0] == 0x9d and data[1] == 0x01 and data[2] == 0x2a);
}

/// Validates the VP8 data-header and retrieves basic header information viz
/// width and height. Returns `false` in case of formatting error.
/// *width/*height can be passed `null`. `data` — data available so far.
pub fn VP8GetInfo(data: []const u8, chunk_size: usize, width: ?*c_int, height: ?*c_int) bool {
    // TODO: width height fix
    if (data.len < webp.VP8_FRAME_HEADER_SIZE) {
        return false; // not enough data
    }

    // check signature
    if (!VP8CheckSignature(data[3..])) {
        return false; // Wrong signature.
    }

    const bits: u32 = @as(u32, data[0]) | (@as(u32, data[1]) << 8) | (@as(u32, data[2]) << 16);
    const key_frame = bits & 1 == 0;
    const w: u16 = ((@as(u16, data[7]) << 8) | @as(u16, data[6])) & 0x3fff;
    const h: u16 = ((@as(u16, data[9]) << 8) | @as(u16, data[8])) & 0x3fff;

    // Not a keyframe.
    if (!key_frame) return false;

    // unknown profile
    if (((bits >> 1) & 7) > 3) return false;

    // first frame is invisible!
    if ((bits >> 4) & 1 == 0) return false;

    if (((bits >> 5)) >= chunk_size) { // partition_length
        return false; // inconsistent size information.
    }

    // We don't support both width and height to be zero.
    if (w == 0 or h == 0) return false;

    if (width) |wp| wp.* = @intCast(w);
    if (height) |hp| hp.* = @intCast(h);

    return true;
}

fn VP8GetInfoC(data: [*c]const u8, data_size: usize, chunk_size: usize, width: [*c]c_int, height: [*c]c_int) callconv(.C) c_int {
    return @intFromBool(VP8GetInfo(data[0..data_size], chunk_size, width, height));
}

comptime {
    @export(VP8GetInfoC, .{ .name = "VP8GetInfo" });
}

//------------------------------------------------------------------------------
// Header parsing

fn ResetSegmentHeader(hdr: *VP8SegmentHeader) void {
    hdr.use_segment_ = 0;
    hdr.update_map_ = 0;
    hdr.absolute_delta_ = 1;
    @memset(&hdr.quantizer_, 0);
    @memset(&hdr.filter_strength_, 0);
}

// Paragraph 9.3
fn ParseSegmentHeader(br: *webp.VP8BitReader, hdr: *VP8SegmentHeader, proba: *VP8Proba) bool {
    hdr.use_segment_ = @intFromBool(webp.VP8Get(br, "global-header"));
    if (hdr.use_segment_ != 0) {
        hdr.update_map_ = @intFromBool(webp.VP8Get(br, "global-header"));
        if (webp.VP8Get(br, "global-header")) { // update data
            hdr.absolute_delta_ = @intFromBool(webp.VP8Get(br, "global-header"));
            for (0..webp.NUM_MB_SEGMENTS) |s|
                hdr.quantizer_[s] = if (webp.VP8Get(br, "global-header"))
                    @truncate(webp.VP8GetSignedValue(br, 7, "global-header"))
                else
                    0;

            for (0..webp.NUM_MB_SEGMENTS) |s|
                hdr.filter_strength_[s] = if (webp.VP8Get(br, "global-header"))
                    @truncate(webp.VP8GetSignedValue(br, 6, "global-header"))
                else
                    0;
        }
        if (hdr.update_map_ != 0) {
            for (0..webp.MB_FEATURE_TREE_PROBS) |s|
                proba.segments_[s] = if (webp.VP8Get(br, "global-header"))
                    @truncate(webp.VP8GetValue(br, 8, "global-header"))
                else
                    255;
        }
    } else {
        hdr.update_map_ = 0;
    }
    return br.eof_ == 0;
}

// Paragraph 9.5
// If we don't have all the necessary data in 'buf', this function returns
// VP8_STATUS_SUSPENDED in incremental decoding, VP8_STATUS_NOT_ENOUGH_DATA
// otherwise.
// In incremental decoding, this case is not necessarily an error. Still, no
// bitreader is ever initialized to make it possible to read unavailable memory.
// If we don't even have the partitions' sizes, then VP8_STATUS_NOT_ENOUGH_DATA
// is returned, and this is an unrecoverable error.
// If the partitions were positioned ok, VP8_STATUS_OK is returned.
fn ParsePartitions(dec: *VP8Decoder, buf: [*c]const u8, size: usize) webp.VP8Error!void {
    const br = &dec.br_;
    var sz: [*c]const u8 = buf;
    var buf_end: [*c]const u8 = buf + size;
    var size_left = size;
    // size_t p;

    dec.num_parts_minus_one_ = (@as(u32, 1) << @as(u2, @truncate(webp.VP8GetValue(br, 2, "global-header")))) - 1;
    const last_part: usize = dec.num_parts_minus_one_;
    if (size < 3 * last_part) {
        // we can't even read the sizes with sz[]! That's a failure.
        return error.NotEnoughData;
    }
    var part_start: [*c]const u8 = buf + last_part * 3;
    size_left -= last_part * 3;
    for (0..last_part) |p| {
        var psize: usize = @as(usize, sz[0]) | (@as(usize, sz[1]) << 8) | (@as(usize, sz[2]) << 16);
        if (psize > size_left) psize = size_left;
        webp.VP8InitBitReader(&dec.parts_[p], part_start, psize);
        part_start += psize;
        size_left -= psize;
        sz += 3;
    }
    webp.VP8InitBitReader(&dec.parts_[last_part], part_start, size_left);
    if (part_start < buf_end) return;
    return if (dec.incremental_ != 0)
        error.Suspended // Init is ok, but there's not enough data
    else
        error.NotEnoughData;
}

// Paragraph 9.4
fn ParseFilterHeader(br: *webp.VP8BitReader, dec: *VP8Decoder) bool {
    const hdr = &dec.filter_hdr_;
    hdr.simple_ = @intFromBool(webp.VP8Get(br, "global-header"));
    hdr.level_ = @intCast(webp.VP8GetValue(br, 6, "global-header"));
    hdr.sharpness_ = @intCast(webp.VP8GetValue(br, 3, "global-header"));
    hdr.use_lf_delta_ = @intFromBool(webp.VP8Get(br, "global-header"));
    if (hdr.use_lf_delta_ != 0) {
        if (webp.VP8Get(br, "global-header")) { // update lf-delta?
            for (0..webp.NUM_REF_LF_DELTAS) |i| {
                if (webp.VP8Get(br, "global-header"))
                    hdr.ref_lf_delta_[i] = webp.VP8GetSignedValue(br, 6, "global-header");
            }

            for (0..webp.NUM_MODE_LF_DELTAS) |i| {
                if (webp.VP8Get(br, "global-header"))
                    hdr.mode_lf_delta_[i] = webp.VP8GetSignedValue(br, 6, "global-header");
            }
        }
    }
    dec.filter_type_ = if (hdr.level_ == 0) 0 else if (hdr.simple_ != 0) 1 else 2;
    return br.eof_ == 0;
}

// Decode the VP8 frame header. Returns true if ok.
// Note: 'io->data' must be pointing to the start of the VP8 frame header.
pub fn VP8GetHeaders(dec_arg: ?*VP8Decoder, io_arg: ?*VP8Io) c_bool {
    const dec = dec_arg orelse return 0;
    SetOk(dec);
    const io = io_arg orelse return VP8SetError(dec, .InvalidParam, "null VP8Io passed to VP8GetHeaders()");

    if (io.data_size < 4) {
        return VP8SetError(dec, .NotEnoughData, "Truncated header.");
    }
    var buf: []const u8 = io.data[0..io.data_size];

    var frm_hdr: *VP8FrameHeader = undefined;
    // Paragraph 9.1
    {
        const bits: u32 = @as(u32, buf[0]) | (@as(u32, buf[1]) << 8) | (@as(u32, buf[2]) << 16);
        frm_hdr = &dec.frm_hdr_;
        frm_hdr.key_frame_ = @intFromBool(bits & 1 == 0);
        frm_hdr.profile_ = @truncate((bits >> 1) & 7);
        frm_hdr.show_ = @truncate((bits >> 4) & 1);
        frm_hdr.partition_length_ = (bits >> 5);

        if (frm_hdr.profile_ > 3)
            return VP8SetError(dec, .BitstreamError, "Incorrect keyframe parameters.");

        if (frm_hdr.show_ == 0)
            return VP8SetError(dec, .UnsupportedFeature, "Frame not displayable.");

        buf = buf[3..];
    }

    const pic_hdr: *VP8PictureHeader = &dec.pic_hdr_;
    if (frm_hdr.key_frame_ != 0) {
        // Paragraph 9.2
        if (buf.len < 7)
            return VP8SetError(dec, .NotEnoughData, "cannot parse picture header");

        if (!VP8CheckSignature(buf))
            return VP8SetError(dec, .BitstreamError, "Bad code word");

        pic_hdr.width_ = ((@as(u16, buf[4]) << 8) | @as(u16, buf[3])) & 0x3fff;
        pic_hdr.xscale_ = buf[4] >> 6; // ratio: 1, 5/4 5/3 or 2
        pic_hdr.height_ = ((@as(u16, buf[6]) << 8) | @as(u16, buf[5])) & 0x3fff;
        pic_hdr.yscale_ = buf[6] >> 6;
        buf = buf[7..];

        dec.mb_w_ = @intCast((pic_hdr.width_ + 15) >> 4);
        dec.mb_h_ = @intCast((pic_hdr.height_ + 15) >> 4);

        // Setup default output area (can be later modified during io->setup())
        io.width = @intCast(pic_hdr.width_);
        io.height = @intCast(pic_hdr.height_);
        // IMPORTANT! use some sane dimensions in crop_* and scaled_* fields.
        // So they can be used interchangeably without always testing for
        // 'use_cropping'.
        io.use_cropping = 0;
        io.crop_top = 0;
        io.crop_left = 0;
        io.crop_right = io.width;
        io.crop_bottom = io.height;
        io.use_scaling = 0;
        io.scaled_width = io.width;
        io.scaled_height = io.height;

        io.mb_w = io.width; // for soundness
        io.mb_h = io.height; // ditto

        webp.VP8ResetProba(&dec.proba_);
        ResetSegmentHeader(&dec.segment_hdr_);
    }

    // Check if we have all the partition #0 available, and initialize dec->br_
    // to read this partition (and this partition only).
    if (frm_hdr.partition_length_ > buf.len)
        return VP8SetError(dec, .NotEnoughData, "bad partition length");

    const br = &dec.br_;
    webp.VP8InitBitReader(br, buf.ptr, frm_hdr.partition_length_);
    buf = buf[frm_hdr.partition_length_..];

    if (frm_hdr.key_frame_ != 0) {
        pic_hdr.colorspace_ = @intFromBool(webp.VP8Get(br, "global-header"));
        pic_hdr.clamp_type_ = @intFromBool(webp.VP8Get(br, "global-header"));
    }
    if (!ParseSegmentHeader(br, &dec.segment_hdr_, &dec.proba_))
        return VP8SetError(dec, .BitstreamError, "cannot parse segment header");

    // Filter specs
    if (!ParseFilterHeader(br, dec))
        return VP8SetError(dec, .BitstreamError, "cannot parse filter header");

    ParsePartitions(dec, buf.ptr, buf.len) catch |e|
        return VP8SetError(dec, webp.VP8Status.fromErr(e), "cannot parse partitions");

    // quantizer change
    webp.VP8ParseQuant(dec);

    // Frame buffer marking
    if (frm_hdr.key_frame_ == 0)
        return VP8SetError(dec, .UnsupportedFeature, "Not a key frame.");

    _ = webp.VP8Get(br, "global-header"); // ignore the value of update_proba_

    webp.VP8ParseProba(br, dec);

    // sanitized state
    dec.ready_ = 1;
    return 1;
}

//------------------------------------------------------------------------------
// Residual decoding (Paragraph 13.2 / 13.3)

const kCat3 = [_:0]u8{ 173, 148, 140 };
const kCat4 = [_:0]u8{ 176, 155, 140, 135 };
const kCat5 = [_:0]u8{ 180, 157, 141, 134, 130 };
const kCat6 = [_:0]u8{ 254, 254, 243, 230, 196, 177, 153, 140, 133, 130, 129 };
const kCat3456 = [_][:0]const u8{ &kCat3, &kCat4, &kCat5, &kCat6 };
const kZigzag = [16]u8{
    0, 1,  4,  8,
    5, 2,  3,  6,
    9, 12, 13, 10,
    7, 11, 14, 15,
};

// See section 13-2: https://datatracker.ietf.org/doc/html/rfc6386#section-13.2
fn GetLargeValue(br: *webp.VP8BitReader, p: [*c]const u8) callconv(.C) c_int {
    var v: c_int = undefined;
    if (!webp.VP8GetBit(br, p[3], "coeffs")) {
        if (!webp.VP8GetBit(br, p[4], "coeffs")) {
            v = 2;
        } else {
            v = 3 + @as(c_int, @intFromBool(webp.VP8GetBit(br, p[5], "coeffs")));
        }
    } else {
        if (!webp.VP8GetBit(br, p[6], "coeffs")) {
            if (!webp.VP8GetBit(br, p[7], "coeffs")) {
                v = 5 + @as(c_int, @intFromBool(webp.VP8GetBit(br, 159, "coeffs")));
            } else {
                v = 7 + 2 * @as(c_int, @intFromBool(webp.VP8GetBit(br, 165, "coeffs")));
                v += @intFromBool(webp.VP8GetBit(br, 145, "coeffs"));
            }
        } else {
            const bit1: u8 = @intFromBool(webp.VP8GetBit(br, p[8], "coeffs"));
            const bit0: u8 = @intFromBool(webp.VP8GetBit(br, p[@abs(9 + bit1)], "coeffs"));
            const cat: u8 = 2 * bit1 + bit0;
            v = 0;

            for (kCat3456[cat]) |tab|
                v += v + @as(c_int, @intFromBool(webp.VP8GetBit(br, tab, "coeffs")));

            v += 3 + (@as(c_int, 8) << @intCast(cat));
        }
    }
    return v;
}

// Returns the position of the last non-zero coeff plus one
fn GetCoeffsFast(br: *webp.VP8BitReader, prob: [*c]const [*c]const VP8BandProbas, ctx: u16, dq: *const quant_t, n_arg: u16, out: [*c]i16) callconv(.C) c_int {
    var n = n_arg;
    var p: []const u8 = &prob[n_arg].*.probas_[ctx];
    while (n < 16) : (n += 1) {
        if (!webp.VP8GetBit(br, p[0], "coeffs"))
            return @intCast(n); // previous coeff was last non-zero coeff

        while (!webp.VP8GetBit(br, p[1], "coeffs")) { // sequence of zero coeffs
            n += 1;
            p = &prob[n].*.probas_[0];
            if (n == 16) return 16;
        }
        { // non zero coeff
            const p_ctx: [*c]const VP8ProbaArray = &prob[n + 1].*.probas_[0];
            var v: c_int = undefined;
            if (!webp.VP8GetBit(br, p[2], "coeffs")) {
                v = 1;
                p = &p_ctx[1];
            } else {
                v = GetLargeValue(br, p.ptr);
                p = &p_ctx[2];
            }
            out[kZigzag[n]] = @truncate(webp.VP8GetSigned(br, v, "coeffs") * dq[@intFromBool(n > 0)]);
        }
    }
    return 16;
}

// This version of GetCoeffs() uses VP8GetBitAlt() which is an alternate version
// of VP8GetBitAlt() targeting specific platforms.
fn GetCoeffsAlt(br: *webp.VP8BitReader, prob: [*c]const [*c]const VP8BandProbas, ctx: u16, dq: *const quant_t, n_arg: u16, out: [*c]i16) callconv(.C) c_int {
    var n = n_arg;
    var p: []const u8 = &prob[n].*.probas_[ctx];
    while (n < 16) : (n += 1) {
        if (!webp.VP8GetBitAlt(br, p[0], "coeffs"))
            return n; // previous coeff was last non-zero coeff

        while (!webp.VP8GetBitAlt(br, p[1], "coeffs")) { // sequence of zero coeffs
            n += 1;
            p = &prob[n].*.probas_[0];
            if (n == 16) return 16;
        }
        { // non zero coeff
            const p_ctx: [*c]const VP8ProbaArray = &prob[n + 1].*.probas_[0];
            var v: c_int = undefined;
            if (!webp.VP8GetBitAlt(br, p[2], "coeffs")) {
                v = 1;
                p = &p_ctx[1];
            } else {
                v = GetLargeValue(br, p.ptr);
                p = &p_ctx[2];
            }
            out[kZigzag[n]] = @truncate(webp.VP8GetSigned(br, v, "coeffs") * dq[@intFromBool(n > 0)]);
        }
    }
    return 16;
}

extern var VP8GetCPUInfo: webp.VP8CPUInfo;

const GetCoeffsFunc = ?*const fn (br: [*c]webp.VP8BitReader, prob: [*c]const [*c]const VP8BandProbas, ctx: c_int, dq: *const quant_t, n: c_int, out: [*c]i16) callconv(.C) c_int;
var GetCoeffs: GetCoeffsFunc = null;

fn InitGetCoeffs() void {
    const S = struct {
        fn InitGetCoeffsBody() void {
            if (VP8GetCPUInfo != null and VP8GetCPUInfo.?(.kSlowSSSE3) != 0) {
                GetCoeffs = @ptrCast(&GetCoeffsAlt);
            } else {
                GetCoeffs = @ptrCast(&GetCoeffsFast);
            }
        }
        var once = std.once(InitGetCoeffsBody);
    };

    S.once.call();
}

inline fn NzCodeBits(nz_coeffs_arg: u32, nz: c_int, dc_nz: bool) u32 {
    var nz_coeffs = nz_coeffs_arg << 2;
    nz_coeffs |= if (nz > 3) 3 else if (nz > 1) 2 else @intFromBool(dc_nz);
    return nz_coeffs;
}

fn ParseResiduals(dec: *VP8Decoder, mb: *VP8MB, token_br: *webp.VP8BitReader) c_bool {
    const bands: [*c][16 + 1][*c]const VP8BandProbas = &dec.proba_.bands_ptr_;
    var ac_proba: [*c]const [*c]const VP8BandProbas = undefined;
    const block: *VP8MBData = webp.offsetPtr(dec.mb_data_, dec.mb_x_).?;
    const q: *const VP8QuantMatrix = &dec.dqm_[block.*.segment_];
    var dst: [*c]i16 = &block.coeffs_;
    const left_mb: *VP8MB = webp.offsetPtr(dec.mb_info_, -1).?;
    var non_zero_y: u32 = 0;
    var non_zero_uv: u32 = 0;
    var first: c_int = undefined;

    @memset(dst[0..384], 0);
    if (block.is_i4x4_ == 0) { // parse DC
        var dc = [_]i16{0} ** 16;
        const ctx: c_int = @intCast(mb.nz_dc_ + left_mb.nz_dc_);
        const nz: c_int = GetCoeffs.?(token_br, &bands[1], ctx, &q.y2_mat_, 0, &dc);
        mb.nz_dc_ = @intFromBool(nz > 0);
        left_mb.nz_dc_ = @intFromBool(nz > 0);
        if (nz > 1) { // more than just the DC -> perform the full transform
            webp.VP8TransformWHT.?(&dc, dst);
        } else { // only DC is non-zero -> inlined simplified transform
            var i: usize = 0;
            const dc0 = (dc[0] + 3) >> 3;
            while (i < 16 * 16) : (i += 16) dst[i] = dc0;
        }
        first = 1;
        ac_proba = &bands[0];
    } else {
        first = 0;
        ac_proba = &bands[3];
    }

    var tnz: u8 = mb.nz_ & 0x0f;
    var lnz: u8 = left_mb.nz_ & 0x0f;
    // for (y = 0; y < 4; ++y) {
    for (0..4) |_| {
        var l: bool = lnz & 1 != 0;
        var nz_coeffs: u32 = 0;
        for (0..4) |_| {
            const ctx: c_int = @intFromBool(l) + (tnz & 1);
            const nz: c_int = GetCoeffs.?(token_br, ac_proba, ctx, &q.y1_mat_, first, dst);
            l = nz > first;
            tnz = (tnz >> 1) | (@as(u8, @intFromBool(l)) << 7);
            nz_coeffs = NzCodeBits(nz_coeffs, nz, dst[0] != 0);
            dst += 16;
        }
        tnz >>= 4;
        lnz = (lnz >> 1) | (@as(u8, @intFromBool(l)) << 7);
        non_zero_y = (non_zero_y << 8) | nz_coeffs;
    }
    var out_t_nz: u32 = tnz;
    var out_l_nz: u32 = lnz >> 4;

    var ch: usize = 0;
    while (ch < 4) : (ch += 2) {
        var nz_coeffs: u32 = 0;
        tnz = mb.nz_ >> @truncate(4 + ch);
        lnz = left_mb.nz_ >> @truncate(4 + ch);
        for (0..2) |_| {
            var l: bool = lnz & 1 != 0;
            for (0..2) |_| {
                const ctx: c_int = @intFromBool(l) + (tnz & 1);
                const nz: c_int = GetCoeffs.?(token_br, &bands[2], ctx, &q.uv_mat_, 0, dst);
                l = nz > 0;
                tnz = (tnz >> 1) | (@as(u8, @intFromBool(l)) << 3);
                nz_coeffs = NzCodeBits(nz_coeffs, nz, dst[0] != 0);
                dst += 16;
            }
            tnz >>= 2;
            lnz = (lnz >> 1) | (@as(u8, @intFromBool(l)) << 5);
        }
        // Note: we don't really need the per-4x4 details for U/V blocks.
        non_zero_uv |= nz_coeffs << @truncate(4 * ch);
        out_t_nz |= (tnz << 4) << @truncate(ch);
        out_l_nz |= (lnz & 0xf0) << @truncate(ch);
    }
    mb.nz_ = @truncate(out_t_nz);
    left_mb.nz_ = @truncate(out_l_nz);

    block.non_zero_y_ = non_zero_y;
    block.non_zero_uv_ = non_zero_uv;

    // We look at the mode-code of each block and check if some blocks have less
    // than three non-zero coeffs (code < 2). This is to avoid dithering flat and
    // empty blocks.
    block.dither_ = if (non_zero_uv & 0xaaaa != 0) 0 else @intCast(q.dither_);

    return @intFromBool((non_zero_y | non_zero_uv) == 0); // will be used for further optimization
}

//------------------------------------------------------------------------------
// Main loop

/// Decode one macroblock. Returns false if there is not enough data.
pub fn VP8DecodeMB(dec: *VP8Decoder, token_br: *webp.VP8BitReader) c_bool {
    const left: *VP8MB = webp.offsetPtr(dec.mb_info_, -1).?;
    const mb: *VP8MB = webp.offsetPtr(dec.mb_info_, dec.mb_x_).?;
    const block: *VP8MBData = webp.offsetPtr(dec.mb_data_, dec.mb_x_).?;
    var skip = if (dec.use_skip_proba_ != 0) block.skip_ != 0 else false;

    if (!skip) {
        skip = ParseResiduals(dec, mb, token_br) != 0;
    } else {
        left.nz_, mb.nz_ = .{ 0, 0 };
        if (block.is_i4x4_ == 0) {
            left.nz_dc_, mb.nz_dc_ = .{ 0, 0 };
        }
        block.non_zero_y_ = 0;
        block.non_zero_uv_ = 0;
        block.dither_ = 0;
    }

    if (dec.filter_type_ > 0) { // store filter info
        const finfo: *VP8FInfo = webp.offsetPtr(dec.f_info_, dec.mb_x_);
        finfo.* = dec.fstrengths_[block.segment_][block.is_i4x4_];
        finfo.f_inner_ |= @intFromBool(!skip);
    }

    return @intFromBool(token_br.eof_ == 0);
}

pub fn VP8InitScanline(dec: *VP8Decoder) void {
    const left: *VP8MB = webp.offsetPtr(dec.mb_info_, -1).?;
    left.nz_ = 0;
    left.nz_dc_ = 0;
    @memset(&dec.intra_l_, webp.B_DC_PRED);
    dec.mb_x_ = 0;
}

fn ParseFrame(dec: *VP8Decoder, io: *VP8Io) c_int {
    dec.mb_y_ = 0;
    while (dec.mb_y_ < dec.br_mb_y_) : (dec.mb_y_ += 1) {
        // Parse bitstream for this row.
        const token_br: *webp.VP8BitReader = webp.offsetPtr(@as([*c]webp.VP8BitReader, &dec.parts_), dec.mb_y_ & @as(c_int, @bitCast(dec.num_parts_minus_one_)));
        if (webp.VP8ParseIntraModeRow(&dec.br_, dec) == 0)
            return VP8SetError(dec, .NotEnoughData, "Premature end-of-partition0 encountered.");

        while (dec.mb_x_ < dec.mb_w_) : (dec.mb_x_ += 1) {
            if (!(VP8DecodeMB(dec, token_br) != 0))
                return VP8SetError(dec, .NotEnoughData, "Premature end-of-file encountered.");
        }
        VP8InitScanline(dec); // Prepare for next scanline

        // Reconstruct, filter and emit the row.
        if (webp.VP8ProcessRow(dec, io) == 0)
            return VP8SetError(dec, .UserAbort, "Output aborted.");
    }
    if (dec.mt_method_ > 0) {
        if (webp.WebPGetWorkerInterface().?.Sync.?(&dec.worker_) == 0) return 0;
    }

    return 1;
}

// Main entry point
// Decode a picture. Will call VP8GetHeaders() if it wasn't done already.
// Returns false in case of error.
pub fn VP8Decode(dec_arg: ?*VP8Decoder, io_arg: ?*VP8Io) c_int {
    var ok: c_int = 0;
    const dec = dec_arg orelse return 0;
    const io = io_arg orelse return VP8SetError(dec, .InvalidParam, "NULL VP8Io parameter in VP8Decode().");

    if (dec.ready_ == 0) {
        if (VP8GetHeaders(dec, io) == 0) return 0;
    }
    assert(dec.ready_ != 0);

    // Finish setting up the decoding parameter. Will call io->setup().
    ok = @intFromBool(webp.VP8EnterCritical(dec, io) == .Ok);
    if (ok != 0) { // good to go.
        // Will allocate memory and prepare everything.
        if (ok != 0) ok = webp.VP8InitFrame(dec, io);

        // Main decoding loop
        if (ok != 0) ok = ParseFrame(dec, io);

        // Exit.
        ok &= webp.VP8ExitCritical(dec, io);
    }

    if (ok == 0) {
        VP8Clear(dec);
        return 0;
    }

    dec.ready_ = 0;
    return ok;
}
