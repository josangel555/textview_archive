import Foundation
import Combine
import SwiftUI
import ViewerKit
import ViewerCore

// MARK: - Cross-file search + replace commands
//
// Carved out of DocumentModel.swift (TSK-1110 — DocumentModel SRP split). These
// are the command methods that drive the unified cross-file search/replace
// panel. The @Published cross-search state (query/results/flags/scope/…) stays
// on the main class, as does the `crossSearchGeneration` cancellation counter
// (a stored property — it's `internal` rather than `private` precisely so these
// extracted commands can drive it). No @Published moves → no observation change
// → zero render risk; behaviour-identical to the inline versions.
/// TSK-1465 — live walk feedback for the cross-search panel.
public struct CrossSearchProgress: Equatable, Sendable {
    /// Filesystem entries visited so far (files + dirs — the walk's unit).
    public let scanned: Int
    /// Matches folded so far.
    public let matches: Int
    public init(scanned: Int, matches: Int) {
        self.scanned = scanned
        self.matches = matches
    }
}

/// TSK-1465 — cooperative cancel handle shared between the main actor (the
/// Cancel button) and the background walk (polled at the engine's cancel
/// stride). Lock-protected Bool; `@unchecked Sendable` because all access
/// goes through the lock.
public final class CrossSearchCancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
    }

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }
}

extension DocumentModel {

    public func showCrossSearch() {
        isCrossSearchPresented = true
    }

    /// Open the unified search panel with `scope` pre-applied. Used by
    /// the sidebar folder-row "Search in Folder" item — the panel's
    /// onAppear hook syncs the picker state to this preset and clears
    /// it. See `FileRowContextMenu` for the call site.
    public func showCrossSearch(scope: SearchScope) {
        crossSearchPresetScope = scope
        isCrossSearchPresented = true
    }

    /// TSK-677 — unified search routing hand-off. When the command palette is in
    /// global-search mode (`?term`) and the user submits, the palette routes
    /// here: pre-fill the cross-file query, surface the overlay, and kick the
    /// existing grep. This makes the palette a single front door that dispatches
    /// to the SAME cross-file engine the `SearchAnywhereSection` / cross-search
    /// panel use — no second scanner. `query` is the already-trimmed term from
    /// `SearchRouter.SubmitAction.runGlobalSearch`.
    public func openGlobalSearch(query: String) {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        crossSearchQuery = q
        isCrossSearchPresented = true
        runCrossSearch()
    }

    public func dismissCrossSearch() {
        isCrossSearchPresented = false
        // TSK-1465 — the QUERY survives the dismiss (persist-last-query):
        // reopening the panel re-runs it via the panel's onAppear hook, so
        // "close, check something, reopen" doesn't retype the search.
        crossSearchResults = []
        crossSearchIsRunning = false
        crossSearchPresetScope = nil
        crossSearchRegexError = nil
        crossSearchProgress = nil
        crossSearchReplacePreview = nil
        crossSearchCancelToken?.cancel()
        crossSearchGeneration &+= 1  // invalidate any in-flight search
    }

    /// TSK-1465 — stop the current walk, keep what it found. Trips the
    /// cooperative token (the engine breaks at its next stride) WITHOUT
    /// bumping the generation, so the walk's early return still lands as
    /// partial results. The spinner clears when they do.
    public func cancelCrossSearch() {
        crossSearchCancelToken?.cancel()
    }

