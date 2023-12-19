const std = @import("std");
const build_options = @import("build_options");
const webp = struct {
    usingnamespace @import("buffer_dec.zig");
    usingnamespace @import("frame_dec.zig");
    usingnamespace @import("io_dec.zig");
    usingnamespace @import("vp8_dec.zig");
    usingnamespace @import("vp8l_dec.zig");
    usingnamespace @import("../utils/rescaler_utils.zig");
    usingnamespace @import("../utils/utils.zig");
    usingnamespace @import("../webp/decode.zig");
    usingnamespace @import("../webp/format_constants.zig");
};

const assert = std.debug.assert;
const c_bool = webp.c_bool;
const VP8Status = webp.VP8Status;

const WebpTag = enum(u32) {
    RIFF = @bitCast(@as([4]u8, "RIFF".*)),
    WEBP = @bitCast(@as([4]u8, "WEBP".*)),
    VP8X = @bitCast(@as([4]u8, "VP8X".*)),
    VP8 = @bitCast(@as([4]u8, "VP8 ".*)),
    VP8L = @bitCast(@as([4]u8, "VP8L".*)),
    ALPH = @bitCast(@as([4]u8, "ALPH".*)),

    pub inline fn is(data: [*c]const u8, tag: WebpTag) bool {
        return @as(u32, @bitCast(data[0..webp.TAG_SIZE].*)) == @intFromEnum(tag);
    }
};

//------------------------------------------------------------------------------
// DecParams: Decoding output parameters. Transient internal object.

pub const DecParams = extern struct {
    pub const OutputFunc = ?*const fn ([*c]const webp.VP8Io, [*c]@This()) callconv(.C) c_int;
    pub const OutputAlphaFunc = ?*const fn ([*c]const webp.VP8Io, [*c]@This(), c_int) callconv(.C) c_int;
    pub const OutputRowFunc = ?*const fn ([*c]@This(), c_int, c_int) callconv(.C) c_int;

    /// output buffer.
    output: ?*webp.DecBuffer,
    // cache for the fancy upsampler
    // or used for tmp rescaling
    tmp_y: [*c]u8,
    tmp_u: [*c]u8,
    tmp_v: [*c]u8,

    /// coordinate of the line that was last output
    last_y: c_int,
    /// if not `null`, use alt decoding features
    options: ?*const webp.DecoderOptions,

    //rescalers
    scaler_y: ?*webp.WebPRescaler,
    scaler_u: ?*webp.WebPRescaler,
    scaler_v: ?*webp.WebPRescaler,
    scaler_a: ?*webp.WebPRescaler,
    /// overall scratch memory for the output work.
    memory: ?*anyopaque,

    /// output RGB or YUV samples
    emit: OutputFunc,
    /// output alpha channel
    emit_alpha: OutputAlphaFunc,
    /// output one line of rescaled alpha values
    emit_alpha_row: OutputRowFunc,
};

/// Should be called first, before any use of the WebPDecParams object.
pub fn WebPResetDecParams(params: ?*DecParams) void {
    if (params) |p| p.* = std.mem.zeroes(DecParams);
}

//------------------------------------------------------------------------------
// Header parsing helpers

/// Structure storing a description of the RIFF headers.
pub const HeaderStructure = extern struct {
    /// input buffer
    data: [*c]const u8,
    /// input buffer size
    data_size: usize,
    /// true if all data is known to be available
    have_all_data: c_bool,
    /// offset to main data chunk (VP8 or VP8L)
    offset: usize,
    /// points to alpha chunk (if present)
    alpha_data: [*c]const u8,
    /// alpha chunk size
    alpha_data_size: usize,
    /// VP8/VP8L compressed data size
    compressed_size: usize,
    /// size of the riff payload (or 0 if absent)
    riff_size: usize,
    /// true if a VP8L chunk is present
    is_lossless: c_bool,
};

/// Skips over all valid chunks prior to the first VP8/VP8L frame header.
/// Returns: VP8_STATUS_OK, VP8_STATUS_BITSTREAM_ERROR (invalid header/chunk),
/// VP8_STATUS_NOT_ENOUGH_DATA (partial input) or VP8_STATUS_UNSUPPORTED_FEATURE
/// in the case of non-decodable features (animation for instance).
/// In 'headers', compressed_size, offset, alpha_data, alpha_size, and lossless
/// fields are updated appropriately upon success.
pub fn WebPParseHeaders(headers: *HeaderStructure) VP8Status {
    var has_animation: c_bool = 0;
    // fill out headers, ignore width/height/has_alpha.
    var status = ParseHeadersInternal(headers.data, headers.data_size, null, null, null, &has_animation, null, headers);
    if (status == .Ok or status == .NotEnoughData) {
        // The WebPDemux API + libwebp can be used to decode individual
        // uncomposited frames or the WebPAnimDecoder can be used to fully
        // reconstruct them (see webp/demux.h).
        if (has_animation != 0) {
            status = .UnsupportedFeature;
        }
    }
    return status;
}

