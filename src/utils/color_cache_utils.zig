const std = @import("std");
const webp = struct {
    usingnamespace @import("utils.zig");
};

const assert = std.debug.assert;
const c_bool = webp.c_bool;

// Main color cache struct.
pub const VP8LColorCache = extern struct {
    /// color entries
    colors_: [*c]u32,
    /// Hash shift: 32 - hash_bits_.
    hash_shift_: c_int,
    hash_bits_: c_int,
};

const kHashMul: u32 = 0x1e35a7bd;

// static WEBP_UBSAN_IGNORE_UNSIGNED_OVERFLOW WEBP_INLINE
// int VP8LHashPix(uint32_t argb, int shift) {
//   return (int)((argb * kHashMul) >> shift);
// }

// static WEBP_INLINE uint32_t VP8LColorCacheLookup(
//     const VP8LColorCache* const cc, uint32_t key) {
//   assert((key >> cc->hash_bits_) == 0u);
//   return cc->colors_[key];
// }

// static WEBP_INLINE void VP8LColorCacheSet(const VP8LColorCache* const cc,
//                                           uint32_t key, uint32_t argb) {
//   assert((key >> cc->hash_bits_) == 0u);
//   cc->colors_[key] = argb;
// }

// static WEBP_INLINE void VP8LColorCacheInsert(const VP8LColorCache* const cc,
//                                              uint32_t argb) {
//   const int key = VP8LHashPix(argb, cc->hash_shift_);
//   cc->colors_[key] = argb;
// }

// static WEBP_INLINE int VP8LColorCacheGetIndex(const VP8LColorCache* const cc,
//                                               uint32_t argb) {
//   return VP8LHashPix(argb, cc->hash_shift_);
// }

// // Return the key if cc contains argb, and -1 otherwise.
// static WEBP_INLINE int VP8LColorCacheContains(const VP8LColorCache* const cc,
//                                               uint32_t argb) {
//   const int key = VP8LHashPix(argb, cc->hash_shift_);
//   return (cc->colors_[key] == argb) ? key : -1;
// }

//------------------------------------------------------------------------------

// Initializes the color cache with 'hash_bits' bits for the keys.
// Returns false in case of memory error.
pub export fn VP8LColorCacheInit(color_cache: *VP8LColorCache, hash_bits: c_int) c_bool {
    const hash_size = @as(c_int, 1) << @intCast(hash_bits);
    assert(hash_bits > 0);
    color_cache.colors_ = @ptrCast(@alignCast(webp.WebPSafeCalloc(@intCast(hash_size), @sizeOf(u32))));
    if (color_cache.colors_ == null) return 0;
    color_cache.hash_shift_ = 32 - hash_bits;
    color_cache.hash_bits_ = hash_bits;
    return 1;
}

pub export fn VP8LColorCacheCopy(src: *const VP8LColorCache, dst: *VP8LColorCache) void {
    assert(src.hash_bits_ == dst.hash_bits_);
    const len = @as(usize, 1) << @intCast(dst.hash_bits_);
    @memcpy(dst.colors_[0..len], src.colors_[0..len]);
}

// Delete the memory associated to color cache.
pub export fn VP8LColorCacheClear(color_cache: ?*VP8LColorCache) void {
    if (color_cache) |cc| {
        webp.WebPSafeFree(cc.colors_);
        cc.colors_ = null;
    }
}

//------------------------------------------------------------------------------
