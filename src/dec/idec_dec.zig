const std = @import("std");
const webp = struct {
    usingnamespace @import("alpha_dec.zig");
    usingnamespace @import("buffer_dec.zig");
    usingnamespace @import("frame_dec.zig");
    usingnamespace @import("io_dec.zig");
    usingnamespace @import("tree_dec.zig");
    usingnamespace @import("vp8_dec.zig");
    usingnamespace @import("vp8l_dec.zig");
    usingnamespace @import("webp_dec.zig");
    usingnamespace @import("../utils/bit_reader_utils.zig");
    usingnamespace @import("../utils/thread_utils.zig");
    usingnamespace @import("../utils/utils.zig");
    usingnamespace @import("../webp/decode.zig");
    usingnamespace @import("../webp/format_constants.zig");
};

const c_bool = webp.c_bool;
const VP8Status = webp.VP8Status;
const assert = std.debug.assert;

/// In append mode, buffer allocations increase as multiples of this value.
/// Needs to be a power of 2.
const CHUNK_SIZE = 4096;
const MAX_MB_SIZE = 4096;

//------------------------------------------------------------------------------
// Data structures for memory and states

/// Decoding states. State normally flows as:
/// WEBP_HEADER->VP8_HEADER->VP8_PARTS0->VP8_DATA->DONE for a lossy image, and
/// WEBP_HEADER->VP8L_HEADER->VP8L_DATA->DONE for a lossless image.
/// If there is any error the decoder goes into state ERROR.
const DecState = enum(c_uint) {
    /// All the data before that of the VP8/VP8L chunk.
    WEBP_HEADER,
    /// The VP8 Frame header (within the VP8 chunk).
    VP8_HEADER,
    VP8_PARTS0,
    VP8_DATA,
    VP8L_HEADER,
    VP8L_DATA,
    DONE,
    ERROR,
};

/// Operating state for the MemBuffer
const MemBufferMode = enum(c_uint) {
    NONE = 0,
    APPEND,
    MAP,
};

/// storage for partition #0 and partial data (in a rolling fashion)
const MemBuffer = extern struct {
    /// Operation mode
    mode_: MemBufferMode,
    /// start location of the data to be decoded
    start_: usize,
    /// end location
    end_: usize,
    /// size of the allocated buffer
    buf_size_: usize,
    /// We don't own this buffer in case WebPIUpdate()
    buf_: [*c]u8,

    /// size of partition #0
    part0_size_: usize,
    /// buffer to store partition #0
    part0_buf_: [*c]const u8,
};

const IDecoder = extern struct {
    /// current decoding state
    state_: DecState,
    /// Params to store output info
    params_: webp.DecParams,
    /// for down-casting 'dec_'.
    is_lossless_: c_bool,
    /// either a VP8Decoder or a VP8LDecoder instance
    dec_: ?*anyopaque,
    io_: webp.VP8Io,

    /// input memory buffer.
    mem_: MemBuffer,
    /// output buffer (when no external one is supplied, or if the external one
    /// has slow-memory)
    output_: webp.DecBuffer,
    /// Slow-memory output to copy to eventually.
    final_output_: [*c]webp.DecBuffer,
    /// Compressed VP8/VP8L size extracted from Header.
    chunk_size_: usize,

    /// last row reached for intra-mode decoding
    last_mb_y_: c_int,
};

/// MB context to restore in case VP8DecodeMB() fails
const MBContext = extern struct {
    left_: webp.VP8MB,
    info_: webp.VP8MB,
    token_br_: webp.VP8BitReader,
};

//------------------------------------------------------------------------------
// MemBuffer: incoming data handling

inline fn MemDataSize(mem: *const MemBuffer) usize {
    return (mem.end_ -| mem.start_);
}

// Check if we need to preserve the compressed alpha data, as it may not have
// been decoded yet.
fn NeedCompressedAlpha(idec: *const IDecoder) c_bool {
    if (idec.state_ == .WEBP_HEADER) {
        // We haven't parsed the headers yet, so we don't know whether the image is
        // lossy or lossless. This also means that we haven't parsed the ALPH chunk.
        return 0;
    }
    if (idec.is_lossless_ != 0) {
        return 0; // ALPH chunk is not present for lossless images.
    } else {
        // Must be not null as idec.state_ != .WEBP_HEADER.
        const dec: *const webp.VP8Decoder = @ptrCast(@alignCast(idec.dec_.?));
        return @intFromBool((dec.alpha_data_ != null) and !(dec.is_alpha_decoded_ != 0));
    }
}

