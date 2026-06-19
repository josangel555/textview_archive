import XCTest
import AppKit
@testable import ViewerCore

/// Teeth for `SpellCheckEngine` (TSK-685). `NSSpellChecker` is host-headless, so
/// these run on the merge gate. Assertions are STRUCTURAL invariants (not "is
/// THIS word wrong") so they don't rot when Apple updates its dictionaries:
///  - clean English text → no issues,
///  - an obvious nonsense token → at least one issue, whose range slices the
///    exact misspelled substring back out of the source,
///  - the issue's 1-based line/column point at the word,
///  - ignored words are dropped,
///  - empty input is a no-op,
///  - suggestions are opt-in.
///
/// Every test guards on `en` being installed so the suite degrades to a skip on
/// a machine without the English dictionary rather than a false red.
final class SpellCheckEngineTests: XCTestCase {

    private let nonsense = "asdkjhqwexyz"   // not a word in any locale

    private func requireEnglish() throws {
        try XCTSkipUnless(
            SpellCheckEngine.availableLanguages.contains(where: { $0.hasPrefix("en") }),
            "No English spell dictionary installed on this host"
        )
    }

    private func engine(ignoring: Set<String> = []) -> SpellCheckEngine {
        SpellCheckEngine(language: "en", ignoredWords: ignoring)
    }

    func test_cleanText_hasNoIssues() throws {
        try requireEnglish()
        let issues = engine().misspelledSpans(in: "The quick brown fox jumps over the lazy dog.")
        XCTAssertTrue(issues.isEmpty, "clean text flagged: \(issues.map(\.word))")
        XCTAssertFalse(engine().hasMisspelling(in: "The quick brown fox."))
    }

    func test_emptyText_isNoOp() throws {
        try requireEnglish()
        XCTAssertEqual(engine().misspelledSpans(in: ""), [])
        XCTAssertFalse(engine().hasMisspelling(in: ""))
    }

    func test_nonsenseToken_isFlagged_andRangeSlicesTheWord() throws {
        try requireEnglish()
        let text = "Here is \(nonsense) word."
        let issues = engine().misspelledSpans(in: text)
        XCTAssertFalse(issues.isEmpty, "nonsense token not flagged")
        let ns = text as NSString
        // The flagged range must extract exactly the word reported on the issue
        // — proving the range is a usable index into the source text.
        for issue in issues {
            XCTAssertEqual(ns.substring(with: issue.range), issue.word)
        }
        XCTAssertTrue(issues.contains { $0.word == nonsense },
                      "expected '\(nonsense)' among \(issues.map(\.word))")
        XCTAssertTrue(engine().hasMisspelling(in: text))
    }

    func test_lineAndColumn_pointAtTheWord() throws {
        try requireEnglish()
        let text = "first line ok\nsecond \(nonsense) here"
        let issues = engine().misspelledSpans(in: text)
        guard let issue = issues.first(where: { $0.word == nonsense }) else {
            return XCTFail("nonsense not flagged: \(issues.map(\.word))")
        }
        XCTAssertEqual(issue.line, 2, "should be on the second line")
        // "second " is 7 UTF-16 units → column 8 (1-based).
        XCTAssertEqual(issue.column, 8)
    }

    func test_ignoredWord_isDropped_caseInsensitive() throws {
        try requireEnglish()
        let text = "Here is \(nonsense) word."
        let withIgnore = engine(ignoring: [nonsense.uppercased()])  // case-fold
        XCTAssertFalse(withIgnore.misspelledSpans(in: text).contains { $0.word == nonsense },
                       "ignored word still flagged")
        XCTAssertFalse(withIgnore.hasMisspelling(in: text),
                       "hasMisspelling ignored the allow-list")
    }

    func test_multipleMisspellings_areReturnedInDocumentOrder() throws {
        try requireEnglish()
        let a = "asdkjh"
        let b = "qwexyz"
        let text = "lead \(a) middle \(b) tail"
        let issues = engine().misspelledSpans(in: text).filter { $0.word == a || $0.word == b }
        XCTAssertEqual(issues.count, 2)
        XCTAssertEqual(issues.map(\.word), [a, b], "not in document order")
        // Ranges must be strictly increasing and non-overlapping.
        XCTAssertLessThan(issues[0].range.location + issues[0].range.length,
                          issues[1].range.location)
    }

    func test_suggestions_areOptIn() throws {
        try requireEnglish()
        let text = "Here is \(nonsense)."
        let without = engine().misspelledSpans(in: text, withSuggestions: false)
        XCTAssertTrue(without.allSatisfy { $0.suggestions.isEmpty },
                      "suggestions populated when not requested")
        // Opt-in is requested; we don't assert non-empty (a true nonsense token
        // may have zero guesses) — only that the path runs without throwing and
        // returns the same span set.
        let with = engine().misspelledSpans(in: text, withSuggestions: true)
        XCTAssertEqual(with.map(\.word), without.map(\.word))
    }

    func test_isLanguageAvailable() throws {
        // nil language is always "available" (auto/default).
        XCTAssertTrue(SpellCheckEngine(language: nil).isLanguageAvailable)
        // A bogus tag should not be among the installed dictionaries.
        XCTAssertFalse(SpellCheckEngine(language: "zz_NOPE").isLanguageAvailable)
        let bogus = SpellCheckEngine(language: "zz_NOPE")
        // An unavailable language reports no findings rather than wrong ones.
        XCTAssertEqual(bogus.misspelledSpans(in: "Here is \(nonsense)."), [])
        XCTAssertFalse(bogus.hasMisspelling(in: "Here is \(nonsense)."))
    }

    func test_lineColumn_acrossCRLF() throws {
        try requireEnglish()
        // CRLF line breaks must still resolve to the right line.
        let text = "alpha\r\nbeta \(nonsense) gamma"
        guard let issue = engine().misspelledSpans(in: text).first(where: { $0.word == nonsense }) else {
            return XCTFail("nonsense not flagged")
        }
        XCTAssertEqual(issue.line, 2)
        // "beta " = 5 UTF-16 units on line 2 → column 6.
        XCTAssertEqual(issue.column, 6)
    }
}
