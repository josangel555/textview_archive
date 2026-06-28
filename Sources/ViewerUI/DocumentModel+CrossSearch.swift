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
        crossSearchQuery = ""
        crossSearchResults = []
        crossSearchIsRunning = false
        crossSearchPresetScope = nil
        crossSearchRegexError = nil
        crossSearchGeneration &+= 1  // invalidate any in-flight search
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
        guard let root = scope ?? sidebar.rootURL else {
            crossSearchResults = []
            return
        }
        let q = crossSearchQuery
        guard !q.isEmpty else {
            crossSearchResults = []
            crossSearchIsRunning = false
            crossSearchRegexError = nil
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
            crossSearchGeneration &+= 1
            return
        }
        crossSearchRegexError = nil
        let filenameMode = crossSearchFilenameMode
        var opts = CrossFileSearch.Options()
        opts.caseSensitive = crossSearchCaseSensitive
        opts.useRegex = crossSearchUseRegex
        crossSearchIsRunning = true
        crossSearchGeneration &+= 1
        let gen = crossSearchGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self, opts, q] in
            let results = filenameMode
                ? CrossFileSearch.searchFilenames(root: root, query: q, options: opts)
                : CrossFileSearch.search(root: root, query: q, options: opts)
            DispatchQueue.main.async {
                guard let self, self.crossSearchGeneration == gen else { return }
                self.crossSearchResults = results
                self.crossSearchIsRunning = false
            }
        }
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