fn DoRemap(idec: *IDecoder, offset: isize) void {
    const mem = &idec.mem_;
    const new_base: [*c]const u8 = mem.buf_ + mem.start_;
    // note: for VP8, setting up idec->io_ is only really needed at the beginning
    // of the decoding, till partition #0 is complete.
    idec.io_.data = new_base;
    idec.io_.data_size = MemDataSize(mem);

    if (idec.dec_ != null) {
        if (!(idec.is_lossless_ != 0)) {
            const dec: *webp.VP8Decoder = @ptrCast(@alignCast(idec.dec_));
            const last_part = dec.num_parts_minus_one_;
            if (offset != 0) {
                for (0..last_part + 1) |p| {
                    webp.VP8RemapBitReader(&dec.parts_[p], offset);
                }
                // Remap partition #0 data pointer to new offset, but only in MAP
                // mode (in APPEND mode, partition #0 is copied into a fixed memory).
                if (mem.mode_ == .MAP) {
                    webp.VP8RemapBitReader(&dec.br_, offset);
                }
            }
            {
                const last_start = dec.parts_[last_part].buf_;
                // pointers are byte-aligned, no need to use sizeof
                webp.VP8BitReaderSetBuffer(&dec.parts_[last_part], last_start, @intFromPtr(mem.buf_) + mem.end_ - @intFromPtr(last_start));
            }
            if (NeedCompressedAlpha(idec) != 0) {
                const alph_dec: ?*webp.ALPHDecoder = dec.alph_dec_;
                dec.alpha_data_ = webp.offsetPtr(dec.alpha_data_, offset);
                if (alph_dec != null and alph_dec.?.vp8l_dec_ != null) {
                    if (alph_dec.?.method_ == webp.ALPHA_LOSSLESS_COMPRESSION) {
                        const alph_vp8l_dec = alph_dec.?.vp8l_dec_.?;
                        assert(dec.alpha_data_size_ >= webp.ALPHA_HEADER_LEN);
                        webp.VP8LBitReaderSetBuffer(&alph_vp8l_dec.br_, dec.alpha_data_ + webp.ALPHA_HEADER_LEN, dec.alpha_data_size_ -% webp.ALPHA_HEADER_LEN);
                    } else { // alph_dec.method_ == ALPHA_NO_COMPRESSION
                        // Nothing special to do in this case.
                    }
                }
            }
        } else { // Resize lossless bitreader
            const dec: *webp.VP8LDecoder = @ptrCast(@alignCast(idec.dec_.?));
            webp.VP8LBitReaderSetBuffer(&dec.br_, new_base, MemDataSize(mem));
        }
    }
}

// Appends data to the end of MemBuffer->buf_. It expands the allocated memory
// size if required and also updates VP8BitReader's if new memory is allocated.
fn AppendToMemBuffer(idec: *IDecoder, data: [*c]const u8, data_size: usize) c_bool {
    const dec: ?*webp.VP8Decoder = @ptrCast(@alignCast(idec.dec_));
    const mem: *MemBuffer = &idec.mem_;
    const need_compressed_alpha = NeedCompressedAlpha(idec) != 0;
    const old_start: [*c]const u8 = if (mem.buf_ == null) null else mem.buf_ + mem.start_;
    const old_base: [*c]const u8 = if (need_compressed_alpha) dec.?.alpha_data_ else old_start;
    assert(mem.buf_ != null or mem.start_ == 0);
    assert(mem.mode_ == .APPEND);
    if (data_size > webp.MAX_CHUNK_PAYLOAD) {
        // security safeguard: trying to allocate more than what the format
        // allows for a chunk should be considered a smoke smell.
        return 0;
    }

    if (mem.end_ + data_size > mem.buf_size_) { // Need some free memory
        // bytes, so no sizeof multiplier
        const new_mem_start: usize = @intFromPtr(old_start) - @intFromPtr(old_base);
        const current_size: usize = MemDataSize(mem) + new_mem_start;
        const new_size: u64 = @intCast(current_size + data_size);
        const extra_size: u64 = (new_size + CHUNK_SIZE - 1) & ~@as(u64, CHUNK_SIZE - 1);
        const new_buf: [*c]u8 = @ptrCast(@alignCast(webp.WebPSafeMalloc(extra_size, @sizeOf(u8)) orelse return 0));
        if (old_base != null) @memcpy(new_buf[0..current_size], old_base[0..current_size]);
        webp.WebPSafeFree(mem.buf_);
        mem.buf_ = new_buf;
        mem.buf_size_ = @truncate(extra_size);
        mem.start_ = new_mem_start;
        mem.end_ = current_size;
    }

    assert(mem.buf_ != null);
    @memcpy(mem.buf_[mem.end_..][0..data_size], data[0..data_size]);
    mem.end_ += data_size;
    assert(mem.end_ <= mem.buf_size_);

    DoRemap(idec, webp.diffPtr(@as([*c]const u8, mem.buf_ + mem.start_), old_start));
    return 1;
}

