import Foundation
import ViewerKit
import ViewerCore

// Lazy / multi-file tab open (TSK-1110 SRP slice) — append a tab without reading
// its contents (state stays .empty until first focus, when materializeIfNeeded
// reads it), and the multi-URL drop/open dispatcher (folders → sidebar root,
// files → all-but-last lazy + last eager). Both delegate the actual read to the
// open/materialize paths that stay on DocumentModel. Behavior-preserving move.
extension DocumentModel {

    /// Append a tab pointing at `url` without loading its contents.
    /// State stays `.empty` until the tab is selected; only then does
    /// `materializeIfNeeded(at:)` actually read the file. Workspace
    /// restore and multi-file drops use this so a 15-file session
    /// doesn't read 15 files at launch — only the focused one.
    public func appendLazyTab(url: URL, viewMode: ViewMode,
                              categoryOverride: FileCategory? = nil,
                              scrollTopLine: Int? = nil,
                              renderedScrollY: Double? = nil,
                              unsavedText: String? = nil,
                              unsavedBaseMTime: Date? = nil,
                              unsavedBaseSize: Int? = nil,
                              imageEditState: ImageEditState? = nil,
                              unsavedHexBase64: String? = nil,
                              isSplitEditing: Bool = false) {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        // Dedup invariant (matches `TabsState.openOrReveal`): never create a
        // SECOND tab for a file that's already open. `appendLazyTab` was the
        // one open-path that skipped this guard, so workspace restore (and
        // multi-file drop) appended a fresh tab per persisted entry even when
        // an identical path was already present. Combined with `makeSnapshot`
        // re-persisting the live list, that ratcheted an active session up to
        // ~2000 tabs of ~35 unique files and pushed launch footprint to ~1 GB.
        // A no-op here keeps "one tab per file" true regardless of caller.
        let key = TabsState.dedupKey(resolved)
        if tabCoordinator.tabs.tabs.contains(where: {
            $0.url.map(TabsState.dedupKey) == key
        }) {
            return
        }
        // Clamp the requested viewMode to one the URL actually
        // supports. Workspaces persisted before mode-set validation
        // could end up with e.g. `.formatted` saved against a `.md`
        // tab; restoring that as-is would bind a Picker to a value
        // not in its tag list and the ModeBar would show no
        // selection at all. Fall back to the file's defaultMode in
        // that case.
        // With a category override, mode validity is judged against the
        // OVERRIDE category's modes (e.g. a `.db` opened as Source must
        // keep .source), not the URL's extension-derived ones.
        let allowed = ViewModeOptions.availableModes(
            for: resolved, forcedCategory: categoryOverride)
        let safeMode = allowed.contains(viewMode)
            ? viewMode
            : ViewModeOptions.defaultMode(for: resolved, forcedCategory: categoryOverride)
        var lazyTab = Tab(
            url: resolved, state: .empty, viewMode: safeMode,
            categoryOverride: categoryOverride,
            // UX-K (#231): carry the persisted per-file scroll position onto
            // the lazy tab so `restoreScroll` can re-apply it once the tab
            // materializes into focus.
            scrollTopLine: scrollTopLine,
            // TSK-1041: carry the persisted rendered-markdown scroll offset so
            // `restoreScroll` can seed `renderedScrollByURL` for the WebView.
            renderedScrollY: renderedScrollY,
            // TSK-718 hot exit: carry the persisted unsaved buffer text so
            // `materializeIfNeeded` can overlay it into the editor buffer once
            // the file has been read from disk (giving the dirty baseline).
            unsavedText: unsavedText,
            // TSK-1025: carry the hot-exit-time (mtime,size) baseline so restore
            // can seed the buffer fingerprint + detect an external change.
            unsavedBaseMTime: unsavedBaseMTime,
            unsavedBaseSize: unsavedBaseSize,
            // TSK-1303: carry the persisted image edit state so
            // `restoreImageEditState` can seed `imageEditStateByURL` for the
            // recreated image editor view once the tab materializes.
            imageEditState: imageEditState)
        // Hex hot-exit (2026-08-01): carried the same way; consumed by
        // `restoreUnsavedHexIfNeeded` at materialization.
        lazyTab.unsavedHexBase64 = unsavedHexBase64
        // I-19: restore the per-tab split-editing layout.
        lazyTab.isSplitEditing = isSplitEditing
        tabCoordinator.append(lazyTab)
    }

    /// Open many URLs at once. Files are appended as lazy tabs (state
    /// = .empty, url set); only the LAST file is read into memory and
    /// gets selection, matching Finder's "drop several files, the last
    /// one wins focus" convention. Folders are routed to `openFolder`
    /// (they set the sidebar root, they are not tabs).
    ///
    /// UDC-5 (2026-05-30): the prior code lazy-appended every non-last
    /// URL unconditionally, then `openPath`'d the last. A dropped FOLDER
    /// anywhere but last became a lazy file tab; selecting it ran
    /// `controller.open` on a directory and produced a broken `.error`
    /// tab. We now partition folders from files up front so folders
    /// never enter the tab list.
    public func openMultiple(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let fm = FileManager.default
        var folders: [URL] = []
        var files: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            // A non-existent path is treated as a "file" so the user
            // still sees the standard "File not found" error tab rather
            // than silently vanishing.
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                folders.append(url)
            } else {
                files.append(url)
            }
        }
        // Folders first: each sets/updates the sidebar root. The last
        // folder wins (matches `openPath`/`openFolder` "last root wins").
        // TSK-919: skip a folder that's already the root or a descendant under
        // it — an accidental self/sub-folder drag from the nav must not re-root
        // (the intentional path is the right-click "Open Folder").
        for folder in folders
        where DropReRootPolicy.shouldReRoot(folder: folder, currentRoot: sidebar.rootURL) {
            openFolder(folder)
        }
        // Files: all but the last lazy, last eager (history-recorded,
        // watcher-bound, focused).
        for url in files.dropLast() {
            let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
            let mode = ViewModeOptions.defaultMode(
                for: resolved, preferred: preferences.viewModeDefaults)
            appendLazyTab(url: resolved, viewMode: mode)
        }
        if let lastFile = files.last {
            // `open(url:)` — not `openPath` — since we've already
            // classified this as a non-directory.
            open(url: lastFile)
        }
    }
}
