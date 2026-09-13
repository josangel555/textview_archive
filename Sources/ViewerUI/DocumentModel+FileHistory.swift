import Foundation
import Combine
import SwiftUI
import ViewerKit
import ViewerCore

// MARK: - Git File History + Local History launchers
//
// Carved out of DocumentModel.swift (TSK-1110 — DocumentModel SRP split). These
// open the in-app File-History / Local-History viewers for a file or tab, and
// gate their menu items. The `fileHistoryAvailability` cache (a stored property)
// stays on the main class (internal — these commands drive it); all other deps
// (GitClient / FileHistoryView / UnifiedHistoryView / LocalHistoryVersionSource,
// localHistoryStore / editorBuffer / updateEditorText / tabs / openHostedView /
// repoRelativePath) are already public/internal. Behaviour-identical move; no
// @Published involved → zero render risk.
extension DocumentModel {

    /// True iff `url` lives in a git repo AND is tracked — i.e. the
    /// in-app File-History view has something to show. Drives the
    /// enable/disable state of the "File History" menu items in the
    /// TabBar and sidebar context menus.
    ///
    /// **NON-BLOCKING (TSK-972).** This used to fork `git ls-files` inline,
    /// which ran on the MAIN THREAD because SwiftUI re-evaluates the
    /// `.disabled(!canShowFileHistory(...))` modifier on every menu body
    /// render (and AppKit menu validation runs main-thread too) — stalling
    /// the run loop per render and freezing the UI on a wedged repo. Now it
    /// answers from `fileHistoryAvailability`: a cached value if known, else
    /// `true` (enabled) while an off-main probe runs. When the probe lands,
    /// the cache republishes the model so the menu re-evaluates with the
    /// true value. `openFileHistory` independently re-gates, so a click
    /// during the brief unknown window is a safe no-op for an untracked file.
    public func canShowFileHistory(for url: URL) -> Bool {
        fileHistoryAvailability.availability(for: url) { [weak self] _, _ in
            // A probe resolved to a value different from what was cached —
            // republish so SwiftUI re-reads `.disabled` / AppKit re-validates.
            self?.objectWillChange.send()
        }
    }

    /// Open the in-app `FileHistoryView` for `url` as a view-hosting tab
    /// (WAVE 2b item 2). Replaces the old `showGitLog(.file)` path that
    /// rendered a synthetic markdown table. Computes the repo root via
    /// `GitClient.discoverRoot`, the path relative to that root (what
    /// `git log -- <path>` wants), and the leaf as the display name.
    /// No-op when the file isn't in a repo / isn't tracked, so callers
    /// can wire it unconditionally and rely on `canShowFileHistory` only
    /// for the menu-item enable state.
    public func openFileHistory(for url: URL) {
        guard let root = GitClient.discoverRoot(from: url),
              let rel = Self.repoRelativePath(of: url, root: root),
              !rel.isEmpty,
              GitClient(repoRoot: root).isTracked(path: rel) else { return }
        let view = FileHistoryView(
            doc: self,
            repoRoot: root,
            relativePath: rel,
            displayName: url.lastPathComponent
        )
        openHostedView(title: "History: \(url.lastPathComponent)", rootView: view)
    }

    /// Open the UNIFIED version viewer for the tab's file backed by **Local
    /// History** (TSK-1103). Lists the file's saved versions; the user can view
    /// a version, diff it vs the current (live) editor content, select a range
    /// for a cumulative diff, and **Restore** a version into the editor as an
    /// undoable edit (NOT a disk write). No-op when the tab has no file URL.
    ///
    /// `currentContent` reads the LIVE editor buffer (falling back to disk) so
    /// "diff vs current" reflects unsaved edits. `onRestore` pushes the chosen
    /// version's text through `updateEditorText` — a normal buffer edit the user
    /// can Cmd-Z and must explicitly save (which then snapshots it as a new
    /// version). This is the integration seam with the save path.
    public func openLocalHistory(forTabID id: UUID) {
        guard let url = tabs.tabs.first(where: { $0.id == id })?.url,
              let source = makeLocalHistorySource(for: url, tabID: id) else { return }
        presentLocalHistory(source: source, url: url)
    }

    /// Owner 2026-08-29 ("I see the blue/red dot and have no clue what the
    /// delta is"): open the Local History viewer on the synthetic **"On
    /// disk"** entry in diff-vs-current mode — the diff IS the unsaved delta
    /// (disk → tab). The "On disk" row is listed first whenever disk ≠ tab,
    /// and the viewer auto-selects the first row, so the delta shows at once.
    public func showUnsavedChanges(forTabID id: UUID) {
        guard let url = tabs.tabs.first(where: { $0.id == id })?.url,
              let source = makeLocalHistorySource(for: url, tabID: id) else { return }
        presentLocalHistory(source: source, url: url, initialSingleMode: .diffVsCurrent)
    }