fn RemapMemBuffer(idec: *IDecoder, data: [*c]const u8, data_size: usize) c_bool {
    const mem = &idec.mem_;
    const old_buf: [*c]const u8 = mem.buf_;
    const old_start: [*c]const u8 = if (old_buf == null) null else old_buf + mem.start_;
    assert(old_buf != null or mem.start_ == 0);
    assert(mem.mode_ == .MAP);

    if (data_size < mem.buf_size_) return 0; // can't remap to a shorter buffer!

    mem.buf_ = @constCast(data); // TODO: not good
    mem.end_, mem.buf_size_ = .{ data_size, data_size };

    DoRemap(idec, webp.diffPtr(@as([*c]const u8, mem.buf_ + mem.start_), old_start));
    return 1;
}

fn InitMemBuffer(mem: *MemBuffer) void {
    mem.mode_ = .NONE;
    mem.buf_ = null;
    mem.buf_size_ = 0;
    mem.part0_buf_ = null;
    mem.part0_size_ = 0;
}

fn ClearMemBuffer(mem: *MemBuffer) void {
    if (mem.mode_ == .APPEND) {
        webp.WebPSafeFree(mem.buf_);
        webp.WebPSafeFree(@constCast(mem.part0_buf_));
    }
}

fn CheckMemBufferMode(mem: *MemBuffer, expected: MemBufferMode) c_bool {
    if (mem.mode_ == .NONE) {
        mem.mode_ = expected; // switch to the expected mode
    } else if (mem.mode_ != expected) {
        return 0; // we mixed the modes => error
    }
    assert(mem.mode_ == expected); // mode is ok
    return 1;
}

// To be called last.
fn FinishDecoding(idec: *IDecoder) VP8Status {
    const options = idec.params_.options;
    const output = idec.params_.output;

    idec.state_ = .DONE;
    if (options != null and options.?.flip != 0) {
        const status = webp.WebPFlipBuffer(output.?);
        if (status != .Ok) return status;
    }
    if (idec.final_output_ != null) {
        _ = webp.WebPCopyDecBufferPixels(output.?, idec.final_output_); // do the slow-copy
        webp.WebPFreeDecBuffer(&idec.output_);
        output.?.* = idec.final_output_.*;
        idec.final_output_ = null;
    }
    return .Ok;
}

//------------------------------------------------------------------------------
// Macroblock-decoding contexts

fn SaveContext(dec: *const webp.VP8Decoder, token_br: *const webp.VP8BitReader, context: *MBContext) void {
    context.left_ = (dec.mb_info_ - 1)[0];
    context.info_ = webp.offsetPtr(dec.mb_info_, dec.mb_x_)[0];
    context.token_br_ = token_br.*;
}

fn RestoreContext(context: *const MBContext, dec: *webp.VP8Decoder, token_br: *webp.VP8BitReader) void {
    (dec.mb_info_ - 1)[0] = context.left_;
    webp.offsetPtr(dec.mb_info_, dec.mb_x_)[0] = context.info_;
    token_br.* = context.token_br_;
}

//------------------------------------------------------------------------------

fn IDecError(idec: *IDecoder, err: VP8Status) VP8Status {
    if (idec.state_ == .VP8_DATA) {
        // Synchronize the thread, clean-up and check for errors.
        _ = webp.VP8ExitCritical(@ptrCast(@alignCast(idec.dec_.?)), &idec.io_);
    }
    idec.state_ = .ERROR;
    return err;
}

fn ChangeState(idec: *IDecoder, new_state: DecState, consumed_bytes: usize) void {
    const mem = &idec.mem_;
    idec.state_ = new_state;
    mem.start_ += consumed_bytes;
    assert(mem.start_ <= mem.end_);
    idec.io_.data = mem.buf_ + mem.start_;
    idec.io_.data_size = MemDataSize(mem);
}

// Headers
fn DecodeWebPHeaders(idec: *IDecoder) VP8Status {
    const mem = &idec.mem_;
    var data: [*c]const u8 = mem.buf_ + mem.start_;
    const curr_size = MemDataSize(mem);
    //   VP8StatusCode status;
    var headers: webp.HeaderStructure = undefined;

    headers.data = data;
    headers.data_size = curr_size;
    headers.have_all_data = 0;
    var status = webp.WebPParseHeaders(&headers);
    if (status == .NotEnoughData) {
        return .Suspended; // We haven't found a VP8 chunk yet.
    } else if (status != .Ok) {
        return IDecError(idec, status);
    }

    idec.chunk_size_ = headers.compressed_size;
    idec.is_lossless_ = headers.is_lossless;
    if (!(idec.is_lossless_ != 0)) {
        const dec = webp.VP8New() orelse return .OutOfMemory;
        dec.incremental_ = 1;
        idec.dec_ = dec;
        dec.alpha_data_ = headers.alpha_data;
        dec.alpha_data_size_ = headers.alpha_data_size;
        ChangeState(idec, .VP8_HEADER, headers.offset);
    } else {
        const dec = webp.VP8LNew() orelse return .OutOfMemory;
        idec.dec_ = dec;
        ChangeState(idec, .VP8L_HEADER, headers.offset);
    }
    return .Ok;
}

