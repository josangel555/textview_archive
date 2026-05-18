import XCTest
@testable import ViewerUI

/// Direct coverage for `SourceTextController.findRanges` — the literal
/// and regex paths that power the Cmd+F bar in the source view.
///
/// Lives here because the symbol is internal to ViewerUI and the find
/// bar's regex toggle (Batch B, commit 2457015) landed without
/// dedicated tests. Catching invalid-regex, multiline, and case-
/// insensitive edge cases here is cheap; doing it through the UI is
/// expensive.
@MainActor
final class TextSearchTests: XCTestCase {

    // MARK: - Empty inputs

    func test_empty_query_returns_nothing() {
        let r = SourceTextController.findRanges(in: "hello", query: "", caseSensitive: false)
        XCTAssertEqual(r.count, 0)
    }

    func test_empty_haystack_returns_nothing() {
        let r = SourceTextController.findRanges(in: "", query: "x", caseSensitive: false)
        XCTAssertEqual(r.count, 0)
    }

    // MARK: - Literal path

    func test_literal_basic() {
        let r = SourceTextController.findRanges(
            in: "the quick brown fox", query: "qu", caseSensitive: false
        )
        XCTAssertEqual(r.map(\.location), [4])
        XCTAssertEqual(r.map(\.length),   [2])
    }

    func test_literal_case_insensitive_by_default() {
        let r = SourceTextController.findRanges(
            in: "Foo foo FOO", query: "foo", caseSensitive: false
        )
        XCTAssertEqual(r.count, 3)
    }

    func test_literal_case_sensitive() {
        let r = SourceTextController.findRanges(
            in: "Foo foo FOO", query: "foo", caseSensitive: true
        )
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].location, 4)
    }

    func test_literal_overlapping_advances_by_at_least_one() {
        // "aaa" with query "aa" → matches at 0 then 1 (literal scan
        // with `next = location + max(length, 1)`). Don't infinite-loop.
        let r = SourceTextController.findRanges(in: "aaaa", query: "aa", caseSensitive: false)
        XCTAssertGreaterThan(r.count, 0)
        XCTAssertLessThanOrEqual(r.count, 4)  // sanity ceiling
    }

    // MARK: - Regex path

    func test_regex_basic_word() {
        let r = SourceTextController.findRanges(
            in: "alpha beta gamma", query: #"\w+"#,
            caseSensitive: false, isRegex: true
        )
        XCTAssertEqual(r.count, 3)
        XCTAssertEqual(r.map(\.length), [5, 4, 5])
    }

    func test_regex_case_insensitive_by_default() {
        let r = SourceTextController.findRanges(
            in: "Foo foo FOO", query: "foo",
            caseSensitive: false, isRegex: true
        )
        XCTAssertEqual(r.count, 3)
    }

    func test_regex_case_sensitive() {
        let r = SourceTextController.findRanges(
            in: "Foo foo FOO", query: "foo",
            caseSensitive: true, isRegex: true
        )
        XCTAssertEqual(r.count, 1)
    }

    func test_regex_anchors_match_lines() {
        // `^a` should match start of every line (anchorsMatchLines is
        // on by default per the implementation).
        let r = SourceTextController.findRanges(
            in: "alpha\nant\nbravo", query: "^a",
            caseSensitive: false, isRegex: true
        )
        XCTAssertEqual(r.count, 2)
    }

    func test_regex_invalid_pattern_yields_zero_matches() {
        // Unbalanced paren is a parse error. The find bar relies on
        // this swallowing rather than crashing — verify directly.
        let r = SourceTextController.findRanges(
            in: "anything", query: "(unbalanced",
            caseSensitive: false, isRegex: true
        )
        XCTAssertEqual(r.count, 0)
    }

    func test_regex_zero_width_match_does_not_explode() {
        // `^` matches at every line start zero-width. NSRegularExpression
        // gracefully handles zero-length matches via .matches API; verify
        // we don't infinite-loop or crash.
        let r = SourceTextController.findRanges(
            in: "a\nb\nc", query: "^",
            caseSensitive: false, isRegex: true
        )
        XCTAssertGreaterThan(r.count, 0)
        for m in r {
            XCTAssertEqual(m.length, 0, "expected zero-width matches for `^`")
        }
    }

    func test_regex_unicode_aware() {
        // `\w` in NSRegularExpression matches Unicode letters; ensure
        // the path doesn't fall through to ASCII-only.
        let r = SourceTextController.findRanges(
            in: "café résumé", query: #"\w+"#,
            caseSensitive: false, isRegex: true
        )
        XCTAssertEqual(r.count, 2)
    }

    // MARK: - summarize (n/N string)

    /// Find bar count formatting. The bar reads `sourceFindMatchSummary`
    /// directly so the format is a UI contract.
    func test_summarize_emits_one_indexed_progress() {
        XCTAssertEqual(TextDisplayView.summarize(matchCount: 12, current: 2), "3/12")
        XCTAssertEqual(TextDisplayView.summarize(matchCount: 1, current: 0), "1/1")
    }

    func test_summarize_empty_when_no_matches_or_no_current() {
        XCTAssertEqual(TextDisplayView.summarize(matchCount: 0, current: nil), "")
        XCTAssertEqual(TextDisplayView.summarize(matchCount: 0, current: 0), "")
        XCTAssertEqual(TextDisplayView.summarize(matchCount: 5, current: nil), "")
    }
}