//------------------------------------------------------------------------------
// Misc utils

/// Returns true if crop dimensions are within image bounds.
pub fn WebPCheckCropDimensions(image_width: c_int, image_height: c_int, x: c_int, y: c_int, w: c_int, h: c_int) bool {
    return !(x < 0 or y < 0 or w <= 0 or h <= 0 or
        x >= image_width or w > image_width or w > image_width - x or
        y >= image_height or h > image_height or h > image_height - y);
}

/// Setup crop_xxx fields, mb_w and mb_h in io. 'src_colorspace' refers
/// to the *compressed* format, not the output one.
pub fn WebPIoInitFromOptions(options: ?*const webp.DecoderOptions, io: *webp.VP8Io, src_colorspace: webp.ColorspaceMode) c_bool {
    const W = io.width;
    const H = io.height;
    var x: c_int, var y: c_int, var w: c_int, var h: c_int = .{ 0, 0, W, H };

    // Cropping
    io.use_cropping = @intFromBool((options != null) and options.?.use_cropping != 0);
    if (io.use_cropping != 0) {
        w = options.?.crop_width;
        h = options.?.crop_height;
        x = options.?.crop_left;
        y = options.?.crop_top;
        if (!src_colorspace.isRGBMode()) { // only snap for YUV420
            x &= ~@as(c_int, 1);
            y &= ~@as(c_int, 1);
        }
        if (!WebPCheckCropDimensions(W, H, x, y, w, h)) {
            return 0; // out of frame boundary error
        }
    }
    io.crop_left = x;
    io.crop_top = y;
    io.crop_right = x + w;
    io.crop_bottom = y + h;
    io.mb_w = w;
    io.mb_h = h;

    // Scaling
    io.use_scaling = @intFromBool((options != null) and options.?.use_scaling != 0);
    if (io.use_scaling != 0) {
        var scaled_width = options.?.scaled_width;
        var scaled_height = options.?.scaled_height;
        if (!(webp.WebPRescalerGetScaledDimensions(w, h, &scaled_width, &scaled_height) != 0))
            return 0;
        io.scaled_width = scaled_width;
        io.scaled_height = scaled_height;
    }

    // Filter
    io.bypass_filtering = @intFromBool((options != null) and options.?.bypass_filtering != 0);

    // Fancy upsampler
    if (comptime build_options.fancy_upsampling)
        io.fancy_upsampling = @intFromBool((options == null) or (options.?.no_fancy_upsampling == 0));

    if (io.use_scaling != 0) {
        // disable filter (only for large downscaling ratio).
        io.bypass_filtering |= @intFromBool(io.scaled_width < @divTrunc(W * 3, 4) and io.scaled_height < @divTrunc(H * 3, 4));
        io.fancy_upsampling = 0;
    }
    return 1;
}

//------------------------------------------------------------------------------
// RIFF layout is:
//   Offset  tag
//   0...3   "RIFF" 4-byte tag
//   4...7   size of image data (including metadata) starting at offset 8
//   8...11  "WEBP"   our form-type signature
// The RIFF container (12 bytes) is followed by appropriate chunks:
//   12..15  "VP8 ": 4-bytes tags, signaling the use of VP8 video format
//   16..19  size of the raw VP8 image data, starting at offset 20
//   20....  the VP8 bytes
// Or,
//   12..15  "VP8L": 4-bytes tags, signaling the use of VP8L lossless format
//   16..19  size of the raw VP8L image data, starting at offset 20
//   20....  the VP8L bytes
// Or,
//   12..15  "VP8X": 4-bytes tags, describing the extended-VP8 chunk.
//   16..19  size of the VP8X chunk starting at offset 20.
//   20..23  VP8X flags bit-map corresponding to the chunk-types present.
//   24..26  Width of the Canvas Image.
//   27..29  Height of the Canvas Image.
// There can be extra chunks after the "VP8X" chunk (ICCP, ANMF, VP8, VP8L,
// XMP, EXIF  ...)
// All sizes are in little-endian order.
// Note: chunk data size must be padded to multiple of 2 when written.