fn DecodeVP8FrameHeader(idec: *IDecoder) VP8Status {
    var data: [*c]const u8 = idec.mem_.buf_ + idec.mem_.start_;
    const curr_size = MemDataSize(&idec.mem_);

    if (curr_size < webp.VP8_FRAME_HEADER_SIZE) {
        // Not enough data bytes to extract VP8 Frame Header.
        return .Suspended;
    }
    var width: c_int, var height: c_int = .{ undefined, undefined };
    if (!webp.VP8GetInfo(data[0..curr_size], idec.chunk_size_, &width, &height)) {
        return IDecError(idec, .BitstreamError);
    }

    var bits: u32 = @as(u32, data[0]) | (@as(u32, data[1]) << 8) | (@as(u32, data[2]) << 16);
    idec.mem_.part0_size_ = (bits >> 5) + webp.VP8_FRAME_HEADER_SIZE;

    idec.io_.data = data;
    idec.io_.data_size = curr_size;
    idec.state_ = .VP8_PARTS0;
    return .Ok;
}

fn CopyParts0Data(idec: *IDecoder) VP8Status {
    const dec: *webp.VP8Decoder = @ptrCast(@alignCast(idec.dec_.?));
    const br = &dec.br_;
    const part_size = @abs(webp.diffPtr(br.buf_end_, br.buf_));
    const mem = &idec.mem_;
    assert(!(idec.is_lossless_ != 0));
    assert(mem.part0_buf_ == null);
    // the following is a format limitation, no need for runtime check:
    assert(part_size <= mem.part0_size_);
    if (part_size == 0) { // can't have zero-size partition #0
        return .BitstreamError;
    }
    if (mem.mode_ == .APPEND) {
        // We copy and grab ownership of the partition #0 data.
        const part0_buf: [*c]u8 = @ptrCast(webp.WebPSafeMalloc(1, part_size) orelse return .OutOfMemory);
        @memcpy(part0_buf[0..part_size], br.buf_[0..part_size]);
        mem.part0_buf_ = part0_buf;
        webp.VP8BitReaderSetBuffer(br, part0_buf, part_size);
    } else {
        // Else: just keep pointers to the partition #0's data in dec_->br_.
    }
    mem.start_ += part_size;
    return .Ok;
}

fn DecodePartition0(idec: *IDecoder) VP8Status {
    const dec: *webp.VP8Decoder = @ptrCast(@alignCast(idec.dec_.?));
    const io = &idec.io_;
    const params: *const webp.DecParams = &idec.params_;
    const output = params.output;

    // Wait till we have enough data for the whole partition #0
    if (MemDataSize(&idec.mem_) < idec.mem_.part0_size_) {
        return .Suspended;
    }

    if (!(webp.VP8GetHeaders(dec, io) != 0)) {
        const status = dec.status_;
        if (status == .Suspended or status == .NotEnoughData) {
            // treating NOT_ENOUGH_DATA as SUSPENDED state
            return .Suspended;
        }
        return IDecError(idec, status);
    }

    // Allocate/Verify output buffer now
    dec.status_ = webp.WebPAllocateDecBuffer(io.width, io.height, params.options, output);
    if (dec.status_ != .Ok) {
        return IDecError(idec, dec.status_);
    }
    // This change must be done before calling VP8InitFrame()
    dec.mt_method_ = webp.VP8GetThreadMethod(params.options, null, io.width, io.height);
    webp.VP8InitDithering(params.options, dec);

    dec.status_ = CopyParts0Data(idec);
    if (dec.status_ != .Ok) {
        return IDecError(idec, dec.status_);
    }

    // Finish setting up the decoding parameters. Will call io.setup().
    if (webp.VP8EnterCritical(dec, io) != .Ok) {
        return IDecError(idec, dec.status_);
    }

    // Note: past this point, teardown() must always be called
    // in case of error.
    idec.state_ = .VP8_DATA;
    // Allocate memory and prepare everything.
    if (!(webp.VP8InitFrame(dec, io) != 0)) {
        return IDecError(idec, dec.status_);
    }
    return .Ok;
}

