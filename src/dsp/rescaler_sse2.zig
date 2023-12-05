const std = @import("std");
const webp = struct {
    usingnamespace @import("intrinsics.zig");
    usingnamespace @import("rescaler.zig");
    usingnamespace @import("../utils/rescaler_utils.zig");
    usingnamespace @import("../utils/utils.zig");
};

const assert = std.debug.assert;
const m128 = webp.m128;
const v128 = webp.v128;

//------------------------------------------------------------------------------
// Implementations of critical functions ImportRow / ExportRow

const ROUNDER = webp.WEBP_RESCALER_ONE >> 1;

inline fn MULT_FIX(x: u32, y: u32) u32 {
    const mult = @as(u64, x) * @as(u64, y) + ROUNDER;
    return @truncate(mult >> webp.WEBP_RESCALER_RFIX);
}

inline fn MULT_FIX_FLOOR(x: u32, y: u32) u32 {
    const mult = @as(u64, x) * @as(u64, y);
    return @truncate(mult >> webp.WEBP_RESCALER_RFIX);
}

// input: 8 bytes ABCDEFGH -> output: A0E0B0F0C0G0D0H0
fn LoadTwoPixels_SSE2(src: [*c]const u8, out: *m128) void {
    const zero = v128.zero().vec();
    const A = webp.Z_mm_loadl_epi64(src); // ABCDEFGH
    const B = webp.Z_mm_unpacklo_epi8(A, zero); // A0B0C0D0E0F0G0H0
    const C = webp.Z_mm_srli_si128(B, 8); // E0F0G0H0
    out.* = webp.Z_mm_unpacklo_epi16(B, C);
}

// input: 8 bytes ABCDEFGH -> output: A0B0C0D0E0F0G0H0
fn LoadEightPixels_SSE2(src: [*c]const u8, out: *m128) void {
    const zero = v128.zero().vec();
    const A = webp.Z_mm_loadl_epi64(src); // ABCDEFGH
    out.* = webp.Z_mm_unpacklo_epi8(A, zero);
}

fn RescalerImportRowExpand_SSE2(wrk: *webp.WebPRescaler, src_: [*c]const u8) callconv(.C) void {
    var src = src_;
    var frow = wrk.frow;
    const frow_end: [*c]const webp.rescaler_t = webp.offsetPtr(frow, wrk.dst_width * wrk.num_channels);
    const x_add = wrk.x_add;
    var accum = x_add;

    // SSE2 implementation only works with 16b signed arithmetic at max.
    if (wrk.src_width < 8 or accum >= (1 << 15)) {
        webp.WebPRescalerImportRowExpand_C(wrk, src);
        return;
    }

    assert(!wrk.inputDone());
    assert(wrk.x_expand != 0);
    var cur_pixels: m128 = undefined;
    if (wrk.num_channels == 4) {
        LoadTwoPixels_SSE2(src, &cur_pixels);
        src += 4;
        while (true) {
            const mult = v128.set1u32(@bitCast(((x_add - accum) << 16) | accum)).vec();
            const out = webp.Z_mm_madd_epi16(cur_pixels, mult);
            frow[0..4].* = @bitCast(out);
            frow += 4;
            if (frow >= frow_end) break;
            accum -= wrk.x_sub;
            if (accum < 0) {
                LoadTwoPixels_SSE2(src, &cur_pixels);
                src += 4;
                accum += x_add;
            }
        }
    } else {
        const src_limit: [*c]const u8 = webp.offsetPtr(src, wrk.src_width - 8);
        LoadEightPixels_SSE2(src, &cur_pixels);
        src += 7;
        var left: c_int = 7;
        while (true) {
            const mult = webp.Z_mm_cvtsi32_si128(@bitCast(((x_add - accum) << 16) | accum));
            const out = webp.Z_mm_madd_epi16(cur_pixels, mult);
            assert(@sizeOf(@TypeOf(frow.*)) == @sizeOf(u32));
            webp.WebPUint32ToMem(@ptrCast(frow), webp.Z_mm_cvtsi128_si32(out));
            frow += 1;
            if (frow >= frow_end) break;
            accum -= wrk.x_sub;
            if (accum < 0) {
                left -= 1;
                if (left != 0) {
                    cur_pixels = webp.Z_mm_srli_si128(cur_pixels, 2);
                } else if (src <= src_limit) {
                    LoadEightPixels_SSE2(src, &cur_pixels);
                    src += 7;
                    left = 7;
                } else { // tail
                    cur_pixels = webp.Z_mm_srli_si128(cur_pixels, 2);
                    cur_pixels = webp.Z_mm_insert_epi16(cur_pixels, src[1], 1);
                    src += 1;
                    left = 1;
                }
                accum += x_add;
            }
        }
    }
    assert(accum == 0);
}

