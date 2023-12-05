const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const reduce_size = b.option(bool, "reduce-size", "") orelse false;
    const no_fancy_upsampling = b.option(bool, "no-fancy-upsampling", "") orelse false;
    const swap_16bit_csp = b.option(bool, "swap-16bit-csp", "") orelse false;
    const use_tables_for_alpha_mult = b.option(bool, "use-tables-for-alpha-mult", "") orelse false;
    const dsp_omit_c_code = b.option(bool, "dsp-omit-c-code", "") orelse true;
    const use_static_tables = b.option(bool, "use-static-tables", "") orelse true;
    const reduce_csp = b.option(bool, "reduce-csp", "") orelse false;
    const max_allocable_memory = b.option(usize, "max-allocable-memory", "") orelse 0;

    const options = b.addOptions();
    options.addOption(bool, "reduce_size", reduce_size);
    options.addOption(bool, "fancy_upsampling", !no_fancy_upsampling);
    options.addOption(bool, "swap_16bit_csp", swap_16bit_csp);
    options.addOption(bool, "use_tables_for_alpha_mult", use_tables_for_alpha_mult);
    options.addOption(bool, "dsp_omit_c_code", dsp_omit_c_code);
    options.addOption(bool, "use_static_tables", use_static_tables);
    options.addOption(bool, "reduce_csp", reduce_csp);
    options.addOption(usize, "max_allocable_memory", max_allocable_memory);

    const lib = b.addStaticLibrary(.{
        .name = "webp",
        .target = target,
        .optimize = optimize,
        .root_source_file = .{ .path = "src/library.zig" },
    });

    // const libs = [_]*std.Build.Step.Compile{
    //     // libwebp
    //     b.addSharedLibrary(.{ .name = "webp", .target = target, .optimize = optimize, .version = .{ .major = 8, .minor = 8, .patch = 1 } }),
    //     b.addStaticLibrary(.{ .name = "webp", .target = target, .optimize = optimize }),
    //     // libwebpdecoder
    //     b.addSharedLibrary(.{ .name = "webpdecoder", .target = target, .optimize = optimize, .version = .{ .major = 4, .minor = 8, .patch = 1 } }),
    //     b.addStaticLibrary(.{ .name = "webpdecoder", .target = target, .optimize = optimize }),
    //     // libwebpmux
    //     b.addSharedLibrary(.{ .name = "webpmux", .target = target, .optimize = optimize, .version = .{ .major = 3, .minor = 13, .patch = 0 } }),
    //     b.addStaticLibrary(.{ .name = "webpmux", .target = target, .optimize = optimize }),
    //     // libwebpdemux
    //     b.addSharedLibrary(.{ .name = "webpdemux", .target = target, .optimize = optimize, .version = .{ .major = 2, .minor = 14, .patch = 0 } }),
    //     b.addStaticLibrary(.{ .name = "webpdemux", .target = target, .optimize = optimize }),
    // };

    var c_flags = std.ArrayList([]const u8).init(b.allocator);
    defer c_flags.deinit();
    try c_flags.appendSlice(&.{
        "-fvisibility=hidden",
        "-Wextra",
        "-Wold-style-definition",
        "-Wmissing-prototypes",
        "-Wmissing-declarations",
        "-Wdeclaration-after-statement",
        "-Wshadow",
        "-Wformat-security",
        "-Wformat-nonliteral",
        "-I.",
        "-Isrc/",
        "-Wall",
        "-lm",
    });

    // Platform-specific settings
    {
        const cpu = target.getCpu();
        // For 32bit x86 platform
        if (have_x86_feat(cpu, .@"32bit_mode") and !have_x86_feat(cpu, .@"64bit"))
            try c_flags.append("-m32");
        // SSE4.1-specific flags:
        if (have_x86_feat(cpu, .sse4_1)) {
            // for (libs) |lib| lib.defineCMacro("WEBP_HAVE_SSE41", null);
            lib.defineCMacro("WEBP_HAVE_SSE41", null);
            try c_flags.append("-msse4.1");
        }
        // NEON-specific flags (mandatory for aarch64):
        if (have_arm_feat(cpu, .neon)) {
            try c_flags.appendSlice(&.{ "-march=armv7-a", "-mfloat-abi=hard", "-mfpu=neon", "-mtune=cortex-a8" });
        }
        // MIPS (MSA) 32-bit build specific flags for mips32r5 (p5600):
        if (have_mips_feat(cpu, .mips32r5))
            try c_flags.appendSlice(&.{ "-mips32r5", "-mabi=32", "-mtune=p5600", "-mmsa", "-mfp64", "-msched-weight", "-mload-store-pairs" });
        // MIPS (MSA) 64-bit build specific flags for mips64r6 (i6400):
        if (have_mips_feat(cpu, .mips64r6))
            try c_flags.appendSlice(&.{ "-mips64r6", "-mabi=64", "-mtune=i6400", "-mmsa", "-mfp64", "-msched-weight", "-mload-store-pairs" });

        // Windows recommends setting both UNICODE and _UNICODE.
        if (target.isWindows()) {
            // for (libs) |lib| {
            lib.defineCMacro("UNICODE", null);
            lib.defineCMacro("_UNICODE", null);
            // }
        }
    }

    // for (libs) |lib| lib.force_pic = true;
    // for (libs) |lib| lib.linkLibC();
    // for (libs) |lib| lib.addIncludePath(.{ .path = "." });
    // for (libs) |lib| lib.defineCMacro("WEBP_USE_THREAD", null);
    // for (libs) |lib| lib.linkSystemLibrary("pthread");
    lib.force_pic = true;
    lib.linkLibC();
    lib.addIncludePath(.{ .path = "." });
    lib.defineCMacro("WEBP_USE_THREAD", null);
    options.addOption(bool, "WEBP_USE_THREAD", true);
    lib.linkSystemLibrary("pthread");
    lib.addOptions("build_options", options);

    // libwebp
    lib.addCSourceFiles(.{ .files = libwebp_srsc, .flags = c_flags.items });
    // for (libs[0..2]) |lib| lib.addCSourceFiles(.{ .files = libwebp_srsc, .flags = c_flags.items });
    // // libwebpdecoder
    // for (libs[2..4]) |lib| lib.addCSourceFiles(.{ .files = libwebpdecoder_srsc, .flags = c_flags.items });
    // // libwebpmux
    // for (libs[4..6]) |lib| lib.addCSourceFiles(.{ .files = libwebpmux_srsc, .flags = c_flags.items });
    // // libwebpdemux
    // for (libs[6..8]) |lib| lib.addCSourceFiles(.{ .files = libwebpdemux_srsc, .flags = c_flags.items });

    const headers: StrSlice = &.{ "decode.h", "encode.h", "types.h", "mux.h", "demux.h", "mux_types.h" };
    inline for (headers) |h| {
        const h_file = b.addInstallHeaderFile("src/webp/" ++ h, h);
        b.install_tls.step.dependOn(&h_file.step);
    }

    // for (libs) |lib| b.installArtifact(lib);
    b.installArtifact(lib);

    const unit_tests = b.addTest(.{
        .name = "tests",
        .root_source_file = .{ .path = "src/tests.zig" },
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    unit_tests.linkLibrary(lib);
    unit_tests.addIncludePath(.{ .path = "." });
    unit_tests.addOptions("build_options", options);

    const tests_cmd = b.addRunArtifact(unit_tests);
    tests_cmd.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&tests_cmd.step);

    const single = b.addExecutable(.{
        .name = "single",
        .root_source_file = .{ .path = "src/single.zig" },
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // single.linkLibrary(lib);
    // single.linkSystemLibrary("webp");
    single.addIncludePath(.{ .path = "." });
    single.addOptions("build_options", options);
    b.installArtifact(single);
    const run_single = b.addRunArtifact(single);
    run_single.step.dependOn(b.getInstallStep());
    b.step("run", "Run single").dependOn(&run_single.step);
}

const StrSlice = []const []const u8;

const libsharpyuv_srsc = sharpyuv_srcs;
const libwebpdecoder_srsc = dec_srcs ++ dsp_dec_srsc ++ utils_dec_srsc;
const libwebp_srsc = libwebpdecoder_srsc ++ enc_srsc ++ dsp_enc_srcs ++ utils_enc_srcs ++ libsharpyuv_srsc;
const libwebpmux_srsc = mux_srcs;
const libwebpdemux_srsc = demux_srcs;
// const libwebpextra = extra_srsc;

const sharpyuv_srcs: StrSlice = &.{
    "sharpyuv/sharpyuv.c",
    "sharpyuv/sharpyuv_cpu.c",
    "sharpyuv/sharpyuv_csp.c",
    "sharpyuv/sharpyuv_dsp.c",
    "sharpyuv/sharpyuv_gamma.c",
    "sharpyuv/sharpyuv_neon.c",
    "sharpyuv/sharpyuv_sse2.c",
};

const dec_srcs: StrSlice = &.{
    // "src/dec/alpha_dec.c",
    // "src/dec/buffer_dec.c",
    // "src/dec/frame_dec.c",
    // "src/dec/idec_dec.c",
    // "src/dec/io_dec.c",
    // "src/dec/quant_dec.c",
    // "src/dec/tree_dec.c",
    // "src/dec/vp8_dec.c",
    // "src/dec/vp8l_dec.c",
    // "src/dec/webp_dec.c",
};

const demux_srcs: StrSlice = &.{
    "src/demux/anim_decode.c",
    "src/demux/demux.c",
};

const dsp_dec_srsc: StrSlice = &.{
    // "src/dsp/alpha_processing.c",
    "src/dsp/alpha_processing_mips_dsp_r2.c",
    "src/dsp/alpha_processing_neon.c",
    // "src/dsp/alpha_processing_sse2.c",
    // "src/dsp/alpha_processing_sse41.c",

    // "src/dsp/cpu.c",

    // "src/dsp/dec.c",
    // "src/dsp/dec_clip_tables.c",
    "src/dsp/dec_mips32.c",
    "src/dsp/dec_mips_dsp_r2.c",
    "src/dsp/dec_msa.c",
    "src/dsp/dec_neon.c",
    // "src/dsp/dec_sse2.c",
    // "src/dsp/dec_sse41.c",

    // "src/dsp/filters.c",
    "src/dsp/filters_mips_dsp_r2.c",
    "src/dsp/filters_msa.c",
    "src/dsp/filters_neon.c",
    // "src/dsp/filters_sse2.c",

    // "src/dsp/lossless.c",
    "src/dsp/lossless_mips_dsp_r2.c",
    "src/dsp/lossless_msa.c",
    "src/dsp/lossless_neon.c",
    "src/dsp/lossless_sse2.c",
    // "src/dsp/lossless_sse41.c",

    // "src/dsp/rescaler.c",
    "src/dsp/rescaler_mips32.c",
    "src/dsp/rescaler_mips_dsp_r2.c",
    "src/dsp/rescaler_msa.c",
    "src/dsp/rescaler_neon.c",
    "src/dsp/rescaler_sse2.c",

    // "src/dsp/upsampling.c",
    "src/dsp/upsampling_mips_dsp_r2.c",
    "src/dsp/upsampling_msa.c",
    "src/dsp/upsampling_neon.c",
    "src/dsp/upsampling_sse2.c",
    "src/dsp/upsampling_sse41.c",

    // "src/dsp/yuv.c",
    "src/dsp/yuv_mips32.c",
    "src/dsp/yuv_mips_dsp_r2.c",
    "src/dsp/yuv_neon.c",
    "src/dsp/yuv_sse2.c",
    "src/dsp/yuv_sse41.c",
};

const dsp_enc_srcs: StrSlice = &.{
    "src/dsp/cost.c",
    "src/dsp/cost_mips32.c",
    "src/dsp/cost_mips_dsp_r2.c",
    "src/dsp/cost_neon.c",
    "src/dsp/cost_sse2.c",
    "src/dsp/enc.c",
    "src/dsp/enc_mips32.c",
    "src/dsp/enc_mips_dsp_r2.c",
    "src/dsp/enc_msa.c",
    "src/dsp/enc_neon.c",
    "src/dsp/enc_sse2.c",
    "src/dsp/enc_sse41.c",
    "src/dsp/lossless_enc.c",
    "src/dsp/lossless_enc_mips32.c",
    "src/dsp/lossless_enc_mips_dsp_r2.c",
    "src/dsp/lossless_enc_msa.c",
    "src/dsp/lossless_enc_neon.c",
    "src/dsp/lossless_enc_sse2.c",
    "src/dsp/lossless_enc_sse41.c",
    "src/dsp/ssim.c",
    "src/dsp/ssim_sse2.c",
};

const enc_srsc: StrSlice = &.{
    "src/enc/alpha_enc.c",
    "src/enc/analysis_enc.c",
    "src/enc/backward_references_cost_enc.c",
    "src/enc/backward_references_enc.c",
    "src/enc/config_enc.c",
    "src/enc/cost_enc.c",
    "src/enc/filter_enc.c",
    "src/enc/frame_enc.c",
    "src/enc/histogram_enc.c",
    "src/enc/iterator_enc.c",
    "src/enc/near_lossless_enc.c",
    "src/enc/picture_enc.c",
    "src/enc/picture_csp_enc.c",
    "src/enc/picture_psnr_enc.c",
    "src/enc/picture_rescale_enc.c",
    "src/enc/picture_tools_enc.c",
    "src/enc/predictor_enc.c",
    "src/enc/quant_enc.c",
    "src/enc/syntax_enc.c",
    "src/enc/token_enc.c",
    "src/enc/tree_enc.c",
    "src/enc/vp8l_enc.c",
    "src/enc/webp_enc.c",
};

const mux_srcs: StrSlice = &.{
    "src/mux/anim_encode.c",
    "src/mux/muxedit.c",
    "src/mux/muxinternal.c",
    "src/mux/muxread.c",
};

const utils_dec_srsc: StrSlice = &.{
    // "src/utils/bit_reader_utils.c",
    // "src/utils/color_cache_utils.c",
    // "src/utils/huffman_utils.c",
    // "src/utils/quant_levels_dec_utils.c",
    // "src/utils/random_utils.c",
    // "src/utils/rescaler_utils.c",
    // "src/utils/thread_utils.c",
    // "src/utils/utils.c",
};

const utils_enc_srcs: StrSlice = &.{
    "src/utils/bit_writer_utils.c",
    "src/utils/filters_utils.c",
    "src/utils/huffman_encode_utils.c",
    "src/utils/palette.c",
    "src/utils/quant_levels_utils.c",
};

// const extra_srsc: StrSlice = &.{
//     "extras/extras.c",
//     "extras/quality_estimate.c",
// };

fn have_x86_feat(cpu: std.Target.Cpu, feat: std.Target.x86.Feature) bool {
    return switch (cpu.arch) {
        .x86, .x86_64 => std.Target.x86.featureSetHas(cpu.features, feat),
        else => false,
    };
}

fn have_arm_feat(cpu: std.Target.Cpu, feat: std.Target.arm.Feature) bool {
    return switch (cpu.arch) {
        .arm, .armeb => std.Target.arm.featureSetHas(cpu.features, feat),
        else => false,
    };
}

fn have_aarch64_feat(cpu: std.Target.Cpu, feat: std.Target.aarch64.Feature) bool {
    return switch (cpu.arch) {
        .aarch64,
        .aarch64_be,
        .aarch64_32,
        => std.Target.aarch64.featureSetHas(cpu.features, feat),

        else => false,
    };
}

fn have_mips_feat(cpu: std.Target.Cpu, feat: std.Target.mips.Feature) bool {
    return switch (cpu.arch) {
        .mips, .mipsel, .mips64, .mips64el => std.Target.mips.featureSetHas(cpu.features, feat),
        else => false,
    };
}
