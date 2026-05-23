import Foundation

/// Pure-value helpers for "highlight the matched substring(s) of a
/// query inside a haystack". Used by the sidebar Search Anywhere pane
/// (filename + line snippet) and any future surface that wants the
/// same match-emphasis treatment.
///
/// Kept in ViewerKit and free of SwiftUI on purpose: returning ranges
/// lets the call site own styling (color tokens, font, bg) while the
/// scanning logic — and its edge cases (overlapping, empty match,
/// invalid regex) — stays in one tested place.
public enum HighlightedText {

    /// How `query` is matched against the haystack.
    public enum Mode: Sendable, Equatable {
        /// Plain literal substring search. The default behavior of the
        /// Search Anywhere pane.
        case literal(caseSensitive: Bool)
        /// ICU regular expression. Invalid patterns fall back to the
        /// equivalent literal (case-insensitive) — never crash, never
        /// throw out of the helper.
        case regex(caseSensitive: Bool)
    }

    /// Returns every non-overlapping match range of `query` in `text`.
    ///
    /// Empty or whitespace-only queries return `[]` so callers can
    /// short-circuit to plain text. Invalid regex patterns degrade to
    /// the literal-case-insensitive interpretation of the same query.
    public static func ranges(
        in text: String,
        query: String,
        mode: Mode = .literal(caseSensitive: false)
    ) -> [Range<String.Index>] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !text.isEmpty else { return [] }

        switch mode {
        case .literal(let caseSensitive):
            return literalRanges(in: text, query: query, caseSensitive: caseSensitive)

        case .regex(let caseSensitive):
            var opts: NSRegularExpression.Options = []
            if !caseSensitive { opts.insert(.caseInsensitive) }
            guard let re = try? NSRegularExpression(pattern: query, options: opts) else {
                // Graceful fallback: treat the pattern as a literal so
                // mid-typing regexes (e.g. user types `foo(`) still
                // highlight something instead of flashing nothing.
                return literalRanges(in: text, query: query, caseSensitive: caseSensitive)
            }
            let ns = text as NSString
            let full = NSRange(location: 0, length: ns.length)
            var out: [Range<String.Index>] = []
            re.enumerateMatches(in: text, options: [], range: full) { match, _, _ in
                guard let m = match, m.range.length > 0,
                      let r = Range(m.range, in: text) else { return }
                out.append(r)
            }
            return out
        }
    }

    // MARK: - Internal

    /// Walks `text` collecting every occurrence of `query`. Uses
    /// `range(of:options:range:)` so the scan stays Unicode-correct
    /// (combining marks, case folding) rather than reaching for raw
    /// byte offsets. Each match advances `cursor` past `upperBound` to
    /// avoid emitting overlapping ranges for queries like "aa" in
    /// "aaaa".
    private static func literalRanges(
        in text: String,
        query: String,
        caseSensitive: Bool
    ) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        var cursor = text.startIndex
        let opts: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        while cursor < text.endIndex,
              let r = text.range(of: query, options: opts, range: cursor..<text.endIndex),
              !r.isEmpty {
            out.append(r)
            cursor = r.upperBound
        }
        return out
    }
}
