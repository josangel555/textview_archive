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

    /// TSK-440 — the full sidebar divider plan, INCLUDING the boundary
    /// between the flex-fill FILES panel and the accordion. The old
    /// accordion-only plan drew dividers only BETWEEN adjacent tool
    /// windows, so FILES + one tool produced ZERO draggable boundaries
    /// (bug B) and FILES + two tools produced one in a misleading place
    /// (bug C). The FILES divider exists exactly when FILES is shown AND
    /// at least one accordion panel is visible below it.
    public struct FullPlan: Equatable, Sendable {
        /// Draw a resizable divider between FILES and the accordion.
        public let drawFilesDivider: Bool
        /// The accordion run — same semantics as `plan(_:)`.
        public let entries: [Entry]

        public init(drawFilesDivider: Bool, entries: [Entry]) {
            self.drawFilesDivider = drawFilesDivider
            self.entries = entries
        }
    }

    public static func plan(
        filesVisible: Bool,
        accordion: [(panel: SidebarPanelKind, isVisible: Bool)]
    ) -> FullPlan {
        let entries = plan(accordion)
        return FullPlan(
            drawFilesDivider: filesVisible && !entries.isEmpty,
            entries: entries
        )
    }

    /// Owner 2026-08-09 ("tool windows must fill the shoulder, whatever the
    /// combination"): the accordion panel that takes FILES' flex-fill role.
    /// FILES fills when it is visible; otherwise the LAST visible accordion
    /// panel does — rendered outside the bounded scroll with the `.infinity`
    /// body sentinel. Plugin sections render below the accordion and manage
    /// their own height, so a visible plugin region disables the accordion
    /// fill (it would otherwise sit between the fill panel and the bottom).
    public static func fillTarget(
        filesVisible: Bool,
        pluginsVisible: Bool,
        accordion: [(panel: SidebarPanelKind, isVisible: Bool)]
    ) -> SidebarPanelKind? {
        guard !filesVisible, !pluginsVisible else { return nil }
        return plan(accordion).last?.panel
    }
}
