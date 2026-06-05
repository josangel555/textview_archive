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
            return boundedEnumerate(re, in: text, range: full)
        }
    }

    // MARK: - Bounded match-time enumeration (SEC-006)

    /// Hard wall-clock deadline for a single `enumerateMatches` run.
    /// The static shape guard (`isLikelyCatastrophicRegex`) is the
    /// primary ReDoS defense; this is the second wall: it bounds the
    /// *caller's* wall-clock even for a polynomial-backtracking pattern
    /// that slips past the shape check, since the closure-based stop
    /// only fires on an emitted match and a non-matching stall never
    /// invokes the closure at all.
    static let matchEnumerationBudgetNanos: UInt64 = 250 * 1_000_000  // 250ms
    static var matchEnumerationBudget: DispatchTimeInterval {
        .nanoseconds(Int(matchEnumerationBudgetNanos))
    }

    /// Runs `re.enumerateMatches` on a worker queue and waits on it with
    /// a hard `DispatchSemaphore` deadline. Returns the collected ranges
    /// on completion, or `[]` if the deadline is exceeded.
    ///
    /// Why off-thread + semaphore rather than the in-block `stop` flag:
    /// catastrophic backtracking burns CPU *inside* ICU while failing to
    /// match, so the per-match closure never runs and the cooperative
    /// stop can never fire. Moving enumeration to a worker lets the
    /// caller abandon the wait after the budget; the worker's ICU run
    /// cannot be force-killed, so it keeps running to natural completion
    /// (or its own cooperative stop on the next emitted match) but no
    /// longer holds up the sidebar. The cooperative `stop` is retained
    /// so the *worker* unwinds promptly on the polynomial-but-emitting
    /// case.
    /// Carries the (non-`Sendable`) enumeration inputs and the mutable
    /// result across the worker-queue boundary. Safe to mark
    /// `@unchecked Sendable`: the deadline protocol guarantees the box is
    /// touched by exactly one side at a time — the worker owns it while
    /// enumerating; the caller reads `ranges` only after `done.wait()`
    /// returns `.success` (a happens-before barrier), and on overrun the
    /// caller never touches it again, leaving the worker sole owner.
    /// `NSRegularExpression` matching is itself documented thread-safe.
    private final class EnumerationContext: @unchecked Sendable {
        let re: NSRegularExpression
        let text: String
        let range: NSRange
        var ranges: [Range<String.Index>] = []
        init(_ re: NSRegularExpression, _ text: String, _ range: NSRange) {
            self.re = re
            self.text = text
            self.range = range
        }
    }

    private static func boundedEnumerate(
        _ re: NSRegularExpression,
        in text: String,
        range: NSRange
    ) -> [Range<String.Index>] {
        let ctx = EnumerationContext(re, text, range)
        let done = DispatchSemaphore(value: 0)
        let deadline = DispatchTime.now() + matchEnumerationBudget

        DispatchQueue.global(qos: .userInitiated).async {
            let start = DispatchTime.now()
            ctx.re.enumerateMatches(in: ctx.text, options: [], range: ctx.range) { match, _, stop in
                if let m = match, m.range.length > 0,
                   let r = Range(m.range, in: ctx.text) {
                    ctx.ranges.append(r)
                }
                // Cooperative stop for the emitting-but-slow case so the
                // worker unwinds rather than spinning forever.
                let elapsed = DispatchTime.now().uptimeNanoseconds
                    - start.uptimeNanoseconds
                if elapsed >= matchEnumerationBudgetNanos { stop.pointee = true }
            }
            done.signal()
        }

        if done.wait(timeout: deadline) == .timedOut {
            // Overrun: abandon the worker (it owns `ctx` from here on)
            // and degrade to "no highlights" for this row.
            return []
        }
        return ctx.ranges
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

    // MARK: - Shared regex-shape scan helpers

    /// Hand-rolled scan (no substring copy, no per-call `NSRegularExpression`
    /// compile) of a quantifier brace starting at `chars[start]`. Recognizes
    /// `{n}`, `{n,}`, and `{n,m}` with optional whitespace, where the digit
    /// runs are non-empty. Returns the index just past the closing `}` plus
    /// whether the upper bound is unbounded (`{n,}`) and the parsed upper
    /// bound (`nil` when unbounded or absent → treated as the lower bound).
    /// Returns `nil` when `chars[start...]` is not a well-formed quantifier
    /// brace.
    private static func scanBrace(
        _ chars: [Character], at start: Int
    ) -> (end: Int, unbounded: Bool, upperBound: Int?)? {
        var i = start
        guard i < chars.count, chars[i] == "{" else { return nil }
        i += 1
        // Lower bound: one or more digits.
        let lowerStart = i
        while i < chars.count, chars[i].isNumber { i += 1 }
        guard i > lowerStart else { return nil }
        let lower = Int(String(chars[lowerStart..<i]))
        // `{n}` — no comma.
        if i < chars.count, chars[i] == "}" {
            return (i + 1, false, lower)
        }
        guard i < chars.count, chars[i] == "," else { return nil }
        i += 1
        // Optional whitespace after the comma.
        while i < chars.count, chars[i].isWhitespace { i += 1 }
        // `{n,}` — unbounded upper.
        if i < chars.count, chars[i] == "}" {
            return (i + 1, true, nil)
        }
        // `{n,m}` — bounded upper.
        let upperStart = i
        while i < chars.count, chars[i].isNumber { i += 1 }
        guard i > upperStart, i < chars.count, chars[i] == "}" else { return nil }
        let upper = Int(String(chars[upperStart..<i]))
        return (i + 1, false, upper)
    }

    /// True iff the quantifier brace at `chars[start]` can repeat its atom
    /// more than once — i.e. it is `{n,}` (unbounded) or has an upper bound
    /// `>= 2`. `{0}`/`{1}`/`{0,1}`/`{1,1}` cannot drive backtracking blowup.
    private static func braceRepeats(_ chars: [Character], at start: Int) -> Bool {
        guard let b = scanBrace(chars, at: start) else { return false }
        if b.unbounded { return true }
        // A bounded brace whose count overflowed `Int` (a pathologically
        // long digit run) is treated as repeating — it is certainly >= 2.
        guard let upper = b.upperBound else { return true }
        return upper >= 2
    }

    /// Parses a `(?...)` group introducer beginning at `chars[afterParen]`
    /// (the index of the `?` immediately after `(`). Returns the index just
    /// past the introducer and whether it is a *named* group
    /// (`(?<name>...)`, `(?P<name>...)`, `(?'name'...)`). The named-group
    /// `<...>` / `'...'` body is fully consumed through its closing
    /// delimiter — the bug the prior letter-only skip loop hit, where `>`
    /// leaked out and was miscounted as the group's first atom. Lookbehind
    /// (`(?<=`, `(?<!`) is NOT treated as named.
    ///
    /// Returns `i` positioned at the first char of the group body (or at
    /// `)` for an empty/flags-only group). On a malformed/unterminated
    /// named introducer returns `fullyParsed: false` so callers can treat
    /// the whole group as opaque/suspicious.
    private static func scanGroupIntroducer(
        _ chars: [Character], afterParen: Int
    ) -> (next: Int, named: Bool, fullyParsed: Bool) {
        var i = afterParen
        guard i < chars.count, chars[i] == "?" else {
            return (i, false, true)
        }
        i += 1
        guard i < chars.count else { return (i, false, false) }
        // Named-capture introducers: `(?<name>`, `(?P<name>`, `(?'name'`.
        // Distinguish named `(?<name>` from lookbehind `(?<=`/`(?<!`.
        if chars[i] == "P", i + 1 < chars.count, chars[i + 1] == "<" {
            return consumeNamed(chars, openAngleAt: i + 1, close: ">")
        }
        if chars[i] == "<", i + 1 < chars.count,
           chars[i + 1] != "=", chars[i + 1] != "!" {
            return consumeNamed(chars, openAngleAt: i, close: ">")
        }
        if chars[i] == "'" {
            return consumeNamed(chars, openAngleAt: i, close: "'")
        }
        // Comment group `(?#...)` — consume through the closing `)`.
        if chars[i] == "#" {
            var j = i + 1
            while j < chars.count, chars[j] != ")" { j += 1 }
            // Position AT the `)` (the body is empty); the main loop's
            // `)` handler then closes the frame.
            return (j, false, j < chars.count)
        }
        // Atomic `(?>...)`, lookahead `(?=`/`(?!`, lookbehind `(?<=`/`(?<!`.
        // These are fixed-length introducers — consume exactly them, then
        // the rest is the group body (do NOT greedily eat body letters).
        if chars[i] == ">" || chars[i] == "=" || chars[i] == "!" {
            return (i + 1, false, true)
        }
        if chars[i] == "<" {
            // `(?<` with a following `=`/`!` is lookbehind; anything else
            // (including a truncated `(?<`) is a named-group fragment we
            // couldn't fully classify — treat as opaque rather than let a
            // stray `<` leak into the body as a counted atom (the S3 bug).
            if i + 1 < chars.count, chars[i + 1] == "=" || chars[i + 1] == "!" {
                return (i + 2, false, true)
            }
            return (i, true, false)
        }
        if chars[i] == ":" {
            return (i + 1, false, true)
        }
        // Inline-flag group `(?ims-x)` or `(?ims-x:...)`: a run of flag
        // letters and `-`, terminated by `:` (then body) or `)` (then
        // empty). Anything outside that alphabet is an unfamiliar form —
        // leave the cursor at it (it becomes body; the body scan still
        // catches a nested quantifier).
        var j = i
        while j < chars.count {
            let m = chars[j]
            if m.isLetter || m == "-" { j += 1 } else { break }
        }
        if j < chars.count, chars[j] == ":" {
            return (j + 1, false, true)  // flags then body
        }
        // `(?i)` flags-only, or an unrecognized prefix — leave at current
        // position; the main loop handles the `)` / body.
        return (j, false, true)
    }

    /// Consumes a named-group delimiter body from `openAngleAt` (the `<` or
    /// `'`) through its matching `close`. Returns `fullyParsed: false` if
    /// the closing delimiter is missing.
    private static func consumeNamed(
        _ chars: [Character], openAngleAt: Int, close: Character
    ) -> (next: Int, named: Bool, fullyParsed: Bool) {
        var i = openAngleAt + 1
        while i < chars.count, chars[i] != close { i += 1 }
        guard i < chars.count else { return (i, true, false) }
        return (i + 1, true, true)  // position past the close delimiter
    }

    /// True iff a repeated group's first atom is itself unbounded-
    /// quantified — the ambiguous-start ReDoS shape. Catches the
    /// capturing `(a+)+`, `(a*)*`, `(\d+){1,}`; the non-capturing
    /// `(?:a+)+`; the doubly-nested `((a+))+`; the named `(?<n>a+)+`
    /// (introducer now fully consumed); the bounded-outer `(.*a){26}`;
    /// and stacked bounded quantifiers `a{1000}{1000}`. Benign shapes
    /// like `(?:\.\d+)+` (first atom is the mandatory `\.`, which anchors
    /// each iteration) and `(abc)+` are allowed.
    private static func hasNestedUnboundedQuantifier(_ pattern: String) -> Bool {
        // Per-group state. `firstAtomUnbounded` is the load-bearing
        // signal: a group whose FIRST atom carries an unbounded
        // quantifier (`+`, `*`, `{n,}`) is the ambiguous-start shape that
        // makes nesting/repetition explode — `(a+)+`, `(.*a){26}`,
        // `(?:a+)+`. It is set both directly (first atom `+`/`*`/`{n,}`)
        // and by propagation up from an inner group that was itself this
        // shape, so doubly-nested `((a+))+` is caught at the outer `)`.
        //
        // A non-first-atom unbounded quantifier preceded by a mandatory
        // atom (e.g. `\.` in `(?:\.\d+)+`) is intentionally NOT flagged:
        // the mandatory leading atom anchors each iteration, so it is
        // linear, not catastrophic — that shape is documented benign.
        struct Frame { var atoms = 0; var firstAtomUnbounded = false }
        var stack: [Frame] = []
        var escape = false
        var inClass = false
        let chars = Array(pattern)
        var i = 0
        // Was the immediately-preceding token a quantifier? Used to flag
        // stacked/multiplicative quantifiers like `a{1000}{1000}`, the
        // bounded-blowup class.
        var prevWasQuantifier = false

        func consume() {
            if !stack.isEmpty { stack[stack.count - 1].atoms += 1 }
        }
        // Flag the current group's first atom as unbounded-quantified
        // (only when the quantifier actually applies to atom #1).
        func quantifyFirstAtom() {
            if let top = stack.last, top.atoms == 1 {
                stack[stack.count - 1].firstAtomUnbounded = true
            }
        }

        while i < chars.count {
            let c = chars[i]
            if escape { escape = false; consume(); prevWasQuantifier = false; i += 1; continue }
            if c == "\\" { escape = true; i += 1; continue }
            if inClass {
                if c == "]" { inClass = false; consume(); prevWasQuantifier = false }
                i += 1; continue
            }
            if c == "[" { inClass = true; i += 1; continue }
            if c == "(" {
                stack.append(Frame())
                prevWasQuantifier = false
                let intro = scanGroupIntroducer(chars, afterParen: i + 1)
                // A `(?...)` group whose introducer we couldn't fully
                // parse (e.g. an unterminated `(?<name…`) is opaque —
                // err catastrophic rather than mis-tokenize it (the S3
                // named-group bug class).
                if !intro.fullyParsed { return true }
                i = intro.next
                continue
            }
            if c == ")" {
                let frame = stack.popLast() ?? Frame()
                let groupRepeats: Bool = {
                    guard i + 1 < chars.count else { return false }
                    let next = chars[i + 1]
                    if next == "+" || next == "*" { return true }
                    if next == "{" { return braceRepeats(chars, at: i + 1) }
                    return false
                }()
                // `(a+)+` / `(a+){2}` / `(.*a){26}` / `(?:a+)+` /
                // `((a+))+` — first atom unbounded-quantified AND the
                // group itself repeats.
                if frame.firstAtomUnbounded, groupRepeats { return true }
                // The closing group is itself an atom of the enclosing
                // group; if it was the ambiguous-start shape, that
                // property propagates outward so a doubly-nested
                // `((a+))+` is caught at the OUTER `)`.
                consume()
                if frame.firstAtomUnbounded { quantifyFirstAtom() }
                prevWasQuantifier = false
                i += 1
                continue
            }
            if c == "+" || c == "*" {
                quantifyFirstAtom(); prevWasQuantifier = true; i += 1; continue
            }
            if c == "?" {
                // `?` is either the 0-or-1 quantifier (bounded — no
                // blowup) or a lazy/possessive modifier on a preceding
                // quantifier (`a+?`, `a*?`). Either way the construct is
                // complete and nothing stacks onto it, so clear the flag.
                prevWasQuantifier = false
                i += 1; continue
            }
            if c == "{" {
                if let b = scanBrace(chars, at: i) {
                    // Stacked bounded quantifiers, e.g. `a{1000}{1000}`:
                    // a quantifier brace applied to something that was
                    // *already* quantified is multiplicative blowup.
                    if prevWasQuantifier { return true }
                    if b.unbounded { quantifyFirstAtom() }
                    prevWasQuantifier = true
                    i = b.end
                    continue
                }
                // Not a quantifier brace — a literal `{`. Treat as an atom.
                consume(); prevWasQuantifier = false; i += 1; continue
            }
            if c != "^" && c != "$" { consume() }
            prevWasQuantifier = false
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
        struct Frame { var arms: [[Character]] = [[]]; var hasMeta = false; var named = false }
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
                let intro = scanGroupIntroducer(chars, afterParen: i + 1)
                // An introducer we couldn't fully parse (e.g. an
                // unterminated `(?<name…`) is opaque — err catastrophic
                // rather than risk mis-tokenizing it (the S3 named-group
                // bug class). A well-formed named group is tracked on the
                // frame and rejected at `)` if it turns out quantified.
                if !intro.fullyParsed { return true }
                var frame = Frame()
                frame.named = intro.named
                stack.append(frame)
                i = intro.next
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
                    if n == "{" { return braceRepeats(chars, at: i + 1) }
                    return false
                }()
                // S3 defense-in-depth: a *quantified* named group
                // (`(?<n>…)+`) is rejected outright. Benign non-quantified
                // named captures still degrade gracefully (this guard never
                // fires for them); the `hasNestedUnboundedQuantifier` half
                // remains responsible for the precise body analysis.
                if quantified, frame.named { return true }
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
