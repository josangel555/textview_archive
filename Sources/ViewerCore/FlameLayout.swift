import CoreGraphics

/// Deterministic flame-chart geometry over a `FlameProfile` — pure geometry,
/// no AppKit/SwiftUI, so it's fully host-testable (mirrors `TreemapLayout` and
/// `DependencyGraphLayout`). Foundation slice of TSK-715.
///
/// A flame chart stacks frames by call depth:
///   - the X axis encodes weight — a frame's width is proportional to its
///     `total`, and it sits directly above the slice of its parent it accounts
///     for (siblings are laid left-to-right in the parent's child order);
///   - the Y axis encodes depth — depth 0 (the outermost stack frames) is the
///     bottom row, deeper callees stack upward. Each row is `rowHeight` tall.
///
/// The synthetic root is NOT emitted as a tile (it's the whole canvas); its
/// children form the bottom row. `bounds.width` maps to `root.total` weight.
public enum FlameLayout {

    /// One laid-out flame cell: the frame, its rectangle, and its depth row.
    public struct Cell: Equatable {
        /// The profile frame this cell draws.
        public let frame: FlameProfile.Frame
        /// Rectangle in `bounds` coordinates (origin top-left, depth grows up
        /// in value but the rect's `minY` grows downward — see `lay` docs).
        public let rect: CGRect
        /// Call depth: the bottom (outermost) row is `0`.
        public let depth: Int
        public init(frame: FlameProfile.Frame, rect: CGRect, depth: Int) {
            self.frame = frame
            self.rect = rect
            self.depth = depth
        }
    }

    /// Lay `profile` into `bounds`.
    ///
    /// Coordinate convention: cells are placed with the depth-0 row at the
    /// BOTTOM of `bounds` and deeper rows stacking toward the top, which is the
    /// conventional flame-chart orientation. In a top-left-origin space that
    /// means `rect.minY = bounds.maxY − (depth + 1) * rowHeight`. Callers in a
    /// bottom-left-origin space (CoreGraphics default) can flip trivially.
    ///
    /// Cells whose computed width is below `minCellWidth` are dropped along
    /// with their entire subtree (a 0.3-px sliver is unclickable and just
    /// inflates the cell count) — the classic flame-graph "prune thin frames"
    /// behaviour. Set `minCellWidth = 0` to keep everything.
    ///
    /// Returns cells in a stable pre-order (parent before children, siblings in
    /// `children` order) so rendering and hit-testing are deterministic.
    public static func lay(
        _ profile: FlameProfile,
        in bounds: CGRect,
        rowHeight: CGFloat = 18,
        minCellWidth: CGFloat = 0
    ) -> [Cell] {
        let total = profile.root.total
        guard total > 0, bounds.width > 0, bounds.height > 0, rowHeight > 0 else {
            return []
        }
        let pxPerUnit = Double(bounds.width) / Double(total)
        var cells: [Cell] = []

        // Recursively place a frame's children across `[xStart, xStart+width]`.
        func place(_ frame: FlameProfile.Frame, depth: Int, xStart: CGFloat) {
            var x = xStart
            for child in frame.children {
                let w = CGFloat(Double(child.total) * pxPerUnit)
                if w < minCellWidth { x += w; continue }
                let y = bounds.maxY - CGFloat(depth + 1) * rowHeight
                let rect = CGRect(x: x, y: y, width: w, height: rowHeight)
                cells.append(Cell(frame: child, rect: rect, depth: depth))
                place(child, depth: depth + 1, xStart: x)
                x += w
            }
        }
        place(profile.root, depth: 0, xStart: bounds.minX)
        return cells
    }
}
