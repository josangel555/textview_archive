import Foundation

/// Per-line diff status mapped from `git diff` unified output.
public enum DiffMark: Equatable, Sendable {
    /// New line in the working tree (didn't exist at HEAD).
    case added
    /// Line existed at HEAD but its content was modified.
    case modified
    /// Marks the working-tree line **after** a deletion. The deleted
    /// line itself isn't in the working tree (it's gone), so the
    /// gutter signal lands on its successor with a thin tick so the
    /// user knows lines were removed just above.
    case deleted
}

/// Parses unified `git diff` output and returns a per-working-tree-line
/// mark for the file. The keys are 1-based line numbers in the file
/// *as it stands on disk*; that's what the source-view gutter
/// renders against.
public enum DiffHunkParser {

    /// Parse the unified diff for a single file. Multi-file diffs are
    /// handled — the parser scans every hunk and accumulates marks.
    public static func parse(_ diff: String) -> [Int: DiffMark] {
        var marks: [Int: DiffMark] = [:]
        var lineInNew = 0
        var pendingDeletion = false

        for raw in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("@@") {
                // Hunk header: "@@ -old,oldLen +new,newLen @@ context"
                // Pull the new-side start line.
                if let plus = line.range(of: "+"),
                   let space = line[plus.upperBound...].firstIndex(where: { $0 == " " || $0 == "," }) {
                    let numStr = line[plus.upperBound..<space]
                    if let n = Int(numStr) {
                        // Clamp (TSK-576): the header is attacker-controlled,
                        // and Int.min - 1 TRAPS. PARITY-LOCKED with the Rust
                        // hunk_marks (same clamp ceiling as its MAX_COORD).
                        lineInNew = min(max(n, 0), 1_000_000_000) - 1  // bumped before each consumed line
                    }
                }
                pendingDeletion = false
                continue
            }
            // Skip non-hunk metadata.
            if line.hasPrefix("diff ") || line.hasPrefix("index ")
                || line.hasPrefix("--- ") || line.hasPrefix("+++ ")
                || line.hasPrefix("Binary ") || line.hasPrefix("new file")
                || line.hasPrefix("deleted file") || line.hasPrefix("similarity ")
                || line.hasPrefix("rename ") || line.hasPrefix("copy ") {
                continue
            }
            guard let first = line.first else {
                // Empty separator line inside a hunk maps to the new
                // file (it's a context line).
                lineInNew += 1
                continue
            }
            switch first {
            case " ":
                // Context line — present in both.
                lineInNew += 1
                pendingDeletion = false
            case "+":
                // Added or modified — if a removal immediately preceded
                // this added line, the result is a modify on the new
                // line; otherwise it's a fresh addition.
                lineInNew += 1
                if pendingDeletion {
                    marks[lineInNew] = .modified
                } else {
                    marks[lineInNew] = .added
                }
                pendingDeletion = false
            case "-":
                // Removed at this point. Mark the *next* line in the
                // new file as `.deleted` so the gutter has a place to
                // surface the change. If the next event is `+` we'll
                // upgrade to `.modified` above.
                pendingDeletion = true
                // max(…, 1) (TSK-565): a deletion at the very top of the file
                // (new-side start 0) would otherwise mark line 0 — keys are
                // 1-based, so the tick was invisible in the gutter. PARITY-
                // LOCKED with the Rust hunk_marks.
                let tick = max(lineInNew + 1, 1)
                if marks[tick] == nil {
                    marks[tick] = .deleted
                }
            case "\\":
                // "\ No newline at end of file" — not a content line.
                continue
            default:
                // Unknown line marker — skip silently rather than
                // crashing.
                continue
            }
        }
        return marks
    }
}
