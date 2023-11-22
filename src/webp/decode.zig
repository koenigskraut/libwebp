pub const DECODER_ABI_VERSION = 0x0209;

pub const VP8Error = error{
    OutOfMemory,
    InvalidParam,
    BitstreamError,
    UnsupportedFeature,
    Suspended,
    UserAbort,
    NotEnoughData,
};

/// Enumeration of the status codes
pub const VP8Status = enum(c_uint) {
    Ok = 0,
    OutOfMemory,
    InvalidParam,
    BitstreamError,
    UnsupportedFeature,
    Suspended,
    UserAbort,
    NotEnoughData,

    pub fn fromErr(err: VP8Error) VP8Status {
        return switch (err) {
            error.OutOfMemory => .OutOfMemory,
            error.InvalidParam => .InvalidParam,
            error.BitstreamError => .BitstreamError,
            error.UnsupportedFeature => .UnsupportedFeature,
            error.Suspended => .Suspended,
            error.UserAbort => .UserAbort,
            error.NotEnoughData => .NotEnoughData,
        };
    }

    pub fn toErr(self: VP8Status) VP8Error!void {
        return switch (self) {
            .Ok => .Ok,
            .OutOfMemory => VP8Error.OutOfMemory,
            .InvalidParam => VP8Error.InvalidParam,
            .BitstreamError => VP8Error.BitstreamError,
            .UnsupportedFeature => VP8Error.UnsupportedFeature,
            .Suspended => VP8Error.Suspended,
            .UserAbort => VP8Error.UserAbort,
            .NotEnoughData => VP8Error.NotEnoughData,
        };
    }
};

/// Colorspaces
/// Note: the naming describes the byte-ordering of packed samples in memory.
/// For instance, `BGRA` relates to samples ordered as B,G,R,A,B,G,R,A,...
/// Non-capital names (e.g.:`Argb`) relates to pre-multiplied RGB channels.
/// RGBA-4444 and RGB-565 colorspaces are represented by following byte-order:
///
/// RGBA-4444: [r3 r2 r1 r0 g3 g2 g1 g0], [b3 b2 b1 b0 a3 a2 a1 a0], ...
///
/// RGB-565: [r4 r3 r2 r1 r0 g5 g4 g3], [g2 g1 g0 b4 b3 b2 b1 b0], ...
///
/// In the case `WEBP_SWAP_16BITS_CSP` is defined, the bytes are swapped for
/// these two modes:
///
/// RGBA-4444: [b3 b2 b1 b0 a3 a2 a1 a0], [r3 r2 r1 r0 g3 g2 g1 g0], ...
///
/// RGB-565: [g2 g1 g0 b4 b3 b2 b1 b0], [r4 r3 r2 r1 r0 g5 g4 g3], ...
pub const ColorspaceMode = enum(c_uint) {
    RGB = 0,
    RGBA = 1,
    BGR = 2,
    BGRA = 3,
    ARGB = 4,
    RGBA_4444 = 5,
    RGB_565 = 6,
    // RGB-premultiplied transparent modes (alpha value is preserved)
    rgbA = 7,
    bgrA = 8,
    Argb = 9,
    rgbA_4444 = 10,
    // YUV modes must come after RGB ones.
    YUV = 11,
    YUVA = 12, // yuv 4:2:0
    LAST = 13,

    pub inline fn isPremultipliedMode(self: ColorspaceMode) bool {
        return switch (self) {
            .rgbA, .bgrA, .Argb, .rgbA_4444 => true,
            else => false,
        };
    }

    pub inline fn isAlphaMode(self: ColorspaceMode) bool {
        return switch (self) {
            .RGBA, .BGRA, .ARGB, .RGBA_4444, .YUVA => true,
            else => self.isPremultipliedMode(),
        };
    }

    pub inline fn isRGBMode(self: ColorspaceMode) bool {
        return @intFromEnum(self) < @intFromEnum(ColorspaceMode.YUV);
    }

    // Check that `webp_csp_mode` is within the bounds of `ColorspaceMode`.
    pub inline fn isValidColorspace(webp_csp_mode: anytype) bool {
        return webp_csp_mode >= @intFromEnum(ColorspaceMode.RGB) and webp_csp_mode < @intFromEnum(ColorspaceMode.LAST);
    }
};

