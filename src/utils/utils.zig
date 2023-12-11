const std = @import("std");
const build_options = @import("build_options");
const webp = struct {
    usingnamespace @import("../webp/encode.zig");
    usingnamespace @import("../webp/mux_types.zig");
};

const assert = std.debug.assert;
pub const c_bool = c_int;

// inline fn Increment(v: anytype) void {}
// inline fn AddMem(p: anytype, s: anytype) void {}
// inline fn SubMem(p: anytype)    void {}
pub var allocator: std.mem.Allocator = std.heap.c_allocator;

//------------------------------------------------------------------------------
// Memory allocation

/// This is the maximum memory amount that libwebp will ever try to allocate.
const max_allocable_memory = if (build_options.max_allocable_memory > 0)
    build_options.max_allocable_memory
else if (std.math.maxInt(usize) > 1 << 34)
    1 << 34
else // For 32-bit targets keep this below INT_MAX to avoid valgrind warnings.
    (1 << 31) - (1 << 16);

/// Returns 0 in case of overflow of nmemb * size.
fn CheckSizeArgumentsOverflow(nmemb: u64, size: usize) bool {
    const total_size: u64 = nmemb * size;
    if (nmemb == 0) return true;
    if (@as(u64, size) > @as(u64, max_allocable_memory) / nmemb) return false;
    if (!CheckSizeOverflow(total_size)) return false;
    // #if defined(PRINT_MEM_INFO) && defined(MALLOC_FAIL_AT)
    // if (countdown_to_fail > 0 && --countdown_to_fail == 0) {
    //     return 0;    // fake fail!
    // }
    // #endif
    // #if defined(PRINT_MEM_INFO) && defined(MALLOC_LIMIT)
    // if (mem_limit > 0) {
    //     const uint64_t new_total_mem = (uint64_t)total_mem + total_size;
    //     if (!CheckSizeOverflow(new_total_mem) ||
    //         new_total_mem > mem_limit) {
    //     return 0;   // fake fail!
    //     }
    // }
    // #endif
    return true;
}

pub inline fn CheckSizeOverflow(size: u64) bool {
    return size == @as(usize, @bitCast(size));
}

// size-checking safe malloc/calloc: verify that the requested size is not too
// large, or return NULL. You don't need to call these for constructs like
// malloc(sizeof(foo)), but only if there's picture-dependent size involved
// somewhere (like: malloc(num_pixels * sizeof(*something))). That's why this
// safe malloc() borrows the signature from calloc(), pointing at the dangerous
// underlying multiply involved.
pub export fn WebPSafeMalloc(nmemb: u64, size: usize) ?*anyopaque {
    // Increment(&num_malloc_calls);
    if (!CheckSizeArgumentsOverflow(nmemb, size)) return null;
    assert(nmemb * size > 0);
    const ptr = std.c.malloc(nmemb * size);
    // AddMem(ptr, (size_t)(nmemb * size));
    return ptr;
}

// Note that WebPSafeCalloc() expects the second argument type to be 'size_t'
// in order to favor the "calloc(num_foo, sizeof(foo))" pattern.
pub export fn WebPSafeCalloc(nmemb: u64, size: usize) ?*anyopaque {
    // Increment(&num_calloc_calls);
    if (!CheckSizeArgumentsOverflow(nmemb, size)) return null;
    assert(nmemb * size > 0);
    const ptr = std.c.malloc(nmemb * size) orelse return null;
    @memset(@as([*]u8, @ptrCast(ptr))[0 .. nmemb * size], 0);
    // AddMem(ptr, (size_t)(nmemb * size));
    return ptr;
}

// Companion deallocation function to the above allocations.
pub export fn WebPSafeFree(ptr: ?*anyopaque) void {
    // if (ptr != null) {
    //     Increment(&num_free_calls);
    //     SubMem(ptr);
    // }
    std.c.free(ptr);
}

pub fn setAllocator(a: std.mem.Allocator) void {
    allocator = a;
}

// Public API functions.

pub export fn WebPMalloc(size: usize) ?*anyopaque {
    return WebPSafeMalloc(1, size);
}

pub export fn WebPFree(ptr: ?*anyopaque) void {
    WebPSafeFree(ptr);
}

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
    ptr[0..4].* = @bitCast(val);
}

pub inline fn WebPInt32ToMem(ptr: [*c]u8, val: i32) void {
    ptr[0..4].* = @bitCast(val);
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

// extern fn GetColorPalette(pic: ?*const webp.Picture, palette: [*c]u32) callconv(.C) c_int;
pub export fn WebPGetColorPalette(pic: ?*const webp.Picture, palette: [*c]u32) c_int {
    _ = pic;
    _ = palette;
    return 0;
    // return GetColorPalette(pic, palette);
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

pub inline fn offsetPtr(ptr: anytype, offset: isize) @TypeOf(ptr) {
    return ptr + @as(usize, @bitCast(offset));
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

pub inline fn hasFlag(flags: u32, flag: webp.FeatureFlags) bool {
    return flags & @intFromEnum(flag) == 1;
}

pub inline fn getLE32(data: []const u8) u32 {
    return std.mem.readInt(u32, data[0..4], .little);
}

pub inline fn getLE24(data: []const u8) u24 {
    return std.mem.readInt(u24, data[0..3], .little);
}
