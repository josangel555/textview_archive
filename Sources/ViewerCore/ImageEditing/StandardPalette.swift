/// TSK-1070 — the default color palette for the image editor's swatch strip: a
/// compact MS-Paint-style set (grays + a saturated/dark spectrum). Pure data,
/// host-testable; the swatch UI is the render-gated remainder.
public enum StandardPalette {
    public static let colors: [RGBAColor] = [
        .black,
        RGBAColor(r: 64, g: 64, b: 64),
        RGBAColor(r: 128, g: 128, b: 128),
        RGBAColor(r: 192, g: 192, b: 192),
        .white,
        RGBAColor(r: 128, g: 0, b: 0),     // maroon
        .red,
        RGBAColor(r: 255, g: 128, b: 0),   // orange
        RGBAColor(r: 255, g: 255, b: 0),   // yellow
        RGBAColor(r: 128, g: 128, b: 0),   // olive
        RGBAColor(r: 0, g: 128, b: 0),     // green
        .green,                            // lime
        RGBAColor(r: 0, g: 128, b: 128),   // teal
        RGBAColor(r: 0, g: 255, b: 255),   // cyan
        .blue,
        RGBAColor(r: 0, g: 0, b: 128),     // navy
        RGBAColor(r: 128, g: 0, b: 128),   // purple
        RGBAColor(r: 255, g: 0, b: 255),   // magenta
        RGBAColor(r: 128, g: 64, b: 0),    // brown
        RGBAColor(r: 255, g: 128, b: 192), // pink
    ]
}
