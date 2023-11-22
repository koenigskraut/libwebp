const std = @import("std");

const c = @cImport({
    @cInclude("src/webp/decode.h");
});

const lossy = @embedFile("data/lossy.webp");
const lossless = @embedFile("data/lossless.webp");
const lossy_noalpha = @embedFile("data/lossy-noalpha.webp");
const lossless_noalpha = @embedFile("data/lossless-noalpha.webp");

const CompareCase = struct {
    RGBA: []const u8,
    ARGB: []const u8,
    BGRA: []const u8,
    RGB: []const u8,
    BGR: []const u8,
    YUV: []const u8,
    dithering50: []const u8,
    dithering100: []const u8,
    alpha_dithering50: []const u8,
    alpha_dithering100: []const u8,
    both_dithering50: []const u8,
    both_dithering100: []const u8,
    bypass_filtering: []const u8,
    cropped: []const u8,
    downscaled: []const u8,
    flip: []const u8,
    no_fancy_upsampling: []const u8,
    use_threads: []const u8,
};

const compare_cases = .{
    .@"alpha-lossy" = CompareCase{
        .RGBA = @embedFile("compare/alpha-lossy/RGBA.bin"),
        .ARGB = @embedFile("compare/alpha-lossy/ARGB.bin"),
        .BGRA = @embedFile("compare/alpha-lossy/BGRA.bin"),
        .RGB = @embedFile("compare/alpha-lossy/RGB.bin"),
        .BGR = @embedFile("compare/alpha-lossy/BGR.bin"),
        .YUV = @embedFile("compare/alpha-lossy/YUV.bin"),
        .dithering50 = @embedFile("compare/alpha-lossy/dithering50.bin"),
        .dithering100 = @embedFile("compare/alpha-lossy/dithering100.bin"),
        .alpha_dithering50 = @embedFile("compare/alpha-lossy/alpha_dithering50.bin"),
        .alpha_dithering100 = @embedFile("compare/alpha-lossy/alpha_dithering100.bin"),
        .both_dithering50 = @embedFile("compare/alpha-lossy/both_dithering50.bin"),
        .both_dithering100 = @embedFile("compare/alpha-lossy/both_dithering100.bin"),
        .bypass_filtering = @embedFile("compare/alpha-lossy/bypass_filtering.bin"),
        .cropped = @embedFile("compare/alpha-lossy/cropped.bin"),
        .downscaled = @embedFile("compare/alpha-lossy/downscaled.bin"),
        .flip = @embedFile("compare/alpha-lossy/flip.bin"),
        .no_fancy_upsampling = @embedFile("compare/alpha-lossy/no_fancy_upsampling.bin"),
        .use_threads = @embedFile("compare/alpha-lossy/use_threads.bin"),
    },
    .@"alpha-lossless" = CompareCase{
        .RGBA = @embedFile("compare/alpha-lossless/RGBA.bin"),
        .ARGB = @embedFile("compare/alpha-lossless/ARGB.bin"),
        .BGRA = @embedFile("compare/alpha-lossless/BGRA.bin"),
        .RGB = @embedFile("compare/alpha-lossless/RGB.bin"),
        .BGR = @embedFile("compare/alpha-lossless/BGR.bin"),
        .YUV = @embedFile("compare/alpha-lossless/YUV.bin"),
        .dithering50 = @embedFile("compare/alpha-lossless/dithering50.bin"),
        .dithering100 = @embedFile("compare/alpha-lossless/dithering100.bin"),
        .alpha_dithering50 = @embedFile("compare/alpha-lossless/alpha_dithering50.bin"),
        .alpha_dithering100 = @embedFile("compare/alpha-lossless/alpha_dithering100.bin"),
        .both_dithering50 = @embedFile("compare/alpha-lossless/both_dithering50.bin"),
        .both_dithering100 = @embedFile("compare/alpha-lossless/both_dithering100.bin"),
        .bypass_filtering = @embedFile("compare/alpha-lossless/bypass_filtering.bin"),
        .cropped = @embedFile("compare/alpha-lossless/cropped.bin"),
        .downscaled = @embedFile("compare/alpha-lossless/downscaled.bin"),
        .flip = @embedFile("compare/alpha-lossless/flip.bin"),
        .no_fancy_upsampling = @embedFile("compare/alpha-lossless/no_fancy_upsampling.bin"),
        .use_threads = @embedFile("compare/alpha-lossless/use_threads.bin"),
    },
    .@"noalpha-lossy" = CompareCase{
        .RGBA = @embedFile("compare/noalpha-lossy/RGBA.bin"),
        .ARGB = @embedFile("compare/noalpha-lossy/ARGB.bin"),
        .BGRA = @embedFile("compare/noalpha-lossy/BGRA.bin"),
        .RGB = @embedFile("compare/noalpha-lossy/RGB.bin"),
        .BGR = @embedFile("compare/noalpha-lossy/BGR.bin"),
        .YUV = @embedFile("compare/noalpha-lossy/YUV.bin"),
        .dithering50 = @embedFile("compare/noalpha-lossy/dithering50.bin"),
        .dithering100 = @embedFile("compare/noalpha-lossy/dithering100.bin"),
        .alpha_dithering50 = @embedFile("compare/noalpha-lossy/alpha_dithering50.bin"),
        .alpha_dithering100 = @embedFile("compare/noalpha-lossy/alpha_dithering100.bin"),
        .both_dithering50 = @embedFile("compare/noalpha-lossy/both_dithering50.bin"),
        .both_dithering100 = @embedFile("compare/noalpha-lossy/both_dithering100.bin"),
        .bypass_filtering = @embedFile("compare/noalpha-lossy/bypass_filtering.bin"),
        .cropped = @embedFile("compare/noalpha-lossy/cropped.bin"),
        .downscaled = @embedFile("compare/noalpha-lossy/downscaled.bin"),
        .flip = @embedFile("compare/noalpha-lossy/flip.bin"),
        .no_fancy_upsampling = @embedFile("compare/noalpha-lossy/no_fancy_upsampling.bin"),
        .use_threads = @embedFile("compare/noalpha-lossy/use_threads.bin"),
    },
    .@"noalpha-lossless" = CompareCase{
        .RGBA = @embedFile("compare/noalpha-lossless/RGBA.bin"),
        .ARGB = @embedFile("compare/noalpha-lossless/ARGB.bin"),
        .BGRA = @embedFile("compare/noalpha-lossless/BGRA.bin"),
        .RGB = @embedFile("compare/noalpha-lossless/RGB.bin"),
        .BGR = @embedFile("compare/noalpha-lossless/BGR.bin"),
        .YUV = @embedFile("compare/noalpha-lossless/YUV.bin"),
        .dithering50 = @embedFile("compare/noalpha-lossless/dithering50.bin"),
        .dithering100 = @embedFile("compare/noalpha-lossless/dithering100.bin"),
        .alpha_dithering50 = @embedFile("compare/noalpha-lossless/alpha_dithering50.bin"),
        .alpha_dithering100 = @embedFile("compare/noalpha-lossless/alpha_dithering100.bin"),
        .both_dithering50 = @embedFile("compare/noalpha-lossless/both_dithering50.bin"),
        .both_dithering100 = @embedFile("compare/noalpha-lossless/both_dithering100.bin"),
        .bypass_filtering = @embedFile("compare/noalpha-lossless/bypass_filtering.bin"),
        .cropped = @embedFile("compare/noalpha-lossless/cropped.bin"),
        .downscaled = @embedFile("compare/noalpha-lossless/downscaled.bin"),
        .flip = @embedFile("compare/noalpha-lossless/flip.bin"),
        .no_fancy_upsampling = @embedFile("compare/noalpha-lossless/no_fancy_upsampling.bin"),
        .use_threads = @embedFile("compare/noalpha-lossless/use_threads.bin"),
    },
};

