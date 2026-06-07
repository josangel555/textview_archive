import XCTest
@testable import ViewerCore

/// Coverage for the ReDoS-class pattern rejection guard wired into
/// `FindEngine` for `query.kind == .regex` (finding §6.1 in
/// `docs/code-review/SECURITY_CONCURRENCY_2026-05-25.md`).
final class RegexComplexityGuardTests: XCTestCase {

    // MARK: - Rejected (positive matches)

    func test_rejectsNestedQuantifier_PlusPlus() {
        XCTAssertNotNil(RegexComplexityGuard.reject("(a+)+"))
    }

    func test_rejectsNestedQuantifier_StarStar() {
        XCTAssertNotNil(RegexComplexityGuard.reject("(a*)*"))
    }

    func test_rejectsNestedQuantifier_PlusStar() {
        XCTAssertNotNil(RegexComplexityGuard.reject("(a+)*"))
    }

    func test_rejectsUnboundedQuantifierBraces() {
        // `{1,}` is unbounded — same exponential risk as `+`.
        XCTAssertNotNil(RegexComplexityGuard.reject("(a+){1,}"))
    }

    func test_acceptsNonOverlappingAlternation() {
        // `(a|b)+` is NOT ReDoS-prone — alternatives don't overlap,
        // so each outer iteration commits to one branch uniquely.
        // Documented as a deliberate non-rejection (cf. `(a|aa)+`).
        XCTAssertNil(RegexComplexityGuard.reject("(a|b)+"))
    }

    func test_rejectsAlternationUnderQuantifier_classic() {
        // The "evil regex" canonical example: `a` is a prefix of `aa`,
        // so each outer iteration has multiple ways to split.
        XCTAssertNotNil(RegexComplexityGuard.reject("^(a|aa)+$"))
    }

    // MARK: - Group-prefix tokenization (TSK-293 / TSK-279)
    // These ReDoS shapes previously slipped through because the group-
    // modifier-prefix skip over-consumed: it ate `>` of a named group as
    // the "first atom", and ate the first body letter of `(?:…)`.

    func test_rejectsNestedQuantifier_nonCapturingGroup() {
        // (?:a+)+ is the non-capturing twin of (a+)+ — equally exponential.
        XCTAssertNotNil(RegexComplexityGuard.reject("(?:a+)+"))
    }

    func test_rejectsNestedQuantifier_namedGroup() {
        // (?<name>a+)+ — ICU/NSRegularExpression named-capture syntax.
        XCTAssertNotNil(RegexComplexityGuard.reject("(?<name>a+)+"))
    }

    func test_rejectsNestedQuantifier_pythonNamedGroup() {
        XCTAssertNotNil(RegexComplexityGuard.reject("(?P<name>a+)+"))
    }

    func test_rejectsNestedQuantifier_flaggedGroup() {
        // (?i:a+)+ — flags-on-group prefix; body still nests.
        XCTAssertNotNil(RegexComplexityGuard.reject("(?i:a+)+"))
    }

    func test_rejectsAlternationUnderQuantifier_nonCapturing() {
        XCTAssertNotNil(RegexComplexityGuard.reject("(?:a|aa)+"))
    }

    func test_rejectsAlternationUnderQuantifier_namedGroup() {
        XCTAssertNotNil(RegexComplexityGuard.reject("(?<g>a|aa)+"))
    }

    // Benign group-prefix forms must STILL pass (no false positives).

