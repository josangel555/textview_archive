import XCTest
@testable import ViewerKit

final class HighlightedTextTests: XCTestCase {

    // MARK: - Empty / no-match

    func testEmptyQueryReturnsNoRanges() {
        let r = HighlightedText.ranges(in: "hello world", query: "")
        XCTAssertEqual(r.count, 0)
    }

    func testWhitespaceOnlyQueryReturnsNoRanges() {
        let r = HighlightedText.ranges(in: "hello world", query: "   ")
        XCTAssertEqual(r.count, 0)
    }

    func testEmptyHaystackReturnsNoRanges() {
        let r = HighlightedText.ranges(in: "", query: "x")
        XCTAssertEqual(r.count, 0)
    }

    func testNoMatchReturnsEmpty() {
        let r = HighlightedText.ranges(in: "hello", query: "xyz")
        XCTAssertEqual(r.count, 0)
    }

    // MARK: - Literal matching

    func testSingleMatch() {
        let text = "hello world"
        let ranges = HighlightedText.ranges(in: text, query: "world")
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(String(text[ranges[0]]), "world")
    }

    func testMultipleMatches() {
        let text = "foo bar foo baz foo"
        let ranges = HighlightedText.ranges(in: text, query: "foo")
        XCTAssertEqual(ranges.count, 3)
        for r in ranges {
            XCTAssertEqual(String(text[r]), "foo")
        }
    }

    func testCaseInsensitiveByDefault() {
        let text = "Hello WORLD hello"
        let ranges = HighlightedText.ranges(in: text, query: "hello")
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(String(text[ranges[0]]), "Hello")
        XCTAssertEqual(String(text[ranges[1]]), "hello")
    }

    func testCaseSensitiveSkipsDifferentCase() {
        let text = "Hello WORLD hello"
        let ranges = HighlightedText.ranges(
            in: text,
            query: "hello",
            mode: .literal(caseSensitive: true)
        )
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(String(text[ranges[0]]), "hello")
    }

    func testOverlappingNeedleAdvancesPastMatch() {
        // "aa" in "aaaa" should match at positions 0 and 2, not
        // 0/1/2/3 — overlap suppression is part of the contract.
        let text = "aaaa"
        let ranges = HighlightedText.ranges(in: text, query: "aa")
        XCTAssertEqual(ranges.count, 2)
    }

    func testUnicodeMatch() {
        let text = "café au lait, CAFÉ noir"
        let ranges = HighlightedText.ranges(in: text, query: "café")
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(String(text[ranges[0]]), "café")
        XCTAssertEqual(String(text[ranges[1]]), "CAFÉ")
    }

    // MARK: - Regex mode

    func testRegexValidPattern() {
        let text = "foo123 bar456 baz"
        let ranges = HighlightedText.ranges(
            in: text,
            query: "\\d+",
            mode: .regex(caseSensitive: false)
        )
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(String(text[ranges[0]]), "123")
        XCTAssertEqual(String(text[ranges[1]]), "456")
    }

    func testRegexInvalidPatternFallsBackToLiteral() {
        // `foo(` is invalid regex (unbalanced paren). Should not throw
        // and should match the literal substring instead.
        let text = "see foo( here"
        let ranges = HighlightedText.ranges(
            in: text,
            query: "foo(",
            mode: .regex(caseSensitive: false)
        )
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(String(text[ranges[0]]), "foo(")
    }

    func testRegexCaseSensitivity() {
        let text = "Foo foo FOO"
        let insensitive = HighlightedText.ranges(
            in: text, query: "foo", mode: .regex(caseSensitive: false)
        )
        XCTAssertEqual(insensitive.count, 3)
        let sensitive = HighlightedText.ranges(
            in: text, query: "foo", mode: .regex(caseSensitive: true)
        )
        XCTAssertEqual(sensitive.count, 1)
        XCTAssertEqual(String(text[sensitive[0]]), "foo")
    }

    // MARK: - SEC-004: ReDoS guard (falls back to literal)

    func testCatastrophicRegexFallsBackToLiteral() {
        // `(a+)+` is the canonical exponential shape. The guard refuses
        // it and treats the query as a literal — so a haystack that
        // contains the literal text `(a+)+` still highlights it, while
        // a haystack that doesn't matches nothing (no hang).
        let text = "pattern (a+)+ shown literally"
        let ranges = HighlightedText.ranges(
            in: text, query: "(a+)+", mode: .regex(caseSensitive: false))
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(String(text[ranges[0]]), "(a+)+")
    }

    func testCatastrophicRegexDoesNotHang() {
        // Worst-case input for `(a+)+$`: many `a`s then a non-match.
        let text = String(repeating: "a", count: 40) + "!"
        let start = Date()
        let ranges = HighlightedText.ranges(
            in: text, query: "(a+)+$", mode: .regex(caseSensitive: false))
        let elapsed = Date().timeIntervalSince(start)
        // Falls back to literal — the literal "(a+)+$" isn't present.
        XCTAssertEqual(ranges.count, 0)
        XCTAssertLessThan(elapsed, 1.0,
                          "guard must short-circuit, not backtrack for seconds")
    }

    func testAlternationOverlapUnderQuantifierRejected() {
        XCTAssertTrue(HighlightedText.isLikelyCatastrophicRegex("(a|aa)+"))
    }

    func testBenignRegexNotRejected() {
        XCTAssertFalse(HighlightedText.isLikelyCatastrophicRegex("\\d+"))
        XCTAssertFalse(HighlightedText.isLikelyCatastrophicRegex("(cat|dog)+"))
        XCTAssertFalse(HighlightedText.isLikelyCatastrophicRegex("[abc]+"))
        XCTAssertFalse(HighlightedText.isLikelyCatastrophicRegex("foo(bar)?"))
    }

