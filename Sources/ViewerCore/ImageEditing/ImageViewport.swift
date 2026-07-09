import CoreGraphics

/// TSK-1088 / TSK-1441 — the pure zoom + pan viewport transform for the image
/// editor, plus the derived grid / ruler / pixel-coordinate geometry. The
/// editor fits the image into a container with an aspect-fit rect; this maps
/// that fitted rect through a zoom (scale about the fitted centre) + a clamped
/// pan (so the image can't be dragged entirely off), and answers the questions
/// the view + status bar ask: where does the content actually sit, which image
/// pixel is under the cursor, and where do grid lines / ruler ticks fall.
///
/// Pure + host-tested; the `MagnificationGesture` / `DragGesture` + the grid /
/// ruler drawing are the render tail (VM/owner glance).
public struct ImageViewport: Equatable, Sendable {
    /// 1.0 = fit-to-window (the aspect-fit rect); > 1 zoomed in. Clamped to
    /// `minZoom...maxZoom` on every mutation.
    public private(set) var zoom: CGFloat
    /// Pan offset in VIEW POINTS from the fitted-centre. Stored raw; clamped to
    /// the over-scroll bounds by `transformedRect` / `panned`.
    public private(set) var panX: CGFloat
    public private(set) var panY: CGFloat

    public let minZoom: CGFloat
    public let maxZoom: CGFloat

    public init(
        zoom: CGFloat = 1, panX: CGFloat = 0, panY: CGFloat = 0,
        minZoom: CGFloat = 1, maxZoom: CGFloat = 16
    ) {
        self.minZoom = minZoom
        self.maxZoom = maxZoom
        self.zoom = Self.clamp(zoom, minZoom, maxZoom)
        self.panX = panX
        self.panY = panY
    }

    /// True when at fit (no zoom, no pan) — the view hides the reset control then.
    public var isFit: Bool { zoom == minZoom && panX == 0 && panY == 0 }

    // MARK: - Mutations

    /// Set an absolute zoom (clamped). Pan is left as-is; `transformedRect`
    /// re-clamps it to the new over-scroll bounds.
    public func withZoom(_ z: CGFloat) -> ImageViewport {
        ImageViewport(zoom: z, panX: panX, panY: panY, minZoom: minZoom, maxZoom: maxZoom)
    }

    /// Multiply the zoom by `factor` (e.g. 1.25 for a zoom-in step).
    public func zoomed(by factor: CGFloat) -> ImageViewport {
        withZoom(zoom * factor)
    }

    /// Reset to fit (zoom 1, pan 0).
    public func fit() -> ImageViewport {
        ImageViewport(minZoom: minZoom, maxZoom: maxZoom)
    }

    /// Accumulate a pan delta (view points), clamped to the over-scroll bounds
    /// for the given fitted rect so you can never drag the image off-screen.
    public func panned(byX dx: CGFloat, y dy: CGFloat, in fitted: CGRect) -> ImageViewport {
        let (mx, my) = overscroll(fitted: fitted)
        return ImageViewport(
            zoom: zoom,
            panX: Self.clamp(panX + dx, -mx, mx),
            panY: Self.clamp(panY + dy, -my, my),
            minZoom: minZoom, maxZoom: maxZoom)
    }

    // MARK: - Geometry

    /// How far the zoomed image extends beyond the fitted rect on each side —
    /// the max pan magnitude in each axis (0 when not zoomed in).
    public func overscroll(fitted: CGRect) -> (x: CGFloat, y: CGFloat) {
        (max(0, (fitted.width * zoom - fitted.width) / 2),
         max(0, (fitted.height * zoom - fitted.height) / 2))
    }

    /// The on-screen rect the zoomed + (clamped-)panned image occupies, given
    /// the aspect-fit rect the caller computed for the container.
    public func transformedRect(fitted: CGRect) -> CGRect {
        let w = fitted.width * zoom, h = fitted.height * zoom
        let (mx, my) = overscroll(fitted: fitted)
        let px = Self.clamp(panX, -mx, mx), py = Self.clamp(panY, -my, my)
        return CGRect(x: fitted.midX + px - w / 2, y: fitted.midY + py - h / 2, width: w, height: h)
    }

    /// The image pixel `(x, y)` under a view point, or `nil` if the point falls
    /// outside the displayed image. `x`/`y` are clamped to `[0, imageSize)`.
    public func imagePixel(
        at viewPoint: CGPoint, fitted: CGRect, imageSize: CGSize
    ) -> (x: Int, y: Int)? {
        let r = transformedRect(fitted: fitted)
        guard r.width > 0, r.height > 0, r.contains(viewPoint),
              imageSize.width > 0, imageSize.height > 0 else { return nil }
        let fx = (viewPoint.x - r.minX) / r.width
        let fy = (viewPoint.y - r.minY) / r.height
        let x = min(Int(imageSize.width) - 1, max(0, Int(fx * imageSize.width)))
        let y = min(Int(imageSize.height) - 1, max(0, Int(fy * imageSize.height)))
        return (x, y)
    }

    /// View-space X positions of vertical grid lines (and Y of horizontal),
    /// one every `spacingPx` image pixels, that fall inside `fitted`.
    public func gridLines(
        fitted: CGRect, imageSize: CGSize, spacingPx: Int
    ) -> (vertical: [CGFloat], horizontal: [CGFloat]) {
        guard spacingPx > 0, imageSize.width > 0, imageSize.height > 0 else { return ([], []) }
        let r = transformedRect(fitted: fitted)
        var vs: [CGFloat] = [], hs: [CGFloat] = []
        var ix = 0
        while ix <= Int(imageSize.width) {
            let vx = r.minX + CGFloat(ix) / imageSize.width * r.width
            if vx >= fitted.minX - 0.5, vx <= fitted.maxX + 0.5 { vs.append(vx) }
            ix += spacingPx
        }
        var iy = 0
        while iy <= Int(imageSize.height) {
            let vy = r.minY + CGFloat(iy) / imageSize.height * r.height
            if vy >= fitted.minY - 0.5, vy <= fitted.maxY + 0.5 { hs.append(vy) }
            iy += spacingPx
        }
        return (vs, hs)
    }

    /// Ruler ticks: image-pixel value → view coordinate, every `stepPx` pixels,
    /// for the ticks visible within `fitted`.
    public func rulerTicks(
        fitted: CGRect, imageSize: CGSize, stepPx: Int
    ) -> (x: [(px: Int, view: CGFloat)], y: [(px: Int, view: CGFloat)]) {
        guard stepPx > 0, imageSize.width > 0, imageSize.height > 0 else { return ([], []) }
        let r = transformedRect(fitted: fitted)
        var xs: [(Int, CGFloat)] = [], ys: [(Int, CGFloat)] = []
        var ix = 0
        while ix <= Int(imageSize.width) {
            let vx = r.minX + CGFloat(ix) / imageSize.width * r.width
            if vx >= fitted.minX - 0.5, vx <= fitted.maxX + 0.5 { xs.append((ix, vx)) }
            ix += stepPx
        }
        var iy = 0
        while iy <= Int(imageSize.height) {
            let vy = r.minY + CGFloat(iy) / imageSize.height * r.height
            if vy >= fitted.minY - 0.5, vy <= fitted.maxY + 0.5 { ys.append((iy, vy)) }
            iy += stepPx
        }
        return (xs, ys)
    }

    private static func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        guard v.isFinite else { return lo }
        return min(hi, max(lo, v))
    }
}