fn RescalerImportRowShrink_SSE2(wrk: *webp.WebPRescaler, src_: [*c]const u8) callconv(.C) void {
    var src = src_;
    const x_sub = wrk.x_sub;
    const zero = v128.zero().vec();
    const mult0 = v128.set1u16(@truncate(@as(u32, @bitCast(x_sub)))).vec();
    const mult1 = v128.set1u32(wrk.fx_scale).vec();
    const rounder = v128.setU32(.{ 0, ROUNDER, 0, ROUNDER }).vec();
    var sum = zero;
    var frow: [*c]webp.rescaler_t = wrk.frow;
    const frow_end: [*c]const webp.rescaler_t = webp.offsetPtr(wrk.frow, 4 * wrk.dst_width);

    if (wrk.num_channels != 4 or wrk.x_add > (x_sub << 7)) {
        webp.WebPRescalerImportRowShrink_C(wrk, src);
        return;
    }
    assert(!wrk.inputDone());
    assert(!(wrk.x_expand != 0));

    var accum: c_int = 0;
    while (frow < frow_end) : (frow += 4) {
        var base = zero;
        accum += wrk.x_add;
        while (accum > 0) {
            const A = webp.Z_mm_cvtsi32_si128(webp.WebPMemToUint32(src));
            src += 4;
            base = webp.Z_mm_unpacklo_epi8(A, zero);
            // To avoid overflow, we need: base * x_add / x_sub < 32768
            // => x_add < x_sub << 7. That's a 1/128 reduction ratio limit.
            sum = webp.Z_mm_add_epi16(sum, base);
            accum -= x_sub;
        }
        { // Emit next horizontal pixel.
            const mult = v128.set1u16(@truncate(@as(u32, @bitCast(-accum)))).vec();
            const frac0 = webp.Z_mm_mullo_epi16(base, mult); // 16b x 16b -> 32b
            const frac1 = webp.Z_mm_mulhi_epu16(base, mult);
            const frac = webp.Z_mm_unpacklo_epi16(frac0, frac1); // frac is 32b
            const A0 = webp.Z_mm_mullo_epi16(sum, mult0);
            const A1 = webp.Z_mm_mulhi_epu16(sum, mult0);
            const B0 = webp.Z_mm_unpacklo_epi16(A0, A1); // sum * x_sub
            const frow_out = webp.Z_mm_sub_epi32(B0, frac); // sum * x_sub - frac
            const D0 = webp.Z_mm_srli_epi64(frac, 32);
            const D1 = webp.Z_mm_mul_epu32(frac, mult1); // 32b x 16b -> 64b
            const D2 = webp.Z_mm_mul_epu32(D0, mult1);
            const E1 = webp.Z_mm_add_epi64(D1, rounder);
            const E2 = webp.Z_mm_add_epi64(D2, rounder);
            const F1 = webp.Z_mm_shuffle_epi32(E1, .{ 1, 3, 0, 0 });
            const F2 = webp.Z_mm_shuffle_epi32(E2, .{ 1, 3, 0, 0 });
            const G = webp.Z_mm_unpacklo_epi32(F1, F2);
            sum = webp.Z_mm_packs_epi32(G, zero);
            frow[0..4].* = @bitCast(frow_out);
        }
    }
    assert(accum == 0);
}

