import Foundation
import ViewerCore

// TSK-1463 — file-tree operations: Delete (trash), New Folder, Move, and the
// open-tab retargeting that rename/move share. The disk primitives are the
// pure ViewerCore types (`FileRenamer` / `FolderCreator` / `FileMover` /
// `PathRebase`); this file is the model glue — tree refresh, tab follow,
// bookmark relocation, toast feedback. Destructive confirmation lives in the
// UI (SidebarView presents the alert); the model ops themselves are safe by
// construction: trash (recoverable) instead of unlink, and no op ever
// overwrites an existing item.
extension DocumentModel {

    // MARK: - Delete (→ Trash)

    /// Move the file/folder at `url` to the Trash — NEVER `removeItem` (the
    /// Trash keeps the delete recoverable; the unlink footgun is banned).
    /// Open tabs on the item (or beneath a trashed folder) stay open with
    /// their content and are marked `diskState == .deleted` immediately (the
    /// same signal an external delete raises), so unsaved work is never
    /// closed out from under the user — re-saving resurrects the file.
    /// Returns true when the item landed in the Trash.
    @discardableResult
    public func deleteFileToTrash(at url: URL) -> Bool {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            Obs.shared.emit(.warn, "files",
                            "Move to Trash failed: \(String(describing: error))")
            ToastCenter.shared.postError(
                "Couldn\u{2019}t move \u{201C}\(url.lastPathComponent)\u{201D} to Trash",
                reason: (error as NSError).localizedDescription)
            return false
        }
        sidebar.reloadChildren(of: url.deletingLastPathComponent())
        markOpenTabsDeleted(under: url)
        ToastCenter.shared.post(
            .success, "Moved \u{201C}\(url.lastPathComponent)\u{201D} to Trash")
        return true
    }

    /// Eagerly flag tabs whose file just went to the Trash (exact item or a
    /// descendant of a trashed folder). Deterministic — the watcher's stat
    /// sweep would get there too, but eventually.
    private func markOpenTabsDeleted(under url: URL) {
        let old = url.standardizedFileURL
        for (i, tab) in tabs.tabs.enumerated() {
            guard let tabURL = tab.url,
                  PathRebase.rebased(tabURL, from: old, to: old) != nil,
                  tab.diskState != .deleted else { continue }
            var t = tab
            t.diskState = .deleted
            tabCoordinator.replace(at: i, with: t)
        }
        updateDerived()
    }

    // MARK: - New Folder

    /// Create a non-colliding "untitled folder" in `directory`, reveal and
    /// select it in the tree. Returns the created URL, or nil on failure
    /// (logged + toasted; a sandbox denial must not crash the menu action).
    @discardableResult
    public func createNewFolder(in directory: URL) -> URL? {
        do {
            let url = try FolderCreator.create(in: directory)
            if sidebar.contains(directory) {
                sidebar.reloadChildren(of: directory)
                sidebar.setSelected(url)
            }
            return url
        } catch {
            Obs.shared.emit(.warn, "files",
                            "New Folder failed: \(String(describing: error))")
            ToastCenter.shared.postError("Couldn\u{2019}t create a new folder",
                                         reason: String(describing: error))
            return nil
        }
    }

    // MARK: - Move

    /// Move the item at `url` into `directory` (keeping its name), then
    /// refresh both tree locations, follow with open tabs, and relocate
    /// bookmarks. Never overwrites an existing destination (`FileMover`).
    /// Returns the new URL, or nil on failure (toasted).
    @discardableResult
    public func moveFile(at url: URL, to directory: URL) -> URL? {
        do {
            let newURL = try FileMover.move(url, into: directory)
            sidebar.reloadChildren(of: url.deletingLastPathComponent())
            sidebar.reloadChildren(of: directory)
            sidebar.setSelected(newURL)
            retargetOpenTabs(from: url, to: newURL)
            if bookmarksStore.relocate(from: url, to: newURL) > 0 {
                refreshBookmarks()
            }
            ToastCenter.shared.post(
                .success,
                "Moved \u{201C}\(url.lastPathComponent)\u{201D} to \(directory.lastPathComponent)")
            return newURL
        } catch {
            Obs.shared.emit(.warn, "files",
                            "Move failed: \(String(describing: error))")
            ToastCenter.shared.postError(
                "Couldn\u{2019}t move \u{201C}\(url.lastPathComponent)\u{201D}",
                reason: String(describing: error))
            return nil
        }
    }

    // MARK: - Tab follow (rename/move)

    /// Repoint open tabs after `oldURL` became `newURL` (file rename, folder
    /// rename, or move): the exact item AND anything beneath a renamed/moved
    /// folder. Follows the tab's `url`, its `.loaded`/`.preview` state URL,
    /// and the editor buffer — PRESERVING dirty text, the undo-relevant
    /// original, and the saved-fingerprint (so external-edit detection keeps
    /// working across the retarget). Returns the number of tabs retargeted.
    ///
    /// This closes the gap `renameFile` used to document as deferred ("an
    /// editor tab open on the renamed file is intentionally left as-is"):
    /// a rename no longer strands open tabs on a dead path.
    @discardableResult
    public func retargetOpenTabs(from oldURL: URL, to newURL: URL) -> Int {
        var moved = 0
        for (i, tab) in tabs.tabs.enumerated() {
            guard let tabURL = tab.url,
                  let rebased = PathRebase.rebased(tabURL, from: oldURL, to: newURL)
            else { continue }
            var t = tab
            t.url = rebased
            switch t.state {
            case .loaded(let file):
                t.state = .loaded(TextFile(
                    url: rebased,
                    contents: file.contents,
                    encoding: file.encoding,
                    byteCount: file.byteCount,
                    modifiedTime: file.modifiedTime,
                    isLargeReadOnly: file.isLargeReadOnly,
                    isExtractedReadOnly: file.isExtractedReadOnly,
                    xlsxSheets: file.xlsxSheets))
            case .preview(_, let category):
                t.state = .preview(rebased, category)
            case .empty, .binary, .error, .loading, .hostedView:
                break   // no URL payload worth rewriting mid-flight
            }
            // The rename/move didn't change CONTENT — a `.deleted` flag from
            // the watcher racing the op must not stick to the new path.
            t.diskState = .fresh
            tabCoordinator.replace(at: i, with: t)
            // Rebuild the buffer at the new URL, preserving edited text +
            // dirty state + the last-saved fingerprint (EditorBuffer.url is
            // immutable by design — the save path trusts it).
            if let buf = editorBuffer(forTabID: t.id) {
                var newBuf = EditorBuffer(
                    url: rebased,
                    original: buf.originalText,
                    encoding: buf.encoding,
                    lastSavedMTime: buf.lastSavedMTime,
                    lastSavedSize: buf.lastSavedSize,
                    isReadOnly: buf.isReadOnly)
                newBuf.setText(buf.text)
                tabCoordinator.setEditorBuffer(newBuf, forTabID: t.id)
            }
            moved += 1
        }
        if moved > 0 { updateDerived() }
        return moved
    }
}