// Remaining partitions
fn DecodeRemaining(idec: *IDecoder) VP8Status {
    const dec: *webp.VP8Decoder = @ptrCast(@alignCast(idec.dec_.?));
    const io = &idec.io_;

    // Make sure partition #0 has been read before, to set dec to ready_.
    if (!(dec.ready_ != 0)) return IDecError(idec, .BitstreamError);

    while (dec.mb_y_ < dec.mb_h_) : (dec.mb_y_ += 1) {
        if (idec.last_mb_y_ != dec.mb_y_) {
            if (!(webp.VP8ParseIntraModeRow(&dec.br_, dec) != 0)) {
                // note: normally, error shouldn't occur since we already have the whole
                // partition0 available here in DecodeRemaining(). Reaching EOF while
                // reading intra modes really means a BITSTREAM_ERROR.
                return IDecError(idec, .BitstreamError);
            }
            idec.last_mb_y_ = dec.mb_y_;
        }
        while (dec.mb_x_ < dec.mb_w_) : (dec.mb_x_ += 1) {
            const token_br = &dec.parts_[@as(u32, @intCast(dec.mb_y_)) & dec.num_parts_minus_one_];
            var context: MBContext = undefined;
            SaveContext(dec, token_br, &context);
            if (!(webp.VP8DecodeMB(dec, token_br) != 0)) {
                // We shouldn't fail when MAX_MB data was available
                if (dec.num_parts_minus_one_ == 0 and
                    MemDataSize(&idec.mem_) > MAX_MB_SIZE)
                {
                    return IDecError(idec, .BitstreamError);
                }
                // Synchronize the threads.
                if (dec.mt_method_ > 0) {
                    if (!(webp.WebPGetWorkerInterface().?.Sync.?(&dec.worker_) != 0)) {
                        return IDecError(idec, .BitstreamError);
                    }
                }
                RestoreContext(&context, dec, token_br);
                return .Suspended;
            }
            // Release buffer only if there is only one partition
            if (dec.num_parts_minus_one_ == 0) {
                idec.mem_.start_ = @abs(webp.diffPtr(token_br.buf_, idec.mem_.buf_));
                assert(idec.mem_.start_ <= idec.mem_.end_);
            }
        }
        webp.VP8InitScanline(dec); // Prepare for next scanline

        // Reconstruct, filter and emit the row.
        if (!(webp.VP8ProcessRow(dec, io) != 0))
            return IDecError(idec, .UserAbort);
    }
    // Synchronize the thread and check for errors.
    if (!(webp.VP8ExitCritical(dec, io) != 0)) {
        idec.state_ = .ERROR; // prevent re-entry in IDecError
        return IDecError(idec, .UserAbort);
    }
    dec.ready_ = 0;
    return FinishDecoding(idec);
}

fn ErrorStatusLossless(idec: *IDecoder, status: VP8Status) VP8Status {
    if (status == .Suspended or status == .NotEnoughData)
        return .Suspended;
    return IDecError(idec, status);
}

fn DecodeVP8LHeader(idec: *IDecoder) VP8Status {
    const io = &idec.io_;
    const dec: *webp.VP8LDecoder = @ptrCast(@alignCast(idec.dec_.?));
    const params: *const webp.DecParams = &idec.params_;
    const output = params.output;
    const curr_size = MemDataSize(&idec.mem_);
    assert(idec.is_lossless_ != 0);

    // Wait until there's enough data for decoding header.
    if (curr_size < (idec.chunk_size_ >> 3)) {
        dec.status_ = .Suspended;
        return ErrorStatusLossless(idec, dec.status_);
    }

    if (!(webp.VP8LDecodeHeader(dec, io) != 0)) {
        if (dec.status_ == .BitstreamError and curr_size < idec.chunk_size_)
            dec.status_ = .Suspended;
        return ErrorStatusLossless(idec, dec.status_);
    }
    // Allocate/verify output buffer now.
    dec.status_ = webp.WebPAllocateDecBuffer(io.width, io.height, params.options, output);
    if (dec.status_ != .Ok) {
        return IDecError(idec, dec.status_);
    }

    idec.state_ = .VP8L_DATA;
    return .Ok;
}

fn DecodeVP8LData(idec: *IDecoder) VP8Status {
    const dec: *webp.VP8LDecoder = @ptrCast(@alignCast(idec.dec_.?));
    const curr_size = MemDataSize(&idec.mem_);
    assert(idec.is_lossless_ != 0);

    // Switch to incremental decoding if we don't have all the bytes available.
    dec.incremental_ = @intFromBool(curr_size < idec.chunk_size_);

    if (!(webp.VP8LDecodeImage(dec) != 0)) {
        return ErrorStatusLossless(idec, dec.status_);
    }
    assert(dec.status_ == .Ok or dec.status_ == .Suspended);
    return if (dec.status_ == .Suspended) dec.status_ else FinishDecoding(idec);
}

