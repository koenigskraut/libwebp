const std = @import("std");
const webp = struct {
    usingnamespace @import("../webp/encode.zig");
    usingnamespace @import("../webp/mux_types.zig");
};

const assert = std.debug.assert;
pub const c_bool = c_int;

//------------------------------------------------------------------------------
// Alignment

pub const WEBP_ALIGN_CST = 31;
pub inline fn WEBP_ALIGN(PTR: anytype) usize {
    return (@intFromPtr(PTR) + WEBP_ALIGN_CST) & ~@as(usize, WEBP_ALIGN_CST);
}

// memcpy() is the safe way of moving potentially unaligned 32b memory.
pub inline fn WebPMemToUint32(ptr: [*c]const u8) u32 {
    return @bitCast(ptr[0..4].*);
}

pub inline fn WebPMemToInt32(ptr: [*c]const u8) i32 {
    return @bitCast(ptr[0..4].*);
}

pub inline fn WebPUint32ToMem(ptr: [*c]u8, val: u32) void {
    @memcpy(ptr[0..4], @as(*[4]u8, @ptrCast(&val)));
}

pub inline fn WebPInt32ToMem(ptr: [*c]u8, val: i32) void {
    @memcpy(ptr[0..4], @as(*[4]u8, @ptrCast(&val)));
}

//------------------------------------------------------------------------------
// Pixel copying.

/// Copy width x height pixels from `src` to `dst` honoring the strides.
pub export fn WebPCopyPlane(src_arg: [*]const u8, src_stride: c_int, dst_arg: [*]u8, dst_stride: c_int, width: c_int, height: c_int) void {
    assert(@abs(src_stride) >= width and @abs(dst_stride) >= width);
    var src, var dst = .{ src_arg, dst_arg };
    var h = height;
    while (h > 0) : (h -= 1) {
        @memcpy(dst[0..@abs(width)], src[0..@abs(width)]);
        src = offsetPtr(src, src_stride);
        dst = offsetPtr(dst, dst_stride);
    }
}

/// Copy ARGB pixels from `src` to `dst` honoring strides. `src` and `dst` are
/// assumed to be already allocated and using ARGB data.
pub export fn WebPCopyPixels(src: *const webp.Picture, dst: *webp.Picture) void {
    assert(src.width == dst.width and src.height == dst.height);
    assert(src.use_argb != 0 and dst.use_argb != 0);
    WebPCopyPlane(@ptrCast(src.argb), 4 * src.argb_stride, @ptrCast(dst.argb), 4 * dst.argb_stride, 4 * src.width, src.height);
}

//------------------------------------------------------------------------------

// Returns (int)floor(log2(n)). n must be > 0.
pub inline fn BitsLog2Floor(n: u32) c_int {
    return @as(c_int, 31) ^ @clz(n);
}

pub fn have_x86_feat(cpu: std.Target.Cpu, feat: std.Target.x86.Feature) bool {
    return switch (cpu.arch) {
        .x86, .x86_64 => std.Target.x86.featureSetHas(cpu.features, feat),
        else => false,
    };
}

pub fn have_arm_feat(cpu: std.Target.Cpu, feat: std.Target.arm.Feature) bool {
    return switch (cpu.arch) {
        .arm, .armeb => std.Target.arm.featureSetHas(cpu.features, feat),
        else => false,
    };
}

pub fn have_aarch64_feat(cpu: std.Target.Cpu, feat: std.Target.aarch64.Feature) bool {
    return switch (cpu.arch) {
        .aarch64,
        .aarch64_be,
        .aarch64_32,
        => std.Target.aarch64.featureSetHas(cpu.features, feat),

        else => false,
    };
}

pub fn have_mips_feat(cpu: std.Target.Cpu, feat: std.Target.mips.Feature) bool {
    return switch (cpu.arch) {
        .mips, .mipsel, .mips64, .mips64el => std.Target.mips.featureSetHas(cpu.features, feat),
        else => false,
    };
}

pub extern fn WebPSafeMalloc(nmemb: u64, size: usize) ?*anyopaque;
pub extern fn WebPSafeCalloc(nmemb: u64, size: usize) ?*anyopaque;
pub extern fn WebPSafeFree(ptr: ?*anyopaque) void;

pub inline fn offsetPtr(ptr: anytype, offset: i64) @TypeOf(ptr) {
    return if (offset < 0) ptr - @abs(offset) else ptr + @abs(offset);
}

pub inline fn diffPtr(minuend: anytype, subtrahend: @TypeOf(minuend)) isize {
    const info = @typeInfo(@TypeOf(minuend));
    if (info != .Pointer) @compileError("not a pointer");
    const child_size: isize = @intCast(@sizeOf(info.Pointer.child));
    const m, const s = .{ @intFromPtr(minuend), @intFromPtr(subtrahend) };
    const diff: isize = if (m >= s) @intCast(m - s) else -@as(isize, @intCast(s - m));
    return @divExact(diff, child_size);
}

pub inline fn WEBP_ABI_IS_INCOMPATIBLE(a: anytype, b: anytype) @TypeOf((a >> @as(c_int, 8)) != (b >> @as(c_int, 8))) {
    return (a >> @as(c_int, 8)) != (b >> @as(c_int, 8));
}

pub fn CheckSizeOverflow(size: u64) bool {
    return size == @as(usize, @bitCast(size));
}

pub inline fn hasFlag(flags: u32, flag: webp.FeatureFlags) bool {
    return flags & @intFromEnum(flag) == 1;
}

pub inline fn getLE32(data: []const u8) u32 {
    return std.mem.readInt(u32, data[0..4], .little);
}

pub inline fn getLE24(data: []const u8) u24 {
    return std.mem.readInt(u24, data[0..3], .little);
}
