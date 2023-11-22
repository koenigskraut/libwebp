const std = @import("std");
const build_options = @import("build_options");
const webp = struct {
    usingnamespace @import("webp_dec.zig");
    usingnamespace @import("../utils/utils.zig");
    usingnamespace @import("../webp/decode.zig");

    extern fn WebPRescalerGetScaledDimensions(src_width: c_int, src_height: c_int, scaled_width: ?*c_int, scaled_height: ?*c_int) c_int;
    extern fn WebPCopyPlane(src: [*c]const u8, src_stride: c_int, dst: [*c]u8, dst_stride: c_int, width: c_int, height: c_int) void;
};

const assert = std.debug.assert;
const VP8Error = webp.VP8Error;
const VP8Status = webp.VP8Status;
const CspMode = webp.ColorspaceMode;
const offsetPtr = webp.offsetPtr;

//------------------------------------------------------------------------------
// webp.DecBuffer

/// Number of bytes per pixel for the different color-spaces.
const kModeBpp = [@intFromEnum(CspMode.LAST)]u8{
    3, 4, 3, 4, 4, 2, 2,
    4, 4, 4, 2, // pre-multiplied modes
    1, 1,
};

/// strictly speaking, the very last (or first, if flipped) row
/// doesn't require padding.
inline fn MIN_BUFFER_SIZE(WIDTH: anytype, HEIGHT: anytype, STRIDE: anytype) u64 {
    return @intCast((STRIDE) * (@abs(HEIGHT) - 1) + @abs(WIDTH));
}

fn CheckDecBuffer(buffer: *const webp.DecBuffer) VP8Error!void {
    var ok = true;
    const mode = buffer.colorspace;
    const width = buffer.width;
    const height = buffer.height;
    if (!CspMode.isValidColorspace(@intFromEnum(mode))) {
        ok = false;
    } else if (!mode.isRGBMode()) {
        // YUV checks
        const buf: *const webp.YUVABuffer = &buffer.u.YUVA;
        const uv_width = @divTrunc((width + 1), 2);
        const uv_height = @divTrunc((height + 1), 2);
        const y_stride = @abs(buf.y_stride);
        const u_stride = @abs(buf.u_stride);
        const v_stride = @abs(buf.v_stride);
        const a_stride = @abs(buf.a_stride);
        const y_size: u64 = MIN_BUFFER_SIZE(width, height, y_stride);
        const u_size: u64 = MIN_BUFFER_SIZE(uv_width, uv_height, u_stride);
        const v_size: u64 = MIN_BUFFER_SIZE(uv_width, uv_height, v_stride);
        const a_size: u64 = MIN_BUFFER_SIZE(width, height, a_stride);
        ok = ok and (y_size <= buf.y_size);
        ok = ok and (u_size <= buf.u_size);
        ok = ok and (v_size <= buf.v_size);
        ok = ok and (y_stride >= width);
        ok = ok and (u_stride >= uv_width);
        ok = ok and (v_stride >= uv_width);
        ok = ok and (buf.y != null);
        ok = ok and (buf.u != null);
        ok = ok and (buf.v != null);
        if (mode == .YUVA) {
            ok = ok and (a_stride >= width);
            ok = ok and (a_size <= buf.a_size);
            ok = ok and (buf.a != null);
        }
    } else {
        // RGB checks
        const buf: *const webp.RGBABuffer = &buffer.u.RGBA;
        const stride = @abs(buf.stride);
        const size = MIN_BUFFER_SIZE(@as(u64, @intCast(width)) * kModeBpp[@intFromEnum(mode)], height, stride);
        ok = ok and (size <= buf.size);
        ok = ok and (stride >= @as(u64, @intCast(width)) * kModeBpp[@intFromEnum(mode)]);
        ok = ok and (buf.rgba != null);
    }
    if (!ok) return error.InvalidParam;
}