//------------------------------------------------------------------------------
// Row export

// load *src as epi64, multiply by mult and store result in [out0 ... out3]
inline fn LoadDispatchAndMult_SSE2(src: [*c]const webp.rescaler_t, mult: ?*const m128, out0: *m128, out1: *m128, out2: *m128, out3: *m128) void {
    const A0 = v128.load128(@ptrCast(src + 0)).vec();
    const A1 = v128.load128(@ptrCast(src + 4)).vec();
    const A2 = webp.Z_mm_srli_epi64(A0, 32);
    const A3 = webp.Z_mm_srli_epi64(A1, 32);
    if (mult != null) {
        out0.* = webp.Z_mm_mul_epu32(A0, mult.?.*);
        out1.* = webp.Z_mm_mul_epu32(A1, mult.?.*);
        out2.* = webp.Z_mm_mul_epu32(A2, mult.?.*);
        out3.* = webp.Z_mm_mul_epu32(A3, mult.?.*);
    } else {
        out0.* = A0;
        out1.* = A1;
        out2.* = A2;
        out3.* = A3;
    }
}

inline fn ProcessRow_SSE2(A0: *const m128, A1: *const m128, A2: *const m128, A3: *const m128, mult: *const m128, dst: [*c]u8) void {
    const rounder = v128.setU32(.{ 0, ROUNDER, 0, ROUNDER }).vec();
    const mask = v128.setU32(.{ ~@as(u32, 0), 0, ~@as(u32, 0), 0 }).vec();
    const B0 = webp.Z_mm_mul_epu32(A0.*, mult.*);
    const B1 = webp.Z_mm_mul_epu32(A1.*, mult.*);
    const B2 = webp.Z_mm_mul_epu32(A2.*, mult.*);
    const B3 = webp.Z_mm_mul_epu32(A3.*, mult.*);
    const C0 = webp.Z_mm_add_epi64(B0, rounder);
    const C1 = webp.Z_mm_add_epi64(B1, rounder);
    const C2 = webp.Z_mm_add_epi64(B2, rounder);
    const C3 = webp.Z_mm_add_epi64(B3, rounder);
    const D0 = webp.Z_mm_srli_epi64(C0, webp.WEBP_RESCALER_RFIX);
    const D1 = webp.Z_mm_srli_epi64(C1, webp.WEBP_RESCALER_RFIX);
    const rfix = webp.WEBP_RESCALER_RFIX < 32;
    const D2 = if (comptime rfix) (webp.Z_mm_slli_epi64(C2, 32 - webp.WEBP_RESCALER_RFIX) & mask) else C2 & mask;
    const D3 = if (comptime rfix) (webp.Z_mm_slli_epi64(C3, 32 - webp.WEBP_RESCALER_RFIX) & mask) else C3 & mask;
    const E0 = webp.Z_mm_or_si128(D0, D2);
    const E1 = webp.Z_mm_or_si128(D1, D3);
    const F = webp.Z_mm_packs_epi32(E0, E1);
    const G = webp.Z_mm_packus_epi16(F, F);
    webp.Z_mm_storel_epi64(dst, G);
}

