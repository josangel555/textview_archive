import Foundation
import ViewerCore

// MARK: - Editor-pane verbs at the MODEL level (I-21, owner bug 2026-08-11)
//
// The coordinator's pane verbs change the app-wide selection through the
// COORDINATOR's `select(at:)` — which never runs `DocumentModel.selectTab`'s
// post-select work: `updateDerived()` (the model republish the sidebar/
// file-nav/footer re-body on), the follow-active-tab sidebar reveal, file
// watching, the stale-vs-disk re-check, and scroll capture/restore. The
// live symptom was the FileNav highlighting the WRONG file after pane
// interactions ("Active tab is not showing in the FileNav correctly");
// the quiet ones were skipped stale-file re-checks and watcher switches.
//
// Every UI call site drives panes through THESE verbs: coordinator overlay
// mutation first, then the full model-level `selectTab(at:)` on the
// resulting selection (idempotent — the coordinator already selected, so
// scroll capture's same-index guard no-ops and the rest runs).
extension DocumentModel {

    /// Re-run the full model-level select for whatever the coordinator's
    /// pane verb just made current.
    private func reselectThroughModel() {
        if let idx = tabCoordinator.tabs.selectedIndex {
            selectTab(at: idx)
        }
    }

    /// Focus a pane (content click / strip interactions) — the pane's
    /// remembered tab becomes the app-wide current tab, with the full
    /// select pipeline (file-nav follow, watcher, disk re-check).
    public func focusPane(id: UUID) {
        tabCoordinator.focusPane(id: id)
        reselectThroughModel()
    }

    /// Cycle focus to the next pane (View ▸ Focus Next Pane).
    public func focusNextPane() {
        tabCoordinator.focusNextPane()
        reselectThroughModel()
    }

    /// Move a tab into another pane (the cross-strip drag).
    public func movePaneTab(id tabID: UUID, toPane paneID: UUID) {
        tabCoordinator.movePaneTab(id: tabID, toPane: paneID)
        reselectThroughModel()
    }

    /// Close a pane (absorbs its tabs into the neighbor).
    public func closePane(id: UUID) {
        tabCoordinator.closePane(id: id)
        reselectThroughModel()
    }

    /// Tab context menu: tear THIS tab into a new pane to the right/left
    /// of its pane (owner ask 2026-08-11).
    public func splitPaneRight(tabID: UUID) {
        tabCoordinator.splitPane(movingTab: tabID, placement: .after)
        reselectThroughModel()
    }

    public func splitPaneLeft(tabID: UUID) {
        tabCoordinator.splitPane(movingTab: tabID, placement: .before)
        reselectThroughModel()
    }
}
