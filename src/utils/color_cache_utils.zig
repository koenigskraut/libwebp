// Main color cache struct.
pub const VP8LColorCache = extern struct {
    /// color entries
    colors_: [*c]u32,
    /// Hash shift: 32 - hash_bits_.
    hash_shift_: c_int,
    hash_bits_: c_int,
};

const kHashMul: u32 = 0x1e35a7bd;