fn AllocateBuffer(buffer: *webp.DecBuffer) VP8Error!void {
    const w = buffer.width;
    const h = buffer.height;
    const mode = buffer.colorspace;

    if (w <= 0 or h <= 0 or !CspMode.isValidColorspace(@intFromEnum(mode)))
        return error.InvalidParam;

    if (buffer.is_external_memory <= 0 and buffer.private_memory == null) {
        var output: [*c]u8 = undefined;
        var uv_stride: c_int, var a_stride: c_int = .{ 0, 0 };
        var uv_size: u64, var a_size: u64, var total_size: u64 = .{ 0, 0, 0 };
        // We need memory and it hasn't been allocated yet.
        // => initialize output buffer, now that dimensions are known.
        var stride: c_int = undefined;
        var size: u64 = undefined;

        if (@as(u64, @intCast(w)) * kModeBpp[@intFromEnum(mode)] >= (1 << 31))
            return error.InvalidParam;
        stride = w * @as(c_int, @intCast(kModeBpp[@intFromEnum(mode)]));
        size = @intCast(stride * h);
        if (!mode.isRGBMode()) {
            uv_stride = @divTrunc((w + 1), 2);
            uv_size = @intCast(uv_stride * @divTrunc((h + 1), 2));
            if (mode == .YUVA) {
                a_stride = w;
                a_size = @intCast(a_stride * h);
            }
        }
        total_size = size + 2 * uv_size + a_size;

        output = @ptrCast(webp.WebPSafeMalloc(total_size, @sizeOf(u8)) orelse return error.OutOfMemory);
        buffer.private_memory = output;

        if (!mode.isRGBMode()) {
            // YUVA initialization
            const buf: *webp.YUVABuffer = &buffer.u.YUVA;
            buf.y = output;
            buf.y_stride = stride;
            buf.y_size = size;
            buf.u = output + size;
            buf.u_stride = uv_stride;
            buf.u_size = uv_size;
            buf.v = output + size + uv_size;
            buf.v_stride = uv_stride;
            buf.v_size = uv_size;
            if (mode == .YUVA) {
                buf.a = output + @as(usize, size + 2 * uv_size);
            }
            buf.a_size = a_size;
            buf.a_stride = a_stride;
        } else {
            // RGBA initialization
            const buf: *webp.RGBABuffer = &buffer.u.RGBA;
            buf.rgba = output;
            buf.stride = stride;
            buf.size = size;
        }
    }
    return CheckDecBuffer(buffer);
}

pub export fn WebPFlipBuffer(buffer_arg: ?*webp.DecBuffer) VP8Status {
    const buffer = buffer_arg orelse return .InvalidParam;
    if (buffer.colorspace.isRGBMode()) {
        const buf = &buffer.u.RGBA;
        const ptr_inc: i64 = @as(i64, (buffer.height - 1)) * buf.stride;
        buf.rgba = offsetPtr(buf.rgba, ptr_inc);
        buf.stride = -buf.stride;
    } else {
        const buf = &buffer.u.YUVA;
        const H: i64 = buffer.height;
        buf.y = offsetPtr(buf.y, (H - 1) * buf.y_stride);
        buf.y_stride = -buf.y_stride;
        buf.u = offsetPtr(buf.u, ((H - 1) >> 1) * buf.u_stride);
        buf.u_stride = -buf.u_stride;
        buf.v = offsetPtr(buf.v, ((H - 1) >> 1) * buf.v_stride);
        buf.v_stride = -buf.v_stride;
        if (buf.a != null) {
            buf.a = offsetPtr(buf.a, (H - 1) * buf.a_stride);
            buf.a_stride = -buf.a_stride;
        }
    }
    return .Ok;
}

pub export fn WebPAllocateDecBuffer(width_arg: c_int, height_arg: c_int, options_arg: ?*const webp.DecoderOptions, buffer_arg: ?*webp.DecBuffer) VP8Status {
    const buffer = buffer_arg orelse return .InvalidParam;
    var width, var height = .{ width_arg, height_arg };
    if (width <= 0 or height <= 0)
        return .InvalidParam;

    if (options_arg) |options| {
        // First, apply options if there is any.
        if (options.use_cropping != 0) {
            const cw: c_int = options.crop_width;
            const ch: c_int = options.crop_height;
            const x: c_int = options.crop_left & ~@as(c_int, 1);
            const y: c_int = options.crop_top & ~@as(c_int, 1);
            if (!webp.WebPCheckCropDimensions(width, height, x, y, cw, ch)) {
                return .InvalidParam; // out of frame boundary.
            }
            width = cw;
            height = ch;
        }

        if (options.use_scaling != 0) {
            if (comptime !build_options.reduce_size) {
                var scaled_width = options.scaled_width;
                var scaled_height = options.scaled_height;
                if (webp.WebPRescalerGetScaledDimensions(width, height, &scaled_width, &scaled_height) == 0)
                    return .InvalidParam;

                width = scaled_width;
                height = scaled_height;
            } else {
                return .InvalidParam; // rescaling not supported
            }
        }
    }
    buffer.width = width;
    buffer.height = height;

    // Then, allocate buffer for real.
    AllocateBuffer(buffer) catch |e| return VP8Status.fromErr(e);

    // Use the stride trick if vertical flip is needed.
    if (options_arg) |options| {
        if (options.flip != 0) return WebPFlipBuffer(buffer);
    }
    return .Ok;
}

