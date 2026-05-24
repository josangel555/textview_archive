import Foundation

/// Pure-logic planner for the sidebar accordion's divider placement.
///
/// The sidebar interleaves a `ResizableSectionDivider` between each
/// pair of adjacent visible panels. Several panels self-hide
/// (`GitPanelSection` when there's no repo, `ClaudeTimelineSection`
/// when there are no transcripts, `LSPOutlineSection` when the file
/// has no LSP server) — but the dividers themselves used to render
/// unconditionally, which stacked up multiple hairlines wherever a
/// run of panels was hidden ("3-4 divider lines below GIT").
///
/// The planner takes the visibility array and returns a list of
/// `(panel, drawTrailingDivider)` pairs:
///
///   * Hidden panels are dropped entirely.
///   * A trailing divider is drawn after a visible panel **only** if
///     there's at least one more visible panel after it.
///
/// SwiftUI consumes this list directly: render the panel, and (if
/// the entry says so) render a divider after it.
///
/// Pure value type so it's unit-testable without spinning up a view.
public enum SidebarSectionPlanner {
    public struct Entry: Equatable, Sendable {
        public let panel: SidebarPanelKind
        public let drawTrailingDivider: Bool

        public init(panel: SidebarPanelKind, drawTrailingDivider: Bool) {
            self.panel = panel
            self.drawTrailingDivider = drawTrailingDivider
        }
    }

    /// `visibility` is a parallel array of `(panel, isVisible)`.
    /// Order matches the on-screen order. The output keeps only the
    /// visible entries, with a trailing-divider flag set for every
    /// entry that isn't the last visible one.
    public static func plan(
        _ visibility: [(panel: SidebarPanelKind, isVisible: Bool)]
    ) -> [Entry] {
        let visible = visibility.filter { $0.isVisible }
        guard !visible.isEmpty else { return [] }
        return visible.enumerated().map { (idx, item) in
            Entry(
                panel: item.panel,
                drawTrailingDivider: idx < visible.count - 1
            )
        }
    }
}