/// Validates the RIFF container (if detected) and skips over it.
/// If a RIFF container is detected, returns:
///     VP8_STATUS_BITSTREAM_ERROR for invalid header,
///     VP8_STATUS_NOT_ENOUGH_DATA for truncated data if have_all_data is true,
/// and VP8_STATUS_OK otherwise.
/// In case there are not enough bytes (partial RIFF container), return 0 for
/// *riff_size. Else return the RIFF size extracted from the header.
fn ParseRIFF(data: *[*c]const u8, data_size: *usize, have_all_data: c_bool, riff_size: *usize) VP8Status {
    riff_size.* = 0; // Default: no RIFF present.
    if (data_size.* >= webp.RIFF_HEADER_SIZE and WebpTag.is(data.*, .RIFF)) {
        if (!WebpTag.is(data.*[8..], .WEBP)) {
            return .BitstreamError; // Wrong image file signature.
        } else {
            const size: u32 = webp.getLE32(data.*[webp.TAG_SIZE..][0..4]);
            // Check that we have at least one chunk (i.e "WEBP" + "VP8?nnnn").
            if (size < webp.TAG_SIZE + webp.CHUNK_HEADER_SIZE) {
                return .BitstreamError;
            }
            if (size > webp.MAX_CHUNK_PAYLOAD) {
                return .BitstreamError;
            }
            if (have_all_data != 0 and (size > data_size.* -| webp.CHUNK_HEADER_SIZE)) {
                return .NotEnoughData; // Truncated bitstream.
            }
            // We have a RIFF container. Skip it.
            riff_size.* = size;
            data.* += webp.RIFF_HEADER_SIZE;
            data_size.* -|= webp.RIFF_HEADER_SIZE;
        }
    }
    return .Ok;
}

/// Validates the VP8X header and skips over it.
/// Returns VP8_STATUS_BITSTREAM_ERROR for invalid VP8X header,
///         VP8_STATUS_NOT_ENOUGH_DATA in case of insufficient data, and
///         VP8_STATUS_OK otherwise.
/// If a VP8X chunk is found, found_vp8x is set to true and *width_ptr,
/// *height_ptr and *flags_ptr are set to the corresponding values extracted
/// from the VP8X chunk.
fn ParseVP8X(data: *[*c]const u8, data_size: *usize, found_vp8x: *c_int, width_ptr: ?*c_int, height_ptr: ?*c_int, flags_ptr: ?*u32) VP8Status {
    const vp8x_size: u32 = webp.CHUNK_HEADER_SIZE + webp.VP8X_CHUNK_SIZE;
    found_vp8x.* = 0;

    // Insufficient data.
    if (data_size.* < webp.CHUNK_HEADER_SIZE) return .NotEnoughData;

    if (WebpTag.is(data.*, .VP8X)) {
        const chunk_size: u32 = webp.getLE32(data.*[webp.TAG_SIZE..][0..4]);
        if (chunk_size != webp.VP8X_CHUNK_SIZE) {
            return .BitstreamError; // Wrong chunk size.
        }

        // Verify if enough data is available to validate the VP8X chunk.
        if (data_size.* < vp8x_size) {
            return .NotEnoughData; // Insufficient data.
        }
        const flags = webp.getLE32(data.*[8..][0..4]);
        const width = 1 + webp.getLE24(data.*[12..][0..3]);
        const height = 1 + webp.getLE24(data.*[15..][0..3]);
        if (@as(u64, width) *| @as(u64, height) >= webp.MAX_IMAGE_AREA) {
            return .BitstreamError; // image is too large
        }

        if (flags_ptr) |fp| fp.* = flags;
        if (width_ptr) |wp| wp.* = @intCast(width);
        if (height_ptr) |hp| hp.* = @intCast(height);
        // Skip over VP8X header bytes.

        data.* += vp8x_size;
        data_size.* -|= vp8x_size;
        found_vp8x.* = 1;
    }
    return .Ok;
}

