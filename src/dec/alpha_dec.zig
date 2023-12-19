const std = @import("std");
const webp = struct {
    usingnamespace @import("io_dec.zig");
    usingnamespace @import("vp8_dec.zig");
    usingnamespace @import("vp8l_dec.zig");
    usingnamespace @import("../dsp/dsp.zig");
    usingnamespace @import("../utils/quant_levels_dec_utils.zig");
    usingnamespace @import("../utils/utils.zig");
    usingnamespace @import("../webp/decode.zig");
    usingnamespace @import("../webp/format_constants.zig");
};

const assert = std.debug.assert;
const c_bool = webp.c_bool;

pub const ALPHDecoder = extern struct {
    width_: c_int,
    height_: c_int,
    method_: c_int,
    filter_: webp.FilterType,
    pre_processing_: c_int,
    vp8l_dec_: ?*webp.VP8LDecoder,
    io_: webp.VP8Io,
    /// Although alpha channel requires only 1 byte per pixel, sometimes
    /// `VP8LDecoder` may need to allocate 4 bytes per pixel internally during
    /// decode.
    use_8b_decode_: c_bool,
    output_: [*c]u8,
    /// last output row (or `null`)
    prev_line_: [*c]const u8,
};

// Allocates a new alpha decoder instance.
fn ALPHNew() ?*ALPHDecoder {
    const dec: *ALPHDecoder = @ptrCast(@alignCast(webp.WebPSafeCalloc(1, @sizeOf(ALPHDecoder))));
    return dec;
}

// Clears and deallocates an alpha decoder instance.
fn ALPHDelete(dec: ?*ALPHDecoder) void {
    const d = dec orelse return;
    webp.VP8LDelete(d.vp8l_dec_);
    d.vp8l_dec_ = null;
    webp.WebPSafeFree(d);
}

//------------------------------------------------------------------------------
// Decoding.

/// Initialize alpha decoding by parsing the alpha header and decoding the image
/// header for alpha data stored using lossless compression.
/// Returns false in case of error in alpha header (data too short, invalid
/// compression method or filter, error in lossless header data etc).
fn ALPHInit(dec: *ALPHDecoder, data: []const u8, src_io: *const webp.VP8Io, output: [*]u8) bool {
    var ok = false;
    const alpha_data = data[webp.ALPHA_HEADER_LEN..];
    var rsrv: c_uint = undefined;
    const io: *webp.VP8Io = &dec.io_;

    webp.VP8FiltersInit();
    dec.output_ = output;
    dec.width_ = src_io.width;
    dec.height_ = src_io.height;
    assert(dec.width_ > 0 and dec.height_ > 0);

    if (data.len <= webp.ALPHA_HEADER_LEN) return false;

    dec.method_ = (data[0] >> 0) & 0x03;
    dec.filter_ = @enumFromInt((data[0] >> 2) & 0x03);
    dec.pre_processing_ = (data[0] >> 4) & 0x03;
    rsrv = (data[0] >> 6) & 0x03;
    if (dec.method_ < webp.ALPHA_NO_COMPRESSION or
        dec.method_ > webp.ALPHA_LOSSLESS_COMPRESSION or
        @intFromEnum(dec.filter_) >= @intFromEnum(webp.FilterType.LAST) or
        dec.pre_processing_ > webp.ALPHA_PREPROCESSED_LEVELS or
        rsrv != 0)
    {
        return false;
    }

    // Copy the necessary parameters from src_io to io
    _ = webp.VP8InitIo(io);
    webp.WebPInitCustomIo(null, io);
    io.@"opaque" = dec;
    io.width = src_io.width;
    io.height = src_io.height;

    io.use_cropping = src_io.use_cropping;
    io.crop_left = src_io.crop_left;
    io.crop_right = src_io.crop_right;
    io.crop_top = src_io.crop_top;
    io.crop_bottom = src_io.crop_bottom;
    // No need to copy the scaling parameters.

    if (dec.method_ == webp.ALPHA_NO_COMPRESSION) {
        const alpha_decoded_size = dec.width_ * dec.height_;
        ok = (alpha_data.len >= alpha_decoded_size);
    } else {
        assert(dec.method_ == webp.ALPHA_LOSSLESS_COMPRESSION);
        ok = webp.VP8LDecodeAlphaHeader(dec, alpha_data.ptr, alpha_data.len) != 0;
    }

    return ok;
}

