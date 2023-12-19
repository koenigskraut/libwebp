const std = @import("std");

const webp = struct {
    usingnamespace @import("../utils/utils.zig");
};

const c_bool = webp.c_bool;

const ENCODER_ABI_VERSION = 0x020f;

/// Image characteristics hint for the underlying encoder.
pub const ImageHint = enum(c_uint) {
    /// default preset.
    default = 0,
    /// digital picture, like portrait, inner shot
    picture,
    /// outdoor photograph, with natural lighting
    photo,
    /// Discrete tone image (graph, map-tile etc).
    graph,
    last,
};

/// Color spaces.
pub const EncCSP = enum(c_uint) {
    /// 4:2:0
    pub const YUV420: c_uint = 0;
    /// alpha channel variant
    pub const YUV420A: c_uint = 4;
    /// bit-mask to get the UV sampling factors
    pub const CSP_UV_MASK: c_uint = 3;
    /// bit that is set if alpha is present
    pub const CSP_ALPHA_BIT: c_uint = 4;
};

/// Enumerate some predefined settings for `Config`, depending on the type of
/// source picture. These presets are used when calling `WebPConfigPreset()`.
pub const Preset = enum(c_uint) {
    /// default preset
    default = 0,
    /// digital picture, like portrait, inner shot
    picture,
    /// outdoor photograph, with natural lighting
    photo,
    /// hand or line drawing, with high-contrast details
    drawing,
    /// small-sized colorful images
    icon,
    /// text-like
    text,
};

/// Encoding error conditions.
pub const EncodingError = enum(c_uint) {
    Ok = 0,
    /// memory error allocating objects
    OutOfMemory,
    /// memory error while flushing bits
    BitstreamOutOfMemory,
    /// a pointer parameter is NULL
    NullParameter,
    /// configuration is invalid
    InvalidConfiguration,
    /// picture has invalid width/height
    BadDimension,
    /// partition is bigger than 512k
    Partition0Overflow,
    /// partition is bigger than 16M
    PartitionOverflow,
    /// error while flushing bytes
    BadWrite,
    /// file is bigger than 4G
    FileTooBig,
    /// abort request by user
    UserAbort,
    /// list terminator. always last.
    Last,

    pub const Error = error{
        /// memory error allocating objects
        OutOfMemory,
        /// memory error while flushing bits
        BitstreamOutOfMemory,
        /// a pointer parameter is NULL
        NullParameter,
        /// configuration is invalid
        InvalidConfiguration,
        /// picture has invalid width/height
        BadDimension,
        /// partition is bigger than 512k
        Partition0Overflow,
        /// partition is bigger than 16M
        PartitionOverflow,
        /// error while flushing bytes
        BadWrite,
        /// file is bigger than 4G
        FileTooBig,
        /// abort request by user
        UserAbort,
        /// list terminator. always last.
        Last,
    };

    pub fn toErr(self: EncodingError) Error!void {
        return switch (self) {
            .Ok => void,
            .OutOfMemory => Error.OutOfMemory,
            .BitstreamOutOfMemory => Error.BitstreamOutOfMemory,
            .NullParameter => Error.NullParameter,
            .InvalidConfiguration => Error.InvalidConfiguration,
            .BadDimension => Error.BadDimension,
            .Partition0Overflow => Error.Partition0Overflow,
            .PartitionOverflow => Error.PartitionOverflow,
            .BadWrite => Error.BadWrite,
            .FileTooBig => Error.FileTooBig,
            .UserAbort => Error.UserAbort,
            .Last => Error.Last,
        };
    }
};

