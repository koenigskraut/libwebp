const std = @import("std");
const webp = struct {
    usingnamespace @import("../dsp/dsp.zig");
};

// -----------------------------------------------------------------------------
// Quick estimate of a potentially interesting filter mode to try.

const SMAX = 16;
// inline fn SDIFF(a, b) (abs((a) - (b)) >> 4)
/// Scoring diff, in [0..SMAX)
// inline fn SDIFF(a: anytype, b: anytype) @TypeOf(@abs(a - b) >> @as(c_int, 4)) {
//     return @abs(a - b) >> @as(c_int, 4);
// }

export fn GradientPredictor(a: u8, b: u8, c: u8) u8 {
    const g: i16 = @as(i16, @intCast(a)) + @as(i16, @intCast(b)) - @as(i16, @intCast(c));
    return if ((g & ~@as(i16, 0xff)) == 0) @intCast(g) else if (g < 0) 0 else 255; // clip to 8bit
}

// /// Fast estimate of a potentially good filter.
// pub export fn WebPEstimateBestFilter(data: [*c]const u8, width: c_int, height: c_int, stride: c_int) webp.FilterType {
//     int i, j;
//     int bins[WEBP_FILTER_LAST][SMAX];
//     memset(bins, 0, sizeof(bins));

//     // We only sample every other pixels. That's enough.
//     for (j = 2; j < height - 1; j += 2) {
//         const uint8_t* const p = data + j * stride;
//         int mean = p[0];
//         for (i = 2; i < width - 1; i += 2) {
//         const int diff0 = SDIFF(p[i], mean);
//         const int diff1 = SDIFF(p[i], p[i - 1]);
//         const int diff2 = SDIFF(p[i], p[i - width]);
//         const int grad_pred =
//             GradientPredictor(p[i - 1], p[i - width], p[i - width - 1]);
//         const int diff3 = SDIFF(p[i], grad_pred);
//         bins[WEBP_FILTER_NONE][diff0] = 1;
//         bins[WEBP_FILTER_HORIZONTAL][diff1] = 1;
//         bins[WEBP_FILTER_VERTICAL][diff2] = 1;
//         bins[WEBP_FILTER_GRADIENT][diff3] = 1;
//         mean = (3 * mean + p[i] + 2) >> 2;
//         }
//     }
//     {
//         int filter;
//         WEBP_FILTER_TYPE best_filter = WEBP_FILTER_NONE;
//         int best_score = 0x7fffffff;
//         for (filter = WEBP_FILTER_NONE; filter < WEBP_FILTER_LAST; ++filter) {
//         int score = 0;
//         for (i = 0; i < SMAX; ++i) {
//             if (bins[filter][i] > 0) {
//             score += i;
//             }
//         }
//         if (score < best_score) {
//             best_score = score;
//             best_filter = (WEBP_FILTER_TYPE)filter;
//         }
//         }
//         return best_filter;
//     }
// }
