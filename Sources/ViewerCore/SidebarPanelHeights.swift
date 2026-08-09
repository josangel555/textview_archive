import Foundation
import CoreGraphics

/// Pure-logic side of the resizable left-sidebar sections.
///
/// SwiftUI side: each section between the sidebar header and the
/// FILES tree is followed by a custom drag-handle divider. Dragging
/// adjusts the height of the section above it; the FILES tree (last)
/// keeps its flex-fill behaviour and never owns a height key.
///
/// This type owns three pieces of state-shaping logic that benefit
/// from being decoupled from `@AppStorage` so they can be unit-tested
/// on the host without spinning up SwiftUI:
///
///   * the canonical list of resizable sections + their persistence
///     keys (single source of truth — the view layer reads keys from
///     here, not from string literals scattered across files).
///   * the minimum-height floor (collapsed sections bypass it; only
///     expanded ones get clamped).
///   * the clamp itself, used both on read-back from defaults and
///     during a live drag so the user can't drag a panel below the
///     floor.
///
/// VM-only behaviour (interactive drag, cursor hover, mouse capture)
/// is exercised by the AppKit-driven UI test bundles; this struct is
/// what the host-side `ViewerCoreTests.SidebarPanelHeightsTests`
/// suite covers.
// Canonical panel identity now lives in `SidebarPanelKind.swift`.
// `SidebarPanel` is a type-alias to `SidebarPanelKind` so existing
// call sites compile unchanged.

public enum SidebarPanelHeights {
    /// Floor for an *expanded* section's body. Collapsed sections
    /// render only the header row and bypass the floor entirely (a
    /// header alone is well below this height by design).
    ///
    /// Bumped from 80 → 120 in 2026-05 alongside the fixed-envelope
    /// change: every section now reserves its full body height
    /// regardless of content (an empty Bookmarks panel reads as the
    /// same card as a populated one). 120 leaves room for a section
    /// header + a couple of rows + the "(empty)" placeholder without
    /// looking cramped.
    public static let minExpandedHeight: CGFloat = 120

    /// Clamp a height to the legal range for an expanded section.
    /// Used both on read-back from `@AppStorage` (a hand-edited
    /// defaults plist may contain garbage) and live during a drag.
    public static func clamp(_ height: CGFloat) -> CGFloat {
        max(minExpandedHeight, height)
    }

    /// Window-derived per-panel ceiling (P1 — tool-window bounding).
    ///
    /// The accordion panels carry a stored body height (default 220);
    /// rendered RIGID they over-subscribe the sidebar band and push the
    /// window chrome out. The fix bounds each panel's body to a fraction
    /// of the sidebar's currently-allotted height so the panels SHRINK
    /// toward (but never below) the floor as the window gets smaller —
    /// "dynamic sizing bounded by a region derived from the window size".
    ///
    /// `available` is the sidebar's measured content height (below the
    /// header). `fraction` is how much of it a *single* expanded panel
    /// may claim before it has to give way to its siblings (and, past
    /// the point where even the floors don't all fit, to the accordion's
    /// own scroll). A non-positive / non-finite `available` (the first
    /// pre-measurement body pass) disables the ceiling so we fall back to
    /// the stored height — the measurement settles on the next pass.
    ///
    /// The ceiling is itself floored at `minExpandedHeight`: a single
    /// panel never shrinks below the floor here (multi-panel overflow is
    /// absorbed by the accordion ScrollView, not by squeezing a panel to
    /// nothing).
    public static func clamp(_ height: CGFloat,
                             availableHeight available: CGFloat,
                             fraction: CGFloat = 0.5) -> CGFloat {
        let stored = clamp(height)
        guard available.isFinite, available > 0 else { return stored }
        let ceiling = max(minExpandedHeight, available * fraction)
        return min(stored, ceiling)
    }

    /// TSK-1590 — the per-panel ceiling fraction as a function of how many
    /// accordion panels are visible. The 0.5 default exists to stop ONE panel
    /// hogging the band away from its siblings — but with a SINGLE visible
    /// panel there are no siblings, so that cap just strands the bottom half of
    /// the sidebar empty (owner report: "git only fills half the height when
    /// it's the only tool window"). A lone panel may claim the whole band
    /// (1.0); two or more keep the sibling-protecting 0.5 split.
    public static func ceilingFraction(visiblePanelCount count: Int) -> CGFloat {
        count <= 1 ? 1.0 : 0.5
    }

