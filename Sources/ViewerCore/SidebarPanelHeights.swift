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
