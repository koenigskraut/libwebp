const std = @import("std");
const webp = struct {
    usingnamespace @import("utils.zig");
};

const assert = std.debug.assert;
const c_bool = webp.c_bool;

const kHashMul: u32 = 0x1e35a7bd;

pub inline fn VP8LHashPix(argb: u32, shift: c_int) c_int {
    return @intCast((argb *% kHashMul) >> @intCast(shift));
}

/// Main color cache struct.
pub const VP8LColorCache = extern struct {
    /// color entries
    colors_: [*c]u32,
    /// Hash shift: 32 - hash_bits_.
    hash_shift_: c_int,
    hash_bits_: c_int,

    pub inline fn lookup(cc: *const VP8LColorCache, key: u32) u32 {
        assert((key >> @intCast(cc.hash_bits_)) == 0);
        return cc.colors_[key];
    }

    pub inline fn set(cc: *const VP8LColorCache, key: u32, argb: u32) void {
        assert((key >> @intCast(cc.hash_bits_)) == 0);
        cc.colors_[key] = argb;
    }

    pub inline fn insert(cc: *const VP8LColorCache, argb: u32) void {
        const key: c_int = VP8LHashPix(argb, cc.*.hash_shift_);
        cc.colors_[@intCast(key)] = argb;
    }

    pub inline fn getIndex(cc: *const VP8LColorCache, argb: u32) c_int {
        return VP8LHashPix(argb, cc.hash_shift_);
    }

    /// Return the key if cc contains argb, and -1 otherwise.
    pub inline fn contains(cc: *const VP8LColorCache, argb: u32) c_int {
        const key = VP8LHashPix(argb, cc.hash_shift_);
        return if (cc.colors_[@intCast(key)] == argb) key else -1;
    }
};

//------------------------------------------------------------------------------

/// Initializes the color cache with 'hash_bits' bits for the keys.
/// Returns false in case of memory error.
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

/// Delete the memory associated to color cache.
pub export fn VP8LColorCacheClear(color_cache: ?*VP8LColorCache) void {
    if (color_cache) |cc| {
        webp.WebPSafeFree(cc.colors_);
        cc.colors_ = null;
    }
}

//------------------------------------------------------------------------------
