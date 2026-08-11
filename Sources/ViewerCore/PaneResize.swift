import CoreGraphics

/// I-21 S4d — pure divider-drag math for the editor-pane run: dragging
/// the gutter between panes `divider` and `divider + 1` by `deltaPx`
/// rebalances exactly those two neighbors' weights; every other pane keeps
/// its span. Host-tested (`PaneResizeTests`); the SwiftUI layer only
/// supplies the axis translation and the run's usable span.
public enum PaneResize {

    /// Minimum span a pane can be dragged down to, in points.
    public static let minPaneSpan: CGFloat = 120

    /// New weights after the drag. The delta clamps so neither neighbor
    /// dips under `minPx` (a pane ALREADY under the floor — a tiny
    /// window — only allows growth back). Degenerate inputs (bad index,
    /// non-positive totals) return the weights unchanged.
    public static func dragDivider(
        weights: [CGFloat], divider: Int, deltaPx: CGFloat,
        totalPx: CGFloat, minPx: CGFloat = PaneResize.minPaneSpan
    ) -> [CGFloat] {
        guard weights.count >= 2,
              divider >= 0, divider < weights.count - 1,
              totalPx > 0 else { return weights }
        let sum = weights.reduce(0, +)
        guard sum > 0 else { return weights }
        let leftPx = weights[divider] / sum * totalPx
        let rightPx = weights[divider + 1] / sum * totalPx
        let d = min(max(deltaPx, -max(leftPx - minPx, 0)),
                    max(rightPx - minPx, 0))
        guard d != 0 else { return weights }
        var out = weights
        out[divider] = (leftPx + d) / totalPx * sum
        out[divider + 1] = (rightPx - d) / totalPx * sum
        return out
    }
}
