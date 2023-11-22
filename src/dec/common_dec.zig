// intra prediction modes
pub const B_DC_PRED = 0; // 4x4 modes
pub const B_TM_PRED = 1;
pub const B_VE_PRED = 2;
pub const B_HE_PRED = 3;
pub const B_RD_PRED = 4;
pub const B_VR_PRED = 5;
pub const B_LD_PRED = 6;
pub const B_VL_PRED = 7;
pub const B_HD_PRED = 8;
pub const B_HU_PRED = 9;
pub const NUM_BMODES = B_HU_PRED + 1 - B_DC_PRED; // = 10

// Luma16 or UV modes
pub const DC_PRED = B_DC_PRED;
pub const V_PRED = B_VE_PRED;
pub const H_PRED = B_HE_PRED;
pub const TM_PRED = B_TM_PRED;
pub const B_PRED = NUM_BMODES; // refined I4x4 mode
pub const NUM_PRED_MODES = 4;

// special modes
pub const B_DC_PRED_NOTOP = 4;
pub const B_DC_PRED_NOLEFT = 5;
pub const B_DC_PRED_NOTOPLEFT = 6;
pub const NUM_B_DC_MODES = 7;

pub const MB_FEATURE_TREE_PROBS = 3;
pub const NUM_MB_SEGMENTS = 4;
pub const NUM_REF_LF_DELTAS = 4;
pub const NUM_MODE_LF_DELTAS = 4; // I4x4, ZERO, *, SPLIT
pub const MAX_NUM_PARTITIONS = 8;
// Probabilities
pub const NUM_TYPES = 4; // 0: i16-AC,  1: i16-DC,  2:chroma-AC,  3:i4-AC
pub const NUM_BANDS = 8;
pub const NUM_CTX = 3;
pub const NUM_PROBAS = 11;
