const std = @import("std");
const webp = struct {
    usingnamespace @import("utils.zig");
};

const c_bool = webp.c_bool;

/// set `true` to enable ordered dithering (not vital)
const USE_DITHERING = false;

const FIX = 16; // fix-point precision for averaging
const LFIX = 2; // extra precision for look-up table
const LUT_SIZE = ((1 << (8 + LFIX)) - 1); // look-up table size

/// extra precision for ordered dithering
const DFIX = if (USE_DITHERING) 4 else 0;

/// dithering size (must be a power of two)
const DSIZE = 4;

/// cf. https://en.wikipedia.org/wiki/Ordered_dithering
/// coefficients are in DFIX fixed-point precision
const kOrderedDither = [DSIZE][DSIZE]u8{
    .{ 0, 8, 2, 10 },
    .{ 12, 4, 14, 6 },
    .{ 3, 11, 1, 9 },
    .{ 15, 7, 13, 5 },
};

pub const SmoothParams = extern struct {
    /// dimension
    width_: c_int,
    /// dimension
    height_: c_int,
    /// stride in bytes
    stride_: c_int,
    /// current input row being processed
    row_: c_int,
    /// input pointer
    src_: [*c]u8,
    /// output pointer
    dst_: [*c]u8,

    /// filter radius (=delay)
    radius_: c_int,
    /// normalization factor, in FIX bits precision
    scale_: c_int,

    /// all memory
    mem_: ?*anyopaque,

    // various scratch buffers
    start_: [*c]u16,
    cur_: [*c]u16,
    end_: [*c]u16,
    top_: [*c]u16,
    average_: [*c]u16,

    // input levels distribution
    /// number of quantized levels
    num_levels_: c_int,
    /// min level value
    min_: c_int,
    /// max level value
    max_: c_int,
    /// smallest distance between two consecutive levels
    min_level_dist_: c_int,

    /// size = 1 + 2*LUT_SIZE  -> ~4k memory
    correction_: [*c]i16,
};

//------------------------------------------------------------------------------

const CLIP_8b_MASK: c_int = (~@as(c_int, 0) << (8 + DFIX));

inline fn clip_8b(v: c_int) u8 {
    return if (!(v & CLIP_8b_MASK != 0)) @truncate(@as(c_uint, @bitCast(v >> DFIX))) else if (v < 0) 0 else 255;
}

// vertical accumulation
fn VFilter(p: *SmoothParams) void {
    const src = p.src_;
    const w = p.width_;
    const cur = p.cur_;
    const top = p.top_;
    const out = p.end_;
    var sum: u16 = 0; // all arithmetic is modulo 16bit

    for (0..@intCast(w)) |x| {
        sum +%= src[x];
        const new_value: u16 = top[x] +% sum;
        out[x] = new_value -% cur[x]; // vertical sum of 'r' pixels.
        cur[x] = new_value;
    }
    // move input pointers one row down
    p.top_ = p.cur_;
    p.cur_ = webp.offsetPtr(p.cur_, w);
    if (p.cur_ == p.end_) p.cur_ = p.start_; // roll-over
    // We replicate edges, as it's somewhat easier as a boundary condition.
    // That's why we don't update the 'src' pointer on top/bottom area:
    if (p.row_ >= 0 and p.row_ < p.height_ - 1) {
        p.src_ = webp.offsetPtr(p.src_, p.stride_);
    }
}

fn HFilter(p: *SmoothParams) void {
    const in: [*c]const u16 = p.end_;
    const out = p.average_;
    const scale: u32 = @bitCast(@as(i32, @intCast(p.scale_)));
    const w: usize = @intCast(p.width_);
    const r: usize = @intCast(p.radius_);

    var x: usize = 0;
    while (x <= r) : (x += 1) { // left mirroring
        const delta = @as(u32, in[x + r - 1]) + @as(u32, in[r - x]);
        out[x] = @truncate((delta *% scale) >> FIX);
    }
    while (x < w - r) : (x += 1) { // bulk middle run
        const delta = @as(u32, in[x + r]) -% @as(u32, in[x - r - 1]);
        out[x] = @truncate((delta *% scale) >> FIX);
    }
    while (x < w) : (x += 1) { // right mirroring
        const delta = 2 * @as(u32, in[w - 1]) -% @as(u32, in[2 * w - 2 - r - x]) -% @as(u32, in[x - r - 1]);
        out[x] = @truncate((delta *% scale) >> FIX);
    }
}

fn ApplyFilter(p: *SmoothParams) void {
    const average: [*c]const u16 = p.average_;
    const w: u32 = @intCast(p.width_);
    const correction: [*c]const i16 = p.correction_;
    const dither: [*c]const u8 = if (comptime USE_DITHERING) kOrderedDither[@mod(p.row_, DSIZE)] else null;
    const dst = p.dst_;
    for (0..w) |x| {
        const v = dst[x];
        if (v < p.max_ and v > p.min_) {
            const c = @as(i16, @intCast(v << DFIX)) + correction[average[x] -| (v << LFIX)];
            if (comptime USE_DITHERING)
                dst[x] = clip_8b(c + @as(i16, @intCast(dither[x % DSIZE])))
            else
                dst[x] = clip_8b(c);
        }
    }
    p.dst_ = webp.offsetPtr(p.dst_, p.stride_); // advance output pointer
}

//------------------------------------------------------------------------------
// Initialize correction table

