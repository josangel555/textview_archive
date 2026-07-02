import XCTest
@testable import ViewerCore

/// A `#` line inside a multi-line HTML comment block (`<!-- … -->`) is
/// commented-out, not a heading — it must not appear in the outline/TOC.
/// Same "not real structure" class as the indented-code + code-span fixes.
final class OutlineHtmlCommentTests: XCTestCase {
    func test_headingInsideCommentBlock_skipped() {
        let h = MarkdownOutline.headings(in: "<!--\n# commented out\n## also\n-->\n# Real")
        XCTAssertEqual(h.map(\.title), ["Real"], "commented-out headings must be skipped")
    }

    func test_headingsAroundCommentBlock_kept() {
        let h = MarkdownOutline.headings(in: "# Before\n<!--\n# hidden\n-->\n# After")
        XCTAssertEqual(h.map(\.title), ["Before", "After"])
    }

    func test_singleLineComment_realHeadingAfterKept() {
        // A one-line comment (opens+closes) must not swallow later headings.
        let h = MarkdownOutline.headings(in: "<!-- a note -->\n# Real")
        XCTAssertEqual(h.map(\.title), ["Real"])
    }

    func test_commentDoesNotEatRestOfDocIfUnclosedIsRare() {
        // Sanity: a real heading before any comment is always kept.
        let h = MarkdownOutline.headings(in: "# Top\ntext\n<!--\n# hidden")
        XCTAssertEqual(h.map(\.title), ["Top"], "heading before the comment kept; hidden one skipped")
    }
}
