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
        }
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
