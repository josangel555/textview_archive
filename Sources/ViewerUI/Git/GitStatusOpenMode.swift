import Foundation

/// What a click on a git-status file row opens (owner intake 2026-08-01, I-05):
/// the per-file DIFF (the review-first default — "show me what changed") or the
/// file's SOURCE. Both open into the ephemeral preview slot (TSK-1594) so
/// clicking through a changeset reuses one tab; the row context menu keeps the
/// explicit permanent "Open File".
///
/// Pure + host-tested (`GitStatusOpenModeTests`); the segmented toggle in
/// `GitStatusTab`'s header binds to the persisted raw value.
enum GitStatusOpenMode: String, CaseIterable {
    case diff
    case source

    /// Persisted under UserDefaults (@AppStorage in the view). Diff is the
    /// default: it also covers deleted files, whose source no longer exists.
    static let defaultsKey = "MarkdownViewer.gitPanel.statusOpenMode"

    enum ClickAction: Equatable {
        case showDiff
        case previewSource
    }

    /// Routing rule for a status-row click. Untracked files have no diff to
    /// show — they fall back to the source preview in BOTH modes rather than
    /// opening a placeholder "(no diff output)" document.
    static func clickAction(mode: GitStatusOpenMode, isUntracked: Bool) -> ClickAction {
        (mode == .diff && !isUntracked) ? .showDiff : .previewSource
    }
}
