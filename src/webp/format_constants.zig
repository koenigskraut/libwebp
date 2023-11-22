/// Create fourcc of the chunk from the chunk tag characters.
// pub inline fn MKFOURCC(a, b, c, d) ((a) | (b) << 8 | (c) << 16 | (uint32_t)(d) << 24)

// VP8 related constants.
/// Signature in VP8 data.
pub const VP8_SIGNATURE = 0x9d012a;
/// max size of mode partition
pub const VP8_MAX_PARTITION0_SIZE = (1 << 19);
/// max size for token partition
pub const VP8_MAX_PARTITION_SIZE = (1 << 24);
/// Size of the frame header within VP8 data.
pub const VP8_FRAME_HEADER_SIZE = 10;

// VP8L related constants.
/// VP8L signature size.
pub const VP8L_SIGNATURE_SIZE = 1;
/// VP8L signature byte.
pub const VP8L_MAGIC_BYTE = 0x2f;
/// Number of bits used to store width and height.
pub const VP8L_IMAGE_SIZE_BITS = 14;
/// 3 bits reserved for version.
pub const VP8L_VERSION_BITS = 3;
/// version 0
pub const VP8L_VERSION = 0;
/// Size of the VP8L frame header.
pub const VP8L_FRAME_HEADER_SIZE = 5;

pub const MAX_PALETTE_SIZE = 256;
pub const MAX_CACHE_BITS = 11;
pub const HUFFMAN_CODES_PER_META_CODE = 5;
pub const ARGB_BLACK = 0xff000000;

pub const DEFAULT_CODE_LENGTH = 8;
pub const MAX_ALLOWED_CODE_LENGTH = 15;

pub const NUM_LITERAL_CODES = 256;
pub const NUM_LENGTH_CODES = 24;
pub const NUM_DISTANCE_CODES = 40;
pub const CODE_LENGTH_CODES = 19;

/// min number of Huffman bits
pub const MIN_HUFFMAN_BITS = 2;
/// max number of Huffman bits
pub const MAX_HUFFMAN_BITS = 9;

/// The bit to be written when next data to be read is a transform.
pub const TRANSFORM_PRESENT = 1;
/// Maximum number of allowed transform in a bitstream.
pub const NUM_TRANSFORMS = 4;

pub const VP8LImageTransformType = enum(c_uint) {
    PREDICTOR_TRANSFORM = 0,
    CROSS_COLOR_TRANSFORM = 1,
    SUBTRACT_GREEN_TRANSFORM = 2,
    COLOR_INDEXING_TRANSFORM = 3,
};

// Alpha related constants.
pub const ALPHA_HEADER_LEN = 1;
pub const ALPHA_NO_COMPRESSION = 0;
pub const ALPHA_LOSSLESS_COMPRESSION = 1;
pub const ALPHA_PREPROCESSED_LEVELS = 1;

// Mux related constants.
/// Size of a chunk tag (e.g. "VP8L").
pub const TAG_SIZE = 4;
/// Size needed to store chunk's size.
pub const CHUNK_SIZE_BYTES = 4;
/// Size of a chunk header.
pub const CHUNK_HEADER_SIZE = 8;
/// Size of the RIFF header ("RIFFnnnnWEBP").
pub const RIFF_HEADER_SIZE = 12;
/// Size of an ANMF chunk.
pub const ANMF_CHUNK_SIZE = 16;
/// Size of an ANIM chunk.
pub const ANIM_CHUNK_SIZE = 6;
/// Size of a VP8X chunk.
pub const VP8X_CHUNK_SIZE = 10;

/// 24-bit max for VP8X width/height.
pub const MAX_CANVAS_SIZE = (1 << 24);
/// 32-bit max for width x height.
pub const MAX_IMAGE_AREA = (@as(u64, 1) << 32);
/// maximum value for loop-count
pub const MAX_LOOP_COUNT = (1 << 16);
/// maximum duration
pub const MAX_DURATION = (1 << 24);
/// maximum frame x/y offset
pub const MAX_POSITION_OFFSET = (1 << 24);

/// Maximum chunk payload is such that adding the header and padding won't
/// overflow a uint32_t.
pub const MAX_CHUNK_PAYLOAD = (~@as(u32, 0) - CHUNK_HEADER_SIZE - 1);