// Main decoding loop
fn IDecode(idec: *IDecoder) VP8Status {
    var status: VP8Status = .Suspended;

    if (idec.state_ == .WEBP_HEADER) {
        status = DecodeWebPHeaders(idec);
    } else {
        if (idec.dec_ == null) return .Suspended; // can't continue if we have no decoder.
    }
    if (idec.state_ == .VP8_HEADER) {
        status = DecodeVP8FrameHeader(idec);
    }
    if (idec.state_ == .VP8_PARTS0) {
        status = DecodePartition0(idec);
    }
    if (idec.state_ == .VP8_DATA) {
        const dec: ?*webp.VP8LDecoder = @ptrCast(@alignCast(idec.dec_));
        if (dec == null) return .Suspended; // can't continue if we have no decoder.
        status = DecodeRemaining(idec);
    }
    if (idec.state_ == .VP8L_HEADER) {
        status = DecodeVP8LHeader(idec);
    }
    if (idec.state_ == .VP8L_DATA) {
        status = DecodeVP8LData(idec);
    }
    return status;
}

//------------------------------------------------------------------------------
// Internal constructor

fn NewDecoder(output_buffer: ?*webp.DecBuffer, features: ?*const webp.BitstreamFeatures) ?*IDecoder {
    const idec: *IDecoder = @ptrCast(@alignCast(webp.WebPSafeCalloc(1, @sizeOf(IDecoder)) orelse return null));

    idec.state_ = .WEBP_HEADER;
    idec.chunk_size_ = 0;

    idec.last_mb_y_ = -1;

    InitMemBuffer(&idec.mem_);
    _ = webp.WebPInitDecBuffer(&idec.output_);
    _ = webp.VP8InitIo(&idec.io_);

    webp.WebPResetDecParams(&idec.params_);
    if (output_buffer == null or webp.WebPAvoidSlowMemory(output_buffer.?, features)) {
        idec.params_.output = &idec.output_;
        idec.final_output_ = output_buffer;
        if (output_buffer) |ob| {
            idec.params_.output.?.colorspace = ob.colorspace;
        }
    } else {
        idec.params_.output = output_buffer;
        idec.final_output_ = null;
    }
    webp.WebPInitCustomIo(&idec.params_, &idec.io_); // Plug the I/O functions.

    return idec;
}

//------------------------------------------------------------------------------
// Public functions

pub export fn WebPINewDecoder(output_buffer: ?*webp.DecBuffer) ?*IDecoder {
    return NewDecoder(output_buffer, null);
}

pub export fn WebPIDecode(data: [*c]const u8, data_size: usize, config: ?*webp.DecoderConfig) ?*IDecoder {
    var tmp_features: webp.BitstreamFeatures = undefined;
    const features: *webp.BitstreamFeatures = if (config) |c| &c.input else &tmp_features;
    // memset(&tmp_features, 0, sizeof(tmp_features));

    // Parse the bitstream's features, if requested:
    if (data != null and data_size > 0) {
        if (webp.WebPGetFeatures(data, data_size, features) != .Ok) return null;
    }

    // Create an instance of the incremental decoder
    const idec = (if (config) |c| NewDecoder(&c.output, features) else NewDecoder(null, features)) orelse return null;

    // Finish initialization
    if (config) |c| {
        idec.params_.options = &c.options;
    }
    return idec;
}

pub export fn WebPIDelete(idec_arg: ?*IDecoder) void {
    const idec = idec_arg orelse return;
    if (idec.dec_) |idd| {
        if (!(idec.is_lossless_ != 0)) {
            if (idec.state_ == .VP8_DATA) {
                // Synchronize the thread, clean-up and check for errors.
                _ = webp.VP8ExitCritical(@ptrCast(@alignCast(idd)), &idec.io_);
            }
            webp.VP8Delete(@ptrCast(@alignCast(idd)));
        } else {
            webp.VP8LDelete(@ptrCast(@alignCast(idd)));
        }
    }
    ClearMemBuffer(&idec.mem_);
    webp.WebPFreeDecBuffer(&idec.output_);
    webp.WebPSafeFree(idec);
}

//------------------------------------------------------------------------------
// Wrapper toward WebPINewDecoder

