const std = @import("std");

pub const c_bool = c_int;

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
    return if (offset > 0) ptr + @abs(offset) else ptr - @abs(offset);
}

pub inline fn diffPtr(minuend: anytype, subtrahend: @TypeOf(minuend)) isize {
    const m, const s = .{ @intFromPtr(minuend), @intFromPtr(subtrahend) };
    return if (m > s) @intCast(m - s) else -@as(isize, @intCast(s - m));
}