/// Decodes, unfilters and dequantizes *at least* 'num_rows' rows of alpha
/// starting from row number 'row'. It assumes that rows up to (row - 1) have
/// already been decoded.
/// Returns false in case of bitstream error.
fn ALPHDecode(dec: *webp.VP8Decoder, row: c_int, num_rows: c_int) bool {
    const alph_dec: *ALPHDecoder = dec.alph_dec_.?;
    const width = alph_dec.width_;
    const height = alph_dec.io_.crop_bottom;
    if (alph_dec.method_ == webp.ALPHA_NO_COMPRESSION) {
        var prev_line = dec.alpha_prev_line_;
        var deltas = dec.alpha_data_ + webp.ALPHA_HEADER_LEN + @abs(row * width);
        var dst = dec.alpha_plane_.?.ptr + @abs(row * width);
        assert(deltas <= &dec.alpha_data_[dec.alpha_data_size_]);
        assert(webp.WebPUnfilters[@intFromEnum(alph_dec.filter_)] != null);
        // var y: usize = 0;
        for (0..@abs(num_rows)) |_| {
            webp.WebPUnfilters[@intFromEnum(alph_dec.filter_)].?(prev_line, deltas, dst, width);
            prev_line = dst;
            dst += @abs(width);
            deltas += @abs(width);
        }
        dec.alpha_prev_line_ = prev_line;
    } else { // alph_dec->method_ == ALPHA_LOSSLESS_COMPRESSION
        assert(alph_dec.vp8l_dec_ != null);
        if (webp.VP8LDecodeAlphaImageStream(alph_dec, row + num_rows) == 0) {
            return false;
        }
    }

    if (row + num_rows >= height) {
        dec.is_alpha_decoded_ = true;
    }
    return true;
}

fn AllocateAlphaPlane(dec: *webp.VP8Decoder, io: *const webp.VP8Io) bool {
    const stride = io.width;
    const height = io.crop_bottom;
    const alpha_size: u64 = @intCast(stride * height);
    assert(dec.alpha_plane_mem_ == null);
    dec.alpha_plane_mem_ = if (webp.WebPSafeMalloc(alpha_size, @sizeOf(u8))) |ptr|
        @as([*]u8, @ptrCast(ptr))[0..alpha_size]
    else
        null;
    if (dec.alpha_plane_mem_ == null) {
        return webp.VP8SetError(dec, .OutOfMemory, "Alpha decoder initialization failed.") != 0;
    }
    dec.alpha_plane_ = dec.alpha_plane_mem_;
    dec.alpha_prev_line_ = null;
    return true;
}

/// Deallocate memory associated to dec->alpha_plane_ decoding
pub fn WebPDeallocateAlphaMemory(dec: *webp.VP8Decoder) void {
    webp.WebPSafeFree(if (dec.alpha_plane_mem_) |slice| slice.ptr else null);
    dec.alpha_plane_mem_ = null;
    dec.alpha_plane_ = null;
    ALPHDelete(dec.alph_dec_);
    dec.alph_dec_ = null;
}

pub fn VP8DecompressAlphaRows(dec: *webp.VP8Decoder, io: *const webp.VP8Io, row: c_int, num_rows_arg: c_int) ?[*]const u8 {
    const width = io.width;
    const height = io.crop_bottom;

    var num_rows = num_rows_arg;
    if (row < 0 or num_rows <= 0 or row + num_rows > height) {
        return null;
    }

    if (!dec.is_alpha_decoded_) {
        if (dec.alph_dec_ == null) { // Initialize decoder.
            dec.alph_dec_ = @ptrCast(ALPHNew() orelse {
                _ = webp.VP8SetError(dec, .OutOfMemory, "Alpha decoder initialization failed.");
                return null;
            });
            if (!AllocateAlphaPlane(dec, io)) {
                WebPDeallocateAlphaMemory(dec);
                return null;
            }
            if (!ALPHInit(dec.alph_dec_.?, dec.alpha_data_[0..dec.alpha_data_size_], io, dec.alpha_plane_.?.ptr)) {
                const vp8l_dec = dec.alph_dec_.?.vp8l_dec_;
                _ = webp.VP8SetError(dec, if (vp8l_dec) |ptr| ptr.status_ else .OutOfMemory, "Alpha decoder initialization failed.");
                {
                    WebPDeallocateAlphaMemory(dec);
                    return null;
                }
            }
            // if we allowed use of alpha dithering, check whether it's needed at all
            if (dec.alph_dec_.?.pre_processing_ != webp.ALPHA_PREPROCESSED_LEVELS) {
                dec.alpha_dithering_ = 0; // disable dithering
            } else {
                num_rows = height - row; // decode everything in one pass
            }
        }

        assert(dec.alph_dec_ != null);
        assert(row + num_rows <= height);
        if (!ALPHDecode(dec, row, num_rows)) {
            WebPDeallocateAlphaMemory(dec);
            return null;
        }

        if (dec.is_alpha_decoded_) { // finished?
            ALPHDelete(dec.alph_dec_);
            dec.alph_dec_ = null;
            if (dec.alpha_dithering_ > 0) {
                const alpha: [*c]u8 = dec.alpha_plane_.?.ptr + @abs(io.crop_top * width + io.crop_left);
                if (webp.WebPDequantizeLevels(alpha, io.crop_right - io.crop_left, io.crop_bottom - io.crop_top, width, dec.alpha_dithering_) == 0) {
                    WebPDeallocateAlphaMemory(dec);
                    return null;
                }
            }
        }
    }

    // Return a pointer to the current decoded row.
    return dec.alpha_plane_.?.ptr + @abs(row * width);
}
