const std = @import("std");
const builtin = @import("builtin");

pub inline fn HToLE32(x: u32) u32 {
    if (comptime builtin.cpu.arch.endian() == .big) {
        return @byteSwap(x);
    } else {
        return x;
    }
}

pub inline fn HToLE16(x: u16) u16 {
    if (comptime builtin.cpu.arch.endian() == .big) {
        return @byteSwap(x);
    } else {
        return x;
    }
}
