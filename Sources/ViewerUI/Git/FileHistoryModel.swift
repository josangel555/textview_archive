import Foundation
import SwiftUI
import ViewerCore

/// View-model for `FileHistoryView`. Owns the commit list, the
/// click-driven selection state machine, and the off-main diff load.
///
/// Concurrency: `@MainActor` so SwiftUI observes it safely; the
/// blocking git work (`fileHistory`, `diff`) runs on `Task.detached`
/// and hands back `Sendable` values (`[GitClient.LogEntry]` / `String`).
/// Each new diff request cancels the prior one so rapid clicking can't
/// stack stale results (last-write-wins via a monotonically-increasing
/// request token).
///
/// Narrow `@Published` surface — the view binds to individual fields,
/// never `objectWillChange` wholesale (REPUB-1 discipline).
@MainActor
final class FileHistoryModel: ObservableObject {

    let repoRoot: URL
    let relativePath: String
    let displayName: String

    @Published private(set) var commits: [GitClient.LogEntry] = []
    @Published private(set) var isLoadingHistory = false
    @Published private(set) var isLoadingDiff = false
    @Published private(set) var diffText: String = ""

    /// Ordered full-SHA range selection (cap 2). Empty = no range.
    @Published private(set) var rangeSelection: [String] = []
    /// The single-selected commit's full SHA (drives List highlight +
    /// the single-commit diff). nil when in range mode or nothing picked.
    @Published private(set) var primarySelection: String?
    @Published private(set) var singleCompareMode: SingleCompareMode = .commit

    enum SingleCompareMode: Hashable, Sendable {
        case commit          // this commit's own change (sha~ .. sha)
        case vsWorkingTree   // this commit vs the current working tree
    }

    enum SelectionMode: Equatable {
        case none
        case single
        case range
    }

    var selectionMode: SelectionMode {
        if rangeSelection.count == 2 { return .range }
        if primarySelection != nil { return .single }
        return .none
    }

    /// "abc1234 ‹older› → def5678 ‹newer›" for the range toolbar.
    var rangeLabel: String {
        guard rangeSelection.count == 2 else { return "" }
        let a = shortSHA(rangeSelection[0])
        let b = shortSHA(rangeSelection[1])
        return "\(a) → \(b)"
    }

    /// Monotonic token so a slow diff load can't overwrite a newer one.
    private var diffToken = 0
    private var loaded = false

    init(repoRoot: URL, relativePath: String, displayName: String) {
        self.repoRoot = repoRoot
        self.relativePath = relativePath
        self.displayName = displayName
    }

    // MARK: - History load

    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        isLoadingHistory = true
        let root = repoRoot
        let path = relativePath
        Task { @MainActor [weak self] in
            let history = await Task.detached(priority: .userInitiated) {
                GitClient(repoRoot: root).fileHistory(path: path, maxEntries: 500)
            }.value
            guard let self else { return }
            self.commits = history
            self.isLoadingHistory = false
            // Auto-select the newest commit so the pane isn't blank.
            if let first = history.first {
                self.click(sha: first.fullSHA, command: false)
            }
        }
    }

    // MARK: - Selection state machine

    /// Unified click handler. `command == true` arms / extends the
    /// two-commit range; a plain click resets to single selection.
    func click(sha: String, command: Bool) {
        guard !sha.isEmpty else { return }
        if command {
            armRange(sha)
        } else {
            primarySelection = sha
            rangeSelection = []
            loadSingleDiff(sha: sha)
        }
    }

    /// Cmd-click semantics: first Cmd-click seeds the range from the
    /// current single selection (or the clicked sha if none) and adds
    /// the clicked sha; a second distinct sha completes the pair; a
    /// third Cmd-click starts a fresh pair anchored on the clicked sha.
    private func armRange(_ sha: String) {
        if rangeSelection.count >= 2 {
            // Restart a fresh pair from the existing primary (if any).
            rangeSelection = primarySelection.map { [$0] } ?? []
        }
        if rangeSelection.isEmpty {
            // Seed from current single selection so Cmd-click "extends"
            // intuitively from where the user already is.
            if let primary = primarySelection, primary != sha {
                rangeSelection = [primary]
            }
        }
        if !rangeSelection.contains(sha) {
            rangeSelection.append(sha)
        }
        if rangeSelection.count == 2 {
            loadRangeDiff()
        } else if rangeSelection.count == 1 {
            // Only one endpoint so far — behave like a single selection
            // for the diff while we wait for the second Cmd-click.
            primarySelection = rangeSelection[0]
            loadSingleDiff(sha: rangeSelection[0])
        }
    }

    func clearRange() {
        rangeSelection = []
        if let primary = primarySelection {
            loadSingleDiff(sha: primary)
        } else {
            diffText = ""
        }
    }

    func setSingleCompareMode(_ mode: SingleCompareMode) {
        guard mode != singleCompareMode else { return }
        singleCompareMode = mode
        if let primary = primarySelection, rangeSelection.count != 2 {
            loadSingleDiff(sha: primary)
        }
    }

    // MARK: - Diff load (off-main, last-write-wins)

    private func loadSingleDiff(sha: String) {
        diffToken += 1
        let token = diffToken
        isLoadingDiff = true
        let root = repoRoot
        let path = relativePath
        let mode = singleCompareMode
        Task { @MainActor [weak self] in
            let text = await Task.detached(priority: .userInitiated) { () -> String in
                let client = GitClient(repoRoot: root)
                switch mode {
                case .commit:
                    return client.fileDiff(path: path, atCommit: sha)
                case .vsWorkingTree:
                    // to == nil → diff <sha> against the working tree.
                    return client.diff(from: sha, to: nil, path: path)
                }
            }.value
            guard let self, token == self.diffToken else { return }
            self.diffText = text
            self.isLoadingDiff = false
        }
    }

    private func loadRangeDiff() {
        guard rangeSelection.count == 2 else { return }
        diffToken += 1
        let token = diffToken
        isLoadingDiff = true
        let root = repoRoot
        let path = relativePath
        let from = rangeSelection[0]
        let to = rangeSelection[1]
        Task { @MainActor [weak self] in
            let text = await Task.detached(priority: .userInitiated) {
                GitClient(repoRoot: root).diff(from: from, to: to, path: path)
            }.value
            guard let self, token == self.diffToken else { return }
            self.diffText = text
            self.isLoadingDiff = false
        }
    }

    private func shortSHA(_ full: String) -> String {
        String(full.prefix(7))
    }
}
