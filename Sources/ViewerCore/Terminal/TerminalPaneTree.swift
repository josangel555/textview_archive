import CoreGraphics

/// The split-tree model for a tmux window rendered as native nested splits
/// (TSK-964, the `tmux -CC` control-mode integration). PURE logic + geometry
/// — no AppKit, no SwiftUI, no I/O — so the layout math and key-routing target
/// selection are host-testable end to end. The on-screen split render
/// (`TerminalSplitView`), real keystroke delivery, and divider drag are the
/// VM-only pixel/interaction tier (see CLAUDE.md compositor rules).
///
/// tmux's window layout is a binary-ish tree of nested split containers whose
/// leaves are panes. A horizontal (`h`) container lays its children
/// SIDE-BY-SIDE (left→right); a vertical (`v`) container STACKS them
/// (top→bottom). This mirrors tmux's own `window_layout` grammar:
/// `WIDTHxHEIGHT,X,Y{...}` (h-split, brace) vs `WIDTHxHEIGHT,X,Y[...]`
/// (v-split, bracket). We keep `PaneNode` transport-agnostic: `TmuxController`
/// / `TmuxSession` (slices c/d) build it from `%layout-change`, and this file
/// turns it into nominal frames + routing decisions.

/// A node in a tmux window's split tree: either a single pane (leaf) or a
/// split container with ≥1 children laid out along one axis.
public indirect enum PaneNode: Equatable, Sendable {
    /// A terminal pane leaf, identified by its tmux pane id (e.g. `%3`).
    case leaf(paneID: TmuxPaneID)
    /// A split container. `axis` is how the children are arranged; `children`
    /// is in layout order (h: left→right, v: top→bottom). `weights`, when
    /// present and matching `children.count`, gives each child's proportional
    /// share of the container's length along the split axis (tmux preserves
    /// non-equal sizes across a `resize-pane`). A nil / mismatched / non-
    /// positive-sum `weights` falls back to equal division.
    case split(axis: SplitAxis, children: [PaneNode], weights: [Double]?)

    /// Convenience: an equal-weight split.
    public static func split(axis: SplitAxis, children: [PaneNode]) -> PaneNode {
        .split(axis: axis, children: children, weights: nil)
    }
}

/// Stable identifier for a tmux pane. Wraps tmux's `%N` pane id so callers
/// don't pass bare ints (which would silently transpose with window/session
/// ids). Comparable + Hashable so it keys dictionaries and sorts stably.
public struct TmuxPaneID: Hashable, Comparable, Sendable, CustomStringConvertible {
    /// The numeric part of tmux's `%N` form (e.g. `%3` → 3).
    public let value: Int
    public init(_ value: Int) { self.value = value }
    public var description: String { "%\(value)" }
    public static func < (lhs: TmuxPaneID, rhs: TmuxPaneID) -> Bool {
        lhs.value < rhs.value
    }
}

/// How a split container arranges its children.
public enum SplitAxis: Equatable, Sendable {
    /// Side-by-side, left→right (tmux `{...}` / `split-window -h`).
    case horizontal
    /// Stacked, top→bottom (tmux `[...]` / `split-window -v`).
    case vertical
}

/// A laid-out pane: its id and the rectangle it occupies in the container's
/// coordinate space (origin at the container's `minX`/`minY`).
public struct PaneFrame: Equatable, Sendable {
    public let paneID: TmuxPaneID
    public let rect: CGRect
    public init(paneID: TmuxPaneID, rect: CGRect) {
        self.paneID = paneID
        self.rect = rect
    }
}

public enum TerminalPaneTree {

    /// Compute the nominal on-screen rectangle for every leaf pane, tiling
    /// `bounds` exactly. Pure geometry: a horizontal split divides width
    /// left→right, a vertical split divides height top→bottom, recursing.
    ///
    /// `dividerThickness` reserves a gutter BETWEEN adjacent children (the
    /// draggable divider) so leaf rects don't butt against each other; it is
    /// NOT subtracted from the outer edges. With N children there are N−1
    /// gutters along the split axis.
    ///
    /// Frames are returned in stable left-to-right / top-to-bottom leaf order
    /// (a pre-order walk), so the result is deterministic for snapshot tests.
    /// A leaf node alone fills `bounds`. Degenerate inputs (non-positive
    /// bounds) yield an empty result.
    public static func frames(
        for node: PaneNode,
        in bounds: CGRect,
        dividerThickness: CGFloat = 0
    ) -> [PaneFrame] {
        guard bounds.width > 0, bounds.height > 0 else { return [] }
        var out: [PaneFrame] = []
        layout(node, in: bounds, divider: max(0, dividerThickness), into: &out)
        return out
    }