/// Skips to the next VP8/VP8L chunk header in the data given the size of the
/// RIFF chunk 'riff_size'.
/// Returns VP8_STATUS_BITSTREAM_ERROR if any invalid chunk size is encountered,
///         VP8_STATUS_NOT_ENOUGH_DATA in case of insufficient data, and
///         VP8_STATUS_OK otherwise.
/// If an alpha chunk is found, *alpha_data and *alpha_size are set
/// appropriately.
fn ParseOptionalChunks(data: *[*c]const u8, data_size: *usize, riff_size: usize, alpha_data: *[*c]const u8, alpha_size: *usize) VP8Status {
    var total_size: u32 = webp.TAG_SIZE + // "WEBP".
        webp.CHUNK_HEADER_SIZE + // "VP8Xnnnn".
        webp.VP8X_CHUNK_SIZE; // data.
    var buf = data.*;
    var buf_size = data_size.*;
    alpha_data.* = null;
    alpha_size.* = 0;

    while (true) {
        data.* = buf;
        data_size.* = buf_size;

        // Insufficient data.
        if (buf_size < webp.CHUNK_HEADER_SIZE) return .NotEnoughData;

        const chunk_size = webp.getLE32(buf[webp.TAG_SIZE..][0..4]);
        // Not a valid chunk size.
        if (chunk_size > webp.MAX_CHUNK_PAYLOAD) return .BitstreamError;

        // For odd-sized chunk-payload, there's one byte padding at the end.
        // var disk_chunk_size = ((@as(u32, @bitCast(@as(c_int, 8))) +% chunk_size) +% @as(u32, @bitCast(@as(c_int, 1)))) & ~@as(c_uint, 1);
        const disk_chunk_size: u32 = (webp.CHUNK_HEADER_SIZE + chunk_size + 1) & ~@as(u32, 1);
        total_size +%= disk_chunk_size;

        // Check that total bytes skipped so far does not exceed riff_size.
        if (riff_size > 0 and (total_size > riff_size)) {
            return .BitstreamError; // Not a valid chunk size.
        }

        // Start of a (possibly incomplete) VP8/VP8L chunk implies that we have
        // parsed all the optional chunks.
        // Note: This check must occur before the check 'buf_size < disk_chunk_size'
        // below to allow incomplete VP8/VP8L chunks.
        if (WebpTag.is(data.*, .VP8) or WebpTag.is(data.*, .VP8L)) {
            return .Ok;
        }

        if (buf_size < disk_chunk_size) { // Insufficient data.
            return .NotEnoughData;
        }

        if (WebpTag.is(data.*, .ALPH)) { // A valid ALPH header.
            alpha_data.* = buf + webp.CHUNK_HEADER_SIZE;
            alpha_size.* = chunk_size;
        }

        // We have a full and valid chunk; skip it.
        buf += disk_chunk_size;
        buf_size -|= disk_chunk_size;
    }
    return .Ok;
}

/// Validates the VP8/VP8L Header ("VP8 nnnn" or "VP8L nnnn") and skips over it.
/// Returns VP8_STATUS_BITSTREAM_ERROR for invalid (chunk larger than
///         riff_size) VP8/VP8L header,
///         VP8_STATUS_NOT_ENOUGH_DATA in case of insufficient data, and
///         VP8_STATUS_OK otherwise.
/// If a VP8/VP8L chunk is found, *chunk_size is set to the total number of bytes
/// extracted from the VP8/VP8L chunk header.
/// The flag '*is_lossless' is set to 1 in case of VP8L chunk / raw VP8L data.
fn ParseVP8Header(data_ptr: *[*c]const u8, data_size: *usize, have_all_data: c_bool, riff_size: usize, chunk_size: *usize, is_lossless: *c_bool) VP8Status {
    const data = data_ptr.*;
    const is_vp8 = WebpTag.is(data, .VP8);
    const is_vp8l = WebpTag.is(data, .VP8L);
    const minimal_size = webp.TAG_SIZE + webp.CHUNK_HEADER_SIZE; // "WEBP" + "VP8 nnnn" OR "WEBP" + "VP8Lnnnn"

    if (data_size.* < webp.CHUNK_HEADER_SIZE) {
        return .NotEnoughData; // Insufficient data.
    }

    if (is_vp8 or is_vp8l) {
        // Bitstream contains VP8/VP8L header.
        const size = webp.getLE32(data[webp.TAG_SIZE..][0..4]);
        if ((riff_size >= minimal_size) and (size > riff_size -| minimal_size)) {
            return .BitstreamError; // Inconsistent size information.
        }
        if ((have_all_data != 0) and (size > data_size.* -| webp.CHUNK_HEADER_SIZE)) {
            return .NotEnoughData; // Truncated bitstream.
        }
        // Skip over CHUNK_HEADER_SIZE bytes from VP8/VP8L Header.
        chunk_size.* = size;
        data_ptr.* += webp.CHUNK_HEADER_SIZE;
        data_size.* -= webp.CHUNK_HEADER_SIZE;
        is_lossless.* = @intFromBool(is_vp8l);
    } else {
        // Raw VP8/VP8L bitstream (no header).
        is_lossless.* = @intFromBool(webp.VP8LCheckSignature(data[0..data_size.*]));
        chunk_size.* = data_size.*;
    }

    return .Ok;
}

//------------------------------------------------------------------------------

