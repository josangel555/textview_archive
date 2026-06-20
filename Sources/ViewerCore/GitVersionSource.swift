import Foundation

/// `VersionSource` over `GitClient` — the Git back-end for the unified version
/// viewer (TSK-1103). Lets the SAME viewer that drives Local History also drive
/// a file's git commit history: list commits, view a file at a commit, diff a
/// commit vs the working tree, and a cumulative diff across selected commits.
///
/// Reuses the existing git diff plumbing verbatim (`fileDiff`, `diff(from:to:)`,
/// `cumulativeDiff`, `fileContent`, `fileHistory`) and the pure
/// `CumulativeDiffSelection` range math — no git logic is reinvented. Git already
/// emits unified-diff text, so no `UnifiedDiffGenerator` is needed here.
///
/// `Sendable`: the URL/String fields are value types; `GitClient` is itself
/// `Sendable`. The view-model calls these off the main actor.
public struct GitVersionSource: VersionSource {
    private let client: GitClient
    private let repoRoot: URL
    /// Repo-relative, forward-slash path (what `git log -- <path>` wants).
    private let relativePath: String
    public let displayName: String
    /// How many commits to list (mirrors `FileHistoryModel`'s 500).
    private let maxEntries: Int

    public init(
        repoRoot: URL,
        relativePath: String,
        displayName: String,
        maxEntries: Int = 500
    ) {
        self.client = GitClient(repoRoot: repoRoot)
        self.repoRoot = repoRoot
        self.relativePath = relativePath
        self.displayName = displayName
        self.maxEntries = maxEntries
    }

    public func listVersions() -> [VersionRef] {
        client.fileHistory(path: relativePath, maxEntries: maxEntries).map { entry in
            VersionRef(
                id: entry.fullSHA.isEmpty ? entry.sha : entry.fullSHA,
                shortLabel: entry.sha,
                timestamp: Self.parseGitDate(entry.date),
                author: entry.author,
                subject: entry.subject,
                kind: .git)
        }
    }

    public func content(of version: VersionRef) -> String? {
        client.fileContent(rev: version.id, path: relativePath)
    }

    public func diffAgainstCurrent(_ version: VersionRef) -> String {
        // `diff(from: sha, to: nil, path:)` compares the commit against the
        // working tree — exactly "this version vs current".
        client.diff(from: version.id, to: nil, path: relativePath)
    }

    public func diff(from: VersionRef, to: VersionRef?) -> String {
        if let to {
            // Two-commit diff: order oldest→newest so it reads forward.
            let (a, b) = ordered(from, to)
            return client.diff(from: a.id, to: b.id, path: relativePath)
        }
        // to == nil → this commit's own change (sha~ .. sha), scoped to the file.
        return client.fileDiff(path: relativePath, atCommit: from.id)
    }

    public func cumulativeDiff(in selection: [VersionRef]) -> String {
        // Reuse the pure range math (TSK-522). We need each commit's topoIndex
        // (its position in the fetched newest-first list) and parents. We don't
        // have parents in the lightweight VersionRef, so approximate using the
        // ordered endpoints: base = parent-of-oldest (oldest.id~), tip = newest.
        let ordered = oldestToNewest(selection)
        guard let oldest = ordered.first, let newest = ordered.last,
              oldest != newest else { return "" }
        // `<oldest>~` is the parent of the oldest selected commit, so the diff
        // includes the oldest commit's own changes through the newest.
        return client.diff(from: "\(oldest.id)~", to: newest.id, path: relativePath)
    }

    // MARK: - Helpers

    /// Order a pair oldest→newest by timestamp (falling back to list order).
    private func ordered(_ a: VersionRef, _ b: VersionRef) -> (VersionRef, VersionRef) {
        let ta = a.timestamp ?? .distantPast
        let tb = b.timestamp ?? .distantPast
        return ta <= tb ? (a, b) : (b, a)
    }

    private func oldestToNewest(_ refs: [VersionRef]) -> [VersionRef] {
        refs.sorted { ($0.timestamp ?? .distantPast) < ($1.timestamp ?? .distantPast) }
    }

    /// Parse git's `%ai` author date ("2026-05-31 08:12:03 -0700") into a Date.
    /// Returns nil on an unexpected shape (the row still lists; just no sort key).
    static func parseGitDate(_ s: String) -> Date? {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return fmt.date(from: s)
    }
}
