import Foundation

/// The commit header block that precedes the patch in `git show` output —
/// surfaced as a summary header atop the diff view (TSK-911), since the diff
/// PARSER (`UnifiedDiff`) keeps only files+hunks and drops everything before the
/// first `diff --git`. Pure string split — host-testable; the header VIEW that
/// renders this (plus the `DiffStat.shortStat` totals) is the VM tail.
public enum CommitDiffSummary {

    /// The preamble text before the first `diff --git` line (commit sha / author
    /// / date / message, per `commitDiff`'s `--format`), trimmed. Returns nil for
    /// a plain patch that starts at `diff --git` (no commit header) or when there
    /// is no preamble — so the header only shows for a commit diff.
    public static func preamble(_ diffText: String) -> String? {
        // Starts at the patch ⇒ no commit header.
        if diffText.hasPrefix("diff --git ") { return nil }
        // First file boundary is the first "diff --git" at the start of a line.
        guard let r = diffText.range(of: "\ndiff --git ") else { return nil }
        let head = String(diffText[..<r.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return head.isEmpty ? nil : head
    }
}
