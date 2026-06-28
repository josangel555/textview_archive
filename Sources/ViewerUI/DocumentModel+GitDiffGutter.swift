import Foundation
import Combine
import SwiftUI
import ViewerKit
import ViewerCore

// MARK: - Git diff marks for the source-view gutter (diff / blame / split)
//
// Carved out of DocumentModel.swift (TSK-1110 — DocumentModel SRP split). The
// off-main git-diff / git-blame gutter compute for the source view + the split
// pane. The @Published `sourceDiffMarks` (private(set)) + the in-flight task
// handles stay on the class: `sourceDiffMarks` is written via the vended
// `setSourceDiffMarks(_:)`; `diffMarksTask`/`splitDiffMarksTask` widened
// private→internal so these detached bodies can cancel/reassign them.
// `editorBlameActive` (@Published public) + the editor-folds (refreshEditorFolds /
// editorFoldsTask) + sticky-scroll + loadedText helpers stay on the class
// (separate concerns). `resolveGutterRoot` / `relativePath` are exclusive to
// these git funcs, so they move with the group (pattern c).
extension DocumentModel {
    /// Wall-clock cap for the gutter's `git diff` (CHANGE 3). On timeout
    /// we leave the prior markers rather than clearing. `nonisolated` so
    /// the `Task.detached` diff bodies can read it off-main.
    private nonisolated static let gutterDiffTimeout: TimeInterval = 3

    /// Debounce window for the off-main `git diff` that feeds the
    /// source-view diff stripe. A flurry of `updateDerived()` calls
    /// (opening many files, keystroke-rate watcher/save events) all
    /// funnel through `refreshDiffMarks`; sleeping this long before the
    /// git invocation collapses the burst into one process per
    /// quiescent window. MAGIC-005: named so the timing isn't an
    /// unexplained literal at the call site.
    private static let diffMarksDebounceNanos: UInt64 = 150_000_000  // 150 ms

    /// Recompute `sourceDiffMarks` by shelling out to `git diff` for
    /// the current file. Off-main; main-actor publish at the end.
    /// Cancels any prior in-flight task before launching the new one
    /// so a flurry of `updateDerived()` calls (e.g. opening 50 files
    /// via "Open Recent") doesn't pile up 50 git processes.
    ///
    /// CHANGE 1 (root sharing): resolve the repo root via the multi-repo
    /// registry (`trackedRepos.repoRoot(enclosing:)`) so we reuse its
    /// cached resolution + the per-root watcher that's already running.
    /// Falls back to `GitClient.discoverRoot` if the file's repo isn't
    /// tracked yet (it will be — opening the tab triggers
    /// `repoFocus.recompute()` which retains it).
    /// TSK-672/814: when blame mode is on, the editor gutter shows per-line
    /// authorship instead of diff bars. Toggled via `toggleEditorBlame()` /
    /// the "Toggle Git Blame" command. `refreshDiffMarks` is the central
    /// gutter-refresh (fired on file open/switch/save/watch), so routing it to
    /// blame here makes blame survive tab switches without a separate hook.
    public func refreshDiffMarks() {
        if editorBlameActive { refreshBlameMarks(); return }
        diffMarksTask?.cancel()
        guard let url = currentURL,
              let repoRoot = resolveGutterRoot(for: url)
        else {
            if !sourceDiffMarks.isEmpty { setSourceDiffMarks([:]) }
            diffMarksTask = nil
            return
        }
        let relPath = Self.relativePath(of: url, under: repoRoot)
        let token = url
        diffMarksTask = Task.detached(priority: .userInitiated) { [weak self] in
            // Debounce: if the user is rapidly switching tabs, we'll be
            // cancelled before the git invocation even starts. Same
            // window protects against keystroke-rate calls — the file-
            // watcher / save / external-edit feed all funnel through
            // here, so we get one git process per quiescent window
            // rather than one per event.
            try? await Task.sleep(nanoseconds: Self.diffMarksDebounceNanos)
            if Task.isCancelled { return }
            // CHANGE 3: per-call 3s wall-clock timeout on the diff.
            let client = GitClient(repoRoot: repoRoot, statusTimeout: Self.gutterDiffTimeout)
            let diff = client.diff(forPath: relPath)
            if Task.isCancelled { return }
            // Routed: Rust engine per the `.diff` gate, Swift fallback
            // inside the adapter (TSK-561 closed the gutter routing gap).
            let marks = RustDiffAdapter.hunkMarks(diff)
            // Build the CM6 marker payload off-main so the main-actor
            // hop below is just an assignment. `markers(from:)` is a
            // sort + map; cheap, but no point doing it on the main thread.
            let cmMarkers = DiffGutterFeeder.markers(from: marks)
            await MainActor.run { [weak self] in
                guard let self, self.currentURL == token else { return }
                self.setSourceDiffMarks(marks)
                // Mirror into the CM6 editor's pending-marker channel.
                // `setEditorGutterMarkers` resolves URL → tab itself so a
                // tab-switch racing the task completion can't mis-route.
                self.editor.setEditorGutterMarkers(cmMarkers, forURL: token)
            }
        }
    }