// Fetch '*width', '*height', '*has_alpha' and fill out 'headers' based on
// 'data'. All the output parameters may be NULL. If 'headers' is NULL only the
// minimal amount will be read to fetch the remaining parameters.
// If 'headers' is non-NULL this function will attempt to locate both alpha
// data (with or without a VP8X chunk) and the bitstream chunk (VP8/VP8L).
// Note: The following chunk sequences (before the raw VP8/VP8L data) are
// considered valid by this function:
// RIFF + VP8(L)
// RIFF + VP8X + (optional chunks) + VP8(L)
// ALPH + VP8 <-- Not a valid WebP format: only allowed for internal purpose.
// VP8(L)     <-- Not a valid WebP format: only allowed for internal purpose.
fn ParseHeadersInternal(data_arg: [*c]const u8, data_size_arg: usize, width: ?*c_int, height: ?*c_int, has_alpha: ?*c_bool, has_animation: ?*c_bool, format: ?*c_int, headers: ?*HeaderStructure) VP8Status {
    var data = data_arg orelse return .NotEnoughData;
    var data_size = data_size_arg;
    if (data_size < webp.RIFF_HEADER_SIZE) return .NotEnoughData;

    var canvas_width: c_int = 0;
    var canvas_height: c_int = 0;
    var image_width: c_int = 0;
    var image_height: c_int = 0;
    var found_vp8x: c_bool = 0;
    var animation_present = false;
    const have_all_data = if (headers) |h| h.have_all_data != 0 else false;

    var hdrs = std.mem.zeroes(HeaderStructure);
    hdrs.data = data;
    hdrs.data_size = data_size;

    // Skip over RIFF header.
    var status = ParseRIFF(&data, &data_size, @intFromBool(have_all_data), &hdrs.riff_size);
    if (status != .Ok) return status; // Wrong RIFF header / insufficient data.
    const found_riff = (hdrs.riff_size > 0);

    ReturnWidthHeight: {
        // Skip over VP8X.
        {
            var flags: u32 = 0;
            status = ParseVP8X(&data, &data_size, &found_vp8x, &canvas_width, &canvas_height, &flags);
            if (status != .Ok) return status; // Wrong VP8X / insufficient data.

            animation_present = webp.hasFlag(flags, .animation);
            if (!found_riff and (found_vp8x != 0)) {
                // Note: This restriction may be removed in the future, if it becomes
                // necessary to send VP8X chunk to the decoder.
                return .BitstreamError;
            }
            if (has_alpha) |p| p.* = @intFromBool(webp.hasFlag(flags, .alpha));
            if (has_animation) |p| p.* = @intFromBool(animation_present);
            if (format) |p| p.* = 0; // default = undefined

            image_width = canvas_width;
            image_height = canvas_height;
            if ((found_vp8x != 0) and animation_present and headers == null) {
                status = .Ok;
                break :ReturnWidthHeight;
            }
        }

        if (data_size < webp.TAG_SIZE) {
            status = .NotEnoughData;
            break :ReturnWidthHeight;
        }

        // Skip over optional chunks if data started with "RIFF + VP8X" or "ALPH".
        if ((found_riff and (found_vp8x != 0)) or
            (!found_riff and !(found_vp8x != 0) and WebpTag.is(data, .ALPH)))
        {
            status = ParseOptionalChunks(&data, &data_size, hdrs.riff_size, &hdrs.alpha_data, &hdrs.alpha_data_size);
            if (status != .Ok) break :ReturnWidthHeight; // Invalid chunk size / insufficient data.

        }

        // Skip over VP8/VP8L header.
        status = ParseVP8Header(&data, &data_size, @intFromBool(have_all_data), hdrs.riff_size, &hdrs.compressed_size, &hdrs.is_lossless);
        if (status != .Ok) break :ReturnWidthHeight; // Wrong VP8/VP8L chunk-header / insufficient data.

        if (hdrs.compressed_size > webp.MAX_CHUNK_PAYLOAD) return .BitstreamError;

        if (format != null and !animation_present)
            format.?.* = if (hdrs.is_lossless != 0) 2 else 1;

        if (!(hdrs.is_lossless != 0)) {
            if (data_size < webp.VP8_FRAME_HEADER_SIZE) {
                status = .NotEnoughData;
                break :ReturnWidthHeight;
            }
            // Validates raw VP8 data.
            if (!webp.VP8GetInfo(data[0..data_size], hdrs.compressed_size, &image_width, &image_height))
                return .BitstreamError;
        } else {
            if (data_size < webp.VP8L_FRAME_HEADER_SIZE) {
                status = .NotEnoughData;
                break :ReturnWidthHeight;
            }
            {
                var has_alpha_zig: bool = undefined;
                defer {
                    if (has_alpha) |ptr| ptr.* = @intFromBool(has_alpha_zig);
                }
                // Validates raw VP8L data.
                if (!webp.VP8LGetInfo(data[0..data_size], &image_width, &image_height, &has_alpha_zig))
                    return .BitstreamError;
            }
        }
        // Validates image size coherency.
        if ((found_vp8x != 0)) {
            if (canvas_width != image_width or canvas_height != image_height)
                return .BitstreamError;
        }
        if (headers) |h| {
            h.* = hdrs;
            h.offset = @abs(webp.diffPtr(data, h.data));
            assert(@abs(webp.diffPtr(data, h.data)) < webp.MAX_CHUNK_PAYLOAD);
            assert(h.offset == h.data_size - data_size);
        }
    }
    // ReturnWidthHeight:
    if (status == .Ok or
        (status == .NotEnoughData and (found_vp8x != 0) and headers == null))
    {
        // If the data did not contain a VP8X/VP8L chunk the only definitive way
        // to set this is by looking for alpha data (from an ALPH chunk).
        if (has_alpha) |ptr| ptr.* |= @intFromBool(hdrs.alpha_data != null);

        if (width) |w| w.* = image_width;
        if (height) |h| h.* = image_height;
        return .Ok;
    } else {
        return status;
    }
}

