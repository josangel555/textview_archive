import Foundation

/// A pixel-space selection region for the raster paint editor (TSK-406).
///
/// Pure geometry — no AppKit/CoreGraphics, host-unit-testable. The marquee /
/// lasso DRAWING (the on-canvas affordance) is the SwiftUI render tail; this is
/// the model that constrains paint ops to a region. Coordinates are image-pixel
/// integers (top-left origin), matching `RasterCanvas`.
public enum RasterSelection: Sendable, Equatable {
    /// Axis-aligned rectangle, half-open: x in [x, x+width), y in [y, y+height).
    case rect(x: Int, y: Int, width: Int, height: Int)
    /// Freeform polygon (lasso) — ordered vertices; implicitly closed.
    case polygon([RasterPoint])

    /// Integer bounding box (top-left origin), or nil if degenerate/empty. For a
    /// polygon it's the min/max of the vertices (inclusive). TSK-1064/1066 — lets
    /// the selection ops scan a tight box and mask per-pixel via `contains`.
    public var bounds: (x: Int, y: Int, width: Int, height: Int)? {
        switch self {
        case let .rect(x, y, w, h):
            guard w > 0, h > 0 else { return nil }
            return (x, y, w, h)
        case let .polygon(points):
            guard points.count >= 3 else { return nil }
            let xs = points.map(\.x), ys = points.map(\.y)
            let minX = xs.min()!, maxX = xs.max()!, minY = ys.min()!, maxY = ys.max()!
            let w = maxX - minX + 1, h = maxY - minY + 1
            guard w > 0, h > 0 else { return nil }
            return (minX, minY, w, h)
        }
    }

    /// Whether pixel `(x, y)` is inside the selection.
    public func contains(x: Int, y: Int) -> Bool {
        switch self {
        case let .rect(rx, ry, w, h):
            guard w > 0, h > 0 else { return false }
            return x >= rx && x < rx + w && y >= ry && y < ry + h
        case let .polygon(points):
            return Self.pointInPolygon(x: x, y: y, points: points)
        }
    }

    /// Ray-casting point-in-polygon (even-odd rule). Tests the pixel CENTER
    /// (x+0.5, y+0.5) so a vertex/edge exactly on an integer grid line resolves
    /// deterministically instead of landing ambiguously on a boundary.
    static func pointInPolygon(x: Int, y: Int, points: [RasterPoint]) -> Bool {
        guard points.count >= 3 else { return false }
        let px = Double(x) + 0.5
        let py = Double(y) + 0.5
        var inside = false
        var j = points.count - 1
        for i in 0..<points.count {
            let xi = Double(points[i].x), yi = Double(points[i].y)
            let xj = Double(points[j].x), yj = Double(points[j].y)
            // Does the horizontal ray at py cross edge (j → i)?
            if (yi > py) != (yj > py) {
                let xCross = (xj - xi) * (py - yi) / (yj - yi) + xi
                if px < xCross { inside.toggle() }
            }
            j = i
        }
        return inside
    }
}

/// Integer pixel coordinate (top-left origin).
public struct RasterPoint: Sendable, Equatable {
    public let x: Int
    public let y: Int
    public init(x: Int, y: Int) { self.x = x; self.y = y }
}

public extension RasterCanvas {
    /// Fill every pixel inside `selection` with `color` (selection-constrained
    /// paint — TSK-406). Pixels outside the selection are untouched. The
    /// bounding scan keeps it to the affected rows for a rect; the polygon path
    /// scans the full canvas (callers pass small lassos).
    mutating func fill(_ color: RGBAColor, in selection: RasterSelection) {
        let (minX, minY, maxX, maxY): (Int, Int, Int, Int)
        switch selection {
        case let .rect(rx, ry, w, h):
            minX = max(0, rx); minY = max(0, ry)
            maxX = min(width, rx + w); maxY = min(height, ry + h)
        case .polygon:
            minX = 0; minY = 0; maxX = width; maxY = height
        }
        guard minX < maxX, minY < maxY else { return }
        for y in minY..<maxY {
            for x in minX..<maxX where selection.contains(x: x, y: y) {
                setPixel(x: x, y: y, to: color)
            }
        }
    }
}
