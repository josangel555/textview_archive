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

/// An open 3-pane merge: the conflict it belongs to plus the model driving the
/// sheet. Identifiable so SwiftUI can present it with `sheet(item:)`.
public struct ConflictResolutionSession: Identifiable {
    public let id: UUID          // the tab id
    public let url: URL
    public let model: ConflictResolutionModel
    public var fileName: String { url.lastPathComponent }
    public init(tabID: UUID, url: URL, model: ConflictResolutionModel) {
        self.id = tabID; self.url = url; self.model = model
    }
}

extension DocumentModel {
    /// Resolve the active disk conflict with the user's chosen banner intent.
    ///
    /// ## The rule (owner directive, 2026-07-28)
    ///
    /// Nothing is deleted and nothing is chosen silently. Each branch first
    /// captures the side it is about to lose into Local History and CHECKS that
    /// capture (`DocumentModel+ConflictPreservation`); a refused capture asks
    /// the user rather than quietly destroying the content.
    ///
    /// - **keepMine** — keeps the edits and re-baselines against disk, which
    ///   means the next ⌘S overwrites the external write. So the DISK text is
    ///   captured first: the external change stays recoverable from Local
    ///   History even though the file will be overwritten.
    /// - **takeDisk** — discards the unsaved buffer, so MY text is captured
    ///   first.
    /// - **merge** — opens the real 3-pane merge. It previously fell through to
    ///   `.keepEdits`, i.e. the button silently did Keep Mine while claiming to
    ///   merge; the resolution stack (TSK-1171) existed but had no caller.
    ///
    /// No-op when there is no active conflict. Cancelling an unpreserved-discard
    /// prompt leaves the banner up so the user can choose again.
    public func resolveDiskConflict(_ intent: DiskConflictIntent) {
        guard let conflict = activeDiskConflict else { return }
        // Re-locate the tab by id (indices can shift between capture and resolve);
        // fall back to the captured index (applyExternalEditOutcome's reload path
        // re-locates by URL itself, so a stale index is tolerated).
        let index = tabs.tabs.firstIndex(where: { $0.id == conflict.id }) ?? conflict.index
        let path = conflict.url.path

        // HEX conflicts (audit THEME 1): a hex tab has no editor buffer, so
        // the text branches below would silently no-op around it. Binary
        // content also can't be preserved in Local History (it refuses
        // non-text), so BOTH destructive branches route through the
        // unpreserved-discard confirmation — the honest "no copy can be
        // kept" prompt — rather than pretending a safety net exists.
        if dirtyHexBytes(forTabID: conflict.id) != nil {
            resolveHexDiskConflict(intent, conflict: conflict, index: index)
            return
        }

        switch intent {
        case .takeDisk:
            // About to destroy the unsaved buffer — preserve it first.
            let mine = editor.editorBuffers[conflict.id]?.text ?? ""
            let outcome = preserveConflictSide(.mine, text: mine, path: path)
            guard confirmDiscardIsPreserved(outcome, side: .mine,
                                            fileName: conflict.fileName) else { return }
            editor.applyExternalEditOutcome(
                .discardAndReload, forTabID: conflict.id, at: index, url: conflict.url)

        case .keepMine:
            // The external write survives on disk only until the next save, and
            // the fingerprint refresh below makes the app forget it happened.
            // Capture it so "Keep Mine" can never mean "silently destroy their
            // change".
            if let disk = diskText(forTabID: conflict.id, url: conflict.url) {
                let outcome = preserveConflictSide(.disk, text: disk, path: path)
                guard confirmDiscardIsPreserved(outcome, side: .disk,
                                                fileName: conflict.fileName) else { return }
            }
            editor.applyExternalEditOutcome(
                .keepEdits, forTabID: conflict.id, at: index, url: conflict.url)

        case .merge:
            beginMergeForActiveConflict(conflict)
            return   // banner stays until the sheet resolves
        }
        activeDiskConflict = nil
    }