pub export fn WebPINewRGB(csp: webp.ColorspaceMode, output_buffer: [*c]u8, output_buffer_size_arg: usize, output_stride_arg: c_int) ?*IDecoder {
    const is_external_memory: c_int = if (output_buffer != null) 1 else 0;
    var output_buffer_size = output_buffer_size_arg;
    var output_stride = output_stride_arg;

    if (@intFromEnum(csp) >= @intFromEnum(webp.ColorspaceMode.YUV)) return null;
    if (is_external_memory == 0) { // Overwrite parameters to sane values.
        output_buffer_size = 0;
        output_stride = 0;
    } else { // A buffer was passed. Validate the other params.
        if (output_stride == 0 or output_buffer_size == 0) {
            return null; // invalid parameter.
        }
    }
    const idec = WebPINewDecoder(null) orelse return null;
    idec.output_.colorspace = csp;
    idec.output_.is_external_memory = is_external_memory;
    idec.output_.u.RGBA.rgba = output_buffer;
    idec.output_.u.RGBA.stride = output_stride;
    idec.output_.u.RGBA.size = output_buffer_size;
    return idec;
}

pub export fn WebPINewYUVA(
    luma: [*c]u8,
    luma_size_arg: usize,
    luma_stride_arg: c_int,
    u_arg: [*c]u8,
    u_size_arg: usize,
    u_stride_arg: c_int,
    v_arg: [*c]u8,
    v_size_arg: usize,
    v_stride_arg: c_int,
    a_arg: [*c]u8,
    a_size_arg: usize,
    a_stride_arg: c_int,
) ?*IDecoder {
    const is_external_memory: c_int = if (luma != null) 1 else 0;
    var colorspace: webp.ColorspaceMode = undefined;
    var luma_size = luma_size_arg;
    var luma_stride = luma_stride_arg;
    var u = u_arg;
    var u_size = u_size_arg;
    var u_stride = u_stride_arg;
    var v = v_arg;
    var v_size = v_size_arg;
    var v_stride = v_stride_arg;
    var a = a_arg;
    var a_size = a_size_arg;
    var a_stride = a_stride_arg;

    if (is_external_memory == 0) { // Overwrite parameters to sane values.
        luma_size, u_size, v_size, a_size = .{ 0, 0, 0, 0 };
        luma_stride, u_stride, v_stride, a_stride = .{ 0, 0, 0, 0 };
        u, v, a = .{ null, null, null };
        colorspace = .YUVA;
    } else { // A luma buffer was passed. Validate the other parameters.
        if (u == null or v == null) return null;
        if (luma_size == 0 or u_size == 0 or v_size == 0) return null;
        if (luma_stride == 0 or u_stride == 0 or v_stride == 0) return null;
        if (a != null) {
            if (a_size == 0 or a_stride == 0) return null;
        }
        colorspace = if (a == null) .YUV else .YUVA;
    }

    const idec = WebPINewDecoder(null) orelse return null;

    idec.output_.colorspace = colorspace;
    idec.output_.is_external_memory = is_external_memory;
    idec.output_.u.YUVA.y = luma;
    idec.output_.u.YUVA.y_stride = luma_stride;
    idec.output_.u.YUVA.y_size = luma_size;
    idec.output_.u.YUVA.u = u;
    idec.output_.u.YUVA.u_stride = u_stride;
    idec.output_.u.YUVA.u_size = u_size;
    idec.output_.u.YUVA.v = v;
    idec.output_.u.YUVA.v_stride = v_stride;
    idec.output_.u.YUVA.v_size = v_size;
    idec.output_.u.YUVA.a = a;
    idec.output_.u.YUVA.a_stride = a_stride;
    idec.output_.u.YUVA.a_size = a_size;
    return idec;
}

pub export fn WebPINewYUV(luma: [*c]u8, luma_size: usize, luma_stride: c_int, u: [*c]u8, u_size: usize, u_stride: c_int, v: [*c]u8, v_size: usize, v_stride: c_int) ?*IDecoder {
    return WebPINewYUVA(luma, luma_size, luma_stride, u, u_size, u_stride, v, v_size, v_stride, null, 0, 0);
}

//------------------------------------------------------------------------------

fn IDecCheckStatus(idec: *const IDecoder) VP8Status {
    if (idec.state_ == .ERROR) {
        return .BitstreamError;
    }
    if (idec.state_ == .DONE) {
        return .Ok;
    }
    return .Suspended;
}

pub export fn WebPIAppend(idec: ?*IDecoder, data: [*c]const u8, data_size: usize) VP8Status {
    if (idec == null or data == null) {
        return .InvalidParam;
    }
    const status = IDecCheckStatus(idec.?);
    if (status != .Suspended) {
        return status;
    }
    // Check mixed calls between RemapMemBuffer and AppendToMemBuffer.
    if (!(CheckMemBufferMode(&idec.?.mem_, .APPEND) != 0)) {
        return .InvalidParam;
    }
    // Append data to memory buffer
    if (!(AppendToMemBuffer(idec.?, data, data_size) != 0)) {
        return .OutOfMemory;
    }
    return IDecode(idec.?);
}