const assert = std.debug.assert;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

test "WebPGetFeatures" {
    {
        const compare_to = c.WebPBitstreamFeatures{ .width = 512, .height = 424, .has_alpha = 1, .has_animation = 0, .format = 1 };
        var config: c.WebPDecoderConfig = undefined;
        try expect(c.WebPInitDecoderConfig(&config) == 1);
        defer c.WebPFreeDecBuffer(&config.output);
        try expect(c.WebPGetFeatures(lossy, lossy.len, &config.input) == c.VP8_STATUS_OK);
        try expectEqual(compare_to, config.input);
    }
    {
        const compare_to = c.WebPBitstreamFeatures{ .width = 800, .height = 600, .has_alpha = 1, .has_animation = 0, .format = 2 };
        var config: c.WebPDecoderConfig = undefined;
        try expect(c.WebPInitDecoderConfig(&config) == 1);
        defer c.WebPFreeDecBuffer(&config.output);
        try expect(c.WebPGetFeatures(lossless, lossless.len, &config.input) == c.VP8_STATUS_OK);
        try expectEqual(compare_to, config.input);
    }
    {
        const compare_to = c.WebPBitstreamFeatures{ .width = 550, .height = 368, .has_alpha = 0, .has_animation = 0, .format = 1 };
        var config: c.WebPDecoderConfig = undefined;
        try expect(c.WebPInitDecoderConfig(&config) == 1);
        defer c.WebPFreeDecBuffer(&config.output);
        try expect(c.WebPGetFeatures(lossy_noalpha, lossy_noalpha.len, &config.input) == c.VP8_STATUS_OK);
        try expectEqual(compare_to, config.input);
    }
    {
        const compare_to = c.WebPBitstreamFeatures{ .width = 1024, .height = 768, .has_alpha = 0, .has_animation = 0, .format = 2 };
        var config: c.WebPDecoderConfig = undefined;
        try expect(c.WebPInitDecoderConfig(&config) == 1);
        defer c.WebPFreeDecBuffer(&config.output);
        try expect(c.WebPGetFeatures(lossless_noalpha, lossless_noalpha.len, &config.input) == c.VP8_STATUS_OK);
        try expectEqual(compare_to, config.input);
    }
}

fn decodeAll(comptime prefix: []const u8, data: []const u8) !void {
    var width: c_int, var height: c_int = .{ undefined, undefined };
    // WebPDecodeRGBA
    {
        var result = c.WebPDecodeRGBA(data.ptr, data.len, &width, &height);
        defer c.WebPFree(result);
        const size: usize = @intCast(width * height * 4);
        try expectEqualSlices(u8, @field(compare_cases, prefix).RGBA, result[0..size]);
    }
    // WebPDecodeARGB
    {
        var result = c.WebPDecodeARGB(data.ptr, data.len, &width, &height);
        defer c.WebPFree(result);
        const size: usize = @intCast(width * height * 4);
        try expectEqualSlices(u8, @field(compare_cases, prefix).ARGB, result[0..size]);
    }
    // WebPDecodeBGRA
    {
        var result = c.WebPDecodeBGRA(data.ptr, data.len, &width, &height);
        defer c.WebPFree(result);
        const size: usize = @intCast(width * height * 4);
        try expectEqualSlices(u8, @field(compare_cases, prefix).BGRA, result[0..size]);
    }
    // WebPDecodeRGB
    {
        var result = c.WebPDecodeRGB(data.ptr, data.len, &width, &height);
        defer c.WebPFree(result);
        const size: usize = @intCast(width * height * 3);
        try expectEqualSlices(u8, @field(compare_cases, prefix).RGB, result[0..size]);
    }
    // WebPDecodeBGR
    {
        var result = c.WebPDecodeBGR(data.ptr, data.len, &width, &height);
        defer c.WebPFree(result);
        const size: usize = @intCast(width * height * 3);
        try expectEqualSlices(u8, @field(compare_cases, prefix).BGR, result[0..size]);
    }
    // WebPDecodeYUV
    {
        var stride_y: c_int, var stride_uv: c_int = .{ undefined, undefined };
        var u: [*c]u8, var v: [*c]u8 = .{ null, null };
        var y = c.WebPDecodeYUV(data.ptr, data.len, &width, &height, &u, &v, &stride_y, &stride_uv);
        defer c.WebPFree(y);

        const size_y: usize = @intCast(height * stride_y);
        const size_u: usize = @intCast(@divTrunc(height + 1, 2) * stride_uv);
        const size_v: usize = @intCast(@divTrunc(height + 1, 2) * stride_uv);
        var case = @field(compare_cases, prefix).YUV;
        try expectEqualSlices(u8, case[0..size_y], y[0..size_y]);
        try expectEqualSlices(u8, case[size_y..][0..size_u], u[0..size_u]);
        try expectEqualSlices(u8, case[size_y..][size_u..], v[0..size_v]);
    }
}

