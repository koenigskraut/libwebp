/// Returns true if crop dimensions are within image bounds.
pub fn WebPCheckCropDimensions(image_width: c_int, image_height: c_int, x: c_int, y: c_int, w: c_int, h: c_int) bool {
    return !(x < 0 or y < 0 or w <= 0 or h <= 0 or
        x >= image_width or w > image_width or w > image_width - x or
        y >= image_height or h > image_height or h > image_height - y);
}