    /// TSK-814: feed the editor gutter with per-line git blame for the active
    /// file. Mirrors `refreshDiffMarks` (off-main git + a marker feeder routed
    /// through the same `setEditorGutterMarkers` channel), but produces
    /// `"blame"`-kind markers with author/time/summary tooltips. Reaped/replaced
    /// when blame mode turns off (the diff refresh resumes via the route-guard).
    public func refreshBlameMarks() {
        diffMarksTask?.cancel()
        guard editorBlameActive, let url = currentURL,
              let repoRoot = resolveGutterRoot(for: url)
        else { diffMarksTask = nil; return }
        let relPath = Self.relativePath(of: url, under: repoRoot)
        let token = url
        diffMarksTask = Task.detached(priority: .userInitiated) { [weak self] in
            try? await Task.sleep(nanoseconds: Self.diffMarksDebounceNanos)
            if Task.isCancelled { return }
            let client = GitClient(repoRoot: repoRoot, statusTimeout: Self.gutterDiffTimeout)
            let blame = client.blame(path: relPath)
            if Task.isCancelled { return }
            let cmMarkers = BlameGutterFeeder.markers(from: blame)
            await MainActor.run { [weak self] in
                guard let self, self.currentURL == token, self.editorBlameActive else { return }
                self.editor.setEditorGutterMarkers(cmMarkers, forURL: token)
            }
        }
    }

    /// Toggle the editor blame gutter (the "Toggle Git Blame" command / verb).
    /// Routes through `refreshDiffMarks`, which dispatches to blame-or-diff per
    /// `editorBlameActive` — so turning blame OFF restores the diff bars.
    public func toggleEditorBlame() {
        editorBlameActive.toggle()
        refreshDiffMarks()
    }

    /// CHANGE 2 (split coverage): refresh the SPLIT pane's gutter diff.
    /// The split pane's file gets NO gutter marks today — `refreshDiffMarks`
    /// only runs for `currentURL`. This parallel path keys on `splitURL`,
    /// pushing markers via `editor.setEditorGutterMarkers(_, forURL:)`,
    /// which makes "two repos colored simultaneously" true for gutters in
    /// split view. Shares the same debounce / cancel / per-tab routing
    /// shape; the split pane may resolve to a DIFFERENT repo than the
    /// primary pane. Does NOT publish `sourceDiffMarks` (that's the
    /// primary pane's source-view stripe only).
    public func refreshSplitDiffMarks() {
        splitDiffMarksTask?.cancel()
        guard let url = tabCoordinator.splitURL,
              let repoRoot = resolveGutterRoot(for: url)
        else {
            splitDiffMarksTask = nil
            return
        }
        let relPath = Self.relativePath(of: url, under: repoRoot)
        let token = url
        splitDiffMarksTask = Task.detached(priority: .userInitiated) { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            if Task.isCancelled { return }
            let client = GitClient(repoRoot: repoRoot, statusTimeout: Self.gutterDiffTimeout)
            let diff = client.diff(forPath: relPath)
            if Task.isCancelled { return }
            let marks = RustDiffAdapter.hunkMarks(diff)
            let cmMarkers = DiffGutterFeeder.markers(from: marks)
            await MainActor.run { [weak self] in
                guard let self, self.tabCoordinator.splitURL == token else { return }
                self.editor.setEditorGutterMarkers(cmMarkers, forURL: token)
            }
        }
    }

    /// Resolve the gutter's repo root via the registry first (shared
    /// cached resolution + already-running watcher), falling back to a
    /// fresh `.git` walk for files in not-yet-tracked repos.
    private func resolveGutterRoot(for url: URL) -> URL? {
        if let root = trackedRepos.repoRoot(enclosing: url) { return root }
        return GitClient.discoverRoot(from: url)
    }

    /// Path of `url` relative to `root` (forward-slashed, normalized),
    /// or the absolute path if `url` isn't under `root`.
    private static func relativePath(of url: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let filePath = url.standardizedFileURL.resolvingSymlinksInPath().path
        if filePath.hasPrefix(rootPath + "/") {
            return String(filePath.dropFirst(rootPath.count + 1))
        }
        return filePath
    }
}
