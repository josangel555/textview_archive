import Foundation
import CoreGraphics

/// TSK-440 — pure math for the sidebar tool-window resize model.
///
/// The old model let a divider mutate only the panel ABOVE it, with the
/// flex-fill FILES panel silently absorbing the slack — which made a
/// 3-panel drag feel erratic (the panel you dragged grew, a panel you
/// never touched shrank). The owner-desired model: a drag moves height
/// BETWEEN the two panels adjacent to the divider, sum-preserving, so
/// every other panel stays exactly where it was.
///
/// SwiftUI-free and stateless so the host suite pins it; the live drag
/// gesture (cursor, mouse capture) stays VM-lane.
public enum SidebarResize {

    /// Move `delta` points of height from the panel below a divider to
    /// the panel above it (positive delta = drag down = above grows).
    /// Sum-preserving: `above' + below' == above + below` always. Both
    /// sides are floored at `floor` — the delta is clamped to what the
    /// pair can actually absorb. A degenerate pair (sum < 2×floor, e.g.
    /// hand-edited defaults) is returned unchanged rather than minting
    /// height out of nothing.
    public static func redistribute(
        above: CGFloat,
        below: CGFloat,
        delta: CGFloat,
        floor: CGFloat = SidebarPanelHeights.minExpandedHeight
    ) -> (above: CGFloat, below: CGFloat) {
        let sum = above + below
        guard sum >= 2 * floor else { return (above, below) }
        let newAbove = min(max(above + delta, floor), sum - floor)
        return (newAbove, sum - newAbove)
    }

    // (`redistributeCascading` — the 2026-08-09 flex-borrowing cascade —
    // was DELETED 2026-08-12 on the owner's final spec: "a divider drag
    // moves THAT boundary only; do not affect any other boundary above or
    // below." The cascade borrowed from the flex panel wherever it was,
    // which moved the pair's FAR boundary — panels visibly growing from
    // the end the user wasn't dragging.)
}

/// The FROZEN drag session (owner 2026-08-12, two rounds):
///
/// Round 1 ("can't resize above 50%; the handle isn't synced"): every
/// input to base-relative drag math must be an ORIGIN snapshot — a live
/// budget feeds back into the drag's own writes and stalls at half.
///
/// Round 2 (the final spec): "a divider drag moves THAT boundary only —
/// shrink towards where you drag, grow away from it, and do NOT affect
/// any other boundary above or below." So: a PAIR drag trades space
/// between the two adjacent panels and STOPS when the shrinking side
/// floors — no cascade, no borrowing from the flex panel (which moved
/// the pair's far boundary: panels visibly growing from the end the
/// user wasn't dragging). A divider ADJACENT to the flex panel moves
/// its one stored neighbor against the flex's origin give — still just
/// that one boundary (the flex absorbs by layout; its far edge is the
/// band edge).
public struct DividerDragSession: Equatable, Sendable {
    /// Height bases at drag origin (the RENDERED heights — what the user
    /// saw when they grabbed). nil = that side is the flex panel.
    public let baseAbove: CGFloat?
    public let baseBelow: CGFloat?
    /// The FLEX side's give at drag origin — meaningful only for the
    /// dividers adjacent to the flex panel. Frozen for the drag.
    public let slack: CGFloat

    public init(baseAbove: CGFloat?, baseBelow: CGFloat?, slack: CGFloat) {
        self.baseAbove = baseAbove
        self.baseBelow = baseBelow
        self.slack = max(0, slack)
    }

    /// PAIR divider: sum-preserving exchange between the two adjacent
    /// panels, both floored — the divider stops when the shrinking side
    /// hits its floor. Nothing else moves, by construction.
    public func pairTargets(
        delta: CGFloat,
        floor: CGFloat = SidebarPanelHeights.minExpandedHeight
    ) -> (above: CGFloat, below: CGFloat)? {
        guard let a = baseAbove, let b = baseBelow else { return nil }
        return SidebarResize.redistribute(above: a, below: b, delta: delta, floor: floor)
    }

    /// Stored panel ABOVE the flex: drag down grows it into the flex's
    /// origin give; drag up shrinks it to its floor.
    public func aboveTarget(
        delta: CGFloat,
        floor: CGFloat = SidebarPanelHeights.minExpandedHeight
    ) -> CGFloat? {
        guard let a = baseAbove else { return nil }
        return min(max(a + delta, floor), a + slack)
    }

    /// Stored panel BELOW the flex (the FILES-on-top boundary): drag up
    /// grows it into the flex's origin give; drag down shrinks it to its
    /// floor.
    public func belowTarget(
        delta: CGFloat,
        floor: CGFloat = SidebarPanelHeights.minExpandedHeight
    ) -> CGFloat? {
        guard let b = baseBelow else { return nil }
        return min(max(b - delta, floor), b + slack)
    }
}

// (`AccordionHeightResolver` — the BoundedAccordionScroll relic — was
// deleted 2026-08-12 with the special-case sweep: the one-rule stack has
// no bounded accordion, and the resolver had no callers left.)
