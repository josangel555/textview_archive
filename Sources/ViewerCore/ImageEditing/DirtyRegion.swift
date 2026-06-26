import CoreGraphics

// TSK-1052 — dirty-rect / incremental paint compositing.
//
// Accumulates the canvas region touched by paint ops (dabs, strokes, fills) so
// the renderer can re-composite ONLY the changed bounds instead of rebuilding
// the whole canvas image per dab — the image-editor "clunky"/laggy root when a
// brush drag fires dozens of full-canvas redraws a second.
//
// This is the PURE, host-testable model: pixel-rect union + clamp + the per-op
// dirty-rect math. The renderer's use of `consume()` (redraw only the returned
// sub-rect) is the render-side follow-up (VM/owner). Keeping the math here means
// a wrong dirty rect (which would make the renderer miss a changed pixel) is
// caught host-side, not as an on-screen artifact.
public struct DirtyRegion: Equatable {

    /// Full canvas bounds (origin 0,0). Dirty rects are clamped to this; a
    /// degenerate (0-area) canvas is always clean.
    public let canvas: CGRect

    /// Union of all added dirty rects, clamped to the canvas. `nil` = clean
    /// (nothing to re-composite).
    public private(set) var bounds: CGRect?

    public init(width: Int, height: Int) {
        canvas = CGRect(x: 0, y: 0, width: max(0, width), height: max(0, height))
        bounds = nil
    }

    public var isClean: Bool { bounds == nil }

    /// Union `rect` (canvas pixel coords) into the dirty region, clamped to the
    /// canvas. An out-of-canvas or zero-area rect is a no-op.
    public mutating func add(_ rect: CGRect) {
        guard canvas.width > 0, canvas.height > 0 else { return }
        let clamped = rect.intersection(canvas)
        guard !clamped.isNull, clamped.width > 0, clamped.height > 0 else { return }
        bounds = bounds.map { $0.union(clamped) } ?? clamped
    }

    /// Mark the whole canvas dirty (flood fill, clear, geometry change — ops
    /// whose touched region isn't a cheap local rect).
    public mutating func markAll() {
        bounds = (canvas.width > 0 && canvas.height > 0) ? canvas : nil
    }

    /// Take the current dirty bounds and reset to clean. The renderer calls this
    /// once per frame and re-composites only the returned rect (nil = skip).
    public mutating func consume() -> CGRect? {
        defer { bounds = nil }
        return bounds
    }

    public mutating func clear() { bounds = nil }

    // MARK: - Per-op dirty-rect math (pure)

    /// The rect a circular/square dab of `radius` centred at `(cx, cy)` touches.
    /// Matches RasterCanvas.brushDab's footprint: a (2r+1)² block around the
    /// centre pixel (r=0 ⇒ the single centre pixel).
    public static func dab(cx: Int, cy: Int, radius: Int) -> CGRect {
        let r = max(0, radius)
        return CGRect(x: cx - r, y: cy - r, width: 2 * r + 1, height: 2 * r + 1)
    }

    /// The rect a stroke from `(x0,y0)` to `(x1,y1)` of `radius` touches — the
    /// union of its endpoint dabs (a straight sweep stays within that bbox).
    public static func stroke(x0: Int, y0: Int, x1: Int, y1: Int, radius: Int) -> CGRect {
        dab(cx: x0, cy: y0, radius: radius).union(dab(cx: x1, cy: y1, radius: radius))
    }
}
