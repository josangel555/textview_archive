import XCTest
@testable import ViewerCore

/// TSK-1327 — `RichTextHTMLParser` (pasteboard HTML → restricted `RichTextDocument`,
/// then `RichTextSerializer` emits canonical Markdown for the smart-paste feature).
/// Pins the parse STRUCTURE (post-normalize) + the end-to-end HTML→Markdown, and that
/// the parser is TOTAL (never panics on arbitrary/untrusted pasteboard input).
final class RichTextHTMLParserTests: XCTestCase {

    private func parse(_ html: String) -> RichTextDocument { RichTextHTMLParser.parse(html) }

    // MARK: - Block structure

    func test_paragraph() {
        XCTAssertEqual(parse("<p>Hello</p>"), RichTextDocument([.paragraph([.text("Hello")])]))
    }

    func test_heading_levelPreserved() {
        XCTAssertEqual(parse("<h2>Title</h2>"),
                       RichTextDocument([.heading(level: 2, inlines: [.text("Title")])]))
    }

    func test_heading_h4_clampsToH3() {
        // Out-of-vocab H4 is clamped to H3 by the normalizer (stays in-spec).
        XCTAssertEqual(parse("<h4>Deep</h4>"),
                       RichTextDocument([.heading(level: 3, inlines: [.text("Deep")])]))
    }

    func test_bulletList() {
        XCTAssertEqual(parse("<ul><li>one</li><li>two</li></ul>"),
                       RichTextDocument([.bulletList([RichListItem([.text("one")]),
                                                      RichListItem([.text("two")])])]))
    }

    func test_orderedList() {
        XCTAssertEqual(parse("<ol><li>a</li><li>b</li></ol>"),
                       RichTextDocument([.orderedList(start: 1, items: [RichListItem([.text("a")]),
                                                                        RichListItem([.text("b")])])]))
    }

    func test_blockquote() {
        XCTAssertEqual(parse("<blockquote>quote</blockquote>"),
                       RichTextDocument([.blockquote([[.text("quote")]])]))
    }

    // MARK: - Inline structure

    func test_boldInline_keepsSurroundingText() {
        XCTAssertEqual(parse("<p>x <strong>y</strong></p>"),
                       RichTextDocument([.paragraph([.text("x "), .bold([.text("y")])])]))
    }

    func test_nestedEmphasis() {
        XCTAssertEqual(parse("<p><b>a<i>b</i></b></p>"),
                       RichTextDocument([.paragraph([.bold([.text("a"), .italic([.text("b")])])])]))
    }

    func test_link_carriesHref() {
        XCTAssertEqual(parse("<p><a href=\"http://e.com\">e</a></p>"),
                       RichTextDocument([.paragraph([.link(text: [.text("e")], url: "http://e.com")])]))
    }

    func test_unknownInlineTag_unwraps_andAdjacentTextCoalesces() {
        // <span> has no vocabulary mapping → unwrap to its children; the normalizer
        // then coalesces the three adjacent text runs into one.
        XCTAssertEqual(parse("<p>a <span>b</span> c</p>"),
                       RichTextDocument([.paragraph([.text("a b c")])]))
    }

    func test_entitiesDecoded() {
        XCTAssertEqual(parse("<p>a &amp; b &lt;c&gt; &#39;q&#39;</p>"),
                       RichTextDocument([.paragraph([.text("a & b <c> 'q'")])]))
    }

    // MARK: - End-to-end HTML → canonical Markdown

    func test_markdown_bulletList() {
        XCTAssertEqual(RichTextHTMLParser.markdown(fromHTML: "<ul><li>one</li><li>two</li></ul>"),
                       "- one\n- two")
    }

    func test_markdown_headingThenParagraphWithBold() {
        XCTAssertEqual(RichTextHTMLParser.markdown(fromHTML: "<h1>T</h1><p>body <b>x</b></p>"),
                       "# T\n\nbody **x**")
    }

    func test_markdown_link() {
        XCTAssertEqual(RichTextHTMLParser.markdown(fromHTML: "<p>see <a href=\"https://a.b\">it</a></p>"),
                       "see [it](https://a.b)")
    }

    // MARK: - Totality (the pasteboard is UNTRUSTED → never panic)

    func test_arbitraryInput_neverPanics() {
        // Deterministic LCG fuzz over an HTML-shaped alphabet (tags, attrs, entities,
        // delimiters, text) — merely REACHING the assert proves no crash/overflow on
        // malformed input (unclosed tags, stray < >, bad entities, deep nesting).
        let alphabet = Array("<>/=\"' &;#pbiaulohscdetrong123 abcXYZ\n\t")
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func rnd() -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) & 0x7FFF)
        }
        for _ in 0..<3000 {
            let len = rnd() % 90
            var s = ""
            for _ in 0..<len { s.append(alphabet[rnd() % alphabet.count]) }
            _ = RichTextHTMLParser.parse(s)        // must return, never panic
        }
        // A few hand-picked degenerate cases.
        for s in ["<", "<<<", "</>", "<a href=", "<p><b></p>", "&", "&#;", "&#xZZ;",
                  "<ul><li>", "<!-- unterminated", "<p>" + String(repeating: "<b>", count: 200)] {
            _ = RichTextHTMLParser.parse(s)
        }
    }
}