    /// The hex arm of `resolveDiskConflict`. No auto-merge and no Local
    /// History for binary, so the rules collapse to:
    /// - **takeDisk** — the dirty hex edits are about to be destroyed with no
    ///   recoverable copy → explicit confirm, then drop the stash and reload.
    /// - **keepMine** — the external disk version will be overwritten by the
    ///   next ⌘S with no recoverable copy → the SAME explicit confirm, then
    ///   re-baseline so the watcher stops re-raising and the save guard
    ///   honours the user's decision.
    /// - **merge** — impossible for binary; say so and leave the banner up.
    private func resolveHexDiskConflict(
        _ intent: DiskConflictIntent, conflict: DiskConflictBannerInfo, index: Int
    ) {
        switch intent {
        case .takeDisk:
            guard confirmDiscardIsPreserved(.refused(.looksBinary), side: .mine,
                                            fileName: conflict.fileName) else { return }
            setHexDirty(false, forTabID: conflict.id)   // drops the stash + the dot
            hexDiskBaseline[conflict.id] = HexDiskStamp.current(for: conflict.url)
            reloadFromDisk(url: conflict.url, at: index)

        case .keepMine:
            guard confirmDiscardIsPreserved(.refused(.looksBinary), side: .disk,
                                            fileName: conflict.fileName) else { return }
            hexDiskBaseline[conflict.id] = HexDiskStamp.current(for: conflict.url)

        case .merge:
            ToastCenter.shared.post(.error,
                "Can't merge binary content — choose Keep Mine or Take Disk")
            return   // banner stays up
        }
        activeDiskConflict = nil
    }

    /// Open the 3-pane merge for `conflict`, capturing BOTH sides first — the
    /// merged result replaces the buffer, so the pre-merge "mine" would
    /// otherwise be unrecoverable.
    ///
    /// When the two sides don't actually overlap there is nothing to resolve by
    /// hand: `beginConflictResolution` returns nil and we apply the clean 3-way
    /// auto-merge instead — announced by a toast, never silent, and with both
    /// inputs already in Local History.
    private func beginMergeForActiveConflict(_ conflict: DiskConflictBannerInfo) {
        let path = conflict.url.path
        let mine = editor.editorBuffers[conflict.id]?.text ?? ""
        let mineOutcome = preserveConflictSide(.mine, text: mine, path: path)
        guard confirmDiscardIsPreserved(mineOutcome, side: .mine,
                                        fileName: conflict.fileName) else { return }
        if let disk = diskText(forTabID: conflict.id, url: conflict.url) {
            _ = preserveConflictSide(.disk, text: disk, path: path)
        }

        if let model = beginConflictResolution(forTabID: conflict.id, url: conflict.url) {
            activeConflictResolution = ConflictResolutionSession(
                tabID: conflict.id, url: conflict.url, model: model)
            return
        }

        // No overlapping regions → a clean auto-merge keeps BOTH sides' work.
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        if applyExternalAutoMerge(
            forTabID: conflict.id, url: conflict.url,
            diskMTime: attrs?[.modificationDate] as? Date,
            diskSize: attrs?[.size] as? Int) {
            activeDiskConflict = nil
        } else {
            // Nothing merged (no buffer / unreadable disk) — say so and leave
            // the banner up rather than picking a side behind the user's back.
            ToastCenter.shared.post(.error,
                "Couldn't merge \(conflict.fileName) — choose Keep Mine or Take Disk")
        }
    }

    /// Apply the user's resolved text from the merge sheet. The buffer stays
    /// DIRTY (the user still saves the resolution) and the disk fingerprint is
    /// refreshed so the same external change doesn't immediately re-fire.
    public func applyActiveConflictResolution(_ text: String) {
        guard let session = activeConflictResolution else { return }
        let attrs = try? FileManager.default.attributesOfItem(atPath: session.url.path)
        _ = applyConflictResolution(
            text, forTabID: session.id,
            diskMTime: attrs?[.modificationDate] as? Date,
            diskSize: attrs?[.size] as? Int)
        activeConflictResolution = nil
        activeDiskConflict = nil
        ToastCenter.shared.post(.info, "Merged \(session.fileName) — save to write it to disk")
    }

    /// Dismiss the merge sheet WITHOUT choosing a side: the conflict banner
    /// stays up so the user can pick again. Cancelling must never resolve.
    public func cancelActiveConflictResolution() {
        activeConflictResolution = nil
    }
}
