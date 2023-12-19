const std = @import("std");
const builtin = @import("builtin");
const webp = struct {
    usingnamespace @import("filters.zig");
    usingnamespace @import("intrinzic");
    usingnamespace @import("../utils/utils.zig");
};

const assert = std.debug.assert;
const __m128i = webp.__m128i;

//------------------------------------------------------------------------------
// Helpful macro.

inline fn SANITY_CHECK(width: c_int, height: c_int, stride: c_int, row: c_int, num_rows: c_int) void {
    assert(width > 0);
    assert(height > 0);
    assert(stride >= width);
    assert(row >= 0 and num_rows > 0 and row + num_rows <= height);
}

fn PredictLineTop_SSE2(src: [*c]const u8, pred: [*c]const u8, dst: [*c]u8, length: c_int) void {
    var i: usize = 0;
    const max_pos = length & ~@as(c_int, 31);
    assert(length >= 0);
    while (i < max_pos) : (i += 32) {
        const A0 = webp._mm_loadu_si128(src[i + 0 ..]);
        const A1 = webp._mm_loadu_si128(src[i + 16 ..]);
        const B0 = webp._mm_loadu_si128(pred[i + 0 ..]);
        const B1 = webp._mm_loadu_si128(pred[i + 16 ..]);
        const C0 = webp._mm_sub_epi8(A0, B0);
        const C1 = webp._mm_sub_epi8(A1, B1);
        webp._mm_storeu_si128(@ptrCast(dst[i + 0 ..]), C0);
        webp._mm_storeu_si128(@ptrCast(dst[i + 16 ..]), C1);
    }
    while (i < length) : (i += 1) dst[i] = src[i] -% pred[i];
}

// Special case for left-based prediction (when preds==dst-1 or preds==src-1).
fn PredictLineLeft_SSE2(src: [*c]const u8, dst: [*c]u8, length: c_int) void {
    var i: usize = 0;
    const max_pos = length & ~@as(c_int, 31);
    assert(length >= 0);
    while (i < max_pos) : (i += 32) {
        const A0 = webp._mm_loadu_si128(src + i + 0);
        const B0 = webp._mm_loadu_si128(src + i + 0 - 1);
        const A1 = webp._mm_loadu_si128(src + i + 16);
        const B1 = webp._mm_loadu_si128(src + i + 16 - 1);
        const C0 = webp._mm_sub_epi8(A0, B0);
        const C1 = webp._mm_sub_epi8(A1, B1);
        dst[i + 0 ..][0..16].* = @bitCast(C0);
        dst[i + 16 ..][0..16].* = @bitCast(C1);
    }
    while (i < length) : (i += 1) dst[i] = src[i] - src[i - 1];
}

//------------------------------------------------------------------------------
// Horizontal filter.

inline fn DoHorizontalFilter_SSE2(in_: [*]const u8, width: c_int, height: c_int, stride: c_int, row_: c_int, num_rows: c_int, out_: [*]u8) void {
    var out, var in, var row = .{ out_, in_, row_ };
    const start_offset: usize = @intCast(row * stride);
    const last_row = row + num_rows;
    SANITY_CHECK(width, height, stride, row, num_rows);
    in += start_offset;
    out += start_offset;

    if (row == 0) {
        // Leftmost pixel is the same as input for topmost scanline.
        out[0] = in[0];
        PredictLineLeft_SSE2(in + 1, out + 1, width - 1);
        row = 1;
        in = webp.offsetPtr(in, stride);
        out = webp.offsetPtr(out, stride);
    }

    // Filter line-by-line.
    while (row < last_row) {
        // Leftmost pixel is predicted from above.
        out[0] = in[0] -% webp.offsetPtr(in, -stride)[0];
        PredictLineLeft_SSE2(in + 1, out + 1, width - 1);
        row += 1;
        in = webp.offsetPtr(in, stride);
        out = webp.offsetPtr(out, stride);
    }
}

//------------------------------------------------------------------------------
// Vertical filter.

inline fn DoVerticalFilter_SSE2(in_: [*c]const u8, width: c_int, height: c_int, stride: c_int, row_: c_int, num_rows: c_int, out_: [*c]u8) void {
    var out, var in, var row = .{ out_, in_, row_ };
    const start_offset: usize = @intCast(row * stride);
    const last_row = row + num_rows;
    SANITY_CHECK(width, height, stride, row, num_rows);
    in += start_offset;
    out += start_offset;

    if (row == 0) {
        // Very first top-left pixel is copied.
        out[0] = in[0];
        // Rest of top scan-line is left-predicted.
        PredictLineLeft_SSE2(in + 1, out + 1, width - 1);
        row = 1;
        in = webp.offsetPtr(in, stride);
        out = webp.offsetPtr(out, stride);
    }

    // Filter line-by-line.
    while (row < last_row) {
        PredictLineTop_SSE2(in, webp.offsetPtr(in, -stride), out, width);
        row += 1;
        in = webp.offsetPtr(in, stride);
        out = webp.offsetPtr(out, stride);
    }
}

