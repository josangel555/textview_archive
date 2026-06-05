import XCTest
@testable import ViewerKit

/// Regression coverage for the audit findings fixed in
/// `Sources/ViewerKit/HighlightedText.swift`:
///   - S2 (line 75): off-thread hard wall-clock deadline + broadened
///     `isLikelyCatastrophicRegex` (non-capturing / doubly-nested /
///     unbounded-body / stacked-bounded shapes).
///   - S3 (line 146): named-group introducer fully consumed; `(?<` /
///     `(?P<` / `(?'` rejected on the bounded path.
///   - S4 (line 132): hand-rolled brace scan (behavioral parity only —
///     correctness of the brace classification is exercised here).
///
/// Token in the filename — `Audit_Sources_ViewerKit_HighlightedText_swift`
/// — is intentional, to avoid collision with the shared
/// `HighlightedTextTests.swift`.
final class Audit_Sources_ViewerKit_HighlightedText_swift_ReDoSTests: XCTestCase {

    // MARK: - Shapes that MUST be classified catastrophic

    private let catastrophic: [String] = [
        // Classic capturing nested unbounded.
        "(a+)+$",
        "(a*)*$",
        #"(\d+){1,}$"#,
        // Non-capturing (S2): the introducer must be parsed so the inner
        // `a+` is recognized as the first atom.
        "(?:a+)+$",
        // Doubly-nested (S2): caught at the OUTER `)` via propagation.
        "((a+))+$",
        // Quantified group whose first atom is unbounded with a BOUNDED
        // outer repeat — the audit's documented hang case.
        "(.*a){26}b",
        "(.*a)*b",
        // Named groups (S3): introducer now fully consumed through `>`/`'`.
        "(?<n>a+)+$",
        "(?P<n>a+)+$",
        "(?'n'a+)+$",
        // Stacked / multiplicative bounded quantifiers (S2).
        "a{1000}{1000}",
        "a{500}{500}{500}",
        // Overlapping alternation under a quantifier (pre-existing rule,
        // must still fire).
        "(a|aa)+$",
        // Quantified named group on the bounded path (S3 defense-in-depth).
        "(?<n>a|aa)+$",
        // Truncated / opaque introducers → treated as catastrophic.
        "(?<unterminated",
    ]

    func testCatastrophicShapesAreClassified() {
        for pattern in catastrophic {
            XCTAssertTrue(
                HighlightedText.isLikelyCatastrophicRegex(pattern),
                "Expected catastrophic classification for \(pattern)")
        }
    }

    // MARK: - Benign shapes that must NOT be flagged (no over-rejection)

    private let benign: [String] = [
        "(abc)+",                 // group repeats but first atom not unbounded
        #"(?:\.\d+)+"#,           // mandatory leading `\.` anchors each iter
        "(cat|dog)+",             // alternation, no shared prefix
        #"\d{4}-\d{2}-\d{2}"#,    // bounded, single quantifiers
        "a{1,3}b",                // single bounded quantifier
        "(?<year>\\d{4})",        // benign NON-quantified named capture
        "(?:foo)bar",             // non-capturing, no quantifier
        "(?i)hello",              // inline flags
        "a+b*c?",                 // top-level quantifiers, no nesting
        "[a-z]+@[a-z]+",          // char classes + quantifier, no nesting
    ]

    func testBenignShapesAreNotFlagged() {
        for pattern in benign {
            XCTAssertFalse(
                HighlightedText.isLikelyCatastrophicRegex(pattern),
                "Expected benign classification for \(pattern)")
        }
    }

    // MARK: - End-to-end: catastrophic input never hangs the caller

    /// The load-bearing SEC-006 guarantee: even a pattern that slips past
    /// the static shape guard must return within a hard wall-clock bound
    /// because enumeration runs off-thread with a `DispatchSemaphore`
    /// deadline. The shape guard short-circuits the listed shapes to
    /// literal, but we still assert the wall-clock bound holds.
    func testNamedGroupCatastrophicDoesNotHang() {
        // 40 non-matching 'a's: the historical >4s hang for `(?<n>a+)+$`.
        let haystack = String(repeating: "a", count: 40) + "X"
        let start = Date()
        _ = HighlightedText.ranges(
            in: haystack, query: "(?<n>a+)+$", mode: .regex(caseSensitive: false))
        XCTAssertLessThan(
            Date().timeIntervalSince(start), 1.0,
            "named-group catastrophic regex must not hang the caller")
    }

    func testNonCapturingCatastrophicDoesNotHang() {
        let haystack = String(repeating: "a", count: 40) + "X"
        let start = Date()
        _ = HighlightedText.ranges(
            in: haystack, query: "(?:a+)+$", mode: .regex(caseSensitive: false))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }

    func testBoundedOuterCatastrophicDoesNotHang() {
        let haystack = String(repeating: "a", count: 40)
        let start = Date()
        _ = HighlightedText.ranges(
            in: haystack, query: "(.*a){26}b", mode: .regex(caseSensitive: false))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }

    // MARK: - Correctness preserved for ordinary regex highlighting

    func testValidRegexStillHighlights() {
        let text = "foo123bar456"
        let ranges = HighlightedText.ranges(
            in: text, query: #"\d+"#, mode: .regex(caseSensitive: false))
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(text[ranges[0]], "123")
        XCTAssertEqual(text[ranges[1]], "456")
    }

    func testBenignNamedCaptureStillHighlights() {
        let text = "year 2026 ok"
        let ranges = HighlightedText.ranges(
            in: text, query: #"(?<y>\d{4})"#, mode: .regex(caseSensitive: false))
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(text[ranges[0]], "2026")
    }
}
