import CoreGraphics

/// TSK-1101 — maps a view-space point (within the fitted image's on-screen rect)
/// to a canvas pixel coordinate, for the image-editor paint gesture. Pure
/// geometry, host-tested; the `DragGesture` wiring + the live paint render are
/// the render-gated remainder (validated on the VM pixel lane).
public enum PaintCoordinateMapping {

    /// The canvas pixel under `viewPoint`, or `nil` when the point is outside the
    /// displayed image rect (so a drag off the image doesn't paint a clamped edge
    /// pixel) or the inputs are degenerate.
    ///
    /// - `displayed`: the on-screen rect the fitted image occupies (from the
    ///   editor's `GeometryReader`).
    /// - `imageWidth` / `imageHeight`: the image's pixel dimensions (the paint
    ///   canvas is baked at these dims, so the mapping lands on the right pixel).
    public static func canvasPixel(
        _ viewPoint: CGPoint,
        in displayed: CGRect,
        imageWidth: Int,
        imageHeight: Int
    ) -> (x: Int, y: Int)? {
        guard imageWidth > 0, imageHeight > 0,
              displayed.width > 0, displayed.height > 0,
              displayed.contains(viewPoint) else { return nil }
        let fx = (viewPoint.x - displayed.minX) / displayed.width
        let fy = (viewPoint.y - displayed.minY) / displayed.height
        let px = min(imageWidth - 1, max(0, Int(fx * CGFloat(imageWidth))))
        let py = min(imageHeight - 1, max(0, Int(fy * CGFloat(imageHeight))))
        return (px, py)
    }
}