fn RescalerExportRowExpand_SSE2(wrk: *webp.WebPRescaler) callconv(.C) void {
    // int x_out;
    const dst = wrk.dst;
    const irow = wrk.irow;
    const x_out_max = wrk.dst_width * wrk.num_channels;
    const frow: [*c]const webp.rescaler_t = wrk.frow;
    const mult = v128.setU32(.{ 0, wrk.fy_scale, 0, wrk.fy_scale }).vec();

    assert(!wrk.outputDone());
    assert(wrk.y_accum <= 0 and wrk.y_sub + wrk.y_accum >= 0);
    assert(wrk.y_expand != 0);
    var x_out: usize = 0;
    if (wrk.y_accum == 0) {
        while (x_out + 8 <= x_out_max) : (x_out += 8) {
            var A0: m128, var A1: m128, var A2: m128, var A3: m128 = .{undefined} ** 4;
            LoadDispatchAndMult_SSE2(frow + x_out, null, &A0, &A1, &A2, &A3);
            ProcessRow_SSE2(&A0, &A1, &A2, &A3, &mult, dst + x_out);
        }
        while (x_out < x_out_max) : (x_out += 1) {
            const J: u32 = frow[x_out];
            const v = MULT_FIX(J, wrk.fy_scale);
            dst[x_out] = if (v > 255) 255 else @truncate(v);
        }
    } else {
        const B = webp.WEBP_RESCALER_FRAC(-wrk.y_accum, wrk.y_sub);
        const A: u32 = @truncate(@as(u64, webp.WEBP_RESCALER_ONE) -% B);
        const mA = v128.setU32(.{ 0, A, 0, A }).vec();
        const mB = v128.setU32(.{ 0, B, 0, B }).vec();
        const rounder = v128.setU32(.{ 0, ROUNDER, 0, ROUNDER }).vec();
        while (x_out + 8 <= x_out_max) : (x_out += 8) {
            var A0: m128, var A1: m128, var A2: m128, var A3: m128, var B0: m128, var B1: m128, var B2: m128, var B3: m128 = .{undefined} ** 8;
            LoadDispatchAndMult_SSE2(frow + x_out, &mA, &A0, &A1, &A2, &A3);
            LoadDispatchAndMult_SSE2(irow + x_out, &mB, &B0, &B1, &B2, &B3);
            {
                const C0 = webp.Z_mm_add_epi64(A0, B0);
                const C1 = webp.Z_mm_add_epi64(A1, B1);
                const C2 = webp.Z_mm_add_epi64(A2, B2);
                const C3 = webp.Z_mm_add_epi64(A3, B3);
                const D0 = webp.Z_mm_add_epi64(C0, rounder);
                const D1 = webp.Z_mm_add_epi64(C1, rounder);
                const D2 = webp.Z_mm_add_epi64(C2, rounder);
                const D3 = webp.Z_mm_add_epi64(C3, rounder);
                const E0 = webp.Z_mm_srli_epi64(D0, webp.WEBP_RESCALER_RFIX);
                const E1 = webp.Z_mm_srli_epi64(D1, webp.WEBP_RESCALER_RFIX);
                const E2 = webp.Z_mm_srli_epi64(D2, webp.WEBP_RESCALER_RFIX);
                const E3 = webp.Z_mm_srli_epi64(D3, webp.WEBP_RESCALER_RFIX);
                ProcessRow_SSE2(&E0, &E1, &E2, &E3, &mult, dst + x_out);
            }
        }
        while (x_out < x_out_max) : (x_out += 1) {
            const I = @as(u64, A) * frow[x_out] + @as(u64, B) * irow[x_out];
            const J: u32 = @truncate((I + ROUNDER) >> webp.WEBP_RESCALER_RFIX);
            const v: i32 = @bitCast(MULT_FIX(J, wrk.fy_scale));
            dst[x_out] = if (v > 255) 255 else @truncate(@as(u32, @bitCast(v)));
        }
    }
}