    private static func layout(
        _ node: PaneNode,
        in rect: CGRect,
        divider: CGFloat,
        into out: inout [PaneFrame]
    ) {
        switch node {
        case let .leaf(paneID):
            out.append(PaneFrame(paneID: paneID, rect: rect))
        case let .split(axis, children, weights):
            guard !children.isEmpty else { return }
            if children.count == 1 {
                layout(children[0], in: rect, divider: divider, into: &out)
                return
            }
            let shares = normalizedShares(weights, count: children.count)
            let gutters = CGFloat(children.count - 1) * divider
            switch axis {
            case .horizontal:
                let usable = max(0, rect.width - gutters)
                var x = rect.minX
                for (i, child) in children.enumerated() {
                    let w = usable * CGFloat(shares[i])
                    let childRect = CGRect(x: x, y: rect.minY, width: w, height: rect.height)
                    layout(child, in: childRect, divider: divider, into: &out)
                    x += w + divider
                }
            case .vertical:
                let usable = max(0, rect.height - gutters)
                var y = rect.minY
                for (i, child) in children.enumerated() {
                    let h = usable * CGFloat(shares[i])
                    let childRect = CGRect(x: rect.minX, y: y, width: rect.width, height: h)
                    layout(child, in: childRect, divider: divider, into: &out)
                    y += h + divider
                }
            }
        }
    }

    /// Normalize per-child weights into shares summing to 1. Falls back to an
    /// equal split when `weights` is nil, the wrong length, or has a non-
    /// positive / non-finite sum.
    private static func normalizedShares(_ weights: [Double]?, count: Int) -> [Double] {
        let equal = Array(repeating: 1.0 / Double(count), count: count)
        guard let w = weights, w.count == count else { return equal }
        let sanitized = w.map { $0.isFinite && $0 > 0 ? $0 : 0 }
        let sum = sanitized.reduce(0, +)
        guard sum > 0 else { return equal }
        return sanitized.map { $0 / sum }
    }

    // MARK: - Pane enumeration / routing

    /// Every leaf pane id in stable pre-order (left→right / top→bottom). The
    /// canonical pane ordering for cycle-focus, "first pane", and routing.
    public static func paneIDs(in node: PaneNode) -> [TmuxPaneID] {
        switch node {
        case let .leaf(paneID):
            return [paneID]
        case let .split(_, children, _):
            return children.flatMap { paneIDs(in: $0) }
        }
    }

    /// Whether `node` contains a leaf with `paneID`.
    public static func contains(_ paneID: TmuxPaneID, in node: PaneNode) -> Bool {
        paneIDs(in: node).contains(paneID)
    }

    /// The pane id a keystroke should be delivered to, given the user's
    /// `requestedActive` pane. PURE routing target selection (the model half
    /// of "route input to the active pane" — the real keystroke delivery is
    /// VM-tier). Rules, in order:
    ///   1. If `requestedActive` is set AND still exists in the tree → it.
    ///   2. Else fall back to the FIRST pane in stable order (so a closed /
    ///      stale active pane never strands keystrokes — tmux always keeps an
    ///      active pane while a window has ≥1 pane).
    ///   3. An empty tree (no leaves) → nil (nothing to route to).
    public static func keyRoutingTarget(
        for node: PaneNode,
        requestedActive: TmuxPaneID?
    ) -> TmuxPaneID? {
        let ids = paneIDs(in: node)
        guard !ids.isEmpty else { return nil }
        if let want = requestedActive, ids.contains(want) { return want }
        return ids.first
    }

    /// The id of the pane whose nominal frame contains `point`, for click-to-
    /// focus. Uses the same geometry as `frames(for:in:)`; ties (a point on a
    /// shared edge) resolve to the first matching pane in stable order. nil if
    /// no pane's rect contains the point (e.g. the point is in a divider
    /// gutter or outside `bounds`).
    public static func pane(
        at point: CGPoint,
        for node: PaneNode,
        in bounds: CGRect,
        dividerThickness: CGFloat = 0
    ) -> TmuxPaneID? {
        let laid = frames(for: node, in: bounds, dividerThickness: dividerThickness)
        return laid.first { $0.rect.contains(point) }?.paneID
    }
}
