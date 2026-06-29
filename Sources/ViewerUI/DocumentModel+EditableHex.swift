import AppKit
import Foundation
import ViewerCore

// Editable HEX (TSK-1110 SRP slice; #234 / TSK-467) — the per-tab dirty-bytes
// stash + armed-edit state, the disk write-back (⌘S, watcher-paused, with the
// symlink/IO NSAlert prompts), and the close-confirm save routing. The three
// stored props (hexDirtyBytes / hexEditArmedTabs / hexSavedNotifier) stay on
// DocumentModel (extensions can't add storage). Behavior-preserving move out of
// DocumentModel.swift.
extension DocumentModel {

    /// Test-only read seam for the per-tab HEX dirty stash. Lets the
    /// headless HEX suite assert leak-freedom (every close path empties
    /// the entry) and Discard/Cancel byte behavior without exposing the
    /// mutable dict. `internal` — reachable only via `@testable import`.
    func peekHexDirtyBytesForTest(_ id: UUID) -> Data? { dirtyHexBytes(forTabID: id) }

    /// Read the pending dirty HEX bytes for a tab — the most-specific live
    /// content source for Save-a-Copy. Vends the private `hexDirtyBytes` stash
    /// WITHOUT exposing the mutable dict, so the SaveCopy extension (a separate
    /// file) reads through this rather than reaching the storage directly
    /// (TSK-1110 SRP split — keeps the HEX state encapsulated).
    func dirtyHexBytes(forTabID id: UUID) -> Data? { hexDirtyBytes[id] }

    /// Mirror the HEX edit buffer's dirty state onto `Tab.isDirty` (the
    /// TabBar dot + the close-confirm gate, both reused unchanged from the
    /// editor path). Called by `HexView` on every dirty transition.
    public func setHexDirty(_ dirty: Bool, forTabID id: UUID) {
        guard let idx = tabs.tabs.firstIndex(where: { $0.id == id }) else { return }
        if !dirty { hexDirtyBytes.removeValue(forKey: id) }
        if tabs.tabs[idx].isDirty != dirty {
            var t = tabs.tabs[idx]
            t.isDirty = dirty
            tabCoordinator.replace(at: idx, with: t)
        }
    }

    /// Stash the latest dirty bytes for a HEX tab so the model-side close
    /// save can reach them. Called by `HexView` alongside `setHexDirty`.
    public func stashHexBytes(_ data: Data, forTabID id: UUID) {
        hexDirtyBytes[id] = data
    }

    /// True when the given HEX tab has been armed for byte editing.
    public func isHexEditArmed(forTabID id: UUID) -> Bool {
        hexEditArmedTabs.contains(id)
    }

    /// Arm / disarm byte editing for a HEX tab. Republishes so the toolbar's
    /// ViewOnly checkbox + `HexView.isEditable` re-evaluate (the `.hex`
    /// `ViewMode` is unchanged, so `setCurrentViewMode`'s republish doesn't
    /// fire — we send our own, equality-guarded).
    public func setHexEditArmed(_ armed: Bool, forTabID id: UUID) {
        let changed = armed
            ? hexEditArmedTabs.insert(id).inserted
            : (hexEditArmedTabs.remove(id) != nil)
        guard changed else { return }
        objectWillChange.send()
    }

    /// Write the edited HEX bytes back to disk (⌘S). Mirrors the editor
    /// save: pause the watcher around the write, refresh the loaded
    /// `BinaryFile` so a later re-render shows the saved bytes, clear the
    /// dirty dot. Surfaces I/O / symlink failures via NSAlert and stays
    /// dirty so the next ⌘S retries.
    @discardableResult
    public func saveHexEdits(_ data: Data, forTabID id: UUID) -> Bool {
        guard let idx = tabs.tabs.firstIndex(where: { $0.id == id }),
              let url = tabs.tabs[idx].url else { return false }
        let wasWatchingURL = watchedURL
        pauseFileWatcher()
        defer { if wasWatchingURL == currentURL { startWatchingCurrentFile() } }
        do {
            try HexBinaryWriter.write(data, to: url)
        } catch let HexWriteError.targetIsSymlink(resolved) {
            let proceed = presentHexSymlinkPrompt(url: url, resolvedTarget: resolved)
            guard proceed else { return false }
            do {
                try HexBinaryWriter.write(data, to: url, allowSymlink: true)
            } catch {
                presentHexSaveFailure(url: url, error: error)
                return false
            }
        } catch {
            presentHexSaveFailure(url: url, error: error)
            return false
        }
        // Refresh the tab's loaded BinaryFile to the saved bytes so the
        // dump re-renders against the new baseline if re-entered, and the
        // edit buffer's "original" matches disk.
        var t = tabs.tabs[idx]
        let newFile = BinaryFile(url: url, data: data,
                                 totalByteCount: data.count, isTruncated: false)
        t.state = .binary(newFile)
        t.isDirty = false
        tabCoordinator.replace(at: idx, with: t)
        hexDirtyBytes.removeValue(forKey: id)
        // Tell the live controller (if mounted) to mark its buffer saved.
        hexSavedNotifier?(id)
        if let url = tabs.tabs.first(where: { $0.id == id })?.url {
            repoFocus.refreshRepo(enclosing: url)
        }
        // textDocument/didSave (TSK-464): no text payload for a binary
        // write; the pool no-ops unless this file has a live LSP session
        // (i.e. a source file the user hex-patched while it was open).
        let pool = lspPool
        Task { try? await pool.didSave(fileURL: url, text: nil) }
        return true
    }

    /// Save a HEX tab's stashed dirty bytes (close-confirm "Save" branch).
    /// Returns false when there's nothing stashed (clean / not a hex edit).
    @discardableResult
    public func saveHexEdits(forTabID id: UUID) -> Bool {
        guard let data = hexDirtyBytes[id] else { return false }
        return saveHexEdits(data, forTabID: id)
    }

    /// True when the tab at `index` is a HEX tab with pending dirty bytes
    /// (vs. a text-editor dirty tab). Lets the close paths route "Save" to
    /// the binary writer instead of the text editor writer.
    public func isHexDirtyTab(at index: Int) -> Bool {
        guard tabs.tabs.indices.contains(index) else { return false }
        return hexDirtyBytes[tabs.tabs[index].id] != nil
    }

    private func presentHexSaveFailure(url: URL, error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't save \(url.lastPathComponent)"
        alert.informativeText = "\(error)"
        alert.runModal()
    }

    /// Symlink refusal prompt — same posture as the editor writer. Returns
    /// true if the user opts to write through the link (de-symlinking).
    private func presentHexSymlinkPrompt(url: URL, resolvedTarget: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(url.lastPathComponent) is a symbolic link"
        alert.informativeText = "Saving will replace the link with a regular file "
            + "(target: \(resolvedTarget)). Continue?"
        alert.addButton(withTitle: "Replace Link")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
