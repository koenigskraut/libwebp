const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

const webp = struct {
    usingnamespace @import("../utils/utils.zig");
};

//------------------------------------------------------------------------------

// This macro prevents thread_sanitizer from reporting known concurrent writes.
// #define WEBP_TSAN_IGNORE_FUNCTION
// #if defined(__has_feature)
//     #if __has_feature(thread_sanitizer)
//         #undef WEBP_TSAN_IGNORE_FUNCTION
//         #define WEBP_TSAN_IGNORE_FUNCTION __attribute__((no_sanitize_thread))
//     #endif
// #endif

// #if defined(__has_feature)
//     #if __has_feature(memory_sanitizer)
//         #define WEBP_MSAN
//     #endif
// #endif

// pub extern var VP8GetCPUInfo: VP8CPUInfo;

// pub fn WEBP_DSP_INIT_FUNC(comptime func: fn () void) fn () void {
//     return struct {
//         pub fn _() void {
//             const S = struct {
//                 pub const body: fn () void = func;
//                 pub var last_cpuinfo_used: VP8CPUInfo = null;
//             };
//             if (comptime (build_options.WEBP_USE_THREAD and builtin.os.tag != .windows and false)) {
//                 var lock: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER;
//                 if (std.c.pthread_mutex_lock(&lock) != .SUCCESS) return;
//                 defer _ = std.c.pthread_mutex_unlock(&lock);
//                 if (S.last_cpuinfo_used != VP8GetCPUInfo) S.body();
//                 S.last_cpuinfo_used = VP8GetCPUInfo;
//             } else {
//                 if (S.last_cpuinfo_used == VP8GetCPUInfo) return;
//                 S.body();
//                 S.last_cpuinfo_used = VP8GetCPUInfo;
//             }
//         }
//     }._;
// }

// #define WEBP_UBSAN_IGNORE_UNDEF
// #define WEBP_UBSAN_IGNORE_UNSIGNED_OVERFLOW
// #if defined(__clang__) && defined(__has_attribute)
// #if __has_attribute(no_sanitize)
// // This macro prevents the undefined behavior sanitizer from reporting
// // failures. This is only meant to silence unaligned loads on platforms that
// // are known to support them.
// #undef WEBP_UBSAN_IGNORE_UNDEF
// #define WEBP_UBSAN_IGNORE_UNDEF __attribute__((no_sanitize("undefined")))

// // This macro prevents the undefined behavior sanitizer from reporting
// // failures related to unsigned integer overflows. This is only meant to
// // silence cases where this well defined behavior is expected.
// #undef WEBP_UBSAN_IGNORE_UNSIGNED_OVERFLOW
// #define WEBP_UBSAN_IGNORE_UNSIGNED_OVERFLOW \
//   __attribute__((no_sanitize("unsigned-integer-overflow")))
// #endif
// #endif

// // If 'ptr' is NULL, returns NULL. Otherwise returns 'ptr + off'.
// // Prevents undefined behavior sanitizer nullptr-with-nonzero-offset warning.
// #if !defined(WEBP_OFFSET_PTR)
// #define WEBP_OFFSET_PTR(ptr, off) (((ptr) == NULL) ? NULL : ((ptr) + (off)))
// #endif

// // Regularize the definition of WEBP_SWAP_16BIT_CSP (backward compatibility)
// #if !defined(WEBP_SWAP_16BIT_CSP)
// #define WEBP_SWAP_16BIT_CSP 0
// #endif

// // some endian fix (e.g.: mips-gcc doesn't define __BIG_ENDIAN__)
// #if !defined(WORDS_BIGENDIAN) &&                   \
//     (defined(__BIG_ENDIAN__) || defined(_M_PPC) || \
//      (defined(__BYTE_ORDER__) && (__BYTE_ORDER__ == __ORDER_BIG_ENDIAN__)))
// #define WORDS_BIGENDIAN
// #endif

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
pub const VP8CPUInfo = ?*const fn (CPUFeature) callconv(.C) c_int;
pub const VP8CPUInfoBody = fn (CPUFeature) callconv(.C) c_int;