    func testOversizePatternRejected() {
        let big = String(repeating: "a", count: 2048)
        XCTAssertTrue(HighlightedText.isLikelyCatastrophicRegex(big))
    }

    // MARK: - SEC-004/SEC-006: ReDoS shapes the SHAPE-GUARD misses
    //
    // `testCatastrophicRegexDoesNotHang` above only feeds `(a+)+$`, which
    // `isLikelyCatastrophicRegex` already classifies as catastrophic and
    // short-circuits to literal — so it passes for a reason orthogonal to
    // what it claims (that catastrophic INPUT can't hang the match path).
    //
    // The non-capturing `(?:a+)+`, doubly-nested `((a+))+`, and
    // alternation `(a|aa)+` forms are equally exponential, but if the
    // cheap shape-guard fails to flag them they slip through to
    // `NSRegularExpression.enumerateMatches`, where the in-block 250ms
    // `stop.pointee` flag is NOT a real timeout: `enumerateMatches` only
    // calls the block on a *completed* match, so a single match that
    // backtracks for 20s never re-enters the block to observe the budget.
    //
    // The contract each pattern must satisfy is a disjunction: EITHER the
    // shape-guard rejects it up front, OR the full `ranges()` call returns
    // under a hard wall-clock deadline. We evaluate `ranges()` on a
    // background queue and bound it with `wait(for:timeout:)` so a hang
    // surfaces as a CLEAN test failure at the deadline instead of wedging
    // the whole test process. (The orphaned worker may keep spinning if it
    // truly hangs — that is the bug these tests exist to catch.)

    /// Runs `HighlightedText.ranges(...)` off the test thread and returns
    /// the match count, or `nil` if it did not finish within `deadline`.
    /// Using a background queue + `XCTestExpectation` means a catastrophic
    /// backtrack fails the assertion at the deadline rather than hanging
    /// the runner forever (the in-block 250ms cap cannot interrupt a
    /// single still-backtracking `enumerateMatches` call).
    private func rangeCountWithinDeadline(
        haystack: String,
        pattern: String,
        deadline: TimeInterval
    ) -> Int? {
        // Standalone (untracked) expectation + standalone XCTWaiter: a
        // timeout returns `.timedOut` without auto-failing and without
        // tripping XCTest's "waited-on tracked expectation" bookkeeping,
        // so we own the failure message and the never-fulfilled case is
        // clean rather than an API-misuse error.
        let done = XCTestExpectation(description: "ranges(\(pattern)) returns")
        let box = ResultBox()
        DispatchQueue.global(qos: .userInitiated).async {
            let r = HighlightedText.ranges(
                in: haystack, query: pattern, mode: .regex(caseSensitive: false))
            box.set(r.count)
            done.fulfill()
        }
        let outcome = XCTWaiter().wait(for: [done], timeout: deadline)
        guard outcome == .completed else { return nil }
        return box.value
    }

    /// Asserts the audited disjunction for a known exponential pattern:
    /// the shape-guard rejects it OR `ranges()` returns within `deadline`.
    /// A hang is therefore a deterministic failure, not a frozen process.
    private func assertCatastrophicPatternIsBounded(
        _ pattern: String,
        deadline: TimeInterval = 2.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if HighlightedText.isLikelyCatastrophicRegex(pattern) {
            // Guard caught it — the match path is never reached. The
            // sibling `testCatastrophicRegexFallsBackToLiteral` already
            // covers the literal-fallback semantics; nothing more to do.
            return
        }
        // Guard missed it: the only thing standing between us and a hang
        // is the match-time cap, which must hold off-thread.
        let count = rangeCountWithinDeadline(
            haystack: Self.longNonMatchingHaystack,
            pattern: pattern, deadline: deadline)
        XCTAssertNotNil(
            count,
            "ReDoS: `\(pattern)` neither rejected by isLikelyCatastrophicRegex "
                + "nor bounded by the match-time cap — ranges() did not return "
                + "within \(deadline)s on a non-matching haystack (catastrophic "
                + "backtracking). The 250ms in-block flag is not a real timeout.",
            file: file, line: line)
        // It returned in time: no match expected (haystack is all 'a' then
        // a non-'a' tail that defeats the trailing `$` anchor).
        if let count { XCTAssertEqual(count, 0, file: file, line: line) }
    }

    /// A long all-`a` run with a non-`a` tail: the worst case for the
    /// `...+$` family because every prefix matches and the final anchor
    /// fails, forcing maximal backtracking on a vulnerable engine.
    private static let longNonMatchingHaystack =
        String(repeating: "a", count: 40) + "X"

    func testNonCapturingNestedQuantifierIsBounded() {
        // `(?:a+)+$` — non-capturing twin of `(a+)+$`.
        assertCatastrophicPatternIsBounded("(?:a+)+$")
    }

    func testDoublyNestedQuantifierIsBounded() {
        // `((a+))+$` — extra capturing layer around the inner `a+`.
        assertCatastrophicPatternIsBounded("((a+))+$")
    }

    func testOverlappingAlternationQuantifierIsBounded() {
        // `(a|aa)+$` — alternation arms with a shared prefix under `+`.
        assertCatastrophicPatternIsBounded("(a|aa)+$")
    }
}

/// Thread-safe one-shot holder so the background `ranges()` worker can
/// publish its result to the test thread without a data race.
private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int?
    func set(_ v: Int) { lock.lock(); stored = v; lock.unlock() }
    var value: Int? { lock.lock(); defer { lock.unlock() }; return stored }
}