/// Compression parameters.
pub const Config = extern struct {
    /// Lossless encoding (0=lossy(default), 1=lossless).
    lossless: c_int,
    /// between 0 and 100. For lossy, 0 gives the smallest size and 100 the
    /// largest. For lossless, this parameter is the amount of effort put into
    /// the compression: 0 is the fastest but gives larger files compared to
    /// the slowest, but best, 100.
    quality: f32,
    /// quality/speed trade-off (0=fast, 6=slower-better)
    method: c_int,
    /// Hint for image type (lossless only for now).
    image_hint: ImageHint,
    /// if non-zero, set the desired target size in bytes.
    ///
    /// Takes precedence over the 'compression' parameter.
    target_size: c_int,
    /// if non-zero, specifies the minimal distortion to try to achieve.
    ///
    /// Takes precedence over `target_size`.
    target_PSNR: f32,
    /// maximum number of segments to use, in [1..4]
    segments: c_int,
    /// Spatial Noise Shaping.
    ///
    /// 0=off, 100=maximum.
    sns_strength: c_int,
    /// range: [0 = off .. 100 = strongest]
    filter_strength: c_int,
    /// range: [0 = off .. 7 = least sharp]
    filter_sharpness: c_int,
    /// filtering type: 0 = simple, 1 = strong (only used if
    /// `filter_strength` > 0 or `autofilter` > 0)
    filter_type: c_int,
    /// Auto adjust filter's strength [0 = off, 1 = on]
    autofilter: c_int,
    /// Algorithm for encoding the alpha plane (0 = none, 1 = compressed with
    /// WebP lossless).
    ///
    /// Default is 1.
    alpha_compression: c_int,
    /// Predictive filtering method for alpha plane.
    ///
    /// 0: none, 1: fast, 2: best. Default if 1.
    alpha_filtering: c_int,
    /// Between 0 (smallest size) and 100 (lossless).
    ///
    /// Default is 100.
    alpha_quality: c_int,
    /// number of entropy-analysis passes (in [1..10]).
    pass: c_int,
    /// if not 0, export the compressed picture back. In-loop filtering is not
    /// applied.
    show_compressed: c_int,
    /// preprocessing filter:
    ///
    /// 0=none, 1=segment-smooth, 2=pseudo-random dithering
    preprocessing: c_int,
    /// log2(number of token partitions) in [0..3].
    ///
    /// Default is set to 0 for easier progressive decoding.
    partitions: c_int,
    /// quality degradation allowed to fit the 512k limit on prediction modes
    /// coding (0: no degradation, 100: maximum possible degradation).
    partition_limit: c_int,
    /// If not 0, compression parameters will be remapped to better match the
    /// expected output size from JPEG compression. Generally, the output size
    /// will be similar but the degradation will be lower.
    emulate_jpeg_size: c_int,
    /// If non-zero, try and use multi-threaded encoding.
    thread_level: c_int,
    /// If set, reduce memory usage (but increase CPU use).
    low_memory: c_int,
    /// Near lossless encoding [0 = max loss .. 100 = off (default)].
    near_lossless: c_int,
    /// if non-zero, preserve the exact RGB values under transparent area.
    /// Otherwise, discard this invisible RGB information for better
    /// compression.
    ///
    /// The default value is 0.
    exact: c_int,
    /// reserved for future lossless feature
    use_delta_palette: c_int,
    /// if needed, use sharp (and slow) RGB->YUV conversion
    use_sharp_yuv: c_int,
    /// minimum permissible quality factor
    qmin: c_int,
    /// maximum permissible quality factor
    qmax: c_int,
};

/// maximum width/height allowed (inclusive), in pixels
pub const MAX_DIMENSION = 16383;

/// Main exchange structure (input samples, output bytes, statistics)
///
/// Once WebPPictureInit() has been called, it's ok to make all the INPUT
/// fields (use_argb, y/u/v, argb, ...) point to user-owned data, even if
/// WebPPictureAlloc() has been called. Depending on the value use_argb,
/// it's guaranteed that either *argb or *y/*u/*v content will be kept
/// untouched.
pub const Picture = extern struct {
    //   INPUT
    //////////////

    /// Main flag for encoder selecting between ARGB or YUV input. It is
    /// recommended to use ARGB input (`*argb`, `argb_stride`) for lossless
    /// compression, and YUV input (`*y`, `*u`, `*v`, etc.) for lossy
    /// compression since these are the respective native colorspace for these
    /// formats.
    use_argb: c_bool,

    // YUV input (mostly used for input to lossy compression)

    /// colorspace: should be `EncCSP.YUV420` for now (=Y'CbCr)
    colorspace: EncCSP,
    /// X dimension (less or equal to `MAX_DIMENSION`)
    width: c_int,
    /// Y dimension (less or equal to `MAX_DIMENSION`)
    height: c_int,
    /// pointer to luma plane
    y: [*c]u8,
    /// pointer to U chroma plane
    u: [*c]u8,
    /// pointer to V chroma plane
    v: [*c]u8,
    /// luma stride.
    y_stride: c_int,
    /// chroma stride
    uv_stride: c_int,
    /// pointer to the alpha plane
    a: [*c]u8,
    /// stride of the alpha plane
    a_stride: c_int,
    /// padding for later use
    pad1: [2]u32,

    // ARGB input (mostly used for input to lossless compression)

    /// pointer to argb (32 bit) plane
    argb: [*c]u32,
    /// this is stride in pixels units, not bytes
    argb_stride: c_int,
    /// padding for later use
    pad2: [3]u32,

    //   OUTPUT
    ///////////////

    // Byte-emission hook, to store compressed bytes as they are ready.
    //
    // Can be `null`.
    // writer: WriterFunction,
    /// can be used by the writer
    custom_ptr: ?*anyopaque,
    /// map for extra information (only for lossy compression mode)
    /// - `1`: intra type
    /// - `2`: segment
    /// - `3`: quant
    /// - `4`: intra-16 prediction mode,
    /// - `5`: chroma prediction mode,
    /// - `6`: bit cost, 7: distortion
    extra_info_type: c_int,
    extra_info: [*c]u8,

    //   STATS AND REPORTS
    ///////////////////////////

    /// Pointer to side statistics (updated only if not `null`)
    stats: [*c]AuxStats,
    /// Error code for the latest error encountered during encoding
    error_code: EncodingError,
    // If not `null`, report progress during encoding.
    // progress_hook: ProgressHook,
    /// this field is free to be set to any value and used during callbacks
    /// (like progress-report e.g.)
    user_data: ?*anyopaque,
    /// padding for later use
    pad3: [3]u32,
    /// Unused for now
    pad4: [*c]u8,
    /// Unused for now
    pad5: [*c]u8,
    /// padding for later use
    pad6: [8]u32,

    // PRIVATE FIELDS
    ////////////////////

    /// row chunk of memory for yuva planes
    memory_: ?*anyopaque,
    /// and for argb too
    memory_argb_: ?*anyopaque,
    /// padding for later use
    pad7: [2]?*anyopaque,
};