pub export fn WebPIUpdate(idec: ?*IDecoder, data: [*c]const u8, data_size: usize) VP8Status {
    if (idec == null or data == null) {
        return .InvalidParam;
    }
    const status = IDecCheckStatus(idec.?);
    if (status != .Suspended) {
        return status;
    }
    // Check mixed calls between RemapMemBuffer and AppendToMemBuffer.
    if (!(CheckMemBufferMode(&idec.?.mem_, .MAP) != 0)) {
        return .InvalidParam;
    }
    // Make the memory buffer point to the new buffer
    if (!(RemapMemBuffer(idec.?, data, data_size) != 0)) {
        return .InvalidParam;
    }
    return IDecode(idec.?);
}

//------------------------------------------------------------------------------

fn GetOutputBuffer(idec: ?*const IDecoder) ?*const webp.DecBuffer {
    if (idec == null or idec.?.dec_ == null) {
        return null;
    }
    if (@intFromEnum(idec.?.state_) <= @intFromEnum(DecState.VP8_PARTS0)) {
        return null;
    }
    if (idec.?.final_output_ != null) {
        return null; // not yet slow-copied
    }
    return idec.?.params_.output;
}

pub export fn WebPIDecodedArea(idec: ?*const IDecoder, left: ?*c_int, top: ?*c_int, width: ?*c_int, height: ?*c_int) ?*const webp.DecBuffer {
    const src = GetOutputBuffer(idec.?);
    if (left) |l| l.* = 0;
    if (top) |t| t.* = 0;
    if (src) |s| {
        if (width) |w| w.* = s.width;
        if (height) |h| h.* = idec.?.params_.last_y;
    } else {
        if (width) |w| w.* = 0;
        if (height) |h| h.* = 0;
    }
    return src;
}

pub export fn WebPIDecGetRGB(idec: ?*const IDecoder, last_y: ?*c_int, width: ?*c_int, height: ?*c_int, stride: ?*c_int) [*c]u8 {
    const src = GetOutputBuffer(idec) orelse return null;
    if (@intFromEnum(src.colorspace) >= @intFromEnum(webp.ColorspaceMode.YUV)) {
        return null;
    }

    if (last_y) |l| l.* = idec.?.params_.last_y;
    if (width) |w| w.* = src.width;
    if (height) |h| h.* = src.height;
    if (stride) |s| s.* = src.u.RGBA.stride;

    return src.u.RGBA.rgba;
}

pub export fn WebPIDecGetYUVA(idec: ?*const IDecoder, last_y: ?*c_int, u: ?*[*c]u8, v: ?*[*c]u8, a: ?*[*c]u8, width: ?*c_int, height: ?*c_int, stride: ?*c_int, uv_stride: ?*c_int, a_stride: ?*c_int) [*c]u8 {
    const src = GetOutputBuffer(idec) orelse return null;
    if (@intFromEnum(src.colorspace) < @intFromEnum(webp.ColorspaceMode.YUV)) {
        return null;
    }

    if (last_y) |ptr| ptr.* = idec.?.params_.last_y;
    if (u) |ptr| ptr.* = src.u.YUVA.u;
    if (v) |ptr| ptr.* = src.u.YUVA.v;
    if (a) |ptr| ptr.* = src.u.YUVA.a;
    if (width) |ptr| ptr.* = src.width;
    if (height) |ptr| ptr.* = src.height;
    if (stride) |ptr| ptr.* = src.u.YUVA.y_stride;
    if (uv_stride) |ptr| ptr.* = src.u.YUVA.u_stride;
    if (a_stride) |ptr| ptr.* = src.u.YUVA.a_stride;

    return src.u.YUVA.y;
}

/// Set the custom IO function pointers and user-data. The setter for IO hooks
/// should be called before initiating incremental decoding. Returns true if
/// WebPIDecoder object is successfully modified, false otherwise.
pub export fn WebPISetIOHooks(idec: ?*IDecoder, put: webp.VP8Io.PutHook, setup: webp.VP8Io.SetupHook, teardown: webp.VP8Io.TeardownHook, user_data: ?*anyopaque) c_bool {
    if (idec == null or @intFromEnum(idec.?.state_) > @intFromEnum(DecState.WEBP_HEADER)) {
        return 0;
    }

    idec.?.io_.put = put;
    idec.?.io_.setup = setup;
    idec.?.io_.teardown = teardown;
    idec.?.io_.@"opaque" = user_data;

    return 1;
}
