// Structure used for on-the-fly rescaling
/// type for side-buffer
pub const rescaler_t = u32;

pub const WebPRescaler = extern struct {
    /// true if we're expanding in the x direction
    x_expand: c_int,
    /// true if we're expanding in the y direction
    y_expand: c_int,
    /// bytes to jump between pixels
    num_channels: c_int,
    /// fixed-point scaling factor
    fx_scale: u32,
    /// fixed-point scaling factor
    fy_scale: u32,
    /// fixed-point scaling factor
    fxy_scale: u32,
    /// vertical accumulator
    y_accum: c_int,
    y_add: c_int, // vertical increments
    y_sub: c_int,
    x_add: c_int, // horizontal increments
    x_sub: c_int,
    src_width: c_int, // source dimensions
    src_height: c_int,
    dst_width: c_int, // destination dimensions
    dst_height: c_int,
    src_y: c_int, // row counters for input and output
    dst_y: c_int,
    dst: [*c]u8,
    dst_stride: c_int,
    irow: [*c]rescaler_t, // work buffer
    frow: [*c]rescaler_t,
};

pub fn WebPRescalerOutputDone(rescaler: *const WebPRescaler) bool {
    return rescaler.dst_y >= rescaler.dst_height;
}
pub fn WebPRescalerHasPendingOutput(rescaler: *const WebPRescaler) bool {
    return !(WebPRescalerOutputDone(rescaler)) and (rescaler.y_accum <= 0);
}
