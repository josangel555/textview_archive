import Foundation

public extension UnifiedDiff.File {
    /// Added / removed line counts across all hunks. `context` / `noNewline`
    /// lines don't count; a binary or rename-only file (no hunks) reports (0, 0).
    var lineStats: (added: Int, removed: Int) {
        var added = 0, removed = 0
        for hunk in hunks {
            for line in hunk.lines {
                switch line.kind {
                case .added:   added += 1
                case .removed: removed += 1
                case .context, .noNewline: break
                }
            }
        }
        return (added, removed)
    }
}

/// Aggregate `git diff --shortstat`-style summary over a parsed unified diff
/// (TSK-514). The per-file `+a −r` the diff view shows, plus the multi-file
/// total it was missing. Pure + host-testable; mirrors the other ViewerCore
/// analysis models.
public struct DiffStat: Equatable, Sendable {
    public let filesChanged: Int
    public let additions: Int
    public let deletions: Int

    public init(filesChanged: Int, additions: Int, deletions: Int) {
        self.filesChanged = filesChanged
        self.additions = additions
        self.deletions = deletions
    }

    /// Total across all files. Every parsed file counts toward `filesChanged`
    /// — including binary / rename-only files with no line changes — matching
    /// `git diff --stat`, which lists every changed file.
    public init(_ files: [UnifiedDiff.File]) {
        var add = 0, del = 0
        for f in files {
            let s = f.lineStats
            add += s.added
            del += s.removed
        }
        self.init(filesChanged: files.count, additions: add, deletions: del)
    }

    /// `git diff --shortstat`-style line, e.g.
    /// `"3 files changed, 42 insertions(+), 17 deletions(-)"`, with correct
    /// singular/plural and omitting a zero insertions/deletions clause. An
    /// empty diff returns `"no changes"`.
    public var shortStat: String {
        guard filesChanged > 0 else { return "no changes" }
        var parts = ["\(filesChanged) \(filesChanged == 1 ? "file" : "files") changed"]
        if additions > 0 {
            parts.append("\(additions) \(additions == 1 ? "insertion" : "insertions")(+)")
        }
        if deletions > 0 {
            parts.append("\(deletions) \(deletions == 1 ? "deletion" : "deletions")(-)")
        }
        return parts.joined(separator: ", ")
    }
}