/// Generic structure for describing the output sample buffer.
pub const RGBABuffer = extern struct { // view as RGBA
    /// pointer to RGBA samples
    rgba: [*c]u8,
    /// stride in bytes from one scanline to the next.
    stride: c_int,
    /// total size of the `rgba` buffer.
    size: usize,
};

/// view as YUVA
pub const YUVABuffer = extern struct {
    /// pointer to luma samples
    y: [*c]u8,
    /// pointer to chroma U samples
    u: [*c]u8,
    /// pointer to chroma V samples
    v: [*c]u8,
    /// pointer to alpha samples
    a: [*c]u8,
    /// luma stride
    y_stride: c_int,
    /// chroma U stride
    u_stride: c_int,
    /// chroma V stride
    v_stride: c_int,
    /// alpha stride
    a_stride: c_int,
    /// luma plane size
    y_size: usize,
    /// chroma U plane size
    u_size: usize,
    /// chroma V plane size
    v_size: usize,
    /// alpha-plane size
    a_size: usize,
};

/// Output buffer
pub const DecBuffer = extern struct {
    /// Colorspace.
    colorspace: ColorspaceMode,
    /// X dimension.
    width: c_int,
    /// Y dimension.
    height: c_int,
    /// If non-zero, 'internal_memory' pointer is not used. If value is '2' or
    /// more, the external memory is considered 'slow' and multiple read/write
    /// will be avoided.
    is_external_memory: c_int,
    /// Nameless union of buffer parameters.
    u: extern union {
        RGBA: RGBABuffer,
        YUVA: YUVABuffer,
    },
    /// padding for later use
    pad: [4]u32,
    /// Internally allocated memory (only when is_external_memory is 0). Should
    /// not be used externally, but accessed via the buffer union.
    private_memory: [*c]u8,
};

/// Features gathered from the bitstream
pub const BitstreamFeatures = extern struct {
    /// Width in pixels, as read from the bitstream.
    width: c_int,
    /// Height in pixels, as read from the bitstream.
    height: c_int,
    /// True if the bitstream contains an alpha channel.
    has_alpha: c_int,
    /// True if the bitstream is an animation.
    has_animation: c_int,
    /// 0 = undefined (/mixed), 1 = lossy, 2 = lossless
    format: c_int,
    /// padding for later use
    pad: [5]u32,
};

/// Decoding options.
pub const DecoderOptions = extern struct {
    /// if true, skip the in-loop filtering
    bypass_filtering: c_int,
    /// if true, use faster pointwise upsampler
    no_fancy_upsampling: c_int,
    /// if true, cropping is applied _first_
    use_cropping: c_int,
    /// left position for cropping. Will be snapped to even values.
    crop_left: c_int,
    /// top position for cropping. Will be snapped to even values.
    crop_top: c_int,
    /// X dimension of the cropping area
    crop_width: c_int,
    /// Y dimension of the cropping area
    crop_height: c_int,
    /// if true, scaling is applied _afterward_
    use_scaling: c_int,
    /// final resolution width
    scaled_width: c_int,
    /// final resolution height
    scaled_height: c_int,
    /// if true, use multi-threaded decoding
    use_threads: c_int,
    /// dithering strength (0=Off, 100=full)
    dithering_strength: c_int,
    /// if true, flip output vertically
    flip: c_int,
    /// alpha dithering strength in [0..100]
    alpha_dithering_strength: c_int,
    /// padding for later use
    pad: [5]u32,
};

/// Main object storing the configuration for advanced decoding.
pub const DecoderConfig = extern struct {
    /// Immutable bitstream features (optional)
    input: BitstreamFeatures,
    /// Output buffer (can point to external mem)
    output: DecBuffer,
    /// Decoding options
    options: DecoderOptions,
};
