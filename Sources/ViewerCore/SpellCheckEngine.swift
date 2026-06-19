import Foundation
import AppKit

/// One misspelled span found by a spell-check pass.
///
/// `range` is a UTF-16 `NSRange` into the *checked text* (the unit
/// `NSSpellChecker` itself speaks, and what an `NSTextView`/`NSTextStorage`
/// addresses), so callers can apply attributes / temporary underlines without
/// re-deriving offsets. `line`/`column` are 1-based and derived for UIs that
/// surface findings as a list (like `MarkdownLint` / `JSONSyntaxChecker`),
/// pointing at the START of the misspelled word.
public struct SpellingIssue: Equatable, Sendable {
    public let word: String
    public let range: NSRange
    public let line: Int
    public let column: Int
    /// Correction candidates, best-first (may be empty). Computed lazily by the
    /// engine only when `suggestions` is requested, so the bulk check pass that
    /// just needs ranges doesn't pay for guess generation per word.
    public let suggestions: [String]

    public init(word: String, range: NSRange, line: Int, column: Int, suggestions: [String] = []) {
        self.word = word
        self.range = range
        self.line = line
        self.column = column
        self.suggestions = suggestions
    }
}

/// Host-testable wrapper over `NSSpellChecker` that returns the misspelled
/// spans of a piece of text in a given language (TSK-685).
///
/// `NSSpellChecker` is a process-wide AppKit service (`.shared`) that runs
/// fully headless — no window, no run loop — so this whole engine is exercised
/// on the host merge gate, not the VM (unlike the CodeMirror render path). It
/// is the de-risked, correctness-pinned core that the editor surface
/// (continuous spell-check on an editable text view, or an on-demand "check
/// spelling" pass that lists findings) consumes; the surface wiring lives
/// separately, matching the `TextTools` / `MarkdownLint` split.
///
/// Determinism note: spell results depend on the *installed* dictionaries and
/// the user's learned/ignored words. We pin nothing about WHICH words are
/// wrong (that's the OS's call) — the tests assert structural invariants
/// (clean text → no issues; an obvious nonsense token → at least one issue;
/// ranges line up with the words; an ignored word is dropped) so they don't
/// rot when Apple ships a dictionary update.
public struct SpellCheckEngine {

    /// The BCP-47 language tag to check against, e.g. `"en"`, `"en_US"`,
    /// `"fr"`. `nil` (the default) lets `NSSpellChecker` auto-detect /
    /// fall back to its current language.
    public let language: String?

    /// Words the caller wants treated as correct regardless of the dictionary
    /// (project jargon, identifiers, the user's personal allow-list). Matched
    /// case-insensitively against the misspelled token. Applied by us AFTER
    /// `NSSpellChecker` runs so it's independent of the shared checker's own
    /// (process-global, persisted) ignore list — keeping the engine pure with
    /// respect to its inputs.
    public let ignoredWords: Set<String>

    /// `true` to also surface grammar issues alongside spelling. Off by
    /// default; spelling is the primary ask and grammar markedly raises noise.
    public let checkGrammar: Bool

    public init(language: String? = nil,
                ignoredWords: Set<String> = [],
                checkGrammar: Bool = false) {
        self.language = language
        // Normalize the allow-list to lowercase once so the per-word membership
        // test is a single lowercased lookup rather than a case-fold per check.
        self.ignoredWords = Set(ignoredWords.map { $0.lowercased() })
        self.checkGrammar = checkGrammar
    }

    /// Whether the requested `language` is one the spell checker can serve.
    /// `nil` language is always considered available (auto/default). Useful for
    /// a UI to disable the feature or warn when the dictionary isn't installed
    /// rather than silently returning "no misspellings".
    public var isLanguageAvailable: Bool {
        guard let language else { return true }
        return SpellCheckEngine.availableLanguages.contains(language)
    }

    /// The spell-check languages installed on this machine (BCP-47 tags).
    public static var availableLanguages: [String] {
        NSSpellChecker.shared.availableLanguages
    }

