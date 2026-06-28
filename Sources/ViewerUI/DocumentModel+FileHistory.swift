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
        guard let url = tabs.tabs.first(where: { $0.id == id })?.url else { return }
        let path = url.standardizedFileURL.path
        let store = localHistoryStore
        let tabID = id
        // Live current content for "diff vs current". The diff loads run on a
        // detached (off-main) task, so this closure must be main-actor-safe.
        // We hold a thread-safe latest-snapshot box updated on the main actor,
        // and refresh it from the live editor buffer (falling back to disk) each
        // time the closure is read via a synchronous main-actor hop.
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
        let source = LocalHistoryVersionSource(
            store: store,
            path: path,
            displayName: url.lastPathComponent,
            currentContent: currentContent)
        let view = UnifiedHistoryView(
            doc: self,
            source: source,
            kind: .localHistory,
            onRestore: { [weak self] text in
                self?.updateEditorText(text, forTabID: tabID)
            })
        openHostedView(title: "History: \(url.lastPathComponent)", rootView: view)
    }

    /// Whether the active-or-given tab can show Local History — it has a file
    /// URL (Local History is keyed by path; an untitled buffer has none).
    public func canShowLocalHistory(forTabID id: UUID) -> Bool {
        tabs.tabs.first(where: { $0.id == id })?.url != nil
    }

    /// Open the unified Local-History viewer for a file URL (used by the sidebar
    /// file context menu, which has a URL not a tab id). If a tab is already open
    /// for `url`, Restore targets it (an undoable buffer edit); otherwise Restore
    /// is unavailable (no editor to push into) but viewing/diffing still works.
    public func openLocalHistory(for url: URL) {
        let path = url.standardizedFileURL.path
        let store = localHistoryStore
        // Find an open editable tab for this url so Restore can target it.
        let openTabID = tabs.tabs.first {
            $0.url?.standardizedFileURL.path == path
        }?.id
        let currentContent: @Sendable () -> String? = { [weak self] in
            let read: @MainActor () -> String? = {
                if let tabID = openTabID,
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
            currentContent: currentContent)
        let onRestore: ((String) -> Void)? = openTabID.map { tabID in
            { [weak self] text in self?.updateEditorText(text, forTabID: tabID) }
        }
        let view = UnifiedHistoryView(
            doc: self, source: source, kind: .localHistory, onRestore: onRestore)
        openHostedView(title: "History: \(url.lastPathComponent)", rootView: view)
    }
}
