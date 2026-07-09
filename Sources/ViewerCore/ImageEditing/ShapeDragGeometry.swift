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

    /// Like `normalizedRect` but PRESERVES drag direction (NOT standardized) — for
    /// open shapes (line / arrow) whose endpoint order is meaningful. Origin = `a`,
    /// size = `b - a` (width/height may be negative). Endpoints clamped to `0...1`.
    /// Returns `.null` when `displayed` is degenerate.
    public static func normalizedSignedRect(
        from a: CGPoint, to b: CGPoint, in displayed: CGRect
    ) -> CGRect {
        guard displayed.width > 0, displayed.height > 0 else { return .null }
        let na = normalizedPoint(a, in: displayed)
        let nb = normalizedPoint(b, in: displayed)
        return CGRect(x: na.x, y: na.y, width: nb.x - na.x, height: nb.y - na.y)
    }

    /// A view point as a fraction (`0...1`, clamped) of `displayed`.
    public static func normalizedPoint(_ p: CGPoint, in displayed: CGRect) -> CGPoint {
        let fx = (p.x - displayed.minX) / displayed.width
        let fy = (p.y - displayed.minY) / displayed.height
        return CGPoint(x: min(1, max(0, fx)), y: min(1, max(0, fy)))
    }

    // MARK: - Selection handles + resize (TSK-1168)

    /// The eight resize handles around a shape's bounding box. Corner handles
    /// move BOTH adjacent edges; edge handles move one. Position on the frame is
    /// given by the `moves*` flags.
    public enum Handle: String, CaseIterable, Sendable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        public var movesLeft: Bool   { self == .topLeft || self == .left  || self == .bottomLeft }
        public var movesRight: Bool  { self == .topRight || self == .right || self == .bottomRight }
        public var movesTop: Bool    { self == .topLeft || self == .top   || self == .topRight }
        public var movesBottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }
    }

    /// Normalized (`0...1`) positions of the eight handles for `frame`. The view
    /// draws a grab square at each; `handleHitTest` maps a drag-start back to one.
    public static func handlePoints(for frame: CGRect) -> [(handle: Handle, point: CGPoint)] {
        let f = frame.standardized
        return [
            (.topLeft,     CGPoint(x: f.minX, y: f.minY)),
            (.top,         CGPoint(x: f.midX, y: f.minY)),
            (.topRight,    CGPoint(x: f.maxX, y: f.minY)),
            (.right,       CGPoint(x: f.maxX, y: f.midY)),
            (.bottomRight, CGPoint(x: f.maxX, y: f.maxY)),
            (.bottom,      CGPoint(x: f.midX, y: f.maxY)),
            (.bottomLeft,  CGPoint(x: f.minX, y: f.maxY)),
            (.left,        CGPoint(x: f.minX, y: f.midY)),
        ]
    }

    /// The handle whose grab point is within `tolerance` (normalized) of `point`,
    /// or `nil`. Nearest wins when two overlap. Lets the gesture decide
    /// resize-a-handle vs move-the-body at drag-start.
    public static func handleHitTest(
        _ point: CGPoint, in frame: CGRect, tolerance: CGFloat
    ) -> Handle? {
        var best: (Handle, CGFloat)?
        for (h, p) in handlePoints(for: frame) {
            let d = hypot(point.x - p.x, point.y - p.y)
            if d <= tolerance, best == nil || d < best!.1 { best = (h, d) }
        }
        return best?.0
    }

    /// New normalized frame after dragging `handle` by `(dx, dy)`. Moves only the
    /// edges the handle owns, standardizes (so dragging an edge past its opposite
    /// flips cleanly), clamps corners to `0...1`, and enforces `minSize` so a
    /// shape can't collapse to nothing. Pure — the drag gesture calls this each
    /// change and commits the result via `resizeSelectedShape(to:)`.
    public static func resizedFrame(
        _ frame: CGRect, handle: Handle, byX dx: CGFloat, y dy: CGFloat,
        minSize: CGFloat = 0.02
    ) -> CGRect {
        let f = frame.standardized
        var left = f.minX, right = f.maxX, top = f.minY, bottom = f.maxY
        if handle.movesLeft   { left   = clampUnit(left + dx) }
        if handle.movesRight  { right  = clampUnit(right + dx) }
        if handle.movesTop    { top    = clampUnit(top + dy) }
        if handle.movesBottom { bottom = clampUnit(bottom + dy) }
        var rect = CGRect(x: left, y: top, width: right - left, height: bottom - top).standardized
        if rect.width  < minSize { rect.size.width  = minSize }
        if rect.height < minSize { rect.size.height = minSize }
        return rect
    }

    static func clampUnit(_ v: CGFloat) -> CGFloat {
        guard v.isFinite else { return 0 }
        return min(1, max(0, v))
    }
}
