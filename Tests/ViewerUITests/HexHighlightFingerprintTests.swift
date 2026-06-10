import XCTest
@testable import ViewerUI

/// TSK-141 — HexView's highlight dedupe must stay O(1), not O(matches).
///
/// The audited bug: the update-dedupe key compared the FULL match arrays
/// (up to 50k offsets) on every `updateNSViewController`. The fix is
/// `HighlightFingerprint`: an O(1) summary (count / first / last /
/// pattern length / active index / width) whose DELIBERATE approximation
/// is that two match sets with the same summary are treated as equal even
/// if middle offsets differ. These tests pin that contract — a revert
/// that stores or compares the full arrays (the synthesized `==` would
/// then distinguish middle-differing sets) goes red on the first test.
@MainActor
final class HexHighlightFingerprintTests: XCTestCase {

    private func fp(matches: [Int],
                    current: Int? = nil,
                    clicks: [Int] = [],
                    width: Int = 16) -> HexTextController.HighlightFingerprint {
        HexTextController.HighlightFingerprint(
            matches: matches,
            matchPatternLength: 4,
            currentMatch: current,
            clickOffsets: clicks,
            clickPatternLength: 2,
            width: width)
    }

    /// THE O(1) contract: same count/first/last ⇒ equal, even when middle
    /// offsets differ. This is what makes the dedupe O(1); a full-array
    /// compare (the audited regression) distinguishes these and fails here.
    func test_equalWhenOnlyMiddleOffsetsDiffer() {
        let a = fp(matches: [0, 100, 200, 300, 900])
        let b = fp(matches: [0, 150, 250, 333, 900])
        XCTAssertEqual(a, b,
            "fingerprint must be an O(1) summary (count/first/last) — "
            + "inequality here means the full arrays are being compared again")
        let c = fp(matches: [5, 100, 200], clicks: [10, 50, 90])
        let d = fp(matches: [5, 180, 200], clicks: [10, 44, 90])
        XCTAssertEqual(c, d, "same contract for clickOffsets")
    }

    /// The summary must still DISCRIMINATE on every field it keeps —
    /// otherwise the dedupe would wrongly skip real repaints.
    func test_unequalWhenSummaryFieldsChange() {
        let base = fp(matches: [0, 100, 900], current: 1)
        XCTAssertNotEqual(base, fp(matches: [0, 100, 500, 900], current: 1), "count")
        XCTAssertNotEqual(base, fp(matches: [4, 100, 900], current: 1), "first")
        XCTAssertNotEqual(base, fp(matches: [0, 100, 904], current: 1), "last")
        XCTAssertNotEqual(base, fp(matches: [0, 100, 900], current: 2), "active index")
        XCTAssertNotEqual(base, fp(matches: [0, 100, 900], current: 1, width: 32), "width")
        XCTAssertNotEqual(base, fp(matches: [0, 100, 900], current: 1, clicks: [7]), "clicks")
    }

    /// The ⌘G fast path predicate: true exactly when ONLY the active
    /// match index moved (the O(2) repaint case), false when anything
    /// else changed too.
    func test_differsOnlyByActiveMatch() {
        let a = fp(matches: [0, 100, 900], current: 0)
        let b = fp(matches: [0, 100, 900], current: 2)
        XCTAssertTrue(b.differsOnlyByActiveMatch(from: a))
        let widthChanged = fp(matches: [0, 100, 900], current: 2, width: 32)
        XCTAssertFalse(widthChanged.differsOnlyByActiveMatch(from: a))
        let setChanged = fp(matches: [0, 100, 901], current: 2)
        XCTAssertFalse(setChanged.differsOnlyByActiveMatch(from: a))
        XCTAssertFalse(a.differsOnlyByActiveMatch(from: a),
            "identical fingerprints are NOT an active-match step")
    }
}
