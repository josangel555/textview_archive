import CoreGraphics

/// A laid-out treemap tile: an item id + the rectangle it occupies.
public struct TreemapTile<ID: Hashable>: Equatable {
    public let id: ID
    public let rect: CGRect
    public init(id: ID, rect: CGRect) { self.id = id; self.rect = rect }
}

/// Squarified treemap layout (Bruls, Huizing & van Wijk, 2000). Maps weighted
/// items into `bounds` as size-proportional rectangles that exactly tile the
/// area, greedily minimizing each row's worst aspect ratio so tiles stay close
/// to square (readable). Pure geometry — no rendering, no AppKit. Backs the
/// folder-stats "bundle-analyzer"-style treemap (TSK-334).
public enum TreemapLayout {

    /// Lay `items` (id + weight) into `bounds`. Items with non-positive or
    /// non-finite weight are dropped. Tiles are returned in layout order; the
    /// total tiled area equals `bounds`'s area and each tile's area is
    /// proportional to its weight.
    public static func squarify<ID: Hashable>(
        _ items: [(id: ID, weight: Double)],
        in bounds: CGRect
    ) -> [TreemapTile<ID>] {
        let positive = items.filter { $0.weight > 0 && $0.weight.isFinite }
        guard !positive.isEmpty, bounds.width > 0, bounds.height > 0 else { return [] }

        let totalWeight = positive.reduce(0.0) { $0 + $1.weight }
        // Scale weights to points² so the whole set fills `bounds`.
        let scale = (Double(bounds.width) * Double(bounds.height)) / totalWeight
        let pending = positive.map { (id: $0.id, area: $0.weight * scale) }

        var tiles: [TreemapTile<ID>] = []
        var rect = bounds
        var row: [(id: ID, area: Double)] = []

        // Worst (largest) aspect ratio produced by laying `r` along side `w`.
        func worst(_ r: [(id: ID, area: Double)], _ w: Double) -> Double {
            guard !r.isEmpty, w > 0 else { return .infinity }
            let s = r.reduce(0.0) { $0 + $1.area }
            guard s > 0 else { return .infinity }
            let rmax = r.map(\.area).max()!
            let rmin = r.map(\.area).min()!
            let w2 = w * w, s2 = s * s
            return max(w2 * rmax / s2, s2 / (w2 * rmin))
        }

        // Place `r` as a strip along the SHORTER side of `rect`, then shrink rect.
        func layoutRow(_ r: [(id: ID, area: Double)]) {
            let s = r.reduce(0.0) { $0 + $1.area }
            guard s > 0 else { return }
            if rect.width >= rect.height {
                // Vertical strip on the left; thickness = s / height.
                let stripW = CGFloat(s / Double(rect.height))
                var y = rect.minY
                for item in r {
                    let h = CGFloat(item.area / s) * rect.height
                    tiles.append(TreemapTile(id: item.id,
                        rect: CGRect(x: rect.minX, y: y, width: stripW, height: h)))
                    y += h
                }
                rect = CGRect(x: rect.minX + stripW, y: rect.minY,
                              width: rect.width - stripW, height: rect.height)
            } else {
                // Horizontal strip on the top; thickness = s / width.
                let stripH = CGFloat(s / Double(rect.width))
                var x = rect.minX
                for item in r {
                    let w = CGFloat(item.area / s) * rect.width
                    tiles.append(TreemapTile(id: item.id,
                        rect: CGRect(x: x, y: rect.minY, width: w, height: stripH)))
                    x += w
                }
                rect = CGRect(x: rect.minX, y: rect.minY + stripH,
                              width: rect.width, height: rect.height - stripH)
            }
        }

        var idx = 0
        while idx < pending.count {
            let item = pending[idx]
            let w = Double(min(rect.width, rect.height))
            // Greedily extend the current row while it doesn't worsen the worst
            // aspect ratio; otherwise flush the row and re-test the item fresh.
            if row.isEmpty || worst(row + [item], w) <= worst(row, w) {
                row.append(item)
                idx += 1
            } else {
                layoutRow(row)
                row = []
            }
        }
        if !row.isEmpty { layoutRow(row) }
        return tiles
    }
}