    /// Runs a cross-file search. `scope` overrides the search root —
    /// pass a folder URL to limit the grep to that folder. When `nil`,
    /// falls back to the sidebar's current root; if neither is set,
    /// this is a no-op (sets results to empty).
    ///
    /// The two-argument variant lets the unified search panel's scope
    /// picker target a different folder than the sidebar root (e.g.
    /// "Search in Folder" from a tree right-click). Callers that
    /// want sidebar-root behavior can keep using `runCrossSearch()`.
    public func runCrossSearch(scope: URL? = nil) {
        // A new run supersedes any pending replace preview (it summarized
        // the OLD result set) and any prior walk (cancel it cooperatively).
        crossSearchReplacePreview = nil
        crossSearchCancelToken?.cancel()
        guard let root = scope ?? sidebar.rootURL else {
            crossSearchResults = []
            return
        }
        let q = crossSearchQuery
        guard !q.isEmpty else {
            crossSearchResults = []
            crossSearchIsRunning = false
            crossSearchRegexError = nil
            crossSearchProgress = nil
            crossSearchGeneration &+= 1  // cancel any in-flight search
            return
        }
        // TSK-758 — regex mode: reject ReDoS/invalid patterns up front so the
        // panel can show why instead of silently returning "No matches".
        if crossSearchUseRegex,
           let reason = CrossFileSearch.validateRegex(q, caseSensitive: crossSearchCaseSensitive) {
            crossSearchRegexError = reason
            crossSearchResults = []
            crossSearchIsRunning = false
            crossSearchProgress = nil
            crossSearchGeneration &+= 1
            return
        }
        crossSearchRegexError = nil
        let filenameMode = crossSearchFilenameMode
        var opts = CrossFileSearch.Options()
        opts.caseSensitive = crossSearchCaseSensitive
        opts.useRegex = crossSearchUseRegex
        crossSearchIsRunning = true
        crossSearchProgress = CrossSearchProgress(scanned: 0, matches: 0)
        crossSearchGeneration &+= 1
        let gen = crossSearchGeneration
        // TSK-1465 — cooperative cancel + live progress. The token is polled
        // by the walk every cancel stride; progress hops to the main actor at
        // the same stride (a few Hz on a big tree — no flooding).
        let token = CrossSearchCancelToken()
        crossSearchCancelToken = token
        let onProgress: @Sendable (Int, Int) -> Void = { [weak self] scanned, matches in
            DispatchQueue.main.async {
                guard let self, self.crossSearchGeneration == gen else { return }
                self.crossSearchProgress = CrossSearchProgress(scanned: scanned, matches: matches)
            }
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self, opts, q] in
            let results = filenameMode
                ? CrossFileSearch.searchFilenames(
                    root: root, query: q, options: opts,
                    isCancelled: { token.isCancelled }, onProgress: onProgress)
                : CrossFileSearch.search(
                    root: root, query: q, options: opts,
                    isCancelled: { token.isCancelled }, onProgress: onProgress)
            DispatchQueue.main.async {
                guard let self, self.crossSearchGeneration == gen else { return }
                // A cancelled walk still lands here (same generation) with
                // whatever it found before the token tripped — deliberate.
                self.crossSearchResults = results
                self.crossSearchIsRunning = false
                self.crossSearchProgress = nil
            }
        }
    }

    /// TSK-1465 — the SAFE-replace first step: compute what a replace WOULD do
    /// (per-file counts + failures) without writing a byte, and publish it as
    /// the panel's confirm step. `confirmCrossFileReplace()` applies;
    /// `cancelCrossFileReplacePreview()` discards. Runs the same read/count
    /// path as the real apply (shared engine core), off-main.
    public func runCrossFileReplacePreview() {
        guard !crossSearchFilenameMode else { return }
        let files = crossSearchResults.map(\.url)
        let q = crossSearchQuery
        guard !files.isEmpty, !q.isEmpty else { return }
        let replacement = crossSearchReplacement
        let caseSensitive = crossSearchCaseSensitive
        let useRegex = crossSearchUseRegex
        crossSearchReplaceStatus = nil
        let gen = crossSearchGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self, files, q] in
            let outcomes = CrossFileReplace.preview(
                toFiles: files, query: q, replacement: replacement,
                caseSensitive: caseSensitive, useRegex: useRegex)
            DispatchQueue.main.async {
                guard let self, self.crossSearchGeneration == gen else { return }
                self.crossSearchReplacePreview = outcomes
            }
        }
    }

    /// TSK-1465 — the confirm step: clear the preview and run the real apply.
    public func confirmCrossFileReplace() {
        crossSearchReplacePreview = nil
        runCrossFileReplace()
    }

    /// TSK-1465 — back out of the confirm step; nothing was written.
    public func cancelCrossFileReplacePreview() {
        crossSearchReplacePreview = nil
    }

    /// TSK-726 — apply `crossSearchReplacement` across every file in the current
    /// cross-search results (the user reviewed the matches, now rewrites them).
    /// Runs `CrossFileReplace.apply` off-main (it re-reads + atomically
    /// rewrites files preserving encoding / permissions / symlinks), then posts
    /// a one-line status and clears the stale results so the panel doesn't show
    /// matches that no longer exist. The open-tab side (an editor showing a
    /// rewritten file) is handled by the existing disk-watcher staleness path;
    /// a DIRTY buffer is never clobbered (the engine writes disk, not buffers).
    /// No-op in filename-search mode (nothing to replace inside file contents).
    public func runCrossFileReplace() {
        guard !crossSearchFilenameMode else { return }
        let files = crossSearchResults.map(\.url)
        let q = crossSearchQuery
        guard !files.isEmpty, !q.isEmpty else { return }
        let replacement = crossSearchReplacement
        let caseSensitive = crossSearchCaseSensitive
        let useRegex = crossSearchUseRegex
        crossSearchIsRunning = true
        crossSearchReplaceStatus = nil
        crossSearchGeneration &+= 1  // invalidate any in-flight search
        DispatchQueue.global(qos: .userInitiated).async { [weak self, files, q] in
            let outcomes = CrossFileReplace.apply(
                toFiles: files, query: q, replacement: replacement,
                caseSensitive: caseSensitive, useRegex: useRegex)
            let summary = CrossFileReplace.Summary(outcomes: outcomes)
            DispatchQueue.main.async {
                guard let self else { return }
                self.crossSearchReplaceStatus = DocumentModel.replaceStatusText(summary)
                self.crossSearchResults = []   // matches are stale post-rewrite
                self.crossSearchIsRunning = false
            }
        }
    }

    /// Pure one-line summary of a project-wide replace, for the panel status.
    /// Pluralized; appends a failure tail when some files couldn't be written.
    static func replaceStatusText(_ summary: CrossFileReplace.Summary) -> String {
        let occ = summary.totalReplacements
        let files = summary.filesChanged
        let base: String
        if occ == 0 {
            base = "No occurrences replaced"
        } else {
            let o = occ == 1 ? "1 occurrence" : "\(occ) occurrences"
            let f = files == 1 ? "1 file" : "\(files) files"
            base = "Replaced \(o) in \(f)"
        }
        guard !summary.failures.isEmpty else { return base }
        let n = summary.failures.count
        return "\(base) · \(n) file\(n == 1 ? "" : "s") failed"
    }
}