//------------------------------------------------------------------------------
// constructors / destructors

pub export fn WebPInitDecBufferInternal(buffer: ?*webp.DecBuffer, version: c_int) c_int {
    // TODO: no export
    if (webp.WEBP_ABI_IS_INCOMPATIBLE(version, webp.DECODER_ABI_VERSION)) {
        return 0; // version mismatch
    }
    if (buffer) |b| b.* = std.mem.zeroes(webp.DecBuffer) else return 0;
    return 1;
}

pub export fn WebPFreeDecBuffer(buffer: ?*webp.DecBuffer) void {
    const b = buffer orelse return;
    if (b.is_external_memory <= 0) {
        webp.WebPSafeFree(b.private_memory);
    }
    b.private_memory = null;
}

pub export fn WebPCopyDecBuffer(src_arg: ?*const webp.DecBuffer, dst_arg: ?*webp.DecBuffer) void {
    const src = src_arg orelse return;
    const dst = dst_arg orelse return;
    dst.* = src.*;
    if (src.private_memory != null) {
        dst.is_external_memory = 1; // dst buffer doesn't own the memory.
        dst.private_memory = null;
    }
}

// Copy and transfer ownership from src to dst (beware of parameter order!)
pub fn WebPGrabDecBuffer(src_arg: ?*webp.DecBuffer, dst_arg: ?*webp.DecBuffer) void {
    const src = src_arg orelse return;
    const dst = dst_arg orelse return;
    dst.* = src.*;
    if (src.private_memory != null) {
        src.is_external_memory = 1; // src relinquishes ownership
        src.private_memory = null;
    }
}

pub export fn WebPCopyDecBufferPixels(src_buf: *const webp.DecBuffer, dst_buf: *webp.DecBuffer) VP8Status {
    assert(src_buf.colorspace == dst_buf.colorspace);

    dst_buf.width = src_buf.width;
    dst_buf.height = src_buf.height;
    CheckDecBuffer(dst_buf) catch return .InvalidParam;
    if (src_buf.colorspace.isRGBMode()) {
        const src = &src_buf.u.RGBA;
        const dst = &dst_buf.u.RGBA;
        webp.WebPCopyPlane(src.rgba, src.stride, dst.rgba, dst.stride, src_buf.width * kModeBpp[@intFromEnum(src_buf.colorspace)], src_buf.height);
    } else {
        const src = &src_buf.u.YUVA;
        const dst = &dst_buf.u.YUVA;
        webp.WebPCopyPlane(src.y, src.y_stride, dst.y, dst.y_stride, src_buf.width, src_buf.height);
        webp.WebPCopyPlane(src.u, src.u_stride, dst.u, dst.u_stride, @divTrunc(src_buf.width + 1, 2), @divTrunc(src_buf.height + 1, 2));
        webp.WebPCopyPlane(src.v, src.v_stride, dst.v, dst.v_stride, @divTrunc(src_buf.width + 1, 2), @divTrunc(src_buf.height + 1, 2));
        if (src_buf.colorspace.isAlphaMode()) {
            webp.WebPCopyPlane(src.a, src.a_stride, dst.a, dst.a_stride, src_buf.width, src_buf.height);
        }
    }
    return .Ok;
}

pub export fn WebPAvoidSlowMemory(output: *const webp.DecBuffer, features: ?*const webp.BitstreamFeatures) bool {
    return (output.is_external_memory >= 2) and
        output.colorspace.isPremultipliedMode() and
        (features != null and features.?.has_alpha != 0);
}
