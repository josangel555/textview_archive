import XCTest
@testable import ViewerCore

/// Coverage for the Markdown heading-outline extractor (TSK-511). Pins the
/// documented common subset; the sidebar TOC view that consumes this is a
/// later (VM) phase.
final class MarkdownOutlineTests: XCTestCase {

    private func h(_ s: String) -> [MarkdownHeading] { MarkdownOutline.headings(in: s) }

    func test_atxLevelsAndLineNumbers() {
        let out = h("# One\n## Two\ntext\n### Three\n")
        XCTAssertEqual(out, [
            MarkdownHeading(level: 1, title: "One", line: 1),
            MarkdownHeading(level: 2, title: "Two", line: 2),
            MarkdownHeading(level: 3, title: "Three", line: 4),
        ])
    }

    func test_atxSevenHashes_isNotHeading() {
        XCTAssertEqual(h("####### nope"), [])
    }

    func test_atxNoSpace_isNotHeading() {
        // `#tag` is a paragraph, not a heading (CommonMark requires a space).
        XCTAssertEqual(h("#notaheading"), [])
    }

    func test_atxTrailingHashClosingSequence_stripped() {
        XCTAssertEqual(h("# Title #"), [MarkdownHeading(level: 1, title: "Title", line: 1)])
        XCTAssertEqual(h("## Title ###"), [MarkdownHeading(level: 2, title: "Title", line: 1)])
    }

    func test_atxTrailingHashInWord_kept() {
        // "C#" — the '#' is not space-preceded, so it's part of the title.
        XCTAssertEqual(h("# Learn C#"), [MarkdownHeading(level: 1, title: "Learn C#", line: 1)])
    }

    func test_atxAllHashBody_isEmptyTitle() {
        XCTAssertEqual(h("## ##"), [MarkdownHeading(level: 2, title: "", line: 1)])
    }

    func test_setext_h1AndH2() {
        let out = h("Title One\n=====\n\nTitle Two\n-----\n")
        XCTAssertEqual(out, [
            MarkdownHeading(level: 1, title: "Title One", line: 1),
            MarkdownHeading(level: 2, title: "Title Two", line: 4),
        ])
    }

    func test_setext_needsPrecedingParagraph() {
        // A `===` with a blank line before it is not a setext heading.
        XCTAssertEqual(h("\n=====\n"), [])
    }

    func test_fencedCode_headingsInsideAreSkipped() {
        let out = h("# Real\n```\n# fake in code\n```\n## AlsoReal\n")
        XCTAssertEqual(out, [
            MarkdownHeading(level: 1, title: "Real", line: 1),
            MarkdownHeading(level: 2, title: "AlsoReal", line: 5),
        ])
    }

    func test_tildeFence_skipped() {
        XCTAssertEqual(h("~~~\n# fake\n~~~\n# Real\n"),
                       [MarkdownHeading(level: 1, title: "Real", line: 4)])
    }

    func test_yamlFrontMatter_skipped_noPhantomSetext() {
        // The closing `---` must NOT become a setext h2 of "title: Foo".
        let out = h("---\ntitle: Foo\ndate: 2026\n---\n# Body\n")
        XCTAssertEqual(out, [MarkdownHeading(level: 1, title: "Body", line: 5)])
    }

    func test_thematicBreakWithoutPrecedingText_isNotHeading() {
        // `---` after a blank line is a thematic break, not setext.
        XCTAssertEqual(h("para\n\n---\n"), [])
    }

    func test_crlf_handled() {
        XCTAssertEqual(h("# One\r\n## Two\r\n"), [
            MarkdownHeading(level: 1, title: "One", line: 1),
            MarkdownHeading(level: 2, title: "Two", line: 2),
        ])
    }

    func test_empty_andNoHeadings() {
        XCTAssertEqual(h(""), [])
        XCTAssertEqual(h("just a paragraph\nand another"), [])
    }
}