fn InitCorrectionLUT(lut: [*c]i16, min_dist: c_int) void {
    // The correction curve is:
    //   f(x) = x for x <= threshold2
    //   f(x) = 0 for x >= threshold1
    // and a linear interpolation for range x=[threshold2, threshold1]
    // (along with f(-x) = -f(x) symmetry).
    // Note that: threshold2 = 3/4 * threshold1
    const threshold1: c_int = min_dist << LFIX;
    const threshold2: c_int = (3 * threshold1) >> 2;
    const max_threshold: c_int = threshold2 << DFIX;
    const delta: c_int = threshold1 - threshold2;
    var i: c_int = 1;
    while (i <= LUT_SIZE) : (i += 1) {
        var c: c_int = if (i <= threshold2) (i << DFIX) else if (i < threshold1) @divTrunc(max_threshold * (threshold1 - i), delta) else 0;
        c >>= LFIX;
        webp.offsetPtr(lut, i)[0] = @intCast(c);
        webp.offsetPtr(lut, -i)[0] = @intCast(-c);
    }
    lut[0] = 0;
}

fn CountLevels(p: *SmoothParams) void {
    // int i, j, last_level;
    var used_levels = [_]u8{0} ** 256;
    var data = p.src_;
    p.min_ = 255;
    p.max_ = 0;
    for (0..@intCast(p.height_)) |_| {
        for (data[0..@intCast(p.width_)]) |v| {
            if (v < p.min_) p.min_ = v;
            if (v > p.max_) p.max_ = v;
            used_levels[v] = 1;
        }
        data = webp.offsetPtr(data, p.stride_);
    }
    // Compute the mininum distance between two non-zero levels.
    p.min_level_dist_ = p.max_ - p.min_;
    var last_level: c_int = -1;
    for (0..256) |i| {
        if (used_levels[i] != 0) {
            p.num_levels_ += 1;
            if (last_level >= 0) {
                const level_dist = @as(c_int, @intCast(i)) - last_level;
                if (level_dist < p.min_level_dist_) {
                    p.min_level_dist_ = level_dist;
                }
            }
            last_level = @intCast(i);
        }
    }
}

fn InitParams(data: [*c]u8, width: c_int, height: c_int, stride: c_int, radius: c_int, p: *SmoothParams) c_bool {
    const R = 2 * radius + 1; // total size of the kernel

    const size_scratch_m = @as(usize, @intCast((R + 1) * width)) * @sizeOf(@typeInfo(@TypeOf(p.start_)).Pointer.child);
    const size_m = @as(usize, @intCast(width)) * @sizeOf(@typeInfo(@TypeOf(p.average_)).Pointer.child);
    const size_lut = (1 + 2 * LUT_SIZE) * @sizeOf(@typeInfo(@TypeOf(p.correction_)).Pointer.child);
    const total_size: usize = size_scratch_m + size_m + size_lut;
    var mem: [*c]u8 = @ptrCast(@alignCast(webp.WebPSafeMalloc(1, total_size) orelse return 0));

    p.mem_ = @ptrCast(mem);

    p.start_ = @ptrCast(@alignCast(mem));
    p.cur_ = p.start_;
    p.end_ = webp.offsetPtr(p.start_, R * width);
    p.top_ = webp.offsetPtr(p.end_, -width);
    @memset(p.top_[0..@intCast(width)], 0);
    mem += size_scratch_m;

    p.average_ = @ptrCast(@alignCast(mem));
    mem += size_m;

    p.width_ = width;
    p.height_ = height;
    p.stride_ = stride;
    p.src_ = data;
    p.dst_ = data;
    p.radius_ = radius;
    p.scale_ = @divTrunc((1 << (FIX + LFIX)), (R * R)); // normalization constant
    p.row_ = -radius;

    // analyze the input distribution so we can best-fit the threshold
    CountLevels(p);

    // correction table
    p.correction_ = @as([*c]i16, @ptrCast(@alignCast(mem))) + LUT_SIZE;
    InitCorrectionLUT(p.correction_, p.min_level_dist_);

    return 1;
}

fn CleanupParams(p: *SmoothParams) void {
    webp.WebPSafeFree(p.mem_);
}

// Apply post-processing to input 'data' of size 'width'x'height' assuming that
// the source was quantized to a reduced number of levels. 'stride' is in bytes.
// Strength is in [0..100] and controls the amount of dithering applied.
// Returns false in case of error (data is NULL, invalid parameters,
// malloc failure, ...).
pub fn WebPDequantizeLevels(data: [*c]u8, width: c_int, height: c_int, stride: c_int, strength: c_int) c_bool {
    var radius = @divTrunc(4 * strength, 100);

    if (strength < 0 or strength > 100) return 0;
    if (data == null or width <= 0 or height <= 0) return 0; // bad params

    // limit the filter size to not exceed the image dimensions
    if (2 * radius + 1 > width) radius = (width - 1) >> 1;
    if (2 * radius + 1 > height) radius = (height - 1) >> 1;

    if (radius > 0) {
        var p = std.mem.zeroes(SmoothParams);
        if (!(InitParams(data, width, height, stride, radius, &p) != 0)) return 0;
        if (p.num_levels_ > 2) {
            while (p.row_ < p.height_) : (p.row_ += 1) {
                VFilter(&p); // accumulate average of input
                // Need to wait few rows in order to prime the filter,
                // before emitting some output.
                if (p.row_ >= p.radius_) {
                    HFilter(&p);
                    ApplyFilter(&p);
                }
            }
        }
        CleanupParams(&p);
    }
    return 1;
}
