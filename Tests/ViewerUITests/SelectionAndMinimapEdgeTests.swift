import XCTest
@testable import ViewerUI

/// Edge-case coverage for `SelectionHighlightEngine` boundaries and
/// `FindMinimapLayout` tick-count / nearest-line edge cases. Pure
/// value types — runs on the host.
final class SelectionAndMinimapEdgeTests: XCTestCase {

    // MARK: - SelectionHighlight: boundaries

    private func engine(
        maxBytes: Int = 5 * 1024 * 1024,
        maxLen: Int = 100,
        minLen: Int = 2,
        wordLike: Bool = false  // we test boundary cases without word-like guard
    ) -> SelectionHighlightEngine {
        SelectionHighlightEngine(policy: .init(
            maxHaystackBytes: maxBytes,
            maxSelectionLength: maxLen,
            minSelectionLength: minLen,
            requireWordLike: wordLike
        ))
    }

    func test_selectionAtStartOfDocument_findsLaterOccurrences() {
        let text = "foo bar foo baz"
        let sel = NSRange(location: 0, length: 3)  // first "foo"
        let out = engine().otherOccurrences(
            in: text, selection: sel, haystackByteCount: text.utf8.count)
        XCTAssertEqual(out, [NSRange(location: 8, length: 3)])
    }

    func test_selectionAtEndOfDocument_findsEarlierOccurrences() {
        let text = "foo bar foo"
        let sel = NSRange(location: 8, length: 3)  // last "foo"
        let out = engine().otherOccurrences(
            in: text, selection: sel, haystackByteCount: text.utf8.count)
        XCTAssertEqual(out, [NSRange(location: 0, length: 3)])
    }

    func test_multibyteUtf8_emoji_findsOtherOccurrences() {
        // Each emoji is 4 bytes UTF-8 but 2 UTF-16 units. NSRange uses
        // UTF-16 indexing, so the selection length is 2 per emoji.
        let text = "🌟 hello 🌟 world 🌟"
        // First star at UTF-16 location 0, length 2.
        let sel = NSRange(location: 0, length: 2)
        let out = engine().otherOccurrences(
            in: text, selection: sel, haystackByteCount: text.utf8.count)
        XCTAssertEqual(out.count, 2)
    }

    func test_multibyteUtf8_accentedLetter_findsOtherOccurrences() {
        // 'é' is one Unicode scalar (1 UTF-16 unit) but 2 bytes UTF-8.
        // With minLen=1 we can test single-char selections.
        let eng = SelectionHighlightEngine(policy: .init(
            minSelectionLength: 1, requireWordLike: false))
        let text = "café crépé"
        let sel = NSRange(location: 3, length: 1)  // "é"
        let out = eng.otherOccurrences(
            in: text, selection: sel, haystackByteCount: text.utf8.count)
        XCTAssertEqual(out.count, 2)  // both é. in "crépé"
    }

    func test_selectionLengthBelowMin_returnsEmpty() {
        let text = "ab ab ab"
        let sel = NSRange(location: 0, length: 1)  // length 1 < minLen 2
        let out = engine().otherOccurrences(
            in: text, selection: sel, haystackByteCount: text.utf8.count)
        XCTAssertTrue(out.isEmpty)
    }

    func test_haystackOverByteCap_returnsEmpty_evenWithMatches() {
        let eng = SelectionHighlightEngine(policy: .init(
            maxHaystackBytes: 10,  // tiny cap
            minSelectionLength: 2, requireWordLike: false))
        let text = "foo foo foo foo foo foo"  // way over 10 bytes
        let sel = NSRange(location: 0, length: 3)
        let out = eng.otherOccurrences(
            in: text, selection: sel, haystackByteCount: text.utf8.count)
        XCTAssertTrue(out.isEmpty)
    }

    func test_invalidSelection_outOfBounds_returnsEmpty() {
        let text = "short"
        let sel = NSRange(location: 100, length: 5)
        let out = engine().otherOccurrences(
            in: text, selection: sel, haystackByteCount: text.utf8.count)
        XCTAssertTrue(out.isEmpty)
    }

    // MARK: - FindMinimapLayout: tick edge cases

    func test_minimap_zeroTicks_returnsEmpty() {
        XCTAssertEqual(
            FindMinimapLayout.ticks(matchLines: [], totalLines: 100, canvasHeight: 200),
            []
        )
    }

    func test_minimap_oneTick_lands_inBounds() {
        let out = FindMinimapLayout.ticks(
            matchLines: [50], totalLines: 100, canvasHeight: 200)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].line, 50)
        XCTAssertGreaterThanOrEqual(out[0].y, 0)
        XCTAssertLessThanOrEqual(out[0].y, 200)
    }

    func test_minimap_tenThousandTicks_doesNotCrash_andStaysInBounds() {
        let lines = (1...10_000).map { $0 }
        let out = FindMinimapLayout.ticks(
            matchLines: lines, totalLines: 10_000, canvasHeight: 500)
        XCTAssertEqual(out.count, 10_000)
        for t in out {
            XCTAssertGreaterThanOrEqual(t.y, 0)
            XCTAssertLessThanOrEqual(t.y, 500)
        }
    }

    func test_minimap_zeroCanvas_returnsEmpty() {
        XCTAssertEqual(
            FindMinimapLayout.ticks(matchLines: [1, 2], totalLines: 10, canvasHeight: 0),
            []
        )
    }

    func test_minimap_zeroTotalLines_returnsEmpty() {
        XCTAssertEqual(
            FindMinimapLayout.ticks(matchLines: [1], totalLines: 0, canvasHeight: 100),
            []
        )
    }

    func test_minimap_negativeCanvas_returnsEmpty() {
        XCTAssertEqual(
            FindMinimapLayout.ticks(matchLines: [1], totalLines: 10, canvasHeight: -10),
            []
        )
    }

    func test_minimap_currentMatchFlagged_singleTickIsCurrent() {
        let out = FindMinimapLayout.ticks(
            matchLines: [10, 20, 30],
            totalLines: 100,
            canvasHeight: 300,
            currentMatchIndex: 1)
        XCTAssertEqual(out.map(\.isCurrent), [false, true, false])
    }

    func test_minimap_currentMatchIndexOutOfRange_isIgnored() {
        let out = FindMinimapLayout.ticks(
            matchLines: [10, 20],
            totalLines: 100,
            canvasHeight: 300,
            currentMatchIndex: 99)
        XCTAssertEqual(out.map(\.isCurrent), [false, false])
    }

    // MARK: - nearestLine edge cases

    func test_nearestLine_outsideTolerance_returnsNil() {
        let line = FindMinimapLayout.nearestLine(
            toY: 1000,                  // way below any tick
            matchLines: [1, 10],
            totalLines: 100,
            canvasHeight: 200,
            tolerance: 4)
        XCTAssertNil(line)
    }

    func test_nearestLine_emptyMatchLines_returnsNil() {
        let line = FindMinimapLayout.nearestLine(
            toY: 50,
            matchLines: [],
            totalLines: 100,
            canvasHeight: 200)
        XCTAssertNil(line)
    }

    func test_nearestLine_picksClosestTick() {
        // 3 evenly-spaced ticks at lines 25/50/75 over a 100-line doc,
        // 200pt canvas → y ≈ 48 / 98 / 148. A click at y=50 should
        // pick line 25 (dy=2) over line 50 (dy=48).
        let line = FindMinimapLayout.nearestLine(
            toY: 50,
            matchLines: [25, 50, 75],
            totalLines: 100,
            canvasHeight: 200,
            tolerance: 10)
        XCTAssertEqual(line, 25)
    }
}
