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

    /// Owner 2026-08-09 ("opening 3 tool windows, the third one doesn't even
    /// move"): pure sum-preserving redistribution STOPS the moment the
    /// giving neighbor hits its floor — even when the FLEX panel has plenty
    /// of slack to give. This variant cascades: a GROW drag (positive
    /// delta) takes from the pair neighbor first, then lets the pair's
    /// total grow by up to `flexSlack` (the flex panel absorbs the growth
    /// by layout — "each window can grow, but not push"). The shrink
    /// direction stays pair-only (the divider stops at the above panel's
    /// floor, the conventional splitter behavior).
    public static func redistributeCascading(
        above: CGFloat,
        below: CGFloat,
        delta: CGFloat,
        floor: CGFloat = SidebarPanelHeights.minExpandedHeight,
        flexSlack: CGFloat
    ) -> (above: CGFloat, below: CGFloat) {
        let pair = redistribute(above: above, below: below, delta: delta, floor: floor)
        guard delta > 0 else { return pair }
        // What the neighbor already gave; the remainder comes from flex.
        let absorbed = pair.above - above
        let remainder = delta - absorbed
        guard remainder > 0, flexSlack > 0 else { return pair }
        return (pair.above + min(remainder, flexSlack), pair.below)
    }
}

/// Owner 2026-08-12 ("still can't resize above 50%; the handle isn't synced
/// with the mouse") — the FROZEN drag session.
///
/// The 2026-08-09 fix snapshotted the height BASES at drag origin, but the
/// cascade's flex BUDGET (`flexSlack`) stayed a live per-body-eval value:
/// as a drag consumed slack, the flex panel shrank, the next body eval
/// recomputed a smaller slack, and the next delta was capped by it — a
/// feedback loop that converges at HALF the original slack (G = slack₀ − G)
/// and partially applies every delta on the way (the mouse desync). The
/// rule, generalized: EVERY input to base-relative drag math is an ORIGIN
/// snapshot — bases AND budgets. This value type IS that snapshot: created
/// at drag start, immutable for the drag's lifetime, discarded at end.
public struct DividerDragSession: Equatable, Sendable {
    /// Height bases at drag origin (the RENDERED heights — what the user
    /// saw when they grabbed). nil = that side has no height key.
    public let baseAbove: CGFloat?
    public let baseBelow: CGFloat?
    /// The flex panel's give at drag origin. Frozen — the whole point.
    public let slack: CGFloat

    public init(baseAbove: CGFloat?, baseBelow: CGFloat?, slack: CGFloat) {
        self.baseAbove = baseAbove
        self.baseBelow = baseBelow
        self.slack = max(0, slack)
    }

    /// Absolute pair targets for the CUMULATIVE drag delta — cascade
    /// bounded by the ORIGIN slack, so a monotone drag tracks 1:1 all the
    /// way to `baseAbove + pairGive + slack`, never half of it.
    public func pairTargets(
        delta: CGFloat,
        floor: CGFloat = SidebarPanelHeights.minExpandedHeight
    ) -> (above: CGFloat, below: CGFloat)? {
        guard let a = baseAbove, let b = baseBelow else { return nil }
        return SidebarResize.redistributeCascading(
            above: a, below: b, delta: delta, floor: floor, flexSlack: slack)
    }

    /// Above-only divider (the flex boundary from above): base + delta.
    public func aboveTarget(delta: CGFloat) -> CGFloat? {
        baseAbove.map { $0 + delta }
    }

    /// Below-only divider (the FILES boundary): drag up grows the panel
    /// below by taking from the flex panel above, bounded by the ORIGIN
    /// slack.
    public func belowTarget(delta: CGFloat) -> CGFloat? {
        guard let b = baseBelow else { return nil }
        return min(b - delta, b + slack)
    }
}

/// TSK-440 bug (A) — the lone-FILES gap. `BoundedAccordionScroll` hugs
/// its measured content up to a window-derived cap, but it treated a
/// measured height of 0 as "not measured yet" and fell back to the CAP —
/// so an EMPTY accordion (lone FILES panel) still reserved ~62% of the
/// sidebar as a blank region. The resolver distinguishes the two states:
///
///   * not measured yet  → cap (first-pass behavior, unchanged)
///   * measured ≈ empty  → 0   (the region collapses; FILES flex-fills)
///   * measured, fits    → content height (hug)
///   * measured, over    → cap (scroll)
///
/// `nil` = unconstrained (no cap and nothing measured — let SwiftUI hug).
public enum AccordionHeightResolver {

    /// Content below this measures as "empty" — sub-point layout noise,
    /// not a real panel.
    public static let emptyEpsilon: CGFloat = 1

    public static func resolve(
        contentHeight: CGFloat,
        hasMeasured: Bool,
        cap: CGFloat?
    ) -> CGFloat? {
        if hasMeasured, contentHeight <= emptyEpsilon {
            return 0
        }
        guard let cap else {
            return contentHeight > 0 ? contentHeight : nil
        }
        guard contentHeight > 0 else { return cap }
        return min(contentHeight, cap)
    }
}
