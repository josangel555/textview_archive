import XCTest
@testable import ViewerCore

/// Regression coverage for the [S2] audit finding: `FindEngine.search`
/// enumerated user/automation regex with no wall-clock deadline, bypassing
/// the SEC-006 `RegexComplexityGuard.boundedMatches` defense on the MCP
/// `find` path. The fix routes enumeration through `boundedMatches` and
/// exposes `searchBounded(...) -> (matches, timedOut)` so the deadline is
/// surfaceable to callers.
final class Audit_Sources_ViewerCore_FindEngine_swift_BoundedTests: XCTestCase {
    private let engine = FindEngine()

    // MARK: - Parity: search() delegates to searchBounded()

    func test_search_matchesSearchBounded_underNormalDeadline() throws {
        let text = "line one\nline two\nline three"
        let q = FindQuery(pattern: "line")

        let plain = try engine.search(in: text, query: q)
        let bounded = try engine.searchBounded(in: text, query: q)

        XCTAssertFalse(bounded.timedOut)
        XCTAssertEqual(plain, bounded.matches)
    }

    func test_searchBounded_preservesLineAndColumnAccounting() throws {
        // CRLF + LF mix; column/line accounting must survive the routing
        // through boundedMatches unchanged.
        let text = "abc def\r\nfoo def\nbar"
        let bounded = try engine.searchBounded(
            in: text, query: FindQuery(pattern: "def")
        )
        XCTAssertFalse(bounded.timedOut)
        XCTAssertEqual(bounded.matches.count, 2)
        // First "def" on line 1 col 5, second on line 2 col 5.
        XCTAssertEqual(bounded.matches[0].line, 1)
        XCTAssertEqual(bounded.matches[0].column, 5)
        XCTAssertEqual(bounded.matches[1].line, 2)
        XCTAssertEqual(bounded.matches[1].column, 5)
    }

    func test_emptyQuery_isNotTimedOut() throws {
        let bounded = try engine.searchBounded(
            in: "anything", query: FindQuery(pattern: "")
        )
        XCTAssertEqual(bounded.matches, [])
        XCTAssertFalse(bounded.timedOut)
    }

    // MARK: - Deadline is actually enforced

    /// A zero deadline forces the bounded matcher to stop after the first
    /// match callback — proving enumeration is genuinely deadline-gated and
    /// not running unbounded as before the fix. `timedOut` is surfaced.
    func test_searchBounded_zeroDeadline_timesOutAndTruncates() throws {
        let text = String(repeating: "a ", count: 5_000)  // 5000 matches of "a"
        let bounded = try engine.searchBounded(
            in: text, query: FindQuery(pattern: "a"), deadline: 0
        )
        XCTAssertTrue(bounded.timedOut, "zero deadline must trip the wall-clock guard")
        // We stopped early, so we have strictly fewer than the full set.
        XCTAssertLessThan(bounded.matches.count, 5_000)
    }

    /// A polynomial-backtracking pattern passes the compile-time `reject`
    /// guard (which only models exponential shapes) yet must still be
    /// wall-clock-bounded at enumeration time. The bounded matcher caps
    /// inter-match time; this asserts the call returns within a small
    /// multiple of the deadline rather than pegging a core indefinitely.
    func test_searchBounded_polynomialPattern_returnsWithinBound() throws {
        // `a*a*a*...c` over a long run of 'a' with no terminating 'c' is a
        // classic polynomial-backtracking foot-gun that reject() does NOT
        // model (it is not exponential), so it slips past compile-time.
        let pattern = "a*a*a*a*c"
        XCTAssertNil(
            RegexComplexityGuard.reject(pattern),
            "precondition: this pattern must pass the compile-time guard"
        )
        let text = String(repeating: "a", count: 60)
        let q = FindQuery(pattern: pattern, kind: .regex)

        let deadline: TimeInterval = 0.25
        let clock = DispatchTime.now()
        let bounded = try engine.searchBounded(in: text, query: q, deadline: deadline)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - clock.uptimeNanoseconds) / 1e9

        // No match exists, so the result is empty either way; the point is
        // the call must not hang. Allow generous slack for the single
        // failing-match attempt the guard can't interrupt mid-backtrack,
        // plus host scheduling jitter — the pre-fix code had no bound at all.
        XCTAssertTrue(bounded.matches.isEmpty)
        XCTAssertLessThan(elapsed, 10.0, "enumeration must be wall-clock-bounded, not unbounded")
    }
}
