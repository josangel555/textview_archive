import XCTest
@testable import ViewerCore

final class HTMLRendererTests: XCTestCase {

    private let renderer = HTMLRenderer()

    // MARK: Block elements

    func test_heading_levels_haveSlugIDs() {
        XCTAssertEqual(renderer.render("# Hello"), "<h1 id=\"hello\">Hello</h1>\n")
        XCTAssertEqual(renderer.render("## Sub"), "<h2 id=\"sub\">Sub</h2>\n")
        XCTAssertEqual(renderer.render("###### Tiny"), "<h6 id=\"tiny\">Tiny</h6>\n")
    }

    // CRIT-8: heading anchors enable [link](#heading) navigation
    func test_heading_slug_normalizesPunctuation() {
        let out = renderer.render("# Hello, World!")
        XCTAssertTrue(out.contains("id=\"hello-world\""), "got: \(out)")
    }

    func test_heading_slug_disambiguatesDuplicates() {
        let out = renderer.render("# Setup\n## Setup\n### Setup")
        XCTAssertTrue(out.contains("id=\"setup\""))
        XCTAssertTrue(out.contains("id=\"setup-1\""))
        XCTAssertTrue(out.contains("id=\"setup-2\""))
    }

    func test_heading_slug_handlesEmptyText() {
        let out = renderer.render("# ")  // edge: heading with just whitespace
        // Either renders no heading or one with the placeholder id.
        if out.contains("<h1") {
            XCTAssertTrue(out.contains("id=\"section\""), "got: \(out)")
        }
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
        // Phase 5b: code-fence body is wrapped in per-token <span class="tok-*">
        // runs by TreeSitter, so we no longer assert the raw "let x = 1"
        // substring. Confirm the tokens land in the right kinds instead.
        XCTAssertTrue(out.contains("<span class=\"tok-keyword\">let</span>"),
                      "expected 'let' as keyword span; got: \(out)")
        XCTAssertTrue(out.contains("<span class=\"tok-number\">1</span>"),
                      "expected '1' as number span; got: \(out)")
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
        XCTAssertTrue(page.contains("<h1 id=\"hi\">Hi</h1>"))
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
        for fragment in ["<h1 id=\"title\">", "<strong>", "<em>", "<code>", "<ul>",
                         "<blockquote>", "<pre>", "<a "] {
            XCTAssertTrue(out.contains(fragment), "missing \(fragment) in:\n\(out)")
        }
    }

    // MARK: CRIT-1 — CSP meta header in renderPage

    func test_renderPage_includesContentSecurityPolicy() {
        let page = renderer.renderPage("hi", stylesheet: "")
        XCTAssertTrue(page.contains("http-equiv=\"Content-Security-Policy\""))
        XCTAssertTrue(page.contains("default-src 'none'"))
        XCTAssertTrue(page.contains("frame-src 'none'"))
        XCTAssertTrue(page.contains("object-src 'none'"))
        XCTAssertTrue(page.contains("connect-src 'none'"))
    }

    /// TSK-635 — the EGRESS fence. `safeURL` deliberately admits http/https
    /// image markup (above), so the CSP `img-src` directive is the ONLY
    /// thing preventing remote images / tracking pixels in rendered
    /// markdown from making network requests. The presence-only check
    /// above stays green if someone loosens the source list — pin the
    /// directive EXACTLY, and prove the remote markup really is in the
    /// page (i.e. CSP is the load-bearing layer, not the sanitizer).
    func test_renderPage_cspImgSrc_blocksRemoteImageEgress() {
        let page = renderer.renderPage(
            "![pixel](https://tracker.example/p.png)", stylesheet: "")
        XCTAssertTrue(
            page.contains("img-src file: data:;"),
            "img-src must allow ONLY file:/data: — adding http(s) re-opens "
            + "the tracking-pixel egress documented in docs/EGRESS.md (TSK-635)")
        XCTAssertTrue(
            page.contains("tracker.example"),
            "remote <img> markup is expected to be PRESENT (markup-level "
            + "allowlist admits it); if this fails the render path changed "
            + "and this test's premise needs re-checking")
    }

    // MARK: S5 / F-06 — URL scheme allowlist on link / image

    func test_link_javascriptURL_isNeutralized() {
        let out = renderer.render("[click](javascript:alert(1))")
        XCTAssertFalse(out.contains("javascript:"), "got: \(out)")
        XCTAssertTrue(out.contains("href=\"about:blank\""), "got: \(out)")
    }

    func test_link_dataURL_isNeutralized() {
        let out = renderer.render("[x](data:text/html,<script>alert(1)</script>)")
        XCTAssertFalse(out.contains("data:text/html"))
        XCTAssertTrue(out.contains("href=\"about:blank\""))
    }

    func test_link_fileURL_isNeutralized() {
        let out = renderer.render("[boring](file:///etc/passwd)")
        XCTAssertFalse(out.contains("/etc/passwd"))
        XCTAssertTrue(out.contains("href=\"about:blank\""))
    }

    func test_link_fragmentAndRelative_passThrough() {
        XCTAssertTrue(renderer.render("[x](#heading)").contains("href=\"#heading\""))
        XCTAssertTrue(renderer.render("[x](other.md)").contains("href=\"other.md\""))
        XCTAssertTrue(renderer.render("[x](http://example.com)")
                        .contains("href=\"http://example.com\""))
        XCTAssertTrue(renderer.render("[x](mailto:a@b.com)")
                        .contains("href=\"mailto:a@b.com\""))
    }

    func test_image_javascriptURL_isNeutralized() {
        let out = renderer.render("![x](javascript:alert(1))")
        XCTAssertTrue(out.contains("src=\"about:blank\""))
    }

    func test_image_dataImage_isPreserved() {
        let dataURL = "data:image/png;base64,iVBORw"
        let out = renderer.render("![x](\(dataURL))")
        XCTAssertTrue(out.contains("src=\"\(dataURL)\""), "got: \(out)")
    }

    func test_image_dataNonImage_isNeutralized() {
        let out = renderer.render("![x](data:text/html,bad)")
        XCTAssertTrue(out.contains("src=\"about:blank\""))
    }
}