test "WebPDecode*" {
    try decodeAll("alpha-lossy", lossy);
    try decodeAll("alpha-lossless", lossless);
    try decodeAll("noalpha-lossy", lossy_noalpha);
    try decodeAll("noalpha-lossless", lossless_noalpha);
}

fn decodeAllInto(comptime prefix: []const u8, data: []const u8, allocator: std.mem.Allocator) !void {
    const max_size = 1024 * 768 * 4;

    // WebPDecodeRGBAInto
    {
        var decode_into = try allocator.alloc(u8, max_size);
        defer allocator.free(decode_into);
        var config: c.WebPDecoderConfig = undefined;
        try expect(c.WebPInitDecoderConfig(&config) == 1);
        defer c.WebPFreeDecBuffer(&config.output);
        try expect(c.WebPGetFeatures(data.ptr, data.len, &config.input) == c.VP8_STATUS_OK);
        try expect(c.WebPDecodeRGBAInto(data.ptr, data.len, decode_into.ptr, decode_into.len, config.input.width * 4) != null);
        const size: usize = @intCast(config.input.width * config.input.height * 4);
        try expectEqualSlices(u8, @field(compare_cases, prefix).RGBA, decode_into[0..size]);
    }
    // WebPDecodeARGBInto
    {
        var decode_into = try allocator.alloc(u8, max_size);
        defer allocator.free(decode_into);
        var config: c.WebPDecoderConfig = undefined;
        try expect(c.WebPInitDecoderConfig(&config) == 1);
        defer c.WebPFreeDecBuffer(&config.output);
        try expect(c.WebPGetFeatures(data.ptr, data.len, &config.input) == c.VP8_STATUS_OK);
        try expect(c.WebPDecodeARGBInto(data.ptr, data.len, decode_into.ptr, decode_into.len, config.input.width * 4) != null);
        const size: usize = @intCast(config.input.width * config.input.height * 4);
        try expectEqualSlices(u8, @field(compare_cases, prefix).ARGB, decode_into[0..size]);
    }
    // WebPDecodeBGRAInto
    {
        var decode_into = try allocator.alloc(u8, max_size);
        defer allocator.free(decode_into);
        var config: c.WebPDecoderConfig = undefined;
        try expect(c.WebPInitDecoderConfig(&config) == 1);
        defer c.WebPFreeDecBuffer(&config.output);
        try expect(c.WebPGetFeatures(data.ptr, data.len, &config.input) == c.VP8_STATUS_OK);
        try expect(c.WebPDecodeBGRAInto(data.ptr, data.len, decode_into.ptr, decode_into.len, config.input.width * 4) != null);
        const size: usize = @intCast(config.input.width * config.input.height * 4);
        try expectEqualSlices(u8, @field(compare_cases, prefix).BGRA, decode_into[0..size]);
    }
    // WebPDecodeRGBInto
    {
        var decode_into = try allocator.alloc(u8, max_size);
        defer allocator.free(decode_into);
        var config: c.WebPDecoderConfig = undefined;
        try expect(c.WebPInitDecoderConfig(&config) == 1);
        defer c.WebPFreeDecBuffer(&config.output);
        try expect(c.WebPGetFeatures(data.ptr, data.len, &config.input) == c.VP8_STATUS_OK);
        try expect(c.WebPDecodeRGBInto(data.ptr, data.len, decode_into.ptr, decode_into.len, config.input.width * 3) != null);
        const size: usize = @intCast(config.input.width * config.input.height * 3);
        try expectEqualSlices(u8, @field(compare_cases, prefix).RGB, decode_into[0..size]);
    }
    // WebPDecodeBGRInto
    {
        var decode_into = try allocator.alloc(u8, max_size);
        defer allocator.free(decode_into);
        var config: c.WebPDecoderConfig = undefined;
        try expect(c.WebPInitDecoderConfig(&config) == 1);
        defer c.WebPFreeDecBuffer(&config.output);
        try expect(c.WebPGetFeatures(data.ptr, data.len, &config.input) == c.VP8_STATUS_OK);
        try expect(c.WebPDecodeBGRInto(data.ptr, data.len, decode_into.ptr, decode_into.len, config.input.width * 3) != null);
        const size: usize = @intCast(config.input.width * config.input.height * 3);
        try expectEqualSlices(u8, @field(compare_cases, prefix).BGR, decode_into[0..size]);
    }
    // WebPDecodeYUVInto
    {
        var decode_into = try allocator.alloc(u8, max_size);
        defer allocator.free(decode_into);
        var config: c.WebPDecoderConfig = undefined;
        try expect(c.WebPInitDecoderConfig(&config) == 1);
        defer c.WebPFreeDecBuffer(&config.output);
        try expect(c.WebPGetFeatures(data.ptr, data.len, &config.input) == c.VP8_STATUS_OK);
        const stride_y = config.input.width;
        const stride_uv = @divTrunc(config.input.width + 1, 2);
        const size_y: usize = @intCast(config.input.height * stride_y);
        const size_u: usize = @intCast(@divTrunc(config.input.height + 1, 2) * stride_uv);
        const size_v: usize = @intCast(@divTrunc(config.input.height + 1, 2) * stride_uv);
        var y = try allocator.alloc(u8, size_y);
        defer allocator.free(y);
        var u = try allocator.alloc(u8, size_u);
        defer allocator.free(u);
        var v = try allocator.alloc(u8, size_v);
        defer allocator.free(v);
        try expect(c.WebPDecodeYUVInto(data.ptr, data.len, y.ptr, y.len, stride_y, u.ptr, u.len, stride_uv, v.ptr, v.len, stride_uv) != null);

        var case = @field(compare_cases, prefix).YUV;
        try expectEqualSlices(u8, case[0..size_y], y[0..size_y]);
        try expectEqualSlices(u8, case[size_y..][0..size_u], u[0..size_u]);
        try expectEqualSlices(u8, case[size_y..][size_u..], v[0..size_v]);
    }
}