//------------------------------------------------------------------------------
// "Into" decoding variants

// Main flow
fn DecodeInto(data: [*c]const u8, data_size: usize, params: *DecParams) VP8Status {
    var headers: HeaderStructure = undefined;
    headers.data = data;
    headers.data_size = data_size;
    headers.have_all_data = 1;
    var status = WebPParseHeaders(&headers); // Process Pre-VP8 chunks.
    if (status != .Ok) return status;

    var io: webp.VP8Io = undefined;
    _ = webp.VP8InitIo(&io);
    io.data = headers.data + headers.offset;
    io.data_size = headers.data_size -| headers.offset;
    webp.WebPInitCustomIo(params, &io); // Plug the I/O functions.

    if (!(headers.is_lossless != 0)) {
        const dec: *webp.VP8Decoder = webp.VP8New() orelse return .OutOfMemory;
        dec.alpha_data_ = headers.alpha_data;
        dec.alpha_data_size_ = headers.alpha_data_size;

        // Decode bitstream header, update io->width/io->height.
        if (!(webp.VP8GetHeaders(dec, &io) != 0)) {
            status = dec.status_; // An error occurred. Grab error status.
        } else {
            // Allocate/check output buffers.
            status = webp.WebPAllocateDecBuffer(io.width, io.height, params.options, params.output);
            if (status == .Ok) { // Decode
                // This change must be done before calling VP8Decode()
                dec.mt_method_ = webp.VP8GetThreadMethod(params.options, &headers, io.width, io.height);
                webp.VP8InitDithering(params.options, dec);
                if (webp.VP8Decode(dec, &io) == 0) {
                    status = dec.status_;
                }
            }
        }
        webp.VP8Delete(dec);
    } else {
        const dec: *webp.VP8LDecoder = webp.VP8LNew() orelse return .OutOfMemory;
        if (!(webp.VP8LDecodeHeader(dec, &io) != 0)) {
            status = dec.status_; // An error occurred. Grab error status.
        } else {
            // Allocate/check output buffers.
            status = webp.WebPAllocateDecBuffer(io.width, io.height, params.options, params.output);
            if (status == .Ok) { // Decode
                if (!(webp.VP8LDecodeImage(dec) != 0))
                    status = dec.status_;
            }
        }
        webp.VP8LDelete(dec);
    }

    if (status != .Ok) {
        webp.WebPFreeDecBuffer(params.output);
    } else {
        if (params.options != null and params.options.?.flip != 0) {
            // This restores the original stride values if options->flip was used
            // during the call to WebPAllocateDecBuffer above.
            status = webp.WebPFlipBuffer(params.output);
        }
    }
    return status;
}

fn DecodeIntoRGBABuffer(colorspace: webp.ColorspaceMode, data: [*c]const u8, data_size: usize, rgba: [*c]u8, stride: c_int, size: usize) [*c]u8 {
    if (rgba == null) return null;
    var params: DecParams = undefined;
    var buf: webp.DecBuffer = undefined;
    _ = webp.WebPInitDecBuffer(&buf);
    WebPResetDecParams(&params);

    params.output = &buf;
    buf.colorspace = colorspace;
    buf.u.RGBA.rgba = rgba;
    buf.u.RGBA.stride = stride;
    buf.u.RGBA.size = size;
    buf.is_external_memory = 1;
    if (DecodeInto(data, data_size, &params) != .Ok) return null;

    return rgba;
}

