/// VP8X Feature Flags.
pub const FeatureFlags = enum(c_uint) {
    animation = 0x00000002,
    xmp = 0x00000004,
    exif = 0x00000008,
    alpha = 0x00000010,
    iccp = 0x00000020,

    all_valid_flags = 0x0000003e,
};