    /// Find every misspelled span in `text`, in document order.
    ///
    /// - Parameter withSuggestions: when `true`, each issue carries correction
    ///   candidates (an extra `NSSpellChecker.guesses` call per word). Default
    ///   `false` — the bulk underline/highlight pass only needs ranges.
    ///
    /// Iterates `checkSpelling(of:startingAt:…)` from each found span's end so
    /// the whole text is swept in O(misspellings) checker round-trips. A
    /// dedicated document tag is allocated and released per call so concurrent
    /// callers don't share `NSSpellChecker`'s per-document ignore state.
    public func misspelledSpans(in text: String, withSuggestions: Bool = false) -> [SpellingIssue] {
        guard !text.isEmpty else { return [] }
        // No installed dictionary for the requested language ⇒ checkSpelling
        // would fall back to the current language and give misleading results;
        // be explicit and report nothing rather than wrong findings.
        guard isLanguageAvailable else { return [] }

        let checker = NSSpellChecker.shared
        let tag = NSSpellChecker.uniqueSpellDocumentTag()
        defer { checker.closeSpellDocument(withTag: tag) }

        let ns = text as NSString
        let length = ns.length
        let lineIndex = LineColumnIndex(text: ns)
        var issues: [SpellingIssue] = []
        var start = 0

        while start < length {
            let range = checker.checkSpelling(
                of: text,
                startingAt: start,
                language: language,
                wrap: false,
                inSpellDocumentWithTag: tag,
                wordCount: nil
            )
            // location == NSNotFound (nothing left) or a zero-length span
            // (defensive: would otherwise spin) terminates the sweep.
            guard range.location != NSNotFound, range.length > 0 else { break }

            let word = ns.substring(with: range)
            // Always advance past this span first so an ignored word can't loop.
            start = range.location + range.length

            if ignoredWords.contains(word.lowercased()) { continue }

            let (line, column) = lineIndex.position(ofUTF16Offset: range.location)
            let suggestions = withSuggestions ? self.suggestions(for: word) : []
            issues.append(SpellingIssue(
                word: word, range: range, line: line, column: column,
                suggestions: suggestions
            ))
        }

        if checkGrammar {
            issues.append(contentsOf: grammarIssues(in: text, lineIndex: lineIndex))
        }
        // Spelling sweep is already document-ordered; grammar appended after.
        // Re-sort so a mixed list is monotonically positioned for list UIs.
        if checkGrammar {
            issues.sort { $0.range.location < $1.range.location }
        }
        return issues
    }

    /// Correction candidates for a single (mis)spelled word, best-first.
    /// Empty when the checker has no guesses. Exposed so a context-menu /
    /// quick-fix UI can fetch suggestions on demand for one word.
    public func suggestions(for word: String) -> [String] {
        let checker = NSSpellChecker.shared
        let ns = word as NSString
        let full = NSRange(location: 0, length: ns.length)
        return checker.guesses(
            forWordRange: full,
            in: word,
            language: language,
            inSpellDocumentWithTag: 0
        ) ?? []
    }

    /// `true` if `text` contains at least one (non-ignored) misspelling.
    /// Cheaper than building the full issue list when a caller only needs a
    /// boolean (e.g. a status-bar dot). Short-circuits on the first finding.
    public func hasMisspelling(in text: String) -> Bool {
        guard !text.isEmpty, isLanguageAvailable else { return false }
        let checker = NSSpellChecker.shared
        let tag = NSSpellChecker.uniqueSpellDocumentTag()
        defer { checker.closeSpellDocument(withTag: tag) }
        let ns = text as NSString
        let length = ns.length
        var start = 0
        while start < length {
            let range = checker.checkSpelling(
                of: text, startingAt: start, language: language,
                wrap: false, inSpellDocumentWithTag: tag, wordCount: nil
            )
            guard range.location != NSNotFound, range.length > 0 else { return false }
            let word = ns.substring(with: range)
            start = range.location + range.length
            if !ignoredWords.contains(word.lowercased()) { return true }
        }
        return false
    }

    // MARK: - Grammar

    private func grammarIssues(in text: String, lineIndex: LineColumnIndex) -> [SpellingIssue] {
        let checker = NSSpellChecker.shared
        let ns = text as NSString
        var details: NSArray?
        let range = checker.checkGrammar(
            of: text,
            startingAt: 0,
            language: language,
            wrap: false,
            inSpellDocumentWithTag: 0,
            details: &details
        )
        guard range.location != NSNotFound, range.length > 0 else { return [] }
        let word = ns.substring(with: range)
        let (line, column) = lineIndex.position(ofUTF16Offset: range.location)
        return [SpellingIssue(word: word, range: range, line: line, column: column)]
    }
}

/// Maps a UTF-16 offset (the unit `NSSpellChecker`/`NSString` ranges use) to a
/// 1-based (line, column). Precomputes the start offset of every line once so
/// each lookup is an O(log n) binary search rather than rescanning the string.
private struct LineColumnIndex {
    /// `lineStarts[k]` = UTF-16 offset of the first character of line `k+1`.
    private let lineStarts: [Int]

    init(text ns: NSString) {
        var starts: [Int] = [0]
        let length = ns.length
        var i = 0
        // Walk by composed line ranges so CRLF / CR / LF / U+2028 / U+2029 are
        // all honored exactly as NSString defines a line break.
        while i < length {
            let lineRange = ns.lineRange(for: NSRange(location: i, length: 0))
            let next = lineRange.location + lineRange.length
            if next <= i { break }          // defensive against non-advance
            if next < length { starts.append(next) }
            i = next
        }
        self.lineStarts = starts
    }

    /// 1-based line and column for a UTF-16 offset.
    func position(ofUTF16Offset offset: Int) -> (line: Int, column: Int) {
        // Largest line-start <= offset.
        var lo = 0
        var hi = lineStarts.count - 1
        var lineIdx = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lineStarts[mid] <= offset {
                lineIdx = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        let column = offset - lineStarts[lineIdx] + 1
        return (lineIdx + 1, column)
    }
}