//------------------------------------------------------------------------------
// Gradient filter.

inline fn GradientPredictor_SSE2(a: u8, b: u8, c: u8) u8 {
    const g = @as(i32, a) + @as(i32, b) - @as(i32, c);
    return if ((g & ~@as(i32, 0xff)) == 0) @truncate(@as(u32, @bitCast(g))) else if (g < 0) 0 else 255; // clip to 8bit
}

fn GradientPredictDirect_SSE2(row: [*c]const u8, top: [*c]const u8, out: [*c]u8, length: c_int) void {
    const max_pos = length & ~@as(c_int, 7);
    var i: usize = 0;
    const zero = webp._mm_setzero_si128();
    while (i < max_pos) : (i += 8) {
        const A0 = webp._mm_loadl_epi64(@ptrCast(row + i - 1));
        const B0 = webp._mm_loadl_epi64(@ptrCast(top + i));
        const C0 = webp._mm_loadl_epi64(@ptrCast(top + i - 1));
        const D = webp._mm_loadl_epi64(@ptrCast(row + i));
        const A1 = webp._mm_unpacklo_epi8(A0, zero);
        const B1 = webp._mm_unpacklo_epi8(B0, zero);
        const C1 = webp._mm_unpacklo_epi8(C0, zero);
        const E = webp._mm_add_epi16(A1, B1);
        const F = webp._mm_sub_epi16(E, C1);
        const G = webp._mm_packus_epi16(F, zero);
        const H = webp._mm_sub_epi8(D, G);
        webp._mm_storel_epi64(@ptrCast(out[i..]), H);
    }
    while (i < length) : (i += 1) {
        const delta = GradientPredictor_SSE2((row + i - 1)[0], top[i], (top + i - 1)[0]);
        out[i] = row[i] -% delta;
    }
}

inline fn DoGradientFilter_SSE2(in_: [*c]const u8, width: c_int, height: c_int, stride: c_int, row_: c_int, num_rows: c_int, out_: [*c]u8) void {
    var out, var in, var row = .{ out_, in_, row_ };
    const start_offset: usize = @intCast(row * stride);
    const last_row = row + num_rows;
    SANITY_CHECK(width, height, stride, row, num_rows);
    in += start_offset;
    out += start_offset;

    // left prediction for top scan-line
    if (row == 0) {
        out[0] = in[0];
        PredictLineLeft_SSE2(in + 1, out + 1, width - 1);
        row = 1;
        in = webp.offsetPtr(in, stride);
        out = webp.offsetPtr(out, stride);
    }

    // Filter line-by-line.
    while (row < last_row) {
        out[0] = in[0] -% webp.offsetPtr(in, -stride)[0];
        GradientPredictDirect_SSE2(in + 1, webp.offsetPtr(in + 1, -stride), out + 1, width - 1);
        row += 1;
        in = webp.offsetPtr(in, stride);
        out = webp.offsetPtr(out, stride);
    }
}

//------------------------------------------------------------------------------

fn HorizontalFilter_SSE2(data: [*c]const u8, width: c_int, height: c_int, stride: c_int, filtered_data: [*c]u8) callconv(.C) void {
    DoHorizontalFilter_SSE2(data, width, height, stride, 0, height, filtered_data);
}

fn VerticalFilter_SSE2(data: [*c]const u8, width: c_int, height: c_int, stride: c_int, filtered_data: [*c]u8) callconv(.C) void {
    DoVerticalFilter_SSE2(data, width, height, stride, 0, height, filtered_data);
}

fn GradientFilter_SSE2(data: [*c]const u8, width: c_int, height: c_int, stride: c_int, filtered_data: [*c]u8) callconv(.C) void {
    DoGradientFilter_SSE2(data, width, height, stride, 0, height, filtered_data);
}

//------------------------------------------------------------------------------
// Inverse transforms

fn HorizontalUnfilter_SSE2(prev: [*c]const u8, in: [*c]const u8, out: [*c]u8, width: c_int) callconv(.C) void {
    // __m128i last;
    out[0] = in[0] +% (if (prev == null) 0 else prev[0]);
    if (width <= 1) return;
    var last = webp._mm_set_epi32(0, 0, 0, out[0]);
    var i: usize = 1;
    while (i + 8 <= width) : (i += 8) {
        const A0 = webp._mm_loadl_epi64(@ptrCast(in + i));
        const A1 = webp._mm_add_epi8(A0, last);
        const A2 = webp._mm_slli_si128(A1, 1);
        const A3 = webp._mm_add_epi8(A1, A2);
        const A4 = webp._mm_slli_si128(A3, 2);
        const A5 = webp._mm_add_epi8(A3, A4);
        const A6 = webp._mm_slli_si128(A5, 4);
        const A7 = webp._mm_add_epi8(A5, A6);
        webp._mm_storel_epi64(@ptrCast(out + i), A7);
        last = webp._mm_srli_epi64(A7, 56);
    }
    while (i < width) : (i += 1) out[i] = in[i] +% (out + i - 1)[0];
}

