import Foundation

/// Compile-time pattern rejection for user-supplied regex. The goal
/// is to refuse the well-known ReDoS-class shapes — nested quantifiers
/// over the same character class, ambiguous alternation under a
/// quantifier — before `NSRegularExpression` ever sees them. Lifted as
/// the cheaper, more predictable alternative to a runtime timeout
/// (which `NSRegularExpression` doesn't natively support and which
/// would require a watchdog thread per evaluation).
///
/// **Scope.** This is a defense for **interactive find** (FindEngine,
/// MCP `find` tool, CrossFileSearch). It's not exhaustive — a clever
/// attacker can still craft something that hits a heuristic blind
/// spot. The goal is to make the cheap, "I typed `(a+)+$` in the
/// find bar" foot-gun into an immediate compile error rather than
/// a frozen UI. Documented in finding §6.1 of
/// `docs/code-review/SECURITY_CONCURRENCY_2026-05-25.md`.
///
/// **Trade-offs.** The complexity rules will reject some legitimate
/// patterns that happen to look exponential. We expose
/// `RegexComplexityGuard.bypass` for paths where the caller has
/// already validated the pattern (e.g. a hard-coded internal one).
public enum RegexComplexityGuard {

    /// Maximum length of a user-typed pattern. 1 KB is comfortably
    /// above any realistic find-bar query (the longest real-world
    /// regexes — JSON schemas, URL parsers — top out around 300
    /// chars) and well below what `NSRegularExpression`'s NFA
    /// builder can stall on.
    public static let maxPatternLength: Int = 1024

    /// Default match-time deadline for `boundedMatches` (SEC-006).
    /// 250ms is well above any honest interactive find (a clean regex
    /// over a multi-MB document enumerates in single-digit ms) and
    /// short enough that a pattern which slips past `reject` can't
    /// freeze the UI for more than a frame or two before we bail.
    public static let defaultMatchDeadline: TimeInterval = 0.25

    /// Returns nil if `pattern` is acceptable, or a human-readable
    /// reason string if it should be rejected.
    ///
    /// **Important — what `nil` means.** A `nil` return is *not* a
    /// proof that the pattern is fast. `reject` only catches the
    /// well-known *exponential* shapes (nested unbounded quantifiers,
    /// overlapping alternation under a quantifier). It does **not**
    /// catch *polynomial* backtracking (e.g. `a*a*a*…b` style, or
    /// long chains of optional groups), which can still take seconds
    /// on an adversarial input without ever being "exponential". So
    /// `reject(p) == nil` means "not *known-exponential*", not "safe to
    /// run unbounded". Match-time enumeration over user-supplied
    /// patterns must therefore *also* be wall-clock-bounded — see
    /// `boundedMatches` (SEC-006), the defense-in-depth deadline used
    /// at the live find/highlight enumeration sites.
    public static func reject(_ pattern: String) -> String? {
        if pattern.count > maxPatternLength {
            return "regex too long (\(pattern.count) chars, max \(maxPatternLength))"
        }
        if hasNestedQuantifier(pattern) {
            return "nested repetition is ReDoS-prone; rewrite without grouped repetition (e.g. `(a+)+`)"
        }
        if hasAlternationUnderQuantifier(pattern) {
            return "alternation under a quantifier is ReDoS-prone; rewrite without `(a|a)+` shapes"
        }
        return nil
    }

    // MARK: - Match-time deadline (SEC-006)

    /// Enumerate `regex` matches in `text` with a cooperative
    /// wall-clock deadline. Defense-in-depth for the polynomial-
    /// backtracking shapes `reject` deliberately doesn't model: even a
    /// pattern that passes `reject` is bounded here so a single
    /// adversarial query can't peg a core indefinitely.
    ///
    /// `NSRegularExpression` has no native timeout, but
    /// `enumerateMatches` calls back per match and honours a `stop`
    /// flag — so we check the clock on each callback and stop once the
    /// budget is spent. This bounds the *inter-match* time but not the
    /// backtracking *within* a single failing match attempt; for that
    /// the only real defense is `reject` plus the bounded haystack at
    /// the call sites. In practice the per-match cadence is frequent
    /// enough that pathological *find* queries (which produce a steady
    /// drip of partial matches) are caught well inside one frame.
    ///
    /// Returns the matches collected before the deadline. `timedOut`
    /// is true when enumeration was cut short — callers may surface
    /// that distinctly from a genuine "no more matches".
    public static func boundedMatches(
        _ regex: NSRegularExpression,
        in text: String,
        range: NSRange,
        options: NSRegularExpression.MatchingOptions = [],
        deadline: TimeInterval = defaultMatchDeadline
    ) -> (matches: [NSTextCheckingResult], timedOut: Bool) {
        var out: [NSTextCheckingResult] = []
        var timedOut = false
        let start = DispatchTime.now()
        let budgetNanos = UInt64(max(0, deadline) * 1_000_000_000)
        regex.enumerateMatches(in: text, options: options, range: range) { result, _, stop in
            if let r = result, r.range.location != NSNotFound {
                out.append(r)
            }
            let elapsed = DispatchTime.now().uptimeNanoseconds
                - start.uptimeNanoseconds
            if elapsed >= budgetNanos {
                timedOut = true
                stop.pointee = true
            }
        }
        return (out, timedOut)
    }

