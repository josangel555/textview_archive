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

    /// TSK-122 consumption pin (the dead-channel idiom): the O(1) detector
    /// above is only a perf GUARD if the render path actually uses it.
    /// `applyHighlights` must branch on `differsOnlyByActiveMatch` and take
    /// the `stepActiveMatch` O(2) repaint for an arrow-step. A revert that
    /// deletes the fast path repaints ALL matches (up to 50k) per step —
    /// the original S2 main-thread stall — yet paints IDENTICAL pixels, so
    /// only a wiring pin catches it (no behavioral test can). Source-audit,
    /// same shape as the TSK-123 / TSK-561 dead-channel guards.
    func test_renderPath_consumesTheActiveMatchFastPath() throws {
        let src = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/ViewerUI/HexView.swift"),
            encoding: .utf8)
        XCTAssertTrue(
            src.contains("key.differsOnlyByActiveMatch(from: prev)"),
            "applyHighlights must branch on the active-match fast-path "
            + "detector (TSK-122) — without it every arrow-step repaints "
            + "all matches")
        XCTAssertTrue(
            src.contains("stepActiveMatch("),
            "the fast path must repaint only the two affected ranges, not "
            + "the full match set")
    }
}
