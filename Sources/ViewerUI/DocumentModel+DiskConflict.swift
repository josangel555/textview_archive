import Foundation
import ViewerCore

/// Non-modal disk-conflict surfacing (TSK-1166). When the file-watcher sees a
/// DIRTY buffer's file change on disk (a passive event the user didn't ask for),
/// we raise a `DiskConflictBanner` above the editor instead of the blocking
/// NSAlert. The deliberate `refreshTab` path (the user clicked Refresh) keeps its
/// modal — a modal confirm is right for an explicit destructive action, a
/// non-modal banner is right for a passive notification. Both resolution surfaces
/// funnel through `EditorCoordinator.applyExternalEditOutcome`, so they can't
/// drift on the data-safety-critical buffer handling.
public struct DiskConflictBannerInfo: Identifiable, Equatable, Sendable {
    /// The conflicted tab's id (also the Identifiable key).
    public let id: UUID
    /// The tab's index at capture time — a fallback; `resolveDiskConflict`
    /// re-locates by `id` since indices can shift.
    public let index: Int
    public let url: URL
    public var fileName: String { url.lastPathComponent }
    public init(tabID: UUID, index: Int, url: URL) {
        self.id = tabID; self.index = index; self.url = url
    }
}

extension DocumentModel {
    /// Resolve the active disk conflict with the user's chosen banner intent and
    /// clear the banner. Maps the three `DiskConflictIntent`s onto the shared
    /// `ExternalEditPrompt` side-effect (`EditorCoordinator.applyExternalEditOutcome`):
    ///   - keepMine → keep the edits, refresh the fingerprint (silence the dup event);
    ///   - takeDisk → discard the buffer + reload from disk;
    ///   - merge    → keep the edits for now (a three-way merge UI is future work,
    ///                TSK-768); the pre-conflict baseline stays reachable via Revert.
    /// No-op when there is no active conflict.
    public func resolveDiskConflict(_ intent: DiskConflictIntent) {
        guard let conflict = activeDiskConflict else { return }
        // Re-locate the tab by id (indices can shift between capture and resolve);
        // fall back to the captured index (applyExternalEditOutcome's reload path
        // re-locates by URL itself, so a stale index is tolerated).
        let index = tabs.tabs.firstIndex(where: { $0.id == conflict.id }) ?? conflict.index
        switch intent {
        case .takeDisk:
            editor.applyExternalEditOutcome(.discardAndReload, forTabID: conflict.id, at: index, url: conflict.url)
        case .keepMine, .merge:
            editor.applyExternalEditOutcome(.keepEdits, forTabID: conflict.id, at: index, url: conflict.url)
        }
        activeDiskConflict = nil
    }
}
