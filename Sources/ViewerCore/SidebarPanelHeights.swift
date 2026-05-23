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