    /// The Local-History version source for an OPEN tab: `currentContent`
    /// reads the LIVE editor buffer (falling back to disk); `diskState` reads
    /// the file itself (content + mtime), which powers the "On disk" entry.
    /// Internal so the wiring is host-testable without a view.
    func makeLocalHistorySource(for url: URL, tabID: UUID) -> LocalHistoryVersionSource? {
        let path = url.standardizedFileURL.path
        // Live current content for "diff vs current". The diff loads run on a
        // detached (off-main) task, so this closure must be main-actor-safe:
        // a synchronous main-actor hop reads the buffer each time it's called.
        let currentContent: @Sendable () -> String? = { [weak self] in
            // `DispatchQueue.main.sync` is safe here: the caller is a detached
            // background task, never the main thread (which would deadlock).
            if Thread.isMainThread {
                return MainActor.assumeIsolated {
                    self?.editorBuffer(forTabID: tabID)?.text
                        ?? (try? String(contentsOf: url, encoding: .utf8))
                }
            }
            return DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    self?.editorBuffer(forTabID: tabID)?.text
                        ?? (try? String(contentsOf: url, encoding: .utf8))
                }
            }
        }
        return LocalHistoryVersionSource(
            store: localHistoryStore,
            path: path,
            displayName: url.lastPathComponent,
            currentContent: currentContent,
            diskState: Self.diskStateReader(for: url))
    }

    /// Pure filesystem read (safe off-main): the on-disk content + mtime, or
    /// nil when the file is gone/unreadable (no "On disk" entry then).
    static func diskStateReader(for url: URL)
        -> @Sendable () -> LocalHistoryVersionSource.DiskSnapshot? {
        { () -> LocalHistoryVersionSource.DiskSnapshot? in
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            return .init(content: content, modified: modified)
        }
    }

    private func presentLocalHistory(
        source: LocalHistoryVersionSource, url: URL,
        initialSingleMode: UnifiedHistoryViewModel.SingleMode = .ownChange
    ) {
        let view = UnifiedHistoryView(
            doc: self,
            source: source,
            kind: .localHistory,
            initialSingleMode: initialSingleMode,
            onRestore: { [weak self] text in
                // TSK-1331/1462 — the unified restore path: backup-before-
                // restore, select + editor mode, then an undoable buffer edit
                // (never a disk write). Restoring the "On disk" entry = an
                // undoable revert of the unsaved edits.
                self?.restoreLocalHistoryVersion(text, at: url)
            },
            onMergePick: { [weak self] text in
                // I-08 — per-hunk picker instead of a whole-buffer swap.
                self?.beginVersionMergePick(versionText: text, url: url)
            })
        openHostedView(title: "History: \(url.lastPathComponent)", rootView: view)
    }

    /// Whether the active-or-given tab can show Local History — it has a file
    /// URL (Local History is keyed by path; an untitled buffer has none).
    public func canShowLocalHistory(forTabID id: UUID) -> Bool {
        tabs.tabs.first(where: { $0.id == id })?.url != nil
    }

    /// Open the unified Local-History viewer for a file URL (used by the sidebar
    /// file context menu, which has a URL not a tab id, and by File → Local
    /// History). Restore is ALWAYS available (TSK-1331): with an open tab it's
    /// an undoable buffer edit there; without one, `restoreLocalHistoryVersion`
    /// opens the file first and then applies — never a direct disk write.
    public func openLocalHistory(for url: URL) {
        let path = url.standardizedFileURL.path
        let store = localHistoryStore
        // Prefer an open tab's LIVE buffer for "diff vs current" so unsaved
        // edits are reflected; fall back to disk. Resolved per-read (not
        // captured) so a tab opened AFTER the viewer still wins.
        let currentContent: @Sendable () -> String? = { [weak self] in
            let read: @MainActor () -> String? = {
                if let tabID = self?.tabs.tabs.first(where: {
                       $0.url?.standardizedFileURL.path == path
                   })?.id,
                   let text = self?.editorBuffer(forTabID: tabID)?.text {
                    return text
                }
                return try? String(contentsOf: url, encoding: .utf8)
            }
            if Thread.isMainThread { return MainActor.assumeIsolated { read() } }
            return DispatchQueue.main.sync { MainActor.assumeIsolated { read() } }
        }
        let source = LocalHistoryVersionSource(
            store: store, path: path,
            displayName: url.lastPathComponent,
            currentContent: currentContent,
            diskState: Self.diskStateReader(for: url))
        presentLocalHistory(source: source, url: url)
    }

    // MARK: - Restore (TSK-1331 / TSK-1462)

    /// Outcome of `restoreLocalHistoryVersion` — Equatable so host tests pin
    /// the exact path taken.
    public enum LocalHistoryRestoreOutcome: Equatable {
        /// Applied as an undoable edit to an already-open tab.
        case appliedToOpenTab
        /// No tab was open: the file was opened first, then applied.
        case openedAndApplied
        /// Nothing was changed. `reason` is user-facing (toasted by callers).
        case failed(String)
    }

    /// Restore a Local History version's `text` for the file at `url` — the
    /// data-safety-reviewed design (A) from TSK-1331: **open-then-apply, never
    /// a direct disk write**, so the worst case is a no-op, not data loss.
    ///
    /// Steps:
    /// 1. **Backup-before-restore:** snapshot the current DISK content, and a
    ///    dirty open BUFFER's content if it differs, into Local History — so
    ///    the pre-restore state is recoverable from the same timeline even
    ///    after the user saves the restored text. Best-effort by the store's
    ///    contract (dedup/caps/failures return nil); safe because the restore
    ///    itself never touches the disk.
    /// 2. Ensure a tab: reuse the open one, else `openPath(url)`. Files with
    ///    history are ≤ the store's per-file cap (20 MB), far below the
    ///    off-main open watermark (64 MiB), so the open + buffer seed are
    ///    synchronous here.
    /// 3. Select the tab and force **editor mode** — a buffer-only restore
    ///    under a rendered pane is invisible state, the exact bug class the
    ///    focus/one-shot audits killed. If the editor mode is refused (CM6
    ///    50 MB cap) the restore FAILS honestly instead of mutating hidden
    ///    state.
    /// 4. Apply via `updateEditorText` — a normal, undoable (⌘Z) edit that the
    ///    user must explicitly save (which snapshots the restored text as a
    ///    new version via snapshot-on-save).
    @discardableResult
    public func restoreLocalHistoryVersion(
        _ text: String, at url: URL
    ) -> LocalHistoryRestoreOutcome {
        let path = url.standardizedFileURL.path
        // Fail fast on a vanished file — opening it would only produce an
        // error tab. (Resurrecting a DELETED file from history is a distinct
        // feature: it requires creating the file, i.e. a disk write this
        // deliberately-write-free path must not grow silently.)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return restoreFailure("\(url.lastPathComponent) no longer exists on disk.")
        }
        let existingTabID = tabs.tabs.first {
            $0.url?.standardizedFileURL.path == path
        }?.id

        // 1. Backup-before-restore: disk state first, then a dirty buffer's
        //    unsaved state (both no-op via dedup when already the latest).
        let now = Date()
        if let disk = try? String(contentsOf: url, encoding: .utf8) {
            localHistoryStore.snapshot(path: path, content: disk, at: now)
        }
        if let tabID = existingTabID,
           let buf = editorBuffer(forTabID: tabID), buf.isDirty {
            localHistoryStore.snapshot(path: path, content: buf.text, at: now)
        }

        // 2. Ensure a tab (sync for any history-bearing file; see doc above).
        if existingTabID == nil { openPath(url) }
        guard let tabID = tabs.tabs.first(where: {
            $0.url?.standardizedFileURL.path == path
        })?.id else {
            return restoreFailure("\(url.lastPathComponent) couldn't be opened.")
        }

        // 3. Make the restore VISIBLE: select the tab + force editor mode.
        if let idx = tabs.tabs.firstIndex(where: { $0.id == tabID }),
           tabs.selectedIndex != idx {
            selectTab(at: idx)
        }
        setCurrentViewMode(.editor)
        guard tabs.tabs.first(where: { $0.id == tabID })?.viewMode == .editor,
              editorBuffer(forTabID: tabID) != nil else {
            return restoreFailure("\(url.lastPathComponent) can't be edited (still loading or too large for the editor).")
        }

        // 4. The undoable edit.
        updateEditorText(text, forTabID: tabID)
        ToastCenter.shared.post(
            .success,
            "Restored a version of \(url.lastPathComponent)",
            detail: "⌘Z to undo · save to keep it")
        return existingTabID != nil ? .appliedToOpenTab : .openedAndApplied
    }

    /// Failure helper: surface the reason as an error toast (the standard
    /// async-outcome feedback lane) and return the outcome for callers/tests.
    private func restoreFailure(_ reason: String) -> LocalHistoryRestoreOutcome {
        ToastCenter.shared.postError("Restore failed", reason: reason)
        return .failed(reason)
    }
}
