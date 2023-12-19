const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

const webp = struct {
    usingnamespace @import("../utils/utils.zig");
};
const c_bool = webp.c_bool;

//------------------------------------------------------------------------------
// x86 defines.

pub const use_sse2 = webp.have_x86_feat(builtin.cpu, .sse2);
pub const have_sse2 = use_sse2;

pub const use_sse41 = webp.have_x86_feat(builtin.cpu, .sse4_1);
pub const have_sse41 = use_sse41;

//------------------------------------------------------------------------------
// Arm defines.

pub const use_neon = webp.have_arm_feat(builtin.cpu, .neon) or webp.have_aarch64_feat(builtin.cpu, .neon);
pub const android_neon = use_neon and builtin.target.isAndroid();

pub const aarch64 = builtin.cpu.arch.isAARCH64();
pub const have_neon = use_neon;

//------------------------------------------------------------------------------
// MIPS defines.

pub const use_mips32 = builtin.cpu.arch.isMIPS() and
    !webp.have_mips_feat(builtin.cpu, .mips64) and
    !webp.have_mips_feat(builtin.cpu, .mips32r6);
pub const use_mips32_r2 = use_mips32 and (webp.have_mips_feat(builtin.cpu, .mips32r2) or
    webp.have_mips_feat(builtin.cpu, .mips32r3) or
    webp.have_mips_feat(builtin.cpu, .mips32r5));
pub const use_mips_dsp_r2 = use_mips32_r2 and webp.have_mips_feat(builtin.cpu, .dspr2);

pub const use_msa = webp.have_mips_feat(builtin.cpu, .msa) and (webp.have_mips_feat(builtin.cpu, .mips32r5) or
    webp.have_mips_feat(builtin.cpu, .mips32r6) or
    webp.have_mips_feat(builtin.cpu, .mips64r5) or
    webp.have_mips_feat(builtin.cpu, .mips64r6));

//------------------------------------------------------------------------------

pub const dsp_omit_c_code = build_options.dsp_omit_c_code;
pub const neon_omit_c_code = use_neon and dsp_omit_c_code;

//------------------------------------------------------------------------------

pub fn WEBP_DSP_INIT_FUNC(comptime func: fn () void) fn () void {
    return struct {
        pub fn _() void {
            const S = struct {
                pub var once = std.once(func);
            };
            S.once.call();
        }
    }._;
}

pub const CPUFeature = enum(c_uint) {
    kSSE2,
    kSSE3,
    kSlowSSSE3, // special feature for slow SSSE3 architectures
    kSSE4_1,
    kAVX,
    kAVX2,
    kNEON,
    kMIPS32,
    kMIPSdspR2,
    kMSA,
};

// returns true if the CPU supports the feature.
pub const VP8CPUInfo = ?*const fn (CPUFeature) callconv(.C) c_bool;
pub const VP8CPUInfoBody = fn (CPUFeature) callconv(.C) c_int;

//------------------------------------------------------------------------------
// SSE2 detection.
//

