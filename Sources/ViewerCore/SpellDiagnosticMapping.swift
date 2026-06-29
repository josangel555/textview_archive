import Foundation

/// Map spell-check findings to CM6 inline diagnostics (squiggles) — the spell
/// analog of `CMDiagnosticMapping` (which does the same for LSP diagnostics).
/// TSK-1146 / TSK-685.
///
/// `SpellingIssue.range` is already a UTF-16 `NSRange` into the checked text,
/// which is exactly the coordinate space CM6's `CMDiagnostic.from`/`to` use
/// (UTF-16 doc offsets) — so unlike the LSP mapping (which translates
/// line/character via the doc text) this is a direct offset copy, no document
/// text required. The editor surface feeds the result into the SAME
/// `setDiagnostics` → `lintGutter` render path the LSP squiggles already use;
/// that wiring (debounced spell pass + merge with LSP diagnostics) is the
/// separate render slice, matching the SpellCheckEngine / surface split.
public enum SpellDiagnosticMapping {

    /// CM6 diagnostics for a set of spelling issues. Spelling is advisory, so
    /// severity is `.info` (not error/warning), and `source` is "spell" so the
    /// editor can distinguish spell squiggles from LSP diagnostics (e.g. to
    /// toggle them independently or merge without collision). Issues with an
    /// invalid (`NSNotFound`) or empty range are dropped.
    public static func cmDiagnostics(from issues: [SpellingIssue]) -> [CMDiagnostic] {
        issues.compactMap { issue in
            let r = issue.range
            guard r.location != NSNotFound, r.length > 0 else { return nil }
            return CMDiagnostic(
                from: r.location,
                to: r.location + r.length,
                severity: .info,
                message: message(for: issue),
                source: "spell"
            )
        }
    }

    /// "Misspelled: <word>" plus up to three best-first suggestions when present.
    static func message(for issue: SpellingIssue) -> String {
        let base = "Misspelled: \(issue.word)"
        guard !issue.suggestions.isEmpty else { return base }
        let hints = issue.suggestions.prefix(3).joined(separator: ", ")
        return "\(base) — did you mean: \(hints)?"
    }
}
