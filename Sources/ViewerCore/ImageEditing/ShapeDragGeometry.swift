import CoreGraphics

/// TSK-1059 — geometry for the image-editor drag-to-draw shape tools. Maps two
/// view-space drag points (within the fitted image's on-screen rect) to a
/// NORMALIZED (`0...1`, top-left origin) bounding box — the coordinate space
/// `VectorShape.frame` uses. Pure; host-tested. The `DragGesture` + live preview
/// are the render-gated remainder.
public enum ShapeDragGeometry {

    /// Normalized, standardized bounding box for a drag from `a` to `b` within
    /// `displayed`. Each endpoint is clamped into the image rect, so a drag that
    /// runs off the edge still yields an in-bounds shape. Returns `.null` when
    /// `displayed` is degenerate.
    public static func normalizedRect(
        from a: CGPoint, to b: CGPoint, in displayed: CGRect
    ) -> CGRect {
        guard displayed.width > 0, displayed.height > 0 else { return .null }
        let na = normalizedPoint(a, in: displayed)
        let nb = normalizedPoint(b, in: displayed)
        return CGRect(x: na.x, y: na.y, width: nb.x - na.x, height: nb.y - na.y).standardized
    }

    /// A view point as a fraction (`0...1`, clamped) of `displayed`.
    static func normalizedPoint(_ p: CGPoint, in displayed: CGRect) -> CGPoint {
        let fx = (p.x - displayed.minX) / displayed.width
        let fy = (p.y - displayed.minY) / displayed.height
        return CGPoint(x: min(1, max(0, fx)), y: min(1, max(0, fy)))
    }
}
