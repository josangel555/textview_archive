import Foundation

// Git-panel focus (TSK-1110 SRP slice) — focus the Git panel + the
// focus-eligibility gate. The `GitPanelTab` enum and the
// gitPanelFocusRequest/gitPanelDesiredTab nonces stay on DocumentModel.
// Behavior-preserving move out of DocumentModel.swift.
extension DocumentModel {

    /// Focus the Git panel and select `tab`. If the panel section is
    /// collapsed, the consumer expands it. Used by the View menu
    /// items "Show Repository History" / "Show File History" / "Show
    /// Git Panel" so those entries are discoverable without forcing
    /// the user to click into the sidebar.
    public func showGitPanel(tab: GitPanelTab = .status) {
        gitPanelDesiredTab = tab
        gitPanelFocusRequest &+= 1
    }

    /// True iff the Git panel currently has data to show (a repo is open
    /// under the active root). Mirrors `SidebarDataPresence` for `.git`
    /// (`hasRoot && hasRepo`). Gates the "Focus Git Panel" command —
    /// disabled when there's no repo to focus.
    public var canFocusGitPanel: Bool {
        sidebar.rootURL != nil && sidebar.gitRepoRoot != nil
    }
}