test "WebPDecode*Into" {
    const allocator = std.testing.allocator;
    try decodeAllInto("alpha-lossy", lossy, allocator);
    try decodeAllInto("alpha-lossless", lossless, allocator);
    try decodeAllInto("noalpha-lossy", lossy_noalpha, allocator);
    try decodeAllInto("noalpha-lossless", lossless_noalpha, allocator);
}

fn advancedAll(comptime prefix: []const u8, data: []const u8, allocator: std.mem.Allocator) !void {
    const max_size = 1024 * 768 * 4;

    // bypass_filtering
    {
        var config: c.WebPDecoderConfig = undefined;
        try expect(c.WebPInitDecoderConfig(&config) == 1);
        defer c.WebPFreeDecBuffer(&config.output);
        try expect(c.WebPGetFeatures(data.ptr, data.len, &config.input) == c.VP8_STATUS_OK);

        config.options.bypass_filtering = 1;

        var memory_buffer = try allocator.alloc(u8, max_size);
        defer allocator.free(memory_buffer);

        config.output.colorspace = c.MODE_RGBA;

        const stride = config.input.width * 4;
        config.output.u.RGBA.rgba = memory_buffer.ptr;
        config.output.u.RGBA.stride = stride;
        config.output.u.RGBA.size = memory_buffer.len;
        config.output.is_external_memory = 1;

        try expect(c.WebPDecode(data.ptr, data.len, &config) == c.VP8_STATUS_OK);

        const out = memory_buffer[0..@intCast(config.input.height * stride)];
        try expectEqualSlices(u8, @field(compare_cases, prefix).bypass_filtering, out);
    }

    // flip
    {
        var config: c.WebPDecoderConfig = undefined;
        try expect(c.WebPInitDecoderConfig(&config) == 1);
        defer c.WebPFreeDecBuffer(&config.output);
        try expect(c.WebPGetFeatures(data.ptr, data.len, &config.input) == c.VP8_STATUS_OK);

        config.options.flip = 1;

        var memory_buffer = try allocator.alloc(u8, max_size);
        defer allocator.free(memory_buffer);

        config.output.colorspace = c.MODE_RGBA;

        const stride = config.input.width * 4;
        config.output.u.RGBA.rgba = memory_buffer.ptr;
        config.output.u.RGBA.stride = stride;
        config.output.u.RGBA.size = memory_buffer.len;
        config.output.is_external_memory = 1;

        try expect(c.WebPDecode(data.ptr, data.len, &config) == c.VP8_STATUS_OK);

        const out = memory_buffer[0..@intCast(config.input.height * stride)];
        try expectEqualSlices(u8, @field(compare_cases, prefix).flip, out);
    }

    // no_fancy_upsampling
    {
        var config: c.WebPDecoderConfig = undefined;
        try expect(c.WebPInitDecoderConfig(&config) == 1);
        defer c.WebPFreeDecBuffer(&config.output);
        try expect(c.WebPGetFeatures(data.ptr, data.len, &config.input) == c.VP8_STATUS_OK);

        config.options.no_fancy_upsampling = 1;

        var memory_buffer = try allocator.alloc(u8, max_size);
        defer allocator.free(memory_buffer);

        config.output.colorspace = c.MODE_RGBA;

        const stride = config.input.width * 4;
        config.output.u.RGBA.rgba = memory_buffer.ptr;
        config.output.u.RGBA.stride = stride;
        config.output.u.RGBA.size = memory_buffer.len;
        config.output.is_external_memory = 1;

        try expect(c.WebPDecode(data.ptr, data.len, &config) == c.VP8_STATUS_OK);

        const out = memory_buffer[0..@intCast(config.input.height * stride)];
        try expectEqualSlices(u8, @field(compare_cases, prefix).no_fancy_upsampling, out);
    }

    // use_threads
    {
        var config: c.WebPDecoderConfig = undefined;
        try expect(c.WebPInitDecoderConfig(&config) == 1);
        defer c.WebPFreeDecBuffer(&config.output);
        try expect(c.WebPGetFeatures(data.ptr, data.len, &config.input) == c.VP8_STATUS_OK);

        config.options.use_threads = 1;

        var memory_buffer = try allocator.alloc(u8, max_size);
        defer allocator.free(memory_buffer);

        config.output.colorspace = c.MODE_RGBA;

        const stride = config.input.width * 4;
        config.output.u.RGBA.rgba = memory_buffer.ptr;
        config.output.u.RGBA.stride = stride;
        config.output.u.RGBA.size = memory_buffer.len;
        config.output.is_external_memory = 1;

        try expect(c.WebPDecode(data.ptr, data.len, &config) == c.VP8_STATUS_OK);

        const out = memory_buffer[0..@intCast(config.input.height * stride)];
        try expectEqualSlices(u8, @field(compare_cases, prefix).use_threads, out);
    }

    // dithering 50
    {
        var config: c.WebPDecoderConfig = undefined;
        try expect(c.WebPInitDecoderConfig(&config) == 1);
        defer c.WebPFreeDecBuffer(&config.output);
        try expect(c.WebPGetFeatures(data.ptr, data.len, &config.input) == c.VP8_STATUS_OK);

        config.options.dithering_strength = 50;

        var memory_buffer = try allocator.alloc(u8, max_size);
        defer allocator.free(memory_buffer);

        config.output.colorspace = c.MODE_RGBA;

        const stride = config.input.width * 4;
        config.output.u.RGBA.rgba = memory_buffer.ptr;
        config.output.u.RGBA.stride = stride;
        config.output.u.RGBA.size = memory_buffer.len;
        config.output.is_external_memory = 1;

        try expect(c.WebPDecode(data.ptr, data.len, &config) == c.VP8_STATUS_OK);

        const out = memory_buffer[0..@intCast(config.input.height * stride)];
        try expectEqualSlices(u8, @field(compare_cases, prefix).dithering50, out);
    }

    // dithering 100
    {
        var config: c.WebPDecoderConfig = undefined;
        try expect(c.WebPInitDecoderConfig(&config) == 1);
        defer c.WebPFreeDecBuffer(&config.output);
        try expect(c.WebPGetFeatures(data.ptr, data.len, &config.input) == c.VP8_STATUS_OK);

        config.options.dithering_strength = 100;

        var memory_buffer = try allocator.alloc(u8, max_size);
        defer allocator.free(memory_buffer);

        config.output.colorspace = c.MODE_RGBA;

        const stride = config.input.width * 4;
        config.output.u.RGBA.rgba = memory_buffer.ptr;
        config.output.u.RGBA.stride = stride;
        config.output.u.RGBA.size = memory_buffer.len;
        config.output.is_external_memory = 1;

        try expect(c.WebPDecode(data.ptr, data.len, &config) == c.VP8_STATUS_OK);

        const out = memory_buffer[0..@intCast(config.input.height * stride)];
        try expectEqualSlices(u8, @field(compare_cases, prefix).dithering100, out);
    }

    // alpha_dithering 50
    {
        var config: c.WebPDecoderConfig = undefined;
        try expect(c.WebPInitDecoderConfig(&config) == 1);
        defer c.WebPFreeDecBuffer(&config.output);
        try expect(c.WebPGetFeatures(data.ptr, data.len, &config.input) == c.VP8_STATUS_OK);

        config.options.alpha_dithering_strength = 50;

        var memory_buffer = try allocator.alloc(u8, max_size);
        defer allocator.free(memory_buffer);

        config.output.colorspace = c.MODE_RGBA;

        const stride = config.input.width * 4;
        config.output.u.RGBA.rgba = memory_buffer.ptr;
        config.output.u.RGBA.stride = stride;
        config.output.u.RGBA.size = memory_buffer.len;
        config.output.is_external_memory = 1;

        try expect(c.WebPDecode(data.ptr, data.len, &config) == c.VP8_STATUS_OK);

        const out = memory_buffer[0..@intCast(config.input.height * stride)];
        try expectEqualSlices(u8, @field(compare_cases, prefix).alpha_dithering50, out);
    }

    // alpha_dithering 100
    {
        var config: c.WebPDecoderConfig = undefined;
        try expect(c.WebPInitDecoderConfig(&config) == 1);
        defer c.WebPFreeDecBuffer(&config.output);
        try expect(c.WebPGetFeatures(data.ptr, data.len, &config.input) == c.VP8_STATUS_OK);

        config.options.alpha_dithering_strength = 100;

        var memory_buffer = try allocator.alloc(u8, max_size);
        defer allocator.free(memory_buffer);

        config.output.colorspace = c.MODE_RGBA;

        const stride = config.input.width * 4;
        config.output.u.RGBA.rgba = memory_buffer.ptr;
        config.output.u.RGBA.stride = stride;
        config.output.u.RGBA.size = memory_buffer.len;
        config.output.is_external_memory = 1;

        try expect(c.WebPDecode(data.ptr, data.len, &config) == c.VP8_STATUS_OK);

        const out = memory_buffer[0..@intCast(config.input.height * stride)];
        try expectEqualSlices(u8, @field(compare_cases, prefix).alpha_dithering100, out);
    }

    // both_dithering 50
    {
        var config: c.WebPDecoderConfig = undefined;
        try expect(c.WebPInitDecoderConfig(&config) == 1);
        defer c.WebPFreeDecBuffer(&config.output);
        try expect(c.WebPGetFeatures(data.ptr, data.len, &config.input) == c.VP8_STATUS_OK);

        config.options.dithering_strength = 50;
        config.options.alpha_dithering_strength = 50;

        var memory_buffer = try allocator.alloc(u8, max_size);
        defer allocator.free(memory_buffer);

        config.output.colorspace = c.MODE_RGBA;

        const stride = config.input.width * 4;
        config.output.u.RGBA.rgba = memory_buffer.ptr;
        config.output.u.RGBA.stride = stride;
        config.output.u.RGBA.size = memory_buffer.len;
        config.output.is_external_memory = 1;

        try expect(c.WebPDecode(data.ptr, data.len, &config) == c.VP8_STATUS_OK);

        const out = memory_buffer[0..@intCast(config.input.height * stride)];
        try expectEqualSlices(u8, @field(compare_cases, prefix).both_dithering50, out);
    }

    // both_dithering 100
    {
        var config: c.WebPDecoderConfig = undefined;
        try expect(c.WebPInitDecoderConfig(&config) == 1);
        defer c.WebPFreeDecBuffer(&config.output);
        try expect(c.WebPGetFeatures(data.ptr, data.len, &config.input) == c.VP8_STATUS_OK);

        config.options.dithering_strength = 100;
        config.options.alpha_dithering_strength = 100;

        var memory_buffer = try allocator.alloc(u8, max_size);
        defer allocator.free(memory_buffer);

        config.output.colorspace = c.MODE_RGBA;

        const stride = config.input.width * 4;
        config.output.u.RGBA.rgba = memory_buffer.ptr;
        config.output.u.RGBA.stride = stride;
        config.output.u.RGBA.size = memory_buffer.len;
        config.output.is_external_memory = 1;

        try expect(c.WebPDecode(data.ptr, data.len, &config) == c.VP8_STATUS_OK);

        const out = memory_buffer[0..@intCast(config.input.height * stride)];
        try expectEqualSlices(u8, @field(compare_cases, prefix).both_dithering100, out);
    }

    // cropped
    {
        var config: c.WebPDecoderConfig = undefined;
        try expect(c.WebPInitDecoderConfig(&config) == 1);
        defer c.WebPFreeDecBuffer(&config.output);
        try expect(c.WebPGetFeatures(data.ptr, data.len, &config.input) == c.VP8_STATUS_OK);

        config.options.use_cropping = 1;
        config.options.crop_left = 100;
        config.options.crop_top = 100;
        config.options.crop_width = 100;
        config.options.crop_height = 100;

        var memory_buffer = try allocator.alloc(u8, max_size);
        defer allocator.free(memory_buffer);

        config.output.colorspace = c.MODE_RGBA;

        const stride = 100 * 4;
        config.output.u.RGBA.rgba = memory_buffer.ptr;
        config.output.u.RGBA.stride = stride;
        config.output.u.RGBA.size = memory_buffer.len;
        config.output.is_external_memory = 1;

        try expect(c.WebPDecode(data.ptr, data.len, &config) == c.VP8_STATUS_OK);

        const out = memory_buffer[0..@intCast(100 * stride)];
        try expectEqualSlices(u8, @field(compare_cases, prefix).cropped, out);
    }

    // downscaled
    {
        var config: c.WebPDecoderConfig = undefined;
        try expect(c.WebPInitDecoderConfig(&config) == 1);
        defer c.WebPFreeDecBuffer(&config.output);
        try expect(c.WebPGetFeatures(data.ptr, data.len, &config.input) == c.VP8_STATUS_OK);

        config.options.use_scaling = 1;
        config.options.scaled_width = @divTrunc(config.input.width * 2, 3);
        config.options.scaled_height = @divTrunc(config.input.height * 2, 3);

        var memory_buffer = try allocator.alloc(u8, max_size);
        defer allocator.free(memory_buffer);

        config.output.colorspace = c.MODE_RGBA;

        const stride = @divTrunc(config.input.width * 2, 3) * 4;
        config.output.u.RGBA.rgba = memory_buffer.ptr;
        config.output.u.RGBA.stride = stride;
        config.output.u.RGBA.size = memory_buffer.len;
        config.output.is_external_memory = 1;

        try expect(c.WebPDecode(data.ptr, data.len, &config) == c.VP8_STATUS_OK);

        const out = memory_buffer[0..@intCast(@divTrunc(config.input.height * 2, 3) * stride)];
        try expectEqualSlices(u8, @field(compare_cases, prefix).downscaled, out);
    }
}

