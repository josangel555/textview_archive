import CoreGraphics

/// TSK-1063 — geometry for the image-editor rectangular marquee. Forward: a drag
/// (two view points) → a canvas-pixel `RasterSelection`. Inverse: a pixel
/// selection → its on-screen rect for the marching-ants overlay. Pure; host-tested.
/// The `DragGesture` + the dashed overlay are the render-gated remainder.
public enum SelectionGeometry {

    /// Canvas-pixel selection for a drag from `a` to `b` within `displayed`. Both
    /// points are clamped into the image; returns nil for an empty selection or
    /// degenerate inputs.
    public static func selectionRect(
        from a: CGPoint, to b: CGPoint,
        in displayed: CGRect, imageWidth: Int, imageHeight: Int
    ) -> RasterSelection? {
        guard imageWidth > 0, imageHeight > 0,
              displayed.width > 0, displayed.height > 0 else { return nil }
        let na = ShapeDragGeometry.normalizedPoint(a, in: displayed)
        let nb = ShapeDragGeometry.normalizedPoint(b, in: displayed)
        let ax = Int(na.x * CGFloat(imageWidth)), ay = Int(na.y * CGFloat(imageHeight))
        let bx = Int(nb.x * CGFloat(imageWidth)), by = Int(nb.y * CGFloat(imageHeight))
        let x = max(0, min(ax, bx)), y = max(0, min(ay, by))
        let w = min(abs(bx - ax), imageWidth - x), h = min(abs(by - ay), imageHeight - y)
        guard w >= 1, h >= 1 else { return nil }
        return .rect(x: x, y: y, width: w, height: h)
    }

    /// On-screen rect for a pixel selection — used to draw the marching-ants
    /// overlay over the fitted image. Nil for a non-rect selection.
    public static func viewRect(
        _ selection: RasterSelection, in displayed: CGRect,
        imageWidth: Int, imageHeight: Int
    ) -> CGRect? {
        guard case let .rect(x, y, w, h) = selection,
              imageWidth > 0, imageHeight > 0 else { return nil }
        let sx = displayed.width / CGFloat(imageWidth)
        let sy = displayed.height / CGFloat(imageHeight)
        return CGRect(x: displayed.minX + CGFloat(x) * sx,
                      y: displayed.minY + CGFloat(y) * sy,
                      width: CGFloat(w) * sx, height: CGFloat(h) * sy)
    }
}
