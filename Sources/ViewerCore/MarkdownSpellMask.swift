import Foundation

/// Which parts of a Markdown document should NOT be spell-checked (TSK-1146).
///
/// Spell-checking raw Markdown squiggles code — identifiers, paths, flags inside
/// fenced blocks and inline `code` spans read as misspellings, which is noise.
/// This computes the code ranges to EXCLUDE (UTF-16 offsets — the space
/// `SpellingIssue.range` / `CMDiagnostic.from/to` use) and filters a spelling
/// pass down to prose. Pure + host-testable; the editor's debounced spell trigger
/// runs `SpellCheckEngine` then calls `filterProse` before publishing squiggles.
public enum MarkdownSpellMask {

    /// UTF-16 ranges covering fenced code blocks (```` ``` ```` / `~~~`) and inline
    /// code spans (`` `…` ``). Conservative: a fence line toggles block state, and
    /// every line inside (plus the fence lines) is excluded; inline backtick runs
    /// are excluded line-wide via a regex over the whole text (overlaps with the
    /// block ranges are harmless — they're unioned at filter time).
    public static func excludedRanges(in markdown: String) -> [Range<Int>] {
        let ns = markdown as NSString
        var ranges: [Range<Int>] = []

        // 1. Fenced code blocks — line scan, toggling on each ```/~~~ fence line.
        var inFence = false
        ns.enumerateSubstrings(
            in: NSRange(location: 0, length: ns.length), options: .byLines
        ) { sub, lineRange, _, _ in
            let trimmed = (sub ?? "").trimmingCharacters(in: .whitespaces)
            let isFence = trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
            if isFence {
                ranges.append(lineRange.location ..< (lineRange.location + lineRange.length))
                inFence.toggle()
            } else if inFence {
                ranges.append(lineRange.location ..< (lineRange.location + lineRange.length))
            }
        }

        // 2. Inline code spans — backtick runs (single or multi). Excluded even
        // when not inside a fence (the common case: `foo` in prose).
        if let rx = try? NSRegularExpression(pattern: "`+[^`\\n]*`+") {
            rx.enumerateMatches(
                in: markdown, range: NSRange(location: 0, length: ns.length)
            ) { match, _, _ in
                if let r = match?.range {
                    ranges.append(r.location ..< (r.location + r.length))
                }
            }
        }
        return ranges
    }

    /// Keep only spelling issues lying entirely OUTSIDE the code ranges — i.e.
    /// prose. An issue overlapping any excluded range is dropped.
    public static func filterProse(
        _ issues: [SpellingIssue], in markdown: String
    ) -> [SpellingIssue] {
        let excluded = excludedRanges(in: markdown)
        guard !excluded.isEmpty else { return issues }
        return issues.filter { issue in
            let loc = issue.range.location
            guard loc != NSNotFound, issue.range.length > 0 else { return false }
            let r = loc ..< (loc + issue.range.length)
            return !excluded.contains { $0.overlaps(r) }
        }
    }
}