fn RescalerExportRowShrink_SSE2(wrk: *webp.WebPRescaler) callconv(.C) void {
    const dst = wrk.dst;
    const irow = wrk.irow;
    const x_out_max = wrk.dst_width * wrk.num_channels;
    const frow: [*c]const webp.rescaler_t = wrk.frow;
    const yscale = wrk.fy_scale *% @as(u32, @bitCast(-wrk.y_accum));
    assert(!wrk.outputDone());
    assert(wrk.y_accum <= 0);
    assert(!(wrk.y_expand != 0));
    var x_out: usize = 0;
    if (yscale != 0) {
        const scale_xy = wrk.fxy_scale;
        const mult_xy = v128.setU32(.{ 0, scale_xy, 0, scale_xy }).vec();
        const mult_y = v128.setU32(.{ 0, yscale, 0, yscale }).vec();
        while (x_out + 8 <= x_out_max) : (x_out += 8) {
            var A0: m128, var A1: m128, var A2: m128, var A3: m128, var B0: m128, var B1: m128, var B2: m128, var B3: m128 = .{undefined} ** 8;
            LoadDispatchAndMult_SSE2(irow + x_out, null, &A0, &A1, &A2, &A3);
            LoadDispatchAndMult_SSE2(frow + x_out, &mult_y, &B0, &B1, &B2, &B3);
            {
                const D0 = webp.Z_mm_srli_epi64(B0, webp.WEBP_RESCALER_RFIX); // = frac
                const D1 = webp.Z_mm_srli_epi64(B1, webp.WEBP_RESCALER_RFIX);
                const D2 = webp.Z_mm_srli_epi64(B2, webp.WEBP_RESCALER_RFIX);
                const D3 = webp.Z_mm_srli_epi64(B3, webp.WEBP_RESCALER_RFIX);
                const E0 = webp.Z_mm_sub_epi64(A0, D0); // irow[x] - frac
                const E1 = webp.Z_mm_sub_epi64(A1, D1);
                const E2 = webp.Z_mm_sub_epi64(A2, D2);
                const E3 = webp.Z_mm_sub_epi64(A3, D3);
                const F2 = webp.Z_mm_slli_epi64(D2, 32);
                const F3 = webp.Z_mm_slli_epi64(D3, 32);
                const G0 = webp.Z_mm_or_si128(D0, F2);
                const G1 = webp.Z_mm_or_si128(D1, F3);
                (irow + x_out + 0)[0..4].* = @bitCast(G0);
                (irow + x_out + 4)[0..4].* = @bitCast(G1);
                ProcessRow_SSE2(&E0, &E1, &E2, &E3, &mult_xy, dst + x_out);
            }
        }
        while (x_out < x_out_max) : (x_out += 1) {
            const frac = MULT_FIX_FLOOR(frow[x_out], yscale);
            const v: i32 = @bitCast(MULT_FIX(irow[x_out] -% frac, wrk.fxy_scale));
            dst[x_out] = if (v > 255) 255 else @truncate(@as(u32, @bitCast(v)));
            irow[x_out] = frac; // new fractional start
        }
    } else {
        const scale = wrk.fxy_scale;
        const mult = v128.setU32(.{ 0, scale, 0, scale }).vec();
        const zero = v128.zero().vec();
        while (x_out + 8 <= x_out_max) : (x_out += 8) {
            var A0: m128, var A1: m128, var A2: m128, var A3: m128 = .{undefined} ** 4;
            LoadDispatchAndMult_SSE2(irow + x_out, null, &A0, &A1, &A2, &A3);
            (irow + x_out + 0)[0..4].* = @bitCast(zero);
            (irow + x_out + 4)[0..4].* = @bitCast(zero);
            ProcessRow_SSE2(&A0, &A1, &A2, &A3, &mult, dst + x_out);
        }
        while (x_out < x_out_max) : (x_out += 1) {
            const v: i32 = @bitCast(MULT_FIX(irow[x_out], scale));
            dst[x_out] = if (v > 255) 255 else @truncate(@as(u32, @bitCast(v)));
            irow[x_out] = 0;
        }
    }
}

//------------------------------------------------------------------------------

pub fn WebPRescalerDspInitSSE2() void {
    webp.WebPRescalerImportRowExpand = &RescalerImportRowExpand_SSE2;
    webp.WebPRescalerImportRowShrink = &RescalerImportRowShrink_SSE2;
    webp.WebPRescalerExportRowExpand = &RescalerExportRowExpand_SSE2;
    webp.WebPRescalerExportRowShrink = &RescalerExportRowShrink_SSE2;
}