    func test_acceptsAnchoredNonCapturingRepetition() {
        // (?:\.\d+)+ — first atom `\.` is unquantified; each iteration is
        // anchored, so this is NOT exponential.
        XCTAssertNil(RegexComplexityGuard.reject(#"(?:\.\d+)+"#))
    }

    func test_acceptsNamedGroupBoundedBody() {
        XCTAssertNil(RegexComplexityGuard.reject(#"(?<year>\d{4})"#))
    }

    func test_acceptsInlineFlagsThenLiteral() {
        XCTAssertNil(RegexComplexityGuard.reject("(?i)hello"))
    }

    func test_acceptsLookahead_and_lookbehind() {
        XCTAssertNil(RegexComplexityGuard.reject("foo(?=bar)"))
        XCTAssertNil(RegexComplexityGuard.reject("(?<=foo)bar"))
    }

    func test_rejectsExcessivelyLongPattern() {
        let big = String(repeating: "a", count: 2048)
        XCTAssertNotNil(RegexComplexityGuard.reject(big))
    }

    // MARK: - Accepted (negative matches)

    func test_acceptsSimpleLiteral() {
        XCTAssertNil(RegexComplexityGuard.reject("hello"))
    }

    func test_acceptsAnchoredLiteral() {
        XCTAssertNil(RegexComplexityGuard.reject("^abc$"))
    }

    func test_acceptsBoundedQuantifier() {
        // `{3}` is fixed-count and safe.
        XCTAssertNil(RegexComplexityGuard.reject("(a){3}"))
    }

    func test_acceptsBoundedRange() {
        // `{1,5}` is bounded above and safe.
        XCTAssertNil(RegexComplexityGuard.reject("(a){1,5}"))
    }

    func test_acceptsSinglePlus() {
        XCTAssertNil(RegexComplexityGuard.reject("a+b"))
    }

    func test_acceptsAlternationWithoutQuantifier() {
        XCTAssertNil(RegexComplexityGuard.reject("(cat|dog)"))
    }

    func test_acceptsCharClassWithBrackets() {
        // `[abc]+` is safe — character class, not a group, so no
        // backtracking ambiguity.
        XCTAssertNil(RegexComplexityGuard.reject("[abc]+"))
    }

    func test_acceptsEscapedParen() {
        // `\(` is a literal open-paren and does not start a group.
        XCTAssertNil(RegexComplexityGuard.reject(#"\(a+\)+"#))
    }

    // MARK: - Integration with FindEngine

    func test_findEngine_throwsUnsafeRegex_onNestedQuantifier() {
        let engine = FindEngine()
        let q = FindQuery(pattern: "(a+)+", kind: .regex)
        XCTAssertThrowsError(try engine.search(in: "aaaaa", query: q)) { err in
            guard case FindError.unsafeRegex = err else {
                return XCTFail("Expected .unsafeRegex, got \(err)")
            }
        }
    }

    func test_findEngine_literalQuery_neverRejected() {
        // The literal branch escapes everything, so a user typing
        // "(a+)+" as a literal should match a string containing
        // exactly that — never bounce off the guard.
        let engine = FindEngine()
        let q = FindQuery(pattern: "(a+)+", kind: .literal)
        let matches = try? engine.search(in: "before (a+)+ after", query: q)
        XCTAssertEqual(matches?.count, 1)
    }

    func test_findEngine_simpleRegex_stillWorks() {
        let engine = FindEngine()
        let q = FindQuery(pattern: "ab+c", kind: .regex)
        let matches = try? engine.search(in: "abbbc and abc", query: q)
        XCTAssertEqual(matches?.count, 2)
    }

    // MARK: - SEC-006: match-time deadline (boundedMatches)

    func test_boundedMatches_returnsAllMatchesForBenignPattern() throws {
        let re = try NSRegularExpression(pattern: "\\d+")
        let text = "1 22 333 4444"
        let full = NSRange(location: 0, length: (text as NSString).length)
        let r = RegexComplexityGuard.boundedMatches(re, in: text, range: full)
        XCTAssertEqual(r.matches.count, 4)
        XCTAssertFalse(r.timedOut, "benign pattern shouldn't hit the deadline")
    }

    func test_boundedMatches_zeroDeadlineCutsEnumerationShort() throws {
        // A zero (already-expired) budget makes the very first callback
        // stop. We still expect the first match to be recorded (it's
        // appended before the deadline check), then a clean bail.
        let re = try NSRegularExpression(pattern: "\\d+")
        let text = "1 22 333 4444"
        let full = NSRange(location: 0, length: (text as NSString).length)
        let r = RegexComplexityGuard.boundedMatches(
            re, in: text, range: full, deadline: 0)
        XCTAssertTrue(r.timedOut, "zero deadline must report timedOut")
        XCTAssertLessThan(r.matches.count, 4,
                          "enumeration should stop before collecting all matches")
    }

    func test_boundedMatches_emptyResultWhenNoMatch() throws {
        let re = try NSRegularExpression(pattern: "zzz")
        let text = "no matches here"
        let full = NSRange(location: 0, length: (text as NSString).length)
        let r = RegexComplexityGuard.boundedMatches(re, in: text, range: full)
        XCTAssertTrue(r.matches.isEmpty)
        XCTAssertFalse(r.timedOut)
    }
}
