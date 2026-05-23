import XCTest
@testable import ViewerUI

/// Pure-logic coverage for `FindMinimapLayout`. Doesn't render — just
/// the y-position math + the click→nearest-line inverse.
final class FindMinimapLayoutTests: XCTestCase {

    // MARK: - ticks()

    func test_emptyMatchLines_returnsEmpty() {
        let out = FindMinimapLayout.ticks(
            matchLines: [], totalLines: 100, canvasHeight: 200
        )
        XCTAssertTrue(out.isEmpty)
    }

    func test_zeroTotalLines_returnsEmpty() {
        let out = FindMinimapLayout.ticks(
            matchLines: [1, 2, 3], totalLines: 0, canvasHeight: 200
        )
        XCTAssertTrue(out.isEmpty)
    }

    func test_zeroOrNegativeCanvasHeight_returnsEmpty() {
        let out = FindMinimapLayout.ticks(
            matchLines: [1, 2, 3], totalLines: 100, canvasHeight: 0
        )
        XCTAssertTrue(out.isEmpty)
    }

    func test_firstLineMapsToZero() {
        let ticks = FindMinimapLayout.ticks(
            matchLines: [1], totalLines: 100, canvasHeight: 200
        )
        XCTAssertEqual(ticks.count, 1)
        XCTAssertEqual(ticks[0].y, 0, accuracy: 0.01)
        XCTAssertEqual(ticks[0].line, 1)
        XCTAssertFalse(ticks[0].isCurrent)
    }

    func test_lastLineMapsNearCanvasHeight() {
        let ticks = FindMinimapLayout.ticks(
            matchLines: [100], totalLines: 100, canvasHeight: 200
        )
        XCTAssertEqual(ticks.count, 1)
        // (100-1)/100 * 200 = 198
        XCTAssertEqual(ticks[0].y, 198, accuracy: 0.01)
    }

    func test_midpoint_landsHalfway() {
        let ticks = FindMinimapLayout.ticks(
            matchLines: [51], totalLines: 100, canvasHeight: 200
        )
        // (51-1)/100 * 200 = 100
        XCTAssertEqual(ticks[0].y, 100, accuracy: 0.01)
    }

    func test_allMatchesCollapsedNearTop() {
        // Realistic stress case: 1000-line doc, 10 matches all in
        // the first 5 lines. All ticks should crowd within the top
        // ~1% of the canvas.
        let matches = Array(1...10) // lines 1..10
        let ticks = FindMinimapLayout.ticks(
            matchLines: matches, totalLines: 1000, canvasHeight: 500
        )
        XCTAssertEqual(ticks.count, 10)
        for t in ticks {
            // 10/1000 * 500 = 5 — every tick within top 5pt.
            XCTAssertLessThanOrEqual(t.y, 5.0)
            XCTAssertGreaterThanOrEqual(t.y, 0)
        }
        // Monotonic by y because input is sorted ascending.
        for i in 1..<ticks.count {
            XCTAssertGreaterThanOrEqual(ticks[i].y, ticks[i - 1].y)
        }
    }

    func test_currentMatchFlag_setForOnlyOneTick() {
        let ticks = FindMinimapLayout.ticks(
            matchLines: [10, 20, 30], totalLines: 100,
            canvasHeight: 200, currentMatchIndex: 1
        )
        XCTAssertEqual(ticks.count, 3)
        XCTAssertFalse(ticks[0].isCurrent)
        XCTAssertTrue(ticks[1].isCurrent)
        XCTAssertFalse(ticks[2].isCurrent)
    }

    func test_currentMatchIndex_outOfRange_treatedAsNone() {
        let ticks = FindMinimapLayout.ticks(
            matchLines: [10, 20], totalLines: 100,
            canvasHeight: 200, currentMatchIndex: 5
        )
        XCTAssertEqual(ticks.count, 2)
        for t in ticks { XCTAssertFalse(t.isCurrent) }
    }

    func test_lineNumberClampedToTotalLines() {
        // Match line claims to be at 500 in a 100-line doc — should
        // clamp to 100 rather than overflow the canvas.
        let ticks = FindMinimapLayout.ticks(
            matchLines: [500], totalLines: 100, canvasHeight: 200
        )
        XCTAssertEqual(ticks[0].line, 100)
        XCTAssertEqual(ticks[0].y, 198, accuracy: 0.01)
    }

    // MARK: - nearestLine()

    func test_nearestLine_pickClosest() {
        // Lines 10, 50, 90 in 100-line doc on 200pt canvas → y=18, 98, 178.
        let line = FindMinimapLayout.nearestLine(
            toY: 96,  // close to y=98 (line 50)
            matchLines: [10, 50, 90],
            totalLines: 100, canvasHeight: 200
        )
        XCTAssertEqual(line, 50)
    }

    func test_nearestLine_returnsNilWhenOutsideTolerance() {
        let line = FindMinimapLayout.nearestLine(
            toY: 100,
            matchLines: [10], // y=18
            totalLines: 100, canvasHeight: 200,
            tolerance: 6
        )
        XCTAssertNil(line)
    }

    func test_nearestLine_emptyMatches() {
        let line = FindMinimapLayout.nearestLine(
            toY: 50, matchLines: [], totalLines: 100, canvasHeight: 200
        )
        XCTAssertNil(line)
    }
}
