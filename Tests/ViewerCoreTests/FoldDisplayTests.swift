import XCTest
@testable import ViewerCore

final class FoldDisplayTests: XCTestCase {

    func testNoCollapsed_ReturnsCanonical() {
        let text = "line1\nline2\nline3\n"
        let state = FoldState(
            regions: [FoldRegion(startLine: 1, endLine: 3, kind: .object)],
            collapsed: []
        )
        let r = FoldDisplay.build(text: text, state: state)
        XCTAssertEqual(r.displayedText, text)
        XCTAssertTrue(r.ellipsisDisplayedLines.isEmpty)
        // Identity map sized to line count (text has trailing \n → 4 "lines"
        // in NSTextView terms, last one empty).
        XCTAssertEqual(r.lineMap.displayedLineCount, r.lineMap.originalLineCount)
    }

    func testSingleFoldCollapsed_RendersEllipsisOnStartLine() {
        let text = """
        func foo() {
            let x = 1
            return x
        }
        next()
        """
        let fold = FoldRegion(startLine: 1, endLine: 4, kind: .function)
        let state = FoldState(regions: [fold], collapsed: [fold])
        let r = FoldDisplay.build(text: text, state: state)
        // Expected displayed:
        //   func foo() { {…}
        //   next()
        let lines = r.displayedText.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains(FoldDisplay.ellipsisMarker),
                      "expected marker on fold start line; got \(lines[0])")
        XCTAssertEqual(lines[1], "next()")
        XCTAssertEqual(r.ellipsisDisplayedLines, [1])
    }

    func testNestedFolds_OnlyOuterCarriesEllipsis() {
        let text = """
        outer {
          middle {
            inner {
              x
            }
          }
        }
        """
        let outer = FoldRegion(startLine: 1, endLine: 7, kind: .object)
        let inner = FoldRegion(startLine: 3, endLine: 5, kind: .object)
        let state = FoldState(
            regions: [outer, inner],
            collapsed: [outer, inner]
        )
        let r = FoldDisplay.build(text: text, state: state)
        // Both collapsed but inner is inside outer's hidden range →
        // only outer's start (line 1) carries the marker.
        XCTAssertEqual(r.ellipsisDisplayedLines, [1])
        XCTAssertTrue(r.displayedText.contains(FoldDisplay.ellipsisMarker))
        // Single ellipsis marker total in output.
        let count = r.displayedText.components(
            separatedBy: FoldDisplay.ellipsisMarker
        ).count - 1
        XCTAssertEqual(count, 1)
    }

    func testTwoNonOverlappingFolds_TwoEllipses() {
        let text = """
        a {
          x
        }
        sep
        b {
          y
        }
        """
        let a = FoldRegion(startLine: 1, endLine: 3, kind: .object)
        let b = FoldRegion(startLine: 5, endLine: 7, kind: .object)
        let state = FoldState(regions: [a, b], collapsed: [a, b])
        let r = FoldDisplay.build(text: text, state: state)
        XCTAssertEqual(r.ellipsisDisplayedLines.count, 2)
        XCTAssertEqual(r.lineMap.displayedLineCount, 3)
        // Displayed lines: "a { …", "sep", "b { …"
        let lines = r.displayedText.split(separator: "\n",
                                          omittingEmptySubsequences: false)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[1] == "sep")
    }

    /// Round-trip: build displayed buffer + line map, then translate a
    /// caret position in the displayed buffer back to the original and
    /// confirm the line content matches.
    func testCaretTranslation_RoundTripsThroughLineMap() {
        let text = """
        line1
        line2
        line3
        line4
        line5
        line6
        line7
        """
        let fold = FoldRegion(startLine: 2, endLine: 5, kind: .object)
        let state = FoldState(regions: [fold], collapsed: [fold])
        let r = FoldDisplay.build(text: text, state: state)
        // Displayed lines: 1="line1", 2="line2 {…}", 3="line6", 4="line7"
        XCTAssertEqual(r.lineMap.displayedLineCount, 4)
        XCTAssertEqual(r.lineMap.originalLine(forDisplayed: 3), 6)
        XCTAssertEqual(r.lineMap.originalLine(forDisplayed: 4), 7)
        XCTAssertEqual(r.lineMap.displayedLine(forOriginal: 7), 4)
        // Caret on a hidden line (e.g. original line 4) maps to its
        // carrier — displayed line 2.
        XCTAssertEqual(r.lineMap.displayedLine(forOriginal: 4), 2)
    }
}
