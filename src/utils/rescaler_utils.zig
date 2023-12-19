const std = @import("std");
const webp = struct {
    usingnamespace @import("utils.zig");

    extern fn WebPRescalerDspInit() void;
    extern fn WebPRescalerImportRow(wrk: [*c]WebPRescaler, src: [*c]const u8) void;
    extern fn WebPRescalerExportRow(wrk: [*c]WebPRescaler) void;
};

const c_bool = webp.c_bool;

pub const WEBP_RESCALER_RFIX = 32; // fixed-point precision for multiplies
pub const WEBP_RESCALER_ONE = (1 << WEBP_RESCALER_RFIX);
pub inline fn WEBP_RESCALER_FRAC(x: c_int, y: c_int) u32 {
    return @truncate((@as(u64, @intCast(x)) << WEBP_RESCALER_RFIX) / @as(u64, @intCast(y)));
}

// Structure used for on-the-fly rescaling
/// type for side-buffer
pub const rescaler_t = u32;

pub const WebPRescaler = extern struct {
    /// true if we're expanding in the x direction
    x_expand: c_bool,
    /// true if we're expanding in the y direction
    y_expand: c_bool,
    /// bytes to jump between pixels
    num_channels: c_int,
    /// fixed-point scaling factor
    fx_scale: u32,
    /// fixed-point scaling factor
    fy_scale: u32,
    /// fixed-point scaling factor
    fxy_scale: u32,
    /// vertical accumulator
    y_accum: c_int,
    /// vertical increment
    y_add: c_int,
    /// vertical increment
    y_sub: c_int,
    /// horizontal increment
    x_add: c_int,
    /// horizontal increment
    x_sub: c_int,
    /// source dimension
    src_width: c_int,
    /// source dimension
    src_height: c_int,
    /// destination dimension
    dst_width: c_int,
    /// destination dimension
    dst_height: c_int,
    /// row counter for input and output
    src_y: c_int,
    /// row counter for input and output
    dst_y: c_int,
    dst: [*c]u8,
    dst_stride: c_int,
    /// work buffer
    irow: [*c]rescaler_t,
    /// work buffer
    frow: [*c]rescaler_t,

    /// Return true if input is finished
    pub inline fn inputDone(rescaler: *const WebPRescaler) bool {
        return (rescaler.src_y >= rescaler.src_height);
    }

    /// Return true if output is finished
    pub inline fn outputDone(rescaler: *const WebPRescaler) bool {
        return rescaler.dst_y >= rescaler.dst_height;
    }
    /// Return true if there are pending output rows ready.
    pub inline fn hasPendingOutput(rescaler: *const WebPRescaler) bool {
        return !(rescaler.outputDone()) and (rescaler.y_accum <= 0);
    }
};

/// Initialize a rescaler given scratch area `work` and dimensions of src & dst.
/// Returns false in case of error.
pub export fn WebPRescalerInit(rescaler: *WebPRescaler, src_width: c_int, src_height: c_int, dst: [*c]u8, dst_width: c_int, dst_height: c_int, dst_stride: c_int, num_channels: c_int, work: [*c]rescaler_t) c_bool {
    const x_add, const x_sub = .{ src_width, dst_width };
    const y_add, const y_sub = .{ src_height, dst_height };
    const total_size: u64 = 2 * @as(u64, @intCast(dst_width)) * @as(u64, @intCast(num_channels)) * @sizeOf(rescaler_t);
    if (!webp.CheckSizeOverflow(total_size)) return 0;

    rescaler.x_expand = @intFromBool(src_width < dst_width);
    rescaler.y_expand = @intFromBool(src_height < dst_height);
    rescaler.src_width = src_width;
    rescaler.src_height = src_height;
    rescaler.dst_width = dst_width;
    rescaler.dst_height = dst_height;
    rescaler.src_y = 0;
    rescaler.dst_y = 0;
    rescaler.dst = dst;
    rescaler.dst_stride = dst_stride;
    rescaler.num_channels = num_channels;

    // for 'x_expand', we use bilinear interpolation
    rescaler.x_add = if (rescaler.x_expand != 0) (x_sub - 1) else x_add;
    rescaler.x_sub = if (rescaler.x_expand != 0) (x_add - 1) else x_sub;
    if (!(rescaler.x_expand != 0)) { // fx_scale is not used otherwise
        rescaler.fx_scale = WEBP_RESCALER_FRAC(1, rescaler.x_sub);
    }
    // vertical scaling parameters
    rescaler.y_add = if (rescaler.y_expand != 0) (y_add - 1) else y_add;
    rescaler.y_sub = if (rescaler.y_expand != 0) (y_sub - 1) else y_sub;
    rescaler.y_accum = if (rescaler.y_expand != 0) rescaler.y_sub else rescaler.y_add;
    if (!(rescaler.y_expand != 0)) {
        // This is WEBP_RESCALER_FRAC(dst_height, x_add * y_add) without the cast.
        // Its value is <= WEBP_RESCALER_ONE, because dst_height <= rescaler->y_add
        // and rescaler->x_add >= 1;
        const num: u64 = @as(u64, @intCast(dst_height)) * WEBP_RESCALER_ONE;
        const den: u64 = @as(u64, @intCast(rescaler.x_add)) * @as(u64, @intCast(rescaler.y_add));
        const ratio: u64 = num / den;
        if (ratio != @as(u32, @truncate(ratio))) {
            // When ratio == WEBP_RESCALER_ONE, we can't represent the ratio with the
            // current fixed-point precision. This happens when src_height ==
            // rescaler->y_add (which == src_height), and rescaler->x_add == 1.
            // => We special-case fxy_scale = 0, in WebPRescalerExportRow().
            rescaler.fxy_scale = 0;
        } else {
            rescaler.fxy_scale = @truncate(ratio);
        }
        rescaler.fy_scale = WEBP_RESCALER_FRAC(1, rescaler.y_sub);
    } else {
        rescaler.fy_scale = WEBP_RESCALER_FRAC(1, rescaler.x_add);
        // rescaler->fxy_scale is unused here.
    }
    rescaler.irow = work;
    rescaler.frow = webp.offsetPtr(work, num_channels * dst_width);
    @memset(@as([*]u8, @ptrCast(work))[0..total_size], 0);

    webp.WebPRescalerDspInit();
    return 1;
}

