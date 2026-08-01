import AppKit
import Foundation
import ViewerCore

// Editable HEX (TSK-1110 SRP slice; #234 / TSK-467) — the per-tab dirty-bytes
// stash + armed-edit state, the disk write-back (⌘S, watcher-paused, with the
// symlink/IO NSAlert prompts), and the close-confirm save routing. The three
// stored props (hexDirtyBytes / hexEditArmedTabs / hexSavedNotifier) stay on
// DocumentModel (extensions can't add storage). Behavior-preserving move out of
// DocumentModel.swift.
/// Disk fingerprint for the hex no-clobber baseline. mtime+size — the same
/// signal `EditorBuffer` uses; content hashing a multi-GB binary per save
/// would be absurd, and this catches every editor/tool write in practice.
struct HexDiskStamp: Equatable {
    let mtime: Date?
    let size: Int?

    static func current(for url: URL) -> HexDiskStamp {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return HexDiskStamp(mtime: attrs?[.modificationDate] as? Date,
                            size: attrs?[.size] as? Int)
    }
}

/// The user's answer to "the file changed on disk since you loaded it".
enum HexOverwriteChoice: String {
    case overwrite
    case cancel
}

extension DocumentModel {

    /// Test-only read seam for the per-tab HEX dirty stash. Lets the
    /// headless HEX suite assert leak-freedom (every close path empties
    /// the entry) and Discard/Cancel byte behavior without exposing the
    /// mutable dict. `internal` — reachable only via `@testable import`.
    func peekHexDirtyBytesForTest(_ id: UUID) -> Data? { dirtyHexBytes(forTabID: id) }

    /// Read the pending dirty HEX bytes for a tab — the most-specific live
    /// Hex hot-exit inline cap (2026-08-01): base64 of this rides INSIDE the
    /// session snapshot json, whose READ cap is 8 MiB shared with every
    /// other tab's state — half a MiB of raw bytes (≈700 KB base64) keeps a
    /// pathological multi-tab case far from the cliff. Over-cap edits are
    /// NOT captured and the user is TOLD (never a silent drop).
    static let hexHotExitMaxBytes = 512 * 1024

    /// Fold each hex-dirty tab's stashed bytes onto `Tab.unsavedHexBase64`
    /// so the session snapshot carries them across a switch/relaunch —
    /// hex was the one buffer class the hot-exit machinery dropped
    /// (`closeAllTabsPreservingDirty` still clears the id-keyed stash; the
    /// snapshot travels by PATH). Same boundary + idempotence contract as
    /// `captureUnsavedTextForAllTabs`.
    public func captureUnsavedHexForAllTabs() {
        for index in tabs.tabs.indices {
            let tab = tabs.tabs[index]
            var captured: String? = nil
            if let bytes = hexDirtyBytes[tab.id] {
                if bytes.count <= Self.hexHotExitMaxBytes {
                    captured = bytes.base64EncodedString()
                } else {
                    ToastCenter.shared.post(.error,
                        "\(tab.title): hex edits are too large to carry across "
                        + "a session switch — save (⌘S) to keep them")
                }
            }
            guard tab.unsavedHexBase64 != captured else { continue }
            var t = tab
            t.unsavedHexBase64 = captured
            tabCoordinator.replace(at: index, with: t)
        }
    }

    /// Re-inject persisted unsaved hex bytes into a tab that materialized
    /// from a session restore: re-stash + mark dirty, so ⌘S/close-confirm
    /// operate on the restored bytes and the hex view seeds from the stash
    /// (`HexView`'s identity-change branch consults it). Mirrors
    /// `restoreUnsavedTextIfNeeded`. Returns whether it restored (test hook).
    @discardableResult
    func restoreUnsavedHexIfNeeded(forTabAt index: Int) -> Bool {
        guard tabs.tabs.indices.contains(index) else { return false }
        let tab = tabs.tabs[index]
        guard let b64 = tab.unsavedHexBase64,
              let bytes = Data(base64Encoded: b64), !bytes.isEmpty else { return false }
        stashHexBytes(bytes, forTabID: tab.id)
        setHexDirty(true, forTabID: tab.id)
        return true
    }

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
        // Write-time no-clobber guard (audit THEME 1, fixed 2026-07-29). The
        // TEXT save path has always re-stat'ed the file and prompted before
        // overwriting an external change; the hex path wrote blind — an
        // external write between load and ⌘S was silently destroyed by the
        // (possibly stale) stash. Binary content can't be preserved in Local
        // History (it refuses non-text), so the protection is the explicit
        // prompt: overwrite is a choice, never a default. Cancel is default.
        if let base = hexDiskBaseline[id], HexDiskStamp.current(for: url) != base {
            let choice = hexOverwritePromptOverride?(url)
                ?? runHexOverwriteAlert(url: url)
            guard choice == .overwrite else { return false }
        }
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
        // Re-baseline against the bytes we just wrote, so the next save's
        // guard compares against THIS write, not the original load.
        hexDiskBaseline[id] = HexDiskStamp.current(for: url)
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

    /// The write-time conflict modal. Cancel is the default button — the
    /// safe answer when overwriting someone else's change. "Save a Copy…"
    /// is reachable via File ▸ Save a Copy, named in the copy so the safe
    /// exit is discoverable. Never runs under the headless gate (tests
    /// install `hexOverwritePromptOverride`).
    private func runHexOverwriteAlert(url: URL) -> HexOverwriteChoice {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "\(url.lastPathComponent) changed on disk since you loaded it"
        alert.informativeText =
            "Saving your hex edits now would overwrite the change made by "
            + "another program — and a copy of the current file can't be kept "
            + "(Local History doesn't store binary content). To keep both, "
            + "cancel and use File ▸ Save a Copy first."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Overwrite")
        return alert.runModal() == .alertFirstButtonReturn ? .cancel : .overwrite
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
