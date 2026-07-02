import XCTest
@testable import ViewerCore

/// Promote/Demote Headings must only touch REAL ATX headings — never a `#` line
/// that's inside a fenced block, an indented (4-space) code block, or an HTML
/// comment. Shifting those would CORRUPT the user's code/comment content.
final class HeadingShiftCodeAwareTests: XCTestCase {
    func test_indentedCodeHashNotShifted() {
        let src = "Para\n\n    # not a heading, it's code\n\n# Real"
        let out = MarkdownHeadingShift.shift(src, by: 1)
        XCTAssertTrue(out.contains("    # not a heading, it's code"), "indented code must be untouched")
        XCTAssertTrue(out.contains("\n## Real"), "the real heading is demoted")
    }

    func test_tabIndentedCodeHashNotShifted() {
        let out = MarkdownHeadingShift.shift("\t# tab-indented code\n# Real", by: 1)   // tab = 4 cols
        XCTAssertTrue(out.contains("\t# tab-indented code"), "tab-indented code untouched")
        XCTAssertTrue(out.contains("## Real"))
    }

    func test_htmlCommentHashNotShifted() {
        let out = MarkdownHeadingShift.shift("<!--\n# commented\n-->\n# Real", by: 1)
        XCTAssertTrue(out.contains("\n# commented\n"), "commented # must be untouched")
        XCTAssertTrue(out.contains("\n## Real"))
    }

    func test_fencedCodeStillSafe() {
        let out = MarkdownHeadingShift.shift("```\n# code\n```\n# Real", by: 1)
        XCTAssertTrue(out.contains("\n# code\n"), "fenced code untouched")
        XCTAssertTrue(out.contains("\n## Real"))
    }

    func test_realHeadings0to3SpacesStillShift() {
        // 0–3 space indented ATX headings ARE real → shift.
        let out = MarkdownHeadingShift.shift("# a\n # b\n   ### c", by: 1)
        XCTAssertEqual(out, "## a\n ## b\n   #### c")
    }

    func test_clampAtBounds() {
        XCTAssertEqual(MarkdownHeadingShift.shift("# h1", by: -1), "# h1", "promote clamps at H1")
        XCTAssertEqual(MarkdownHeadingShift.shift("###### h6", by: 1), "###### h6", "demote clamps at H6")
    }
}
