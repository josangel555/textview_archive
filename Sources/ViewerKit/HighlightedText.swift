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
            // SEC-004: ReDoS guard for the sidebar Search Anywhere
            // highlighter. This runs per result row per keystroke, so a
            // catastrophic-backtracking pattern would freeze the
            // sidebar. ViewerKit is the bottom layer and can't import
            // `RegexComplexityGuard` (ViewerCore), so the known-
            // exponential shape check lives here as a self-contained
            // pure-string helper. On rejection we fall back to literal
            // — same graceful degradation as an invalid pattern.
            if isLikelyCatastrophicRegex(query) {
                return literalRanges(in: text, query: query, caseSensitive: caseSensitive)
            }
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
            // SEC-006: defense-in-depth wall-clock cap on match-time
            // enumeration (the shape check above is not a proof of
            // speed — polynomial backtracking slips past it). The
            // haystack here is a single line snippet / filename so this
            // rarely fires, but it bounds a worst case rather than
            // assuming the input is small. Cooperative stop via the
            // `enumerateMatches` flag (NSRegularExpression has no native
            // timeout).
            let start = DispatchTime.now()
            let budgetNanos: UInt64 = 250 * 1_000_000  // 250ms
            re.enumerateMatches(in: text, options: [], range: full) { match, _, stop in
                if let m = match, m.range.length > 0,
                   let r = Range(m.range, in: text) {
                    out.append(r)
                }
                let elapsed = DispatchTime.now().uptimeNanoseconds
                    - start.uptimeNanoseconds
                if elapsed >= budgetNanos { stop.pointee = true }
            }
            return out
        }
    }

    // MARK: - ReDoS guard (SEC-004)

    /// Maximum length of a regex pattern we'll hand to
    /// `NSRegularExpression`. Comfortably above any realistic
    /// Search-Anywhere query; well below what the NFA builder stalls on.
    static let maxRegexPatternLength = 1024

    /// Self-contained, conservative check for the well-known
    /// catastrophic-backtracking shapes, kept in ViewerKit (no
    /// ViewerCore dependency). Returns true for patterns we refuse to
    /// compile; the caller degrades to literal matching.
    ///
    /// This mirrors the intent of `ViewerCore.RegexComplexityGuard` —
    /// not a proof of safety (a `false` return means "not known-
    /// exponential", not "fast"), just a cheap foot-gun catch for the
    /// `(a+)+` / `(a|aa)+` class typed into a live find field. Match-
    /// time cost on anything that slips through is still bounded by the
    /// haystack size (one line snippet / filename here, not a document).
    static func isLikelyCatastrophicRegex(_ pattern: String) -> Bool {
        if pattern.count > maxRegexPatternLength { return true }
        return hasNestedUnboundedQuantifier(pattern)
            || hasOverlappingAlternationUnderQuantifier(pattern)
    }

    /// True iff a quantified group's first atom is itself unbounded-
    /// quantified, e.g. `(a+)+`, `(a*)*`, `(\d+){1,}`. Benign shapes
    /// like `(?:\.\d+)+` (first atom unquantified) and `(abc)+` are
    /// allowed.
    private static func hasNestedUnboundedQuantifier(_ pattern: String) -> Bool {
        struct Frame { var atoms = 0; var firstAtomQuantified = false }
        var stack: [Frame] = []
        var escape = false
        var inClass = false
        let chars = Array(pattern)
        var i = 0

        func consume() {
            if !stack.isEmpty { stack[stack.count - 1].atoms += 1 }
        }
        func quantifyLast() {
            if let top = stack.last, top.atoms == 1 {
                stack[stack.count - 1].firstAtomQuantified = true
            }
        }
        func unboundedBrace(at start: Int) -> Bool {
            String(chars[start...]).range(
                of: #"^\{\d+,\s*\}"#, options: .regularExpression) != nil
        }

        while i < chars.count {
            let c = chars[i]
            if escape { escape = false; consume(); i += 1; continue }
            if c == "\\" { escape = true; i += 1; continue }
            if inClass {
                if c == "]" { inClass = false; consume() }
                i += 1; continue
            }
            if c == "[" { inClass = true; i += 1; continue }
            if c == "(" {
                stack.append(Frame())
                i += 1
                if i < chars.count, chars[i] == "?" {
                    i += 1
                    while i < chars.count {
                        let m = chars[i]
                        if m.isLetter || m == ":" || m == "=" || m == "!" || m == "<" {
                            i += 1
                        } else { break }
                    }
                }
                continue
            }
            if c == ")" {
                let frame = stack.popLast() ?? Frame()
                if frame.firstAtomQuantified, i + 1 < chars.count {
                    let next = chars[i + 1]
                    if next == "+" || next == "*" { return true }
                    if next == "{", unboundedBrace(at: i + 1) { return true }
                }
                consume()
                i += 1
                continue
            }
            if c == "+" || c == "*" { quantifyLast(); i += 1; continue }
            if c == "?" { i += 1; continue }
            if c == "{" {
                if unboundedBrace(at: i) { quantifyLast() }
                if let close = chars[i...].firstIndex(of: "}") {
                    i = close + 1; continue
                }
                i += 1; continue
            }
            if c != "^" && c != "$" { consume() }
            i += 1
        }
        return false
    }

    /// True iff a quantified group has alternation arms that share a
    /// literal prefix, e.g. `(a|aa)+` — the canonical ReDoS where each
    /// outer iteration can be split multiple ways. `(cat|dog)+` is
    /// benign (no shared prefix). Arms containing metacharacters are
    /// skipped (they go through the nested-quantifier rule).
    private static func hasOverlappingAlternationUnderQuantifier(
        _ pattern: String
    ) -> Bool {
        struct Frame { var arms: [[Character]] = [[]]; var hasMeta = false }
        var stack: [Frame] = []
        var escape = false
        var inClass = false
        let chars = Array(pattern)
        var i = 0

        func appendArm(_ c: Character) {
            if let top = stack.last, !top.arms.isEmpty {
                stack[stack.count - 1].arms[top.arms.count - 1].append(c)
            }
        }
        func markMeta() {
            if !stack.isEmpty { stack[stack.count - 1].hasMeta = true }
        }
        func unboundedBrace(at start: Int) -> Bool {
            String(chars[start...]).range(
                of: #"^\{\d+,\s*\}"#, options: .regularExpression) != nil
        }

        while i < chars.count {
            let c = chars[i]
            if escape { escape = false; appendArm(c); i += 1; continue }
            if c == "\\" { escape = true; i += 1; continue }
            if inClass {
                if c == "]" { inClass = false }
                i += 1; continue
            }
            if c == "[" { inClass = true; markMeta(); i += 1; continue }
            if c == "(" {
                stack.append(Frame())
                i += 1
                if i < chars.count, chars[i] == "?" {
                    i += 1
                    while i < chars.count {
                        let m = chars[i]
                        if m.isLetter || m == ":" || m == "=" || m == "!" || m == "<" {
                            i += 1
                        } else { break }
                    }
                }
                continue
            }
            if c == "|", !stack.isEmpty {
                stack[stack.count - 1].arms.append([])
                i += 1; continue
            }
            if c == ")" {
                let frame = stack.popLast() ?? Frame()
                let multiArm = frame.arms.count > 1
                let quantified: Bool = {
                    guard i + 1 < chars.count else { return false }
                    let n = chars[i + 1]
                    if n == "+" || n == "*" { return true }
                    if n == "{" { return unboundedBrace(at: i + 1) }
                    return false
                }()
                if multiArm, quantified, !frame.hasMeta {
                    let prefixes = frame.arms.map { String($0) }
                    for a in 0..<prefixes.count {
                        for b in (a + 1)..<prefixes.count {
                            let x = prefixes[a], y = prefixes[b]
                            if x.isEmpty || y.isEmpty { continue }
                            if x.hasPrefix(y) || y.hasPrefix(x) { return true }
                        }
                    }
                }
                i += 1
                continue
            }
            if c == "+" || c == "*" || c == "?" || c == "{" {
                markMeta(); i += 1; continue
            }
            appendArm(c)
            i += 1
        }
        return false
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
