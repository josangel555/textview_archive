import XCTest
@testable import ViewerCore

/// TSK-1480 — the "show current state before converting" detectors: indent
/// style + the aggregated FileFormatState footer chip.
final class FileFormatStateTests: XCTestCase {

    // MARK: IndentStyleDetector

    func test_indent_tabsVsSpaces_andWidth() {
        XCTAssertEqual(IndentStyleDetector.detect(in: "\tfoo\n\tbar\n"), .tabs)
        XCTAssertEqual(IndentStyleDetector.detect(in: "    a\n    b\n        c\n"),
                       .spaces(width: 4))
        XCTAssertEqual(IndentStyleDetector.detect(in: "  a\n    b\n  c\n"),
                       .spaces(width: 2))
        XCTAssertEqual(IndentStyleDetector.detect(in: "no indent here\njust text\n"),
                       .none)
        XCTAssertEqual(IndentStyleDetector.detect(in: ""), .none)
    }

    func test_indent_dominance_tiesToTabs() {
        // Equal tab/space indented lines → tabs (the unambiguous case).
        XCTAssertEqual(IndentStyleDetector.detect(in: "\ta\n    b\n"), .tabs)
        // More space lines than tab lines → spaces.
        XCTAssertEqual(IndentStyleDetector.detect(in: "\ta\n    b\n    c\n"),
                       .spaces(width: 4))
    }

    func test_indent_ignoresLoneContinuationSpace() {
        // A single leading space (aligned prose) is not an indent step.
        XCTAssertEqual(IndentStyleDetector.detect(in: " x\n y\n"), .none)
    }

    func test_indent_labels() {
        XCTAssertEqual(IndentStyleDetector.Style.tabs.label, "Tabs")
        XCTAssertEqual(IndentStyleDetector.Style.spaces(width: 4).label, "Spaces:4")
        XCTAssertEqual(IndentStyleDetector.Style.none.label, "—")
    }

    // MARK: FileFormatState footer chip

    func test_footerLabel_composesKnownFacets() {
        let s = FileFormatState.detect(text: "    a\n    b\n", encodingLabel: "UTF-8")
        XCTAssertEqual(s.lineEnding, .lf)
        XCTAssertEqual(s.indent, .spaces(width: 4))
        XCTAssertEqual(s.footerLabel, "UTF-8 · LF · Spaces:4")
    }

    func test_footerLabel_crlfTabs() {
        let s = FileFormatState.detect(text: "\ta\r\n\tb\r\n", encodingLabel: "UTF-16")
        XCTAssertEqual(s.footerLabel, "UTF-16 · CRLF · Tabs")
    }

    func test_footerLabel_omitsUnknownFacets() {
        // Blank file: only the encoding is real (no EOL, no indent).
        let s = FileFormatState.detect(text: "", encodingLabel: "UTF-8")
        XCTAssertEqual(s.footerLabel, "UTF-8")
        // No encoding label either → empty chip, no stray separators.
        let bare = FileFormatState.detect(text: "", encodingLabel: "")
        XCTAssertEqual(bare.footerLabel, "")
    }
}
