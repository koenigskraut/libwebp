pub const FilterType = enum(c_uint) { // Filter types.
    NONE = 0,
    HORIZONTAL,
    VERTICAL,
    GRADIENT,
    LAST, // end marker

    BEST, // meta-types
    FAST,
};