    /// 2026-08-09 (owner: "left tool windows cap at a random height instead
    /// of filling the shoulder"). The ceiling work above lets a lone panel's
    /// stored height THROUGH but never RAISES it — a panel stored at 220
    /// strands the rest of a 1200pt band, and because every panel persists
    /// its own height the cap lands somewhere different per panel ("erratic").
    ///
    /// When FILES (the designed flex-fill) is hidden, the LAST visible
    /// accordion panel plays its role: its body is raised to the leftover
    /// band after its siblings' resolved bodies and per-panel chrome
    /// (header rows + dividers). Never returns less than the normally
    /// clamped stored height, so a user-dragged size still wins when it is
    /// LARGER than the leftover; the pre-measurement pass (no usable
    /// available height) falls back to the stored height.
    public static func fillHeight(
        stored: CGFloat,
        availableHeight: CGFloat,
        siblingResolvedHeights: [CGFloat],
        chromePerPanel: CGFloat,
        panelCount: Int
    ) -> CGFloat {
        let base = clamp(stored)
        guard availableHeight.isFinite, availableHeight > 0 else { return base }
        let chrome = chromePerPanel * CGFloat(max(panelCount, 1))
        let leftover = availableHeight
            - siblingResolvedHeights.reduce(0, +)
            - chrome
        return max(base, leftover)
    }

    /// TSK-592 — RESIZE-JANK SUPPRESSION.
    ///
    /// The sidebar measures its allotted content height via a background
    /// `GeometryReader` and commits it to a `@State`. During a live window
    /// (or pane) resize that height changes by points *every frame*, and
    /// each commit re-bodies the whole `SidebarView` — re-running
    /// `clamp(_:availableHeight:)` for every accordion panel. VM Time
    /// Profiler attributed a slice of the per-resize-frame cost to exactly
    /// this re-evaluation (the felt jank in TSK-592).
    ///
    /// But the committed height only MATTERS when it changes a panel's
    /// rendered body height. In the common "roomy" regime the per-panel
    /// ceiling (`available * fraction`) sits above every stored height, so
    /// `min(stored, ceiling) == stored` regardless of the measured height —
    /// the commit re-bodies the sidebar for a layout that is byte-identical.
    /// In the "pinned at floor" regime (a very small sidebar) every panel is
    /// already at `minExpandedHeight`, so again the height is irrelevant.
    ///
    /// This predicate answers "would committing `measured` instead of
    /// `current` change ANY panel's resolved body height?" — the EXACT
    /// condition under which a re-body is observable. The view wires it into
    /// the `GeometryReader` `onChange` so a resize frame that can't change
    /// any panel height is dropped before it touches `@State`. It is defined
    /// directly in terms of `clamp(_:availableHeight:fraction:)` (the same
    /// function that produces the rendered height), so it can never drift
    /// from the real layout math.
    ///
    /// `current` is the height presently committed to the `@State`;
    /// `measured` is the fresh `GeometryReader` reading; `storedHeights` is
    /// the per-panel stored bodies (the `@AppStorage` values, pre-clamp).
    /// `fraction` mirrors the rendering call's fraction.
    ///
    /// Returns `true` (commit) whenever the first measurement arrives from
    /// the unmeasured state (`current <= 0` while `measured > 0`), so the
    /// initial settle is never suppressed.
    public static func shouldCommitAvailableHeight(
        current: CGFloat,
        measured: CGFloat,
        storedHeights: [CGFloat],
        fraction: CGFloat = 0.5
    ) -> Bool {
        guard measured.isFinite else { return false }
        // First real measurement after the pre-measurement zero pass — the
        // ceiling switches on, so the panels genuinely need it.
        let currentUsable = current.isFinite && current > 0
        let measuredUsable = measured > 0
        if measuredUsable != currentUsable { return true }
        if !measuredUsable { return false }   // both unusable → nothing to do
        // Both heights usable: commit only if some panel's RESOLVED body
        // height differs between the two. Evaluating the real clamp keeps
        // this in lockstep with what actually renders.
        for stored in storedHeights {
            let before = clamp(stored, availableHeight: current, fraction: fraction)
            let after = clamp(stored, availableHeight: measured, fraction: fraction)
            if abs(before - after) > heightCommitEpsilon { return true }
        }
        return false
    }

    /// Sub-point resolved-height delta that still counts as "unchanged" for
    /// the resize-commit predicate — guards against float noise re-bodying
    /// the sidebar at a clamp boundary. Tighter than the view's measure
    /// epsilon: this compares *resolved panel heights*, not raw measures.
    public static let heightCommitEpsilon: CGFloat = 0.5

    /// Read a persisted height from any defaults-like store. Falls
    /// back to the section's default when the key is missing.
    /// Always returns a clamped value.
    public static func readClamped(_ section: SidebarPanel,
                                   from defaults: UserDefaults) -> CGFloat {
        let raw = defaults.object(forKey: section.appStorageKey) as? Double
        let value = raw.map { CGFloat($0) } ?? section.defaultHeight
        return clamp(value)
    }
}