inline fn GetCPUInfo(cpu_info: [*]i32, info_type: i32) void {
    var a, var b, var c, var d = .{@as(i32, 0)} ** 4;
    const fpic = comptime builtin.position_independent_code or builtin.position_independent_executable;
    if (comptime fpic and builtin.cpu.arch.isX86() and !webp.have_x86_feat(builtin.cpu, .@"64bit")) {
        // pic and i386
        asm volatile (
            \\mov %edi, %ebx
            \\cpuid
            \\xchg %edi, %ebx
            : [a] "={eax}" (a),
              [b] "={edi}" (b),
              [c] "={ecx}" (c),
              [d] "={edx}" (d),
            : [info_type] "{eax}" (info_type),
              [zero] "{ecx}" (0),
            : "ebx", "edi"
        );
    } else if (comptime webp.have_x86_feat(builtin.cpu, .@"64bit") and fpic and
        (builtin.code_model == .medium or builtin.code_model == .large))
    {
        // x86_64 and (code_model == .medium or .large) and fpic
        asm volatile (
            \\ xchg %rbx, %%rsi
            \\ cpuid
            \\ xchg %rbx, %%rsi
            : [a] "={eax}" (a),
              [b] "=&r" (b),
              [c] "={ecx}" (c),
              [d] "={edx}" (d),
            : [info_type] "{eax}" (info_type),
              [zero] "{ecx}" (0),
        );
    } else if (comptime builtin.cpu.arch.isX86()) {
        // else (if x86)
        asm volatile (
            \\ cpuid
            : [a] "={eax}" (a),
              [b] "={ebx}" (b),
              [c] "={ecx}" (c),
              [d] "={edx}" (d),
            : [info_type] "{eax}" (info_type),
              [zero] "{ecx}" (0),
        );
    }
    cpu_info[0] = a;
    cpu_info[1] = b;
    cpu_info[2] = c;
    cpu_info[3] = d;
}

inline fn xgetbv() u64 {
    // NaCl has no support for xgetbv or the raw opcode.
    if (comptime !builtin.cpu.arch.isX86() or builtin.target.os.tag == .nacl) return 0;

    const ecx: u32 = 0;
    var eax: u32, var edx: u32 = .{ 0, 0 };
    // Use the raw opcode for xgetbv for compatibility with older toolchains.
    asm volatile (
        \\ .byte 0x0f, 0x01, 0xd0
        : [a] "={eax}" (eax),
          [d] "={edx}" (edx),
        : [ecx] "{ecx}" (ecx),
    );
    return (@as(u64, edx) << 32) | @as(u64, eax);
}

// helper function for run-time detection of slow SSSE3 platforms
fn CheckSlowModel(info: u32) bool {
    // Table listing display models with longer latencies for the bsr instruction
    // (ie 2 cycles vs 10/16 cycles) and some SSSE3 instructions like pshufb.
    // Refer to Intel 64 and IA-32 Architectures Optimization Reference Manual.
    const kSlowModels = [_]u8{
        0x37, 0x4a, 0x4d, // Silvermont Microarchitecture
        0x1c, 0x26, 0x27, // Atom Microarchitecture
    };
    const model: u32 = ((info & 0xf0000) >> 12) | ((info >> 4) & 0xf);
    const family: u32 = (info >> 8) & 0xf;
    if (family == 0x06) {
        for (kSlowModels) |slow_model|
            if (model == slow_model) return true;
    }
    return false;
}

fn x86CPUInfo(feature: CPUFeature) callconv(.C) c_bool {
    var cpu_info: [4]i32 = undefined;
    var is_intel = false;

    // get the highest feature value cpuid supports
    GetCPUInfo(&cpu_info, 0);
    const max_cpuid_value = cpu_info[0];
    if (max_cpuid_value < 1) {
        return 0;
    } else {
        const VENDOR_ID_INTEL_EBX: i32 = @bitCast(@as(u32, 0x756e6547)); // uneG
        const VENDOR_ID_INTEL_EDX: i32 = @bitCast(@as(u32, 0x49656e69)); // Ieni
        const VENDOR_ID_INTEL_ECX: i32 = @bitCast(@as(u32, 0x6c65746e)); // letn
        is_intel = (cpu_info[1] == VENDOR_ID_INTEL_EBX and
            cpu_info[2] == VENDOR_ID_INTEL_ECX and
            cpu_info[3] == VENDOR_ID_INTEL_EDX); // genuine Intel?
    }

    GetCPUInfo(&cpu_info, 1);
    if (feature == .kSSE2) {
        return @intFromBool(cpu_info[3] & (@as(i32, 1) << 26) != 0);
    }
    if (feature == .kSSE3) {
        return @intFromBool(cpu_info[2] & (@as(i32, 1) << 0) != 0);
    }
    if (feature == .kSlowSSSE3) {
        if (is_intel and (cpu_info[2] & (@as(i32, 1) << 9) != 0)) { // SSSE3?
            return @intFromBool(CheckSlowModel(@bitCast(cpu_info[0])));
        }
        return 0;
    }

    if (feature == .kSSE4_1) {
        return @intFromBool(cpu_info[2] & (@as(i32, 1) << 19) != 0);
    }
    if (feature == .kAVX) {
        // bits 27 (OSXSAVE) & 28 (256-bit AVX)
        if ((cpu_info[2] & 0x18000000) == 0x18000000) {
            // XMM state and YMM state enabled by the OS.
            return @intFromBool((xgetbv() & 0x6) == 0x6);
        }
    }
    if (feature == .kAVX2) {
        if (x86CPUInfo(.kAVX) != 0 and max_cpuid_value >= 7) {
            GetCPUInfo(&cpu_info, 7);
            return @intFromBool(cpu_info[1] & (@as(i32, 1) << 5) != 0);
        }
    }
    return 0;
}