    // MARK: - Heuristics

    /// True iff the pattern contains a "dangerous nested quantifier"
    /// shape — narrowly: a quantified group whose **first atom** is
    /// itself an unbounded-quantified atom. ReDoS exponential
    /// backtracking arises when each outer iteration can partition
    /// the same matched substring multiple ways; that happens when
    /// the group has no "anchor" atom up front to separate iterations.
    ///
    /// Examples of *dangerous* shapes we catch:
    ///
    ///   * `(a+)+`, `(a*)*`, `(\d+){1,}` — first atom is quantified.
    ///
    /// Examples of *benign* shapes we deliberately allow:
    ///
    ///   * `(?:\.\d+)+` — first atom `\.` is unquantified; each
    ///     iteration is anchored to the next `.`.
    ///   * `(abc)+` — no inner quantifier at all.
    ///   * `[abc]+` — character class is not a group.
    ///
    /// Implementation: walk the pattern. When we see an unescaped
    /// `(`, push a frame and start tracking "what's the first
    /// thing we see". If that first thing is an atom that gets
    /// quantified before any other content arrives, mark
    /// `firstAtomQuantified`. On `)`, check for an outer quantifier.
    static func hasNestedQuantifier(_ pattern: String) -> Bool {
        struct Frame {
            /// Have we consumed at least one atom yet?
            var atomsConsumed: Int = 0
            /// Did the FIRST atom get an unbounded quantifier?
            var firstAtomQuantified: Bool = false
        }
        var stack: [Frame] = []
        var escape = false
        var inCharClass = false
        let chars = Array(pattern)
        var i = 0

        // Helper: register that an atom of width 1 (single char,
        // escape, char class, or group) just completed inside the
        // current frame. The follow-up code may then mark it as
        // quantified.
        func consumeAtom() {
            if var top = stack.last {
                top.atomsConsumed += 1
                stack[stack.count - 1] = top
            }
        }
        // Helper: if the most-recently-consumed atom was the *first*
        // one in the current frame, mark firstAtomQuantified.
        func quantifyLastAtom() {
            if var top = stack.last, top.atomsConsumed == 1 {
                top.firstAtomQuantified = true
                stack[stack.count - 1] = top
            }
        }

        while i < chars.count {
            let c = chars[i]
            if escape {
                escape = false
                // `\d`, `\w`, `\.` — counts as one atom.
                consumeAtom()
                i += 1
                continue
            }
            if c == "\\" {
                escape = true
                i += 1
                continue
            }
            if inCharClass {
                if c == "]" {
                    inCharClass = false
                    consumeAtom()  // the whole [...] is one atom
                }
                i += 1
                continue
            }
            if c == "[" {
                inCharClass = true
                i += 1
                continue
            }
            if c == "(" {
                stack.append(Frame())
                i += 1
                // Skip group-modifier prefix `(?…` so it doesn't
                // appear as content in the new frame.
                if i < chars.count && chars[i] == "?" {
                    i += 1
                    while i < chars.count {
                        let m = chars[i]
                        if m.isLetter || m == ":" || m == "=" || m == "!" || m == "<" {
                            i += 1
                        } else {
                            break
                        }
                    }
                }
                continue
            }
            if c == ")" {
                let frame = stack.popLast() ?? Frame()
                // First atom was quantified => potentially dangerous
                // *if* the group itself is also quantified.
                if frame.firstAtomQuantified, i + 1 < chars.count {
                    let next = chars[i + 1]
                    if next == "+" || next == "*" {
                        return true
                    }
                    if next == "{" {
                        let rest = String(chars[(i+1)...])
                        if rest.range(
                            of: #"^\{\d+,\s*\}"#, options: .regularExpression
                        ) != nil {
                            return true
                        }
                    }
                }
                // The closed group is itself an atom relative to the
                // parent frame.
                consumeAtom()
                i += 1
                continue
            }
            if c == "+" || c == "*" {
                quantifyLastAtom()
                i += 1
                continue
            }
            if c == "?" {
                // `?` is bounded — doesn't induce ReDoS by itself.
                i += 1
                continue
            }
            if c == "{" {
                let rest = String(chars[i...])
                if rest.range(
                    of: #"^\{\d+,\s*\}"#, options: .regularExpression
                ) != nil {
                    quantifyLastAtom()
                }
                // Skip to the closing `}` so we don't consume the
                // digits as atoms.
                if let close = chars[i...].firstIndex(of: "}") {
                    i = close + 1
                    continue
                }
                i += 1
                continue
            }
            // Any other literal char counts as an atom.
            if c != "^" && c != "$" {
                consumeAtom()
            }
            i += 1
        }
        return false
    }

