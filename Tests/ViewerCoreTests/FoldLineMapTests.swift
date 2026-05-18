import XCTest
@testable import ViewerCore

final class FoldLineMapTests: XCTestCase {

    func testIdentity() {
        let m = FoldLineMap.identity(lineCount: 5)
        XCTAssertEqual(m.originalLineCount, 5)
        XCTAssertEqual(m.displayedLineCount, 5)
        for i in 1...5 {
            XCTAssertEqual(m.displayedLine(forOriginal: i), i)
            XCTAssertEqual(m.originalLine(forDisplayed: i), i)
            XCTAssertFalse(m.isHidden(originalLine: i))
        }
    }

    func testSingleFoldCollapsed() {
        // 10 original lines. Fold lines 3..7 collapsed → 6 displayed.
        // Visible original lines: 1,2,3,8,9,10.
        let r = FoldRegion(startLine: 3, endLine: 7, kind: .object)
        let m = FoldLineMap.build(
            originalLineCount: 10,
            collapsed: [r]
        )
        XCTAssertEqual(m.displayedLineCount, 6)
        // Displayed → original
        XCTAssertEqual(m.originalLine(forDisplayed: 1), 1)
        XCTAssertEqual(m.originalLine(forDisplayed: 2), 2)
        XCTAssertEqual(m.originalLine(forDisplayed: 3), 3)   // fold-start visible
        XCTAssertEqual(m.originalLine(forDisplayed: 4), 8)
        XCTAssertEqual(m.originalLine(forDisplayed: 6), 10)
        // Original → displayed
        XCTAssertEqual(m.displayedLine(forOriginal: 3), 3)
        XCTAssertEqual(m.displayedLine(forOriginal: 8), 4)
        // Hidden lines map to carrier (start = 3 → displayed 3).
        XCTAssertEqual(m.displayedLine(forOriginal: 5), 3)
        XCTAssertTrue(m.isHidden(originalLine: 5))
        XCTAssertFalse(m.isHidden(originalLine: 3))
        XCTAssertFalse(m.isHidden(originalLine: 8))
    }

    func testNestedFolds_InnerCarrierWins() {
        // Outer 1..10, inner 4..7 — both collapsed.
        // Outer hides lines 2..10. Inner is inside outer's hidden
        // range. Carrier for hidden lines should be the *innermost*
        // fold's start where applicable.
        // BUT: outer collapsed means inner's startLine (4) is itself
        // hidden by outer. Expected: only line 1 (outer's start) is
        // displayed → 1 displayed line.
        let outer = FoldRegion(startLine: 1, endLine: 10, kind: .function)
        let inner = FoldRegion(startLine: 4, endLine: 7, kind: .object)
        let m = FoldLineMap.build(
            originalLineCount: 12,
            collapsed: [outer, inner]
        )
        // Lines visible: 1, 11, 12.
        XCTAssertEqual(m.displayedLineCount, 3)
        XCTAssertEqual(m.originalLine(forDisplayed: 1), 1)
        XCTAssertEqual(m.originalLine(forDisplayed: 2), 11)
        XCTAssertEqual(m.originalLine(forDisplayed: 3), 12)
        // Hidden line inside inner — maps to outer's carrier (line 1
        // → displayed 1) because inner's start is itself hidden.
        XCTAssertEqual(m.displayedLine(forOriginal: 5), 1)
    }

    func testAdjacentFolds() {
        // Two non-overlapping folds: 2..4 and 6..8.
        let a = FoldRegion(startLine: 2, endLine: 4, kind: .object)
        let b = FoldRegion(startLine: 6, endLine: 8, kind: .array)
        let m = FoldLineMap.build(
            originalLineCount: 10,
            collapsed: [a, b]
        )
        // Hidden: 3,4,7,8. Visible: 1,2,5,6,9,10 → 6 lines.
        XCTAssertEqual(m.displayedLineCount, 6)
        XCTAssertEqual(m.originalLine(forDisplayed: 1), 1)
        XCTAssertEqual(m.originalLine(forDisplayed: 2), 2)
        XCTAssertEqual(m.originalLine(forDisplayed: 3), 5)
        XCTAssertEqual(m.originalLine(forDisplayed: 4), 6)
        XCTAssertEqual(m.originalLine(forDisplayed: 5), 9)
        // Caret in a hidden line maps to its fold's start.
        XCTAssertEqual(m.displayedLine(forOriginal: 3), 2)
        XCTAssertEqual(m.displayedLine(forOriginal: 7), 4)
    }

    func testEmptyCollapsedReturnsIdentity() {
        let m = FoldLineMap.build(
            originalLineCount: 100,
            collapsed: []
        )
        XCTAssertEqual(m.displayedLineCount, 100)
        XCTAssertEqual(m.originalLine(forDisplayed: 50), 50)
    }

    func testZeroLineCount() {
        let m = FoldLineMap.build(
            originalLineCount: 0,
            collapsed: [FoldRegion(startLine: 1, endLine: 5, kind: .object)]
        )
        XCTAssertEqual(m.displayedLineCount, 0)
    }

    // Selection spanning a fold boundary — caret translation idempotence.
    func testCaretRoundTrip_VisibleLines() {
        let m = FoldLineMap.build(
            originalLineCount: 20,
            collapsed: [
                FoldRegion(startLine: 5, endLine: 10, kind: .object),
                FoldRegion(startLine: 13, endLine: 17, kind: .array),
            ]
        )
        // Visible original lines: 1,2,3,4,5,11,12,13,18,19,20.
        for original in [1, 5, 11, 18, 20] {
            let d = m.displayedLine(forOriginal: original)
            let backToOriginal = m.originalLine(forDisplayed: d)
            XCTAssertEqual(
                backToOriginal, original,
                "round trip lost original line \(original)"
            )
        }
    }
}