pub export fn WebPDecodeRGBInto(data: [*c]const u8, data_size: usize, output: [*c]u8, size: usize, stride: c_int) [*c]u8 {
    return DecodeIntoRGBABuffer(.RGB, data, data_size, output, stride, size);
}

pub export fn WebPDecodeRGBAInto(data: [*c]const u8, data_size: usize, output: [*c]u8, size: usize, stride: c_int) [*c]u8 {
    return DecodeIntoRGBABuffer(.RGBA, data, data_size, output, stride, size);
}

pub export fn WebPDecodeARGBInto(data: [*c]const u8, data_size: usize, output: [*c]u8, size: usize, stride: c_int) [*c]u8 {
    return DecodeIntoRGBABuffer(.ARGB, data, data_size, output, stride, size);
}

pub export fn WebPDecodeBGRInto(data: [*c]const u8, data_size: usize, output: [*c]u8, size: usize, stride: c_int) [*c]u8 {
    return DecodeIntoRGBABuffer(.BGR, data, data_size, output, stride, size);
}

pub export fn WebPDecodeBGRAInto(data: [*c]const u8, data_size: usize, output: [*c]u8, size: usize, stride: c_int) [*c]u8 {
    return DecodeIntoRGBABuffer(.BGRA, data, data_size, output, stride, size);
}

pub export fn WebPDecodeYUVInto(data: [*c]const u8, data_size: usize, luma: [*c]u8, luma_size: usize, luma_stride: c_int, u: [*c]u8, u_size: usize, u_stride: c_int, v: [*c]u8, v_size: usize, v_stride: c_int) [*c]u8 {
    if (luma == null) return null;
    var params: DecParams = undefined;
    var output: webp.DecBuffer = undefined;
    _ = webp.WebPInitDecBuffer(&output);
    WebPResetDecParams(&params);
    params.output = &output;
    output.colorspace = .YUV;
    output.u.YUVA.y = luma;
    output.u.YUVA.y_stride = luma_stride;
    output.u.YUVA.y_size = luma_size;
    output.u.YUVA.u = u;
    output.u.YUVA.u_stride = u_stride;
    output.u.YUVA.u_size = u_size;
    output.u.YUVA.v = v;
    output.u.YUVA.v_stride = v_stride;
    output.u.YUVA.v_size = v_size;
    output.is_external_memory = 1;
    if (DecodeInto(data, data_size, &params) != .Ok) return null;
    return luma;
}

//------------------------------------------------------------------------------

fn Decode(mode: webp.ColorspaceMode, data: [*c]const u8, data_size: usize, width: ?*c_int, height: ?*c_int, keep_info: ?*webp.DecBuffer) [*c]u8 {
    var params: DecParams = undefined;
    var output: webp.DecBuffer = undefined;

    _ = webp.WebPInitDecBuffer(&output);
    WebPResetDecParams(&params);
    params.output = &output;
    output.colorspace = mode;

    // Retrieve (and report back) the required dimensions from bitstream.
    if (!(WebPGetInfo(data, data_size, &output.width, &output.height) != 0)) {
        return null;
    }
    if (width) |w| w.* = output.width;
    if (height) |h| h.* = output.height;

    // Decode
    if (DecodeInto(data, data_size, &params) != .Ok)
        return null;

    if (keep_info != null) { // keep track of the side-info
        webp.WebPCopyDecBuffer(&output, keep_info.?);
    }

    // return decoded samples (don't clear 'output'!)
    return if (mode.isRGBMode()) output.u.RGBA.rgba else output.u.YUVA.y;
}

pub export fn WebPDecodeRGB(data: [*c]const u8, data_size: usize, width: ?*c_int, height: ?*c_int) [*c]u8 {
    return Decode(.RGB, data, data_size, width, height, null);
}

pub export fn WebPDecodeRGBA(data: [*c]const u8, data_size: usize, width: ?*c_int, height: ?*c_int) [*c]u8 {
    return Decode(.RGBA, data, data_size, width, height, null);
}

pub export fn WebPDecodeARGB(data: [*c]const u8, data_size: usize, width: ?*c_int, height: ?*c_int) [*c]u8 {
    return Decode(.ARGB, data, data_size, width, height, null);
}

pub export fn WebPDecodeBGR(data: [*c]const u8, data_size: usize, width: ?*c_int, height: ?*c_int) [*c]u8 {
    return Decode(.BGR, data, data_size, width, height, null);
}

