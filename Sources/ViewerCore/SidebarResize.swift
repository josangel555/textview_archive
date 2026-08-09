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
