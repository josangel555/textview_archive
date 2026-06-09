import Foundation

// MARK: - CommitDiffAnchor
//
// TSK-523 slice 2: the pure, host-testable logic that extends the FILE-scoped
// review-comment model to a COMMIT-DIFF context, so a single review can hold
// comments spanning many commits (the "click any commit in the Git Log and
// comment on its diff" flow). The commit dimension lives on
// `ReviewComment.commitSha`; this enum is the vocabulary for partitioning and
// resolving those comments.
//
// SwiftUI/AppKit-free and it performs NO git invocation. The two reused pieces:
//   • `HunkContextCapture` — unchanged; capturing the frozen hunk window from a
//     commit's parsed diff is identical to the working-tree path.
//   • `AnchorStaleness` — composes via `blobRev(...)`. A commit is IMMUTABLE, so
//     a comment on a live commit's diff is always `.current` (captured blob ==
//     the blob still at that rev); if the commit was rewritten (rebase/amend →
//     new sha) or GC'd, the rev no longer resolves and `GitClient.blobSha`
//     returns nil → `.unknown`. It is therefore never `.stale` in the
//     working-tree "code moved under me" sense — the honest signal for a commit
//     comment is "the commit still exists" vs "it's gone".
public enum CommitDiffAnchor {

    /// The comments anchored to commit `sha`'s diff, in input order. Comments
    /// with `commitSha == nil` (scope-diff / file-review comments) are excluded
    /// — they don't belong to any commit's patch.
    public static func comments(
        _ comments: [ReviewComment], forCommit sha: String
    ) -> [ReviewComment] {
        comments.filter { $0.commitSha == sha }
    }

    /// The distinct commit SHAs that carry ≥1 comment, in first-seen order
    /// (so the UI can list "commits with feedback" stably). Excludes `nil`.
    public static func commentedCommits(_ comments: [ReviewComment]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for c in comments {
            guard let sha = c.commitSha else { continue }
            if seen.insert(sha).inserted { out.append(sha) }
        }
        return out
    }

    /// Comment count per commit SHA (commit-scoped comments only; `nil` excluded)
    /// — drives a per-commit badge in the Git Log.
    public static func commentCounts(_ comments: [ReviewComment]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for c in comments {
            guard let sha = c.commitSha else { continue }
            counts[sha, default: 0] += 1
        }
        return counts
    }

    /// The git revision whose blob backs `side` of commit `sha`'s diff. Pair it
    /// with the comment's `filePath` (e.g. resolve `GitClient.blobSha(rev:path:)`)
    /// to get the LIVE blob SHA for `AnchorStaleness.evaluate`.
    ///
    /// `git show <sha>` ≡ `git diff <sha>~ <sha>`, so:
    ///   • `.new` / `.context` lines live in the commit's own tree → `sha`.
    ///   • `.old` lines live in the (first) parent's tree → `firstParent`, or
    ///     the empty-tree object when `sha` is a root commit (no parent).
    public static func blobRev(
        side: LineAnchor.Side, commitSha sha: String, firstParent: String?
    ) -> String {
        switch side {
        case .new, .context:
            return sha
        case .old:
            return firstParent ?? CumulativeDiffSelection.emptyTreeSHA
        }
    }
}