pub export fn WebPDecodeBGRA(data: [*c]const u8, data_size: usize, width: ?*c_int, height: ?*c_int) [*c]u8 {
    return Decode(.BGRA, data, data_size, width, height, null);
}

pub export fn WebPDecodeYUV(data: [*c]const u8, data_size: usize, width: ?*c_int, height: ?*c_int, u: ?*[*c]u8, v: ?*[*c]u8, stride: ?*c_int, uv_stride: ?*c_int) [*c]u8 {
    // data, width and height are checked by Decode().
    if (u == null or v == null or stride == null or uv_stride == null) {
        return null;
    }

    {
        var output: webp.DecBuffer = undefined; // only to preserve the side-infos
        const out = Decode(.YUV, data, data_size, width, height, &output);

        if (out != null) {
            const buf = &output.u.YUVA;
            u.?.* = buf.u;
            v.?.* = buf.v;
            stride.?.* = buf.y_stride;
            uv_stride.?.* = buf.u_stride;
            assert(buf.u_stride == buf.v_stride);
        }
        return out;
    }
}

fn DefaultFeatures(features: *webp.BitstreamFeatures) void {
    features.* = std.mem.zeroes(webp.BitstreamFeatures);
}

fn GetFeatures(data: [*c]const u8, data_size: usize, features: ?*webp.BitstreamFeatures) VP8Status {
    if (features == null or data == null) {
        return .InvalidParam;
    }
    DefaultFeatures(features.?);

    // Only parse enough of the data to retrieve the features.
    return ParseHeadersInternal(data, data_size, &features.?.width, &features.?.height, &features.?.has_alpha, &features.?.has_animation, &features.?.format, null);
}

//------------------------------------------------------------------------------
// WebPGetInfo()

pub export fn WebPGetInfo(data: [*c]const u8, data_size: usize, width: ?*c_int, height: ?*c_int) c_bool {
    var features: webp.BitstreamFeatures = undefined;

    if (GetFeatures(data, data_size, &features) != .Ok) {
        return 0;
    }

    if (width) |w| w.* = features.width;
    if (height) |h| h.* = features.height;

    return 1;
}

//------------------------------------------------------------------------------
// Advance decoding API

pub export fn WebPInitDecoderConfigInternal(config: ?*webp.DecoderConfig, version: c_int) c_bool {
    if (webp.WEBP_ABI_IS_INCOMPATIBLE(version, webp.DECODER_ABI_VERSION)) {
        return 0; // version mismatch
    }
    if (config == null) {
        return 0;
    }
    config.?.* = std.mem.zeroes(webp.DecoderConfig);
    DefaultFeatures(&config.?.input);
    _ = webp.WebPInitDecBuffer(&config.?.output);
    return 1;
}

pub export fn WebPGetFeaturesInternal(data: [*c]const u8, data_size: usize, features: ?*webp.BitstreamFeatures, version: c_int) VP8Status {
    if (webp.WEBP_ABI_IS_INCOMPATIBLE(version, webp.DECODER_ABI_VERSION)) {
        return .InvalidParam; // version mismatch
    }
    if (features == null) {
        return .InvalidParam;
    }
    return GetFeatures(data, data_size, features);
}

pub export fn WebPDecode(data: [*c]const u8, data_size: usize, config: ?*webp.DecoderConfig) VP8Status {
    const config_ = config orelse return .InvalidParam;

    var status = GetFeatures(data, data_size, &config_.input);
    if (status != .Ok) {
        if (status == .NotEnoughData) {
            return .BitstreamError; // Not-enough-data treated as error.
        }
        return status;
    }

    var params: DecParams = undefined;
    WebPResetDecParams(&params);
    params.options = &config_.options;
    params.output = &config_.output;
    if (webp.WebPAvoidSlowMemory(params.output.?, &config_.input)) {
        // decoding to slow memory: use a temporary in-mem buffer to decode into.
        var in_mem_buffer: webp.DecBuffer = undefined;
        _ = webp.WebPInitDecBuffer(&in_mem_buffer);
        in_mem_buffer.colorspace = config_.output.colorspace;
        in_mem_buffer.width = config_.input.width;
        in_mem_buffer.height = config_.input.height;
        params.output = &in_mem_buffer;
        status = DecodeInto(data, data_size, &params);
        if (status == .Ok) { // do the slow-copy
            status = webp.WebPCopyDecBufferPixels(&in_mem_buffer, &config_.output);
        }
        webp.WebPFreeDecBuffer(&in_mem_buffer);
    } else {
        status = DecodeInto(data, data_size, &params);
    }

    return status;
}

//------------------------------------------------------------------------------