fn VerticalUnfilter_SSE2(prev: [*c]const u8, in: [*c]const u8, out: [*c]u8, width: c_int) callconv(.C) void {
    if (prev == null) {
        HorizontalUnfilter_SSE2(null, in, out, width);
        return;
    }
    const max_pos = width & ~@as(c_int, 31);
    assert(width >= 0);
    var i: usize = 0;
    while (i < max_pos) : (i += 32) {
        const A0 = webp._mm_loadu_si128(in[i + 0 ..]);
        const A1 = webp._mm_loadu_si128(in[i + 16 ..]);
        const B0 = webp._mm_loadu_si128(prev[i + 0 ..]);
        const B1 = webp._mm_loadu_si128(prev[i + 16 ..]);
        const C0 = webp._mm_add_epi8(A0, B0);
        const C1 = webp._mm_add_epi8(A1, B1);
        out[i + 0 ..][0..16].* = @bitCast(C0);
        out[i + 16 ..][0..16].* = @bitCast(C1);
    }
    while (i < width) : (i += 1) out[i] = in[i] +% prev[i];
}

fn GradientPredictInverse_SSE2(in: [*c]const u8, top: [*c]const u8, row: [*c]u8, length: c_int) void {
    if (length <= 0) return;
    const max_pos = length & ~@as(c_int, 7);
    const zero = webp._mm_setzero_si128();
    var A = webp._mm_set_epi32(0, 0, 0, (row - 1)[0]); // left sample
    var i: usize = 0;
    while (i < max_pos) : (i += 8) {
        const tmp0 = webp._mm_loadl_epi64(@ptrCast(top[i..]));
        const tmp1 = webp._mm_loadl_epi64(@ptrCast(top + i - 1));
        const B = webp._mm_unpacklo_epi8(tmp0, zero);
        const C = webp._mm_unpacklo_epi8(tmp1, zero);
        const D = webp._mm_loadl_epi64(@ptrCast(in[i..])); // base input
        const E = webp._mm_sub_epi16(B, C); // unclipped gradient basis B - C
        var out = zero; // accumulator for output
        var mask_hi = webp._mm_set_epi32(0, 0, 0, 0xff);
        var k: u8 = 8;
        while (true) {
            const tmp3 = webp._mm_add_epi16(A, E); // delta = A + B - C
            const tmp4 = webp._mm_packus_epi16(tmp3, zero); // saturate delta
            const tmp5 = webp._mm_add_epi8(tmp4, D); // add to in[]
            A = webp._mm_and_si128(tmp5, mask_hi); // 1-complement clip
            out = webp._mm_or_si128(out, A); // accumulate output
            if (k - 1 == 0) break;
            k -= 1;
            A = webp._mm_slli_si128(A, 1); // rotate left sample
            mask_hi = webp._mm_slli_si128(mask_hi, 1); // rotate mask
            A = webp._mm_unpacklo_epi8(A, zero); // convert 8b->16b
        }
        A = webp._mm_srli_si128(A, 7); // prepare left sample for next iteration
        webp._mm_storel_epi64(@ptrCast(row[i..]), out);
    }
    while (i < length) : (i += 1) {
        const delta = GradientPredictor_SSE2((row + i - 1)[0], top[i], (top + i - 1)[0]);
        row[i] = in[i] +% delta;
    }
}

fn GradientUnfilter_SSE2(prev: [*c]const u8, in: [*c]const u8, out: [*c]u8, width: c_int) callconv(.C) void {
    if (prev == null) {
        HorizontalUnfilter_SSE2(null, in, out, width);
    } else {
        out[0] = in[0] +% prev[0]; // predict from above
        GradientPredictInverse_SSE2(in + 1, prev + 1, out + 1, width - 1);
    }
}

//------------------------------------------------------------------------------
// Entry point

pub fn VP8FiltersInitSSE2() void {
    webp.WebPUnfilters[@intFromEnum(webp.FilterType.HORIZONTAL)] = &HorizontalUnfilter_SSE2;
    // #if defined(CHROMIUM)
    // // TODO(crbug.com/654974)
    // (void)VerticalUnfilter_SSE2;
    // #else
    webp.WebPUnfilters[@intFromEnum(webp.FilterType.VERTICAL)] = &VerticalUnfilter_SSE2;
    // #endif
    webp.WebPUnfilters[@intFromEnum(webp.FilterType.GRADIENT)] = &GradientUnfilter_SSE2;

    webp.WebPFilters[@intFromEnum(webp.FilterType.HORIZONTAL)] = &HorizontalFilter_SSE2;
    webp.WebPFilters[@intFromEnum(webp.FilterType.VERTICAL)] = &VerticalFilter_SSE2;
    webp.WebPFilters[@intFromEnum(webp.FilterType.GRADIENT)] = &GradientFilter_SSE2;
}
