import XCTest
@testable import ViewerCore

/// Teeth for ATX heading-level shifting (Promote/Demote Headings).
final class MarkdownHeadingShiftTests: XCTestCase {

    func test_demote_addsHash() {
        XCTAssertEqual(MarkdownHeadingShift.shift("# A\n## B\ntext", by: 1), "## A\n### B\ntext")
    }

    func test_promote_removesHash() {
        XCTAssertEqual(MarkdownHeadingShift.shift("## A\n### B", by: -1), "# A\n## B")
    }

    func test_promote_clampsAtH1() {
        XCTAssertEqual(MarkdownHeadingShift.shift("# A\n## B", by: -1), "# A\n# B",
                       "H1 can't promote past H1")
    }

    func test_demote_clampsAtH6() {
        XCTAssertEqual(MarkdownHeadingShift.shift("##### E\n###### F", by: 1), "###### E\n###### F",
                       "H6 can't demote past H6")
    }

    func test_nonHeadingsUntouched() {
        // #nospace and ####### (7) are not ATX headings; body lines unchanged.
        let s = "#nospace\n####### seven\nplain text\n  - list"
        XCTAssertEqual(MarkdownHeadingShift.shift(s, by: 1), s)
    }

    func test_skipsFencedCode() {
        let s = "# Real\n```\n# not a heading\n```\n## Also real"
        XCTAssertEqual(MarkdownHeadingShift.shift(s, by: 1), "## Real\n```\n# not a heading\n```\n### Also real")
    }

    func test_preservesCRLF() {
        let out = MarkdownHeadingShift.shift("# A\r\n## B", by: 1)
        XCTAssertEqual(out, "## A\r\n### B")
        XCTAssertEqual(LineEndingDetector.detect(in: out), .crlf)
    }

    func test_preservesLeadingWhitespaceAndTitle() {
        XCTAssertEqual(MarkdownHeadingShift.shift("  ## Indented Title #", by: 1), "  ### Indented Title #")
    }

    func test_zeroDelta_isNoOp() {
        let s = "# A\n## B"
        XCTAssertEqual(MarkdownHeadingShift.shift(s, by: 0), s)
    }

    func test_roundTrip_demoteThenPromote() {
        // Only true when no clamping occurred (start ≥ H1, end ≤ H6).
        let s = "## A\n### B\n#### C"
        let demoted = MarkdownHeadingShift.shift(s, by: 1)
        XCTAssertEqual(MarkdownHeadingShift.shift(demoted, by: -1), s)
    }
}