fn AndroidCPUInfo(feature: CPUFeature) callconv(.C) c_bool {
    // const AndroidCpuFamily cpu_family = android_getCpuFamily();
    // const uint64_t cpu_features = android_getCpuFeatures();
    if (feature == .kNEON) {
        return @intFromBool(webp.have_aarch64_feat(builtin.cpu, .neon) or webp.have_arm_feat(builtin.cpu, .neon));
        // return cpu_family == ANDROID_CPU_FAMILY_ARM &&
        //     (cpu_features & ANDROID_CPU_ARM_FEATURE_NEON) != 0;
    }
    return 0;
}

// Use compile flags as an indicator of SIMD support instead of a runtime check.
fn wasmCPUInfo(feature: CPUFeature) callconv(.C) c_bool {
    return @intFromBool(switch (feature) {
        .kSSE2 => have_sse2,
        .kSSE3 => have_sse41,
        .kSlowSSSE3 => have_sse41,
        .kSSE4_1 => have_sse41,
        .kNEON => have_neon,
        else => false,
    });
}

// In most cases this function doesn't check for NEON support (it's assumed by
// the configuration), but enables turning off NEON at runtime, for testing
// purposes, by setting VP8GetCPUInfo = NULL.
fn armCPUInfo(feature: CPUFeature) callconv(.C) c_bool {
    if (feature != .kNEON) return 0;
    if (comptime builtin.os.tag == .linux and have_neon) {
        var has_neon = false;
        var line: [200]u8 = undefined;
        var cpuinfo = std.fs.openFileAbsolute("/proc/cpuinfo", .{}) catch return 0;
        defer cpuinfo.close();
        const reader = cpuinfo.reader();

        while (reader.readUntilDelimiterOrEof(&line, '\n') catch null) |l| {
            if (std.mem.eql(u8, l[0..8], "Features")) {
                if (std.mem.indexOfPos(u8, line, " neon ") != null) {
                    has_neon = true;
                    break;
                }
            }
        }
        return @intFromBool(has_neon);
    } else {
        return 1;
    }
}

fn mipsCPUInfo(feature: CPUFeature) callconv(.C) c_bool {
    if ((feature == .kMIPS32) or (feature == .kMIPSdspR2) or (feature == .kMSA)) {
        return 1;
    } else {
        return 0;
    }
}

pub var VP8GetCPUInfo: VP8CPUInfo = if (builtin.cpu.arch.isX86())
    &x86CPUInfo
else if (android_neon)
    &AndroidCPUInfo
else if (builtin.os.tag == .emscripten)
    &wasmCPUInfo
else if (have_neon)
    &armCPUInfo
else if (use_mips32 or use_mips_dsp_r2 or use_msa)
    &mipsCPUInfo
else
    null;

comptime {
    @export(VP8GetCPUInfo, .{ .name = "VP8GetCPUInfo" });
}
