import Foundation
import CoreGraphics

/// Creates a blank raster image (TSK-1054) — a `width`×`height` canvas filled
/// with a background color, encoded as PNG. Pure `ViewerCore` (host-testable):
/// the File ▸ New Image flow writes this to a file and opens it in the editor.
public enum BlankImageCreator {

    /// Default new-image dimensions (4:3), used when the host doesn't prompt for
    /// a size/color (a follow-on dialog supplies custom values).
    public static let defaultWidth = 800
    public static let defaultHeight = 600

    /// White, the conventional default canvas background.
    public static let defaultColor = RGBAColor(r: 255, g: 255, b: 255)

    /// Sanity ceiling on the canvas: a typo in the size dialog shouldn't try to
    /// allocate gigabytes. 64 MP (~256 MB RGBA) is far beyond any real new image.
    public static let maxPixels = 64_000_000

    /// Encode a blank `width`×`height` canvas filled with `color` as PNG bytes.
    /// Returns nil for non-positive or oversize dimensions, or if encoding fails.
    public static func pngData(
        width: Int = defaultWidth,
        height: Int = defaultHeight,
        color: RGBAColor = defaultColor
    ) -> Data? {
        guard width > 0, height > 0, width <= 30_000, height <= 30_000,
              width * height <= maxPixels else { return nil }
        let canvas = RasterCanvas(width: width, height: height, fill: color)
        guard let cg = canvas.cgImage() else { return nil }
        return try? Exporter.encode(cg, ExportSpec(format: .png))
    }
}
