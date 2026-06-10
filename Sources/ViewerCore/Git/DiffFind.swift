import Foundation

/// TSK-597 — find-in-diff engine. Pure coordinate math over the parsed
/// `[UnifiedDiff.File]` tree so the DiffView's find bar (count +
/// next/prev) is headless-testable: matching, ordering, and wrap-around
/// navigation all live here; the view only renders the results.
public enum DiffFind {

    /// One matched line, addressed by tree coordinates. Hashable so the
    /// view can O(1)-test membership per rendered row.
    public struct Match: Equatable, Hashable, Sendable {
        public let file: Int
        public let hunk: Int
        public let line: Int
        public init(file: Int, hunk: Int, line: Int) {
            self.file = file; self.hunk = hunk; self.line = line
        }
    }

    /// Case-insensitive LITERAL match over every hunk line's content
    /// (added, removed, and context lines all participate — the user is
    /// scanning the diff text, not just one side). Empty / whitespace
    /// query matches nothing. Results are in document order, which is
    /// what makes next/prev intuitive.
    public static func matches(
        in files: [UnifiedDiff.File], query: String
    ) -> [Match] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        var out: [Match] = []
        for (fi, file) in files.enumerated() {
            for (hi, hunk) in file.hunks.enumerated() {
                for (li, line) in hunk.lines.enumerated()
                where line.content.range(of: q, options: .caseInsensitive) != nil {
                    out.append(Match(file: fi, hunk: hi, line: li))
                }
            }
        }
        return out
    }

    /// Wrapping forward step. `nil` current (fresh search) lands on the
    /// FIRST match; stepping past the end wraps to 0. Returns nil only
    /// when there are no matches.
    public static func next(after current: Int?, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return 0 }
        return (current + 1) % count
    }

    /// Wrapping backward step. `nil` current lands on the LAST match;
    /// stepping before 0 wraps to the end.
    public static func previous(before current: Int?, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return count - 1 }
        return (current - 1 + count) % count
    }
}