/// If either `scaled_width` or `scaled_height` (but not both) is 0 the value
/// will be calculated preserving the aspect ratio, otherwise the values are
/// left unmodified. Returns true on success, false if either value is 0 after
/// performing the scaling calculation.
pub export fn WebPRescalerGetScaledDimensions(src_width: c_int, src_height: c_int, scaled_width: *c_int, scaled_height: *c_int) c_bool {
    var width = scaled_width.*;
    var height = scaled_height.*;
    const max_size = comptime @divTrunc(std.math.maxInt(c_int), 2);

    // if width is unspecified, scale original proportionally to height ratio.
    if (width == 0 and src_height > 0) {
        width = @intCast((@as(u64, @intCast(src_width)) * @as(u64, @intCast(height)) + @as(u64, @intCast(src_height - 1))) / @as(u64, @intCast(src_height)));
    }
    // if height is unspecified, scale original proportionally to width ratio.
    if (height == 0 and src_width > 0) {
        height = @intCast((@as(u64, @intCast(src_height)) * @as(u64, @intCast(width)) + @as(u64, @intCast(src_width - 1))) / @as(u64, @intCast(src_width)));
    }
    // Check if the overall dimensions still make sense.
    if (width <= 0 or height <= 0 or width > max_size or height > max_size) {
        return 0;
    }

    scaled_width.* = width;
    scaled_height.* = height;
    return 1;
}

//------------------------------------------------------------------------------
// all-in-one calls

/// Returns the number of input lines needed next to produce one output line,
/// considering that the maximum available input lines are 'max_num_lines'.
pub export fn WebPRescaleNeededLines(rescaler: *const WebPRescaler, max_num_lines: c_int) c_int {
    const num_lines = @divTrunc((rescaler.y_accum + rescaler.y_sub - 1), rescaler.y_sub);
    return if (num_lines > max_num_lines) max_num_lines else num_lines;
}

/// Import multiple rows over all channels, until at least one row is ready to
/// be exported. Returns the actual number of lines that were imported.
pub export fn WebPRescalerImport(rescaler: *WebPRescaler, num_lines: c_int, src_: [*c]const u8, src_stride: c_int) c_int {
    var src = src_;
    var total_imported: c_int = 0;
    while (total_imported < num_lines and !rescaler.hasPendingOutput()) {
        if (rescaler.y_expand != 0) {
            const tmp = rescaler.irow;
            rescaler.irow = rescaler.frow;
            rescaler.frow = tmp;
        }
        webp.WebPRescalerImportRow(rescaler, src);
        if (!(rescaler.y_expand != 0)) { // Accumulate the contribution of the new row.
            for (0..@intCast(rescaler.num_channels * rescaler.dst_width)) |x| {
                rescaler.irow[x] += rescaler.frow[x];
            }
        }
        rescaler.src_y += 1;
        src = webp.offsetPtr(src, src_stride);
        total_imported += 1;
        rescaler.y_accum -= rescaler.y_sub;
    }
    return total_imported;
}

/// Export as many rows as possible. Return the numbers of rows written.
pub export fn WebPRescalerExport(rescaler: *WebPRescaler) c_int {
    var total_exported: c_int = 0;
    while (rescaler.hasPendingOutput()) {
        webp.WebPRescalerExportRow(rescaler);
        total_exported += 1;
    }
    return total_exported;
}