test "advanced API" {
    const allocator = std.testing.allocator;
    try advancedAll("alpha-lossy", lossy, allocator);
    try advancedAll("alpha-lossless", lossless, allocator);
    try advancedAll("noalpha-lossy", lossy_noalpha, allocator);
    try advancedAll("noalpha-lossless", lossless_noalpha, allocator);
}

fn decodeAllIncremental(comptime prefix: []const u8, data: []const u8, allocator: std.mem.Allocator) !void {
    const max_size = 1024 * 768 * 4;
    // var decode_into = try allocator.alloc(u8, max_size);
    // defer allocator.free(decode_into);

    // RGBA
    {
        var config: c.WebPDecoderConfig = undefined;
        try expect(c.WebPInitDecoderConfig(&config) == 1);
        defer c.WebPFreeDecBuffer(&config.output);
        try expect(c.WebPGetFeatures(data.ptr, data.len, &config.input) == c.VP8_STATUS_OK);
        var memory_buffer = try allocator.alloc(u8, max_size);
        defer allocator.free(memory_buffer);

        config.output.colorspace = c.MODE_RGBA;

        const stride = config.input.width * 4;
        config.output.u.RGBA.rgba = memory_buffer.ptr;
        config.output.u.RGBA.stride = stride;
        config.output.u.RGBA.size = memory_buffer.len;
        config.output.is_external_memory = 1;

        const idec = c.WebPINewDecoder(&config.output);
        try expect(idec != null);
        defer c.WebPIDelete(idec);

        const chunk_size = 4096;
        var input: []const u8 = data[0..];
        var last_y: c_int, var i_width: c_int, var i_height: c_int, var i_stride: c_int = .{ 0, 0, 0, 0 };
        var end: usize = 0;
        while (input.len > 0) {
            defer input = if (input.len > chunk_size) input[chunk_size..] else input[input.len..];
            const status = c.WebPIAppend(idec, input.ptr, if (input.len < chunk_size) input.len else chunk_size);
            try expect(status == if (input.len < chunk_size) c.VP8_STATUS_OK else c.VP8_STATUS_SUSPENDED);
            const data_ptr = c.WebPIDecGetRGB(idec, &last_y, &i_width, &i_height, &i_stride);
            try expect(data_ptr != null);
            end = @intCast(i_stride * last_y);
            try expectEqualSlices(u8, @field(compare_cases, prefix).RGBA[0..end], data_ptr[0..end]);
        }

        const out = memory_buffer[0..@intCast(config.input.height * stride)];
        try expectEqualSlices(u8, @field(compare_cases, prefix).RGBA, out);
    }
    // ARGB
    {
        var config: c.WebPDecoderConfig = undefined;
        try expect(c.WebPInitDecoderConfig(&config) == 1);
        defer c.WebPFreeDecBuffer(&config.output);
        try expect(c.WebPGetFeatures(data.ptr, data.len, &config.input) == c.VP8_STATUS_OK);
        var memory_buffer = try allocator.alloc(u8, max_size);
        defer allocator.free(memory_buffer);

        config.output.colorspace = c.MODE_ARGB;

        const stride = config.input.width * 4;
        config.output.u.RGBA.rgba = memory_buffer.ptr;
        config.output.u.RGBA.stride = stride;
        config.output.u.RGBA.size = memory_buffer.len;
        config.output.is_external_memory = 1;

        const idec = c.WebPINewDecoder(&config.output);
        try expect(idec != null);
        defer c.WebPIDelete(idec);

        const chunk_size = 4096;
        var input: []const u8 = data[0..];
        var last_y: c_int, var i_width: c_int, var i_height: c_int, var i_stride: c_int = .{ 0, 0, 0, 0 };
        var end: usize = 0;
        while (input.len > 0) {
            defer input = if (input.len > chunk_size) input[chunk_size..] else input[input.len..];
            const status = c.WebPIAppend(idec, input.ptr, if (input.len < chunk_size) input.len else chunk_size);
            try expect(status == if (input.len < chunk_size) c.VP8_STATUS_OK else c.VP8_STATUS_SUSPENDED);
            const data_ptr = c.WebPIDecGetRGB(idec, &last_y, &i_width, &i_height, &i_stride);
            try expect(data_ptr != null);
            end = @intCast(i_stride * last_y);
            try expectEqualSlices(u8, @field(compare_cases, prefix).ARGB[0..end], data_ptr[0..end]);
        }

        const out = memory_buffer[0..@intCast(config.input.height * stride)];
        try expectEqualSlices(u8, @field(compare_cases, prefix).ARGB, out);
    }
    // BGRA
    {
        var config: c.WebPDecoderConfig = undefined;
        try expect(c.WebPInitDecoderConfig(&config) == 1);
        defer c.WebPFreeDecBuffer(&config.output);
        try expect(c.WebPGetFeatures(data.ptr, data.len, &config.input) == c.VP8_STATUS_OK);
        var memory_buffer = try allocator.alloc(u8, max_size);
        defer allocator.free(memory_buffer);

        config.output.colorspace = c.MODE_BGRA;

        const stride = config.input.width * 4;
        config.output.u.RGBA.rgba = memory_buffer.ptr;
        config.output.u.RGBA.stride = stride;
        config.output.u.RGBA.size = memory_buffer.len;
        config.output.is_external_memory = 1;

        const idec = c.WebPINewDecoder(&config.output);
        try expect(idec != null);
        defer c.WebPIDelete(idec);

        const chunk_size = 4096;
        var input: []const u8 = data[0..];
        var last_y: c_int, var i_width: c_int, var i_height: c_int, var i_stride: c_int = .{ 0, 0, 0, 0 };
        var end: usize = 0;
        while (input.len > 0) {
            defer input = if (input.len > chunk_size) input[chunk_size..] else input[input.len..];
            const status = c.WebPIAppend(idec, input.ptr, if (input.len < chunk_size) input.len else chunk_size);
            try expect(status == if (input.len < chunk_size) c.VP8_STATUS_OK else c.VP8_STATUS_SUSPENDED);
            const data_ptr = c.WebPIDecGetRGB(idec, &last_y, &i_width, &i_height, &i_stride);
            try expect(data_ptr != null);
            end = @intCast(i_stride * last_y);
            try expectEqualSlices(u8, @field(compare_cases, prefix).BGRA[0..end], data_ptr[0..end]);
        }

        const out = memory_buffer[0..@intCast(config.input.height * stride)];
        try expectEqualSlices(u8, @field(compare_cases, prefix).BGRA, out);
    }
    // RGB
    {
        var config: c.WebPDecoderConfig = undefined;
        try expect(c.WebPInitDecoderConfig(&config) == 1);
        defer c.WebPFreeDecBuffer(&config.output);
        try expect(c.WebPGetFeatures(data.ptr, data.len, &config.input) == c.VP8_STATUS_OK);
        var memory_buffer = try allocator.alloc(u8, max_size);
        defer allocator.free(memory_buffer);

        config.output.colorspace = c.MODE_RGB;

        const stride = config.input.width * 3;
        config.output.u.RGBA.rgba = memory_buffer.ptr;
        config.output.u.RGBA.stride = stride;
        config.output.u.RGBA.size = memory_buffer.len;
        config.output.is_external_memory = 1;

        const idec = c.WebPINewDecoder(&config.output);
        try expect(idec != null);
        defer c.WebPIDelete(idec);

        const chunk_size = 4096;
        var input: []const u8 = data[0..];
        var last_y: c_int, var i_width: c_int, var i_height: c_int, var i_stride: c_int = .{ 0, 0, 0, 0 };
        var end: usize = 0;
        while (input.len > 0) {
            defer input = if (input.len > chunk_size) input[chunk_size..] else input[input.len..];
            const status = c.WebPIAppend(idec, input.ptr, if (input.len < chunk_size) input.len else chunk_size);
            try expect(status == if (input.len < chunk_size) c.VP8_STATUS_OK else c.VP8_STATUS_SUSPENDED);
            const data_ptr = c.WebPIDecGetRGB(idec, &last_y, &i_width, &i_height, &i_stride);
            try expect(data_ptr != null);
            end = @intCast(i_stride * last_y);
            try expectEqualSlices(u8, @field(compare_cases, prefix).RGB[0..end], data_ptr[0..end]);
        }

        const out = memory_buffer[0..@intCast(config.input.height * stride)];
        try expectEqualSlices(u8, @field(compare_cases, prefix).RGB, out);
    }
    // BGR
    {
        var config: c.WebPDecoderConfig = undefined;
        try expect(c.WebPInitDecoderConfig(&config) == 1);
        defer c.WebPFreeDecBuffer(&config.output);
        try expect(c.WebPGetFeatures(data.ptr, data.len, &config.input) == c.VP8_STATUS_OK);
        var memory_buffer = try allocator.alloc(u8, max_size);
        defer allocator.free(memory_buffer);

        config.output.colorspace = c.MODE_BGR;

        const stride = config.input.width * 3;
        config.output.u.RGBA.rgba = memory_buffer.ptr;
        config.output.u.RGBA.stride = stride;
        config.output.u.RGBA.size = memory_buffer.len;
        config.output.is_external_memory = 1;

        const idec = c.WebPINewDecoder(&config.output);
        try expect(idec != null);
        defer c.WebPIDelete(idec);

        const chunk_size = 4096;
        var input: []const u8 = data[0..];
        var last_y: c_int, var i_width: c_int, var i_height: c_int, var i_stride: c_int = .{ 0, 0, 0, 0 };
        var end: usize = 0;
        while (input.len > 0) {
            defer input = if (input.len > chunk_size) input[chunk_size..] else input[input.len..];
            const status = c.WebPIAppend(idec, input.ptr, if (input.len < chunk_size) input.len else chunk_size);
            try expect(status == if (input.len < chunk_size) c.VP8_STATUS_OK else c.VP8_STATUS_SUSPENDED);
            const data_ptr = c.WebPIDecGetRGB(idec, &last_y, &i_width, &i_height, &i_stride);
            try expect(data_ptr != null);
            end = @intCast(i_stride * last_y);
            try expectEqualSlices(u8, @field(compare_cases, prefix).BGR[0..end], data_ptr[0..end]);
        }

        const out = memory_buffer[0..@intCast(config.input.height * stride)];
        try expectEqualSlices(u8, @field(compare_cases, prefix).BGR, out);
    }
    // YUV
    {
        var config: c.WebPDecoderConfig = undefined;
        try expect(c.WebPInitDecoderConfig(&config) == 1);
        defer c.WebPFreeDecBuffer(&config.output);
        try expect(c.WebPGetFeatures(data.ptr, data.len, &config.input) == c.VP8_STATUS_OK);

        config.output.colorspace = c.MODE_YUV;

        const stride_y = config.input.width;
        const stride_uv = @divTrunc(config.input.width + 1, 2);
        const size_y: usize = @intCast(config.input.height * stride_y);
        const size_u: usize = @intCast(@divTrunc(config.input.height + 1, 2) * stride_uv);
        const size_v: usize = @intCast(@divTrunc(config.input.height + 1, 2) * stride_uv);
        var y = try allocator.alloc(u8, size_y);
        defer allocator.free(y);
        var u = try allocator.alloc(u8, size_u);
        defer allocator.free(u);
        var v = try allocator.alloc(u8, size_v);
        defer allocator.free(v);

        config.output.u.YUVA.y = y.ptr;
        config.output.u.YUVA.y_stride = stride_y;
        config.output.u.YUVA.y_size = size_y;

        config.output.u.YUVA.u = u.ptr;
        config.output.u.YUVA.u_stride = stride_uv;
        config.output.u.YUVA.u_size = size_u;

        config.output.u.YUVA.v = v.ptr;
        config.output.u.YUVA.v_stride = stride_uv;
        config.output.u.YUVA.v_size = size_v;

        // config.a = ;
        // config.a_stride = ;
        // config.a_size = ;

        config.output.is_external_memory = 1;

        const idec = c.WebPINewDecoder(&config.output);
        try expect(idec != null);
        defer c.WebPIDelete(idec);

        const chunk_size = 4096;
        var input: []const u8 = data[0..];
        // var last_y: c_int, var i_width: c_int, var i_height: c_int, var i_stride: c_int = .{ 0, 0, 0, 0 };
        // var end: usize = 0;
        while (input.len > 0) {
            defer input = if (input.len > chunk_size) input[chunk_size..] else input[input.len..];
            const status = c.WebPIAppend(idec, input.ptr, if (input.len < chunk_size) input.len else chunk_size);
            try expect(status == if (input.len < chunk_size) c.VP8_STATUS_OK else c.VP8_STATUS_SUSPENDED);
            // const data_ptr = c.WebPIDecGetRGB(idec, &last_y, &i_width, &i_height, &i_stride);
            // try expect(data_ptr != null);
            // end = @intCast(i_stride * last_y);
            // try expectEqualSlices(u8, @field(compare_cases, prefix).YUV[0..end], data_ptr[0..end]);
        }

        var case = @field(compare_cases, prefix).YUV;
        try expectEqualSlices(u8, case[0..size_y], y[0..size_y]);
        try expectEqualSlices(u8, case[size_y..][0..size_u], u[0..size_u]);
        try expectEqualSlices(u8, case[size_y..][size_u..], v[0..size_v]);
    }
}

test "incremental decoding" {
    const allocator = std.testing.allocator;

    try decodeAllIncremental("alpha-lossy", lossy, allocator);
    try decodeAllIncremental("alpha-lossless", lossless, allocator);
    try decodeAllIncremental("noalpha-lossy", lossy_noalpha, allocator);
    try decodeAllIncremental("noalpha-lossless", lossless_noalpha, allocator);
}