pub const DistortionMetric = enum(c_int) {
    PSNR,
    SSIM,
    LSIM,
};

/// Structure for storing auxiliary statistics.
pub const AuxStats = extern struct {
    /// final size
    coded_size: c_int,
    /// peak-signal-to-noise ratio for Y/U/V/All/Alpha
    PSNR: [5]f32,
    /// number of intra4/intra16/skipped macroblocks
    block_count: [3]c_int,
    // approximate number of bytes spent for header and mode-partition #0
    header_bytes: [2]c_int,
    /// approximate number of bytes spent for DC/AC/uv coefficients for each
    /// (0..3) segments
    residual_bytes: [3][4]c_int,
    /// number of macroblocks in each segments
    segment_size: [4]c_int,
    /// quantizer values for each segments
    segment_quant: [4]c_int,
    /// filtering strength for each segments [0..63]
    segment_level: [4]c_int,
    /// size of the transparency data
    alpha_data_size: c_int,
    /// size of the enhancement layer data
    layer_data_size: c_int,

    // lossless encoder statistics

    /// - bit 0: predictor
    /// - bit 1: cross-color transform
    /// - bit 2: subtract-green
    /// - bit 3: color indexing
    lossless_features: u32,
    /// number of precision bits of histogram
    histogram_bits: c_int,
    /// precision bits for transform
    transform_bits: c_int,
    /// number of bits for color cache lookup
    cache_bits: c_int,
    /// number of color in palette, if used
    palette_size: c_int,
    /// final lossless size
    lossless_size: c_int,
    /// lossless header (transform, huffman etc) size
    lossless_hdr_size: c_int,
    /// lossless image data size
    lossless_data_size: c_int,
    /// padding for later use
    pad: [2]u32,
};

/// Signature for output function. Should return `1` if writing was
/// successful.
///
/// `data`/`data_size` is the segment of data to write, and `picture` is for
/// reference (and so one can make use of `picture.custom_ptr`).
pub const WriterFunction = ?*const fn (data: [*c]const u8, data_size: usize, picture: [*c]const Picture) callconv(.C) c_int;

// The custom writer to be used with `MemoryWriter` as `custom_ptr`. Upon
// completion, `writer.mem` and `writer.size` will hold the coded data.
// `writer.mem` must be freed by calling `.clear()` on it.
pub const MemoryWriter = extern struct {
    /// final buffer (of size `max_size`, larger than `size`).
    mem: [*c]u8,
    /// final size
    size: usize,
    /// total capacity
    max_size: usize,
    /// padding for later use
    pad: [1]u32,
};

/// `memoryWrite`: a special `WriterFunction` that writes to memory using
/// `MemoryWriter` object (to be set as a `picture.custom_ptr`).
// pub const memoryWrite = c.WebPMemoryWrite;

/// Progress hook, called from time to time to report progress. It can return
/// `0` to request an abort of the encoding process, or `1` otherwise if
/// everything is OK.
pub const ProgressHook = ?*const fn (c_int, [*c]const Picture) callconv(.C) c_int;
