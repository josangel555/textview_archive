import XCTest
@testable import ViewerCore

/// CommonMark: an ATX heading has 0–3 spaces of indentation; 4+ spaces make it an
/// indented code block, NOT a heading. Before this, a `#`-comment inside a 4-space
/// indented code block was extracted as a false heading, polluting the outline/TOC.
final class OutlineIndentedCodeTests: XCTestCase {
    func test_indentedHashIsNotAHeading() {
        let h = MarkdownOutline.headings(in: "Para\n\n    # indented code comment\n\n# Real")
        XCTAssertEqual(h.map(\.title), ["Real"], "4-space-indented # must not be a heading")
    }

    func test_tabIndentedHashIsNotAHeading() {
        let h = MarkdownOutline.headings(in: "\t# tab-indented\n# Real")   // tab = 4 cols
        XCTAssertEqual(h.map(\.title), ["Real"])
    }

    func test_upTo3SpacesStillAHeading() {
        // 0–3 leading spaces are valid ATX headings.
        let h = MarkdownOutline.headings(in: "# a\n # b\n  ## c\n   ### d")
        XCTAssertEqual(h.map(\.title), ["a", "b", "c", "d"], "0–3 space indent stays a heading")
        XCTAssertEqual(h.map(\.level), [1, 1, 2, 3])
    }

    func test_fencedStillSkipped() {
        let h = MarkdownOutline.headings(in: "# Real\n```\n# not\n```\n## Also")
        XCTAssertEqual(h.map(\.title), ["Real", "Also"])
    }
}
