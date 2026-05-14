import XCTest
@testable import ViewerCore

final class HTMLRendererTests: XCTestCase {

    private let renderer = HTMLRenderer()

    // MARK: Block elements

    func test_heading_levels() {
        XCTAssertEqual(renderer.render("# Hello"), "<h1>Hello</h1>\n")
        XCTAssertEqual(renderer.render("## Sub"), "<h2>Sub</h2>\n")
        XCTAssertEqual(renderer.render("###### Tiny"), "<h6>Tiny</h6>\n")
    }

    func test_paragraph() {
        XCTAssertEqual(renderer.render("Just text."), "<p>Just text.</p>\n")
    }

    func test_thematicBreak() {
        XCTAssertEqual(renderer.render("---"), "<hr/>\n")
    }

    func test_blockquote() {
        let out = renderer.render("> quoted")
        XCTAssertTrue(out.contains("<blockquote>"))
        XCTAssertTrue(out.contains("<p>quoted</p>"))
        XCTAssertTrue(out.contains("</blockquote>"))
    }

    func test_unorderedList() {
        let out = renderer.render("- a\n- b")
        XCTAssertTrue(out.contains("<ul>"))
        XCTAssertTrue(out.contains("<li>"))
        XCTAssertTrue(out.contains("a"))
        XCTAssertTrue(out.contains("b"))
    }

    func test_orderedList() {
        let out = renderer.render("1. first\n2. second")
        XCTAssertTrue(out.contains("<ol>"))
        XCTAssertTrue(out.contains("first"))
        XCTAssertTrue(out.contains("second"))
    }

    func test_codeBlock_withoutLanguage() {
        let out = renderer.render("```\nlet x = 1\n```")
        XCTAssertTrue(out.contains("<pre><code>"))
        XCTAssertTrue(out.contains("let x = 1"))
        XCTAssertFalse(out.contains("class=\"language-"))
    }

    func test_codeBlock_withLanguage() {
        let out = renderer.render("```swift\nlet x = 1\n```")
        XCTAssertTrue(out.contains("<pre><code class=\"language-swift\">"),
                      "got: \(out)")
        XCTAssertTrue(out.contains("let x = 1"))
    }

    func test_codeBlock_escapesHTML() {
        let out = renderer.render("```\n<script>alert(1)</script>\n```")
        XCTAssertTrue(out.contains("&lt;script&gt;"))
        XCTAssertFalse(out.contains("<script>"))
    }

    func test_table() {
        let md = """
        | a | b |
        |---|---|
        | 1 | 2 |
        """
        let out = renderer.render(md)
        XCTAssertTrue(out.contains("<table>"))
        XCTAssertTrue(out.contains("<th>a</th>"))
        XCTAssertTrue(out.contains("<th>b</th>"))
        XCTAssertTrue(out.contains("<td>1</td>"))
        XCTAssertTrue(out.contains("<td>2</td>"))
    }

    // MARK: Inline elements

    func test_emphasisAndStrong() {
        let out = renderer.render("*em* and **strong**")
        XCTAssertTrue(out.contains("<em>em</em>"))
        XCTAssertTrue(out.contains("<strong>strong</strong>"))
    }

    func test_inlineCode_escapesHTML() {
        let out = renderer.render("Use `<div>` here.")
        XCTAssertTrue(out.contains("<code>&lt;div&gt;</code>"))
    }

    func test_link() {
        let out = renderer.render("[Apple](https://apple.com)")
        XCTAssertTrue(out.contains("<a href=\"https://apple.com\">Apple</a>"),
                      "got: \(out)")
    }

    func test_link_escapesHrefSpecialChars() {
        let out = renderer.render("[x](https://x.com/?q=\"&y=<)")
        XCTAssertTrue(out.contains("&quot;"))
        XCTAssertTrue(out.contains("&amp;"))
        XCTAssertTrue(out.contains("&lt;"))
    }

    func test_image() {
        let out = renderer.render("![alt text](logo.png)")
        XCTAssertTrue(out.contains("<img"))
        XCTAssertTrue(out.contains("src=\"logo.png\""))
        XCTAssertTrue(out.contains("alt=\"alt text\""))
    }

    func test_strikethrough_gfm() {
        let out = renderer.render("~~gone~~")
        XCTAssertTrue(out.contains("<del>gone</del>"))
    }

    // MARK: Escaping

    func test_textEscapesHTML() {
        let out = renderer.render("a < b & c > d")
        XCTAssertTrue(out.contains("a &lt; b &amp; c &gt; d"))
    }

    // MARK: renderPage wrapping

    func test_renderPage_wrapsInHTMLAndIncludesStylesheet() {
        let page = renderer.renderPage("# Hi", stylesheet: "body { color: red; }")
        XCTAssertTrue(page.contains("<!DOCTYPE html>"))
        XCTAssertTrue(page.contains("<html>"))
        XCTAssertTrue(page.contains("</html>"))
        XCTAssertTrue(page.contains("<style>body { color: red; }</style>"))
        XCTAssertTrue(page.contains("<h1>Hi</h1>"))
    }

    func test_renderPage_handlesEmptyMarkdown() {
        let page = renderer.renderPage("", stylesheet: "")
        XCTAssertTrue(page.contains("<body>"))
        XCTAssertTrue(page.contains("</body>"))
    }

    // MARK: Round-trip

    func test_complexDocument_doesNotCrashAndContainsExpectedTags() {
        let md = """
        # Title

        Some **bold** and *italic* and `code`.

        - item 1
        - item 2

        > a quote

        ```swift
        let x = 1
        ```

        [link](https://example.com)
        """
        let out = renderer.render(md)
        for fragment in ["<h1>", "<strong>", "<em>", "<code>", "<ul>",
                         "<blockquote>", "<pre>", "<a "] {
            XCTAssertTrue(out.contains(fragment), "missing \(fragment) in:\n\(out)")
        }
    }
}
