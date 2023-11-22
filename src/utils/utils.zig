const std = @import("std");

pub const c_bool = c_int;

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
