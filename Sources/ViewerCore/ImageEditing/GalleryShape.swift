import Foundation
import CoreGraphics

/// TSK-1085 — the Win7 shape-gallery VERTEX GEOMETRY. Each gallery shape is
/// a parametric polygon over its bounding rect; `vertices(in:)` returns the
/// closed point ring the existing `EditOp.fillPolygon` / `strokePolygon`
/// rasterizer draws (so no new rasterization needed — this is the pure math
/// half). The tool picker + drag gesture that build the op are the render
/// tail. Pure + host-tested.
///
/// This covers the CLEAN parametric shapes (polygons + stars + block
/// arrows). The freeform Win7 gallery members (heart / lightning / speech
/// callouts) are curve/spline-based and are a separate follow-on.
public enum GalleryShape: String, CaseIterable, Sendable, Codable, Equatable {
    case triangle
    case rightTriangle
    case diamond
    case pentagon
    case hexagon
    case star4
    case star5
    case star6
    case arrowRight
    case arrowLeft
    case arrowUp
    case arrowDown
    // TSK-1574 — freeform Win7 members, curve-based, approximated as dense
    // polygon rings so the existing fillPolygon/strokePolygon rasterizer draws
    // them with no new render path.
    case heart
    case lightning
    case speechCallout

    /// The closed vertex ring (first point != implicitly repeated; the
    /// rasterizer closes the path). Points are in the same space as `rect`.
    public func vertices(in rect: CGRect) -> [CGPoint] {
        let minX = rect.minX, minY = rect.minY
        let w = rect.width, h = rect.height
        let midX = minX + w / 2, midY = minY + h / 2
        func p(_ fx: Double, _ fy: Double) -> CGPoint {
            CGPoint(x: minX + fx * w, y: minY + fy * h)
        }
        switch self {
        case .triangle:
            return [p(0.5, 0), p(1, 1), p(0, 1)]
        case .rightTriangle:
            return [p(0, 0), p(0, 1), p(1, 1)]
        case .diamond:
            return [p(0.5, 0), p(1, 0.5), p(0.5, 1), p(0, 0.5)]
        case .pentagon:
            return regularPolygon(sides: 5, cx: midX, cy: midY, rx: w / 2, ry: h / 2, startAngle: -.pi / 2)
        case .hexagon:
            return regularPolygon(sides: 6, cx: midX, cy: midY, rx: w / 2, ry: h / 2, startAngle: 0)
        case .star4:
            return star(points: 4, cx: midX, cy: midY, rx: w / 2, ry: h / 2, innerRatio: 0.4)
        case .star5:
            return star(points: 5, cx: midX, cy: midY, rx: w / 2, ry: h / 2, innerRatio: 0.4)
        case .star6:
            return star(points: 6, cx: midX, cy: midY, rx: w / 2, ry: h / 2, innerRatio: 0.5)
        case .arrowRight:
            // shaft ← 60% of width; head → last 40%, half-height barbs.
            return [p(0, 0.3), p(0.6, 0.3), p(0.6, 0), p(1, 0.5),
                    p(0.6, 1), p(0.6, 0.7), p(0, 0.7)]
        case .arrowLeft:
            return [p(1, 0.3), p(0.4, 0.3), p(0.4, 0), p(0, 0.5),
                    p(0.4, 1), p(0.4, 0.7), p(1, 0.7)]
        case .arrowUp:
            return [p(0.3, 1), p(0.3, 0.4), p(0, 0.4), p(0.5, 0),
                    p(1, 0.4), p(0.7, 0.4), p(0.7, 1)]
        case .arrowDown:
            return [p(0.3, 0), p(0.3, 0.6), p(0, 0.6), p(0.5, 1),
                    p(1, 0.6), p(0.7, 0.6), p(0.7, 0)]
        case .heart:
            return heartRing.map { p($0.x, $0.y) }
        case .lightning:
            // A zig-zag bolt: tip top, kicks left then right, point at bottom.
            return [p(0.55, 0), p(0.15, 0.55), p(0.45, 0.55), p(0.30, 1),
                    p(0.85, 0.42), p(0.55, 0.42), p(0.72, 0)]
        case .speechCallout:
            // A rounded-ish speech bubble body (top ¾) with a tail at bottom-left.
            return [p(0, 0), p(1, 0), p(1, 0.72), p(0.42, 0.72),
                    p(0.22, 1), p(0.26, 0.72), p(0, 0.72)]
        }
    }

    /// A heart outline as a normalized (`0...1`, y-down) polygon ring, sampled
    /// from the classic parametric heart curve and rescaled to fill the unit
    /// box. Precomputed once (pure constants) so `vertices(in:)` just maps it
    /// into the rect. TSK-1574.
    private var heartRing: [(x: Double, y: Double)] {
        let n = 28
        var pts: [(Double, Double)] = []
        for i in 0..<n {
            let t = 2 * Double.pi * Double(i) / Double(n)
            let x = 16 * pow(sin(t), 3)
            let y = 13 * cos(t) - 5 * cos(2 * t) - 2 * cos(3 * t) - cos(4 * t)
            pts.append((x, y))
        }
        let xs = pts.map(\.0), ys = pts.map(\.1)
        let minX = xs.min()!, maxX = xs.max()!, minY = ys.min()!, maxY = ys.max()!
        let dx = maxX - minX, dy = maxY - minY
        // Normalize into 0...1; flip Y because the math curve is y-up but image
        // space is y-down (the heart's cusp must land at the TOP of the box).
        return pts.map { (($0.0 - minX) / dx, 1 - ($0.1 - minY) / dy) }
    }

    /// A regular n-gon inscribed in the rect's ellipse, first vertex at
    /// `startAngle` (radians, 0 = +x, growing clockwise in image space).
    private func regularPolygon(
        sides: Int, cx: Double, cy: Double, rx: Double, ry: Double, startAngle: Double
    ) -> [CGPoint] {
        (0..<sides).map { i in
            let a = startAngle + 2 * .pi * Double(i) / Double(sides)
            return CGPoint(x: cx + rx * cos(a), y: cy + ry * sin(a))
        }
    }

    /// An n-pointed star: `points` outer tips alternating with inner
    /// vertices at `innerRatio` of the radius. First tip points up.
    private func star(
        points: Int, cx: Double, cy: Double, rx: Double, ry: Double, innerRatio: Double
    ) -> [CGPoint] {
        let n = points * 2
        return (0..<n).map { i in
            let outer = i % 2 == 0
            let r = outer ? 1.0 : innerRatio
            let a = -Double.pi / 2 + 2 * .pi * Double(i) / Double(n)
            return CGPoint(x: cx + rx * r * cos(a), y: cy + ry * r * sin(a))
        }
    }
}