    /// True iff the pattern contains a quantified group whose
    /// alternation arms overlap. `(a|aa)+` against `aaa…` is the
    /// canonical ReDoS — the engine has multiple ways to split each
    /// outer iteration. `(cat|dog)+` is benign because the arms
    /// don't share a prefix.
    ///
    /// Heuristic: collect the literal-prefix of each alternative in
    /// the group; if any pair's shorter is a prefix of the other,
    /// flag it. Skips alternatives that contain quantifiers /
    /// metachars (those go through `hasNestedQuantifier`).
    ///
    /// False negatives possible — anyone determined to ReDoS will
    /// reach for `(a+)+` first, and that's covered by the other rule.
    static func hasAlternationUnderQuantifier(_ pattern: String) -> Bool {
        struct Frame {
            var arms: [[Character]] = [[]]
            var hasMeta: Bool = false  // skip prefix analysis if arms contain meta
        }
        var stack: [Frame] = []
        var escape = false
        var inCharClass = false
        let chars = Array(pattern)
        var i = 0

        func appendToCurrentArm(_ c: Character) {
            if var top = stack.last {
                if !top.arms.isEmpty {
                    top.arms[top.arms.count - 1].append(c)
                    stack[stack.count - 1] = top
                }
            }
        }
        func markMeta() {
            if var top = stack.last {
                top.hasMeta = true
                stack[stack.count - 1] = top
            }
        }

        while i < chars.count {
            let c = chars[i]
            if escape {
                escape = false
                appendToCurrentArm(c)
                i += 1
                continue
            }
            if c == "\\" { escape = true; i += 1; continue }
            if inCharClass {
                if c == "]" { inCharClass = false }
                i += 1
                continue
            }
            if c == "[" { inCharClass = true; markMeta(); i += 1; continue }
            if c == "(" {
                stack.append(Frame())
                i += 1
                if i < chars.count && chars[i] == "?" {
                    i += 1
                    while i < chars.count {
                        let m = chars[i]
                        if m.isLetter || m == ":" || m == "=" || m == "!" || m == "<" {
                            i += 1
                        } else {
                            break
                        }
                    }
                }
                continue
            }
            if c == "|", !stack.isEmpty {
                if var top = stack.last {
                    top.arms.append([])
                    stack[stack.count - 1] = top
                }
                i += 1
                continue
            }
            if c == ")" {
                let frame = stack.popLast() ?? Frame()
                let multiArm = frame.arms.count > 1
                let arms = frame.arms
                let isQuantified: Bool = {
                    guard i + 1 < chars.count else { return false }
                    let n = chars[i + 1]
                    if n == "+" || n == "*" { return true }
                    if n == "{" {
                        let rest = String(chars[(i+1)...])
                        return rest.range(
                            of: #"^\{\d+,\s*\}"#, options: .regularExpression
                        ) != nil
                    }
                    return false
                }()
                if multiArm, isQuantified, !frame.hasMeta {
                    // Pairwise prefix-overlap check.
                    let prefixes = arms.map { String($0) }
                    for a in 0..<prefixes.count {
                        for b in (a+1)..<prefixes.count {
                            let x = prefixes[a], y = prefixes[b]
                            if x.isEmpty || y.isEmpty { continue }
                            if x.hasPrefix(y) || y.hasPrefix(x) {
                                return true
                            }
                        }
                    }
                }
                i += 1
                continue
            }
            if c == "+" || c == "*" || c == "?" || c == "{" {
                markMeta()
                i += 1
                continue
            }
            appendToCurrentArm(c)
            i += 1
        }
        return false
    }
}
