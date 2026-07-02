import XCTest
@testable import ViewerCore

/// Host coverage for the restricted-Markdown RichText document model (TSK-706
/// foundation slice). Pins:
///   - allowed constructs parse into the correct closed IR,
///   - `normalize()` deterministically downgrades a table, raw HTML, and an
///     image to allowed forms,
///   - round-trip of allowed-only Markdown is idempotent
///     (parse → serialize → parse stable),
///   - disallowed input NEVER produces an out-of-vocabulary IR node.
///
/// The read-only render skeleton is a VM concern; this suite is the model gate.
final class RichTextDocumentTests: XCTestCase {

    private func parse(_ s: String) -> RichTextDocument { RichTextDocument.parse(s) }

    // MARK: - Allowed constructs parse correctly

    func test_headings_H1_H2_H3() {
        let doc = parse("# One\n\n## Two\n\n### Three")
        XCTAssertEqual(doc.blocks, [
            .heading(level: 1, inlines: [.text("One")]),
            .heading(level: 2, inlines: [.text("Two")]),
            .heading(level: 3, inlines: [.text("Three")]),
        ])
    }

    func test_inlineEmphasis_boldItalicStrikeCode() {
        let doc = parse("a **b** c *d* e ~~f~~ g `h`")
        XCTAssertEqual(doc.blocks, [
            .paragraph([
                .text("a "), .bold([.text("b")]),
                .text(" c "), .italic([.text("d")]),
                .text(" e "), .strike([.text("f")]),
                .text(" g "), .code("h"),
            ]),
        ])
    }

    func test_link_parsesIntoLinkNode() {
        let doc = parse("see [the docs](https://example.com/x) now")
        XCTAssertEqual(doc.blocks, [
            .paragraph([
                .text("see "),
                .link(text: [.text("the docs")], url: "https://example.com/x"),
                .text(" now"),
            ]),
        ])
    }

    func test_link_dropsTitle() {
        let doc = parse("[a](http://x.com \"a title\")")
        XCTAssertEqual(doc.blocks, [
            .paragraph([.link(text: [.text("a")], url: "http://x.com")]),
        ])
    }

    func test_bulletList() {
        let doc = parse("- one\n- two\n- three")
        XCTAssertEqual(doc.blocks, [
            .bulletList([
                RichListItem([.text("one")]),
                RichListItem([.text("two")]),
                RichListItem([.text("three")]),
            ]),
        ])
    }

    func test_orderedList_capturesStart() {
        let doc = parse("3. a\n4. b")
        XCTAssertEqual(doc.blocks, [
            .orderedList(start: 3, items: [
                RichListItem([.text("a")]),
                RichListItem([.text("b")]),
            ]),
        ])
    }

    func test_blockquote() {
        let doc = parse("> quoted **bold**")
        XCTAssertEqual(doc.blocks, [
            .blockquote([[.text("quoted "), .bold([.text("bold")])]]),
        ])
    }

    func test_nestedEmphasis_boldInsideItalic() {
        let doc = parse("*a **b** c*")
        XCTAssertEqual(doc.blocks, [
            .paragraph([.italic([.text("a "), .bold([.text("b")]), .text(" c")])]),
        ])
    }

    func test_codeSpan_isOpaque_doesNotParseInner() {
        // The `*` inside code must NOT become emphasis.
        let doc = parse("`a*b*c`")
        XCTAssertEqual(doc.blocks, [.paragraph([.code("a*b*c")])])
    }

    // MARK: - normalize() downgrades disallowed constructs

    func test_normalize_downgradesTable_toParagraphs() {
        let doc = parse("""
        | Name | Age |
        | ---- | --- |
        | Ann  | 30  |
        | Bob  | 25  |
        """)
        // Each row → a plain paragraph of joined cell text; the delimiter row
        // is dropped. No table node exists in the vocabulary.
        XCTAssertEqual(doc.blocks, [
            .paragraph([.text("Name Age")]),
            .paragraph([.text("Ann 30")]),
            .paragraph([.text("Bob 25")]),
        ])
        assertInVocabulary(doc)
    }

    func test_normalize_stripsRawHTML_keepsText() {
        let doc = parse("<div class=\"x\">hello <b>world</b></div>")
        XCTAssertEqual(doc.blocks, [.paragraph([.text("hello world")])])
        assertInVocabulary(doc)
    }

    func test_normalize_stripsHTMLComment() {
        let doc = parse("before <!-- secret --> after")
        XCTAssertEqual(doc.blocks, [.paragraph([.text("before  after")])])
        assertInVocabulary(doc)
    }

    func test_normalize_downgradesImage_toAltText() {
        let doc = parse("![a cat](https://x.com/cat.png) sits here")
        // Image → its alt text as plain inline (NOT a link, NOT an image node).
        XCTAssertEqual(doc.blocks, [
            .paragraph([.text("a cat sits here")]),
        ])
        assertInVocabulary(doc)
        // Verify no link node leaked in (image must not become a link).
        XCTAssertFalse(containsLink(doc))
    }

    func test_normalize_downgradesH4plus_toParagraph() {
        let doc = parse("#### deep\n\n###### deeper")
        XCTAssertEqual(doc.blocks, [
            .paragraph([.text("deep")]),
            .paragraph([.text("deeper")]),
        ])
        assertInVocabulary(doc)
    }

    func test_normalize_dropsFencedCodeBlock_keepsLinesAsParagraphs() {
        let doc = parse("```swift\nlet x = 1\nlet y = 2\n```")
        XCTAssertEqual(doc.blocks, [
            .paragraph([.text("let x = 1")]),
            .paragraph([.text("let y = 2")]),
        ])
        assertInVocabulary(doc)
    }

    func test_normalize_dropsThematicBreak() {
        let doc = parse("above\n\n---\n\nbelow")
        XCTAssertEqual(doc.blocks, [
            .paragraph([.text("above")]),
            .paragraph([.text("below")]),
        ])
        assertInVocabulary(doc)
    }

    func test_normalize_clampsHandBuiltHeadingLevel() {
        // A hand-built H7 (not from the parser) is clamped to maxHeadingLevel.
        let raw = RichTextDocument([.heading(level: 7, inlines: [.text("x")])])
        let n = RichTextNormalizer.normalize(raw)
        XCTAssertEqual(n.blocks, [.heading(level: 3, inlines: [.text("x")])])
    }

    func test_normalize_dropsEmptyBlocks() {
        let raw = RichTextDocument([
            .paragraph([.text("")]),
            .heading(level: 1, inlines: []),
            .bulletList([RichListItem([.text("")])]),
            .paragraph([.text("keep")]),
        ])
        let n = RichTextNormalizer.normalize(raw)
        XCTAssertEqual(n.blocks, [.paragraph([.text("keep")])])
    }

    func test_normalize_isIdempotent() {
        let doc = parse("""
        # Title

        Para with **bold** and *italic* and `code` and [a](http://x.com).

        - one
        - two

        > a quote
        """)
        let once = RichTextNormalizer.normalize(doc)
        let twice = RichTextNormalizer.normalize(once)
        XCTAssertEqual(once, twice)
    }

    func test_normalize_linkWithEmptyURL_degradesToText() {
        let raw = RichTextDocument([.paragraph([.link(text: [.text("label")], url: "")])])
        let n = RichTextNormalizer.normalize(raw)
        XCTAssertEqual(n.blocks, [.paragraph([.text("label")])])
    }

    // MARK: - Round-trip idempotence

    func test_roundTrip_allowedOnly_isStable() {
        let inputs = [
            "# Heading\n\nA paragraph.",
            "## Sub\n\nText with **bold**, *italic*, ~~strike~~, `code`.",
            "- a\n- b\n- c",
            "1. first\n2. second",
            "5. five\n6. six",
            "> a quote line",
            "Visit [site](https://example.com/p).",
            "Mixed: **b** then *i* then `c` then [l](http://x.y).",
        ]
        for input in inputs {
            let doc1 = parse(input)
            let serialized = doc1.serialized()
            let doc2 = parse(serialized)
            XCTAssertEqual(doc1, doc2, "round-trip drifted for input:\n\(input)\nserialized:\n\(serialized)")
        }
    }

    func test_roundTrip_afterDowngrade_isStable() {
        // After the disallowed input is downgraded once, re-serializing and
        // re-parsing must be a fixed point.
        let inputs = [
            "| a | b |\n| - | - |\n| 1 | 2 |",
            "<p>raw <em>html</em></p>",
            "![alt text](img.png)",
            "#### too deep",
            "```\ncode line\n```",
        ]
        for input in inputs {
            let doc1 = parse(input)
            assertInVocabulary(doc1)
            let doc2 = parse(doc1.serialized())
            XCTAssertEqual(doc1, doc2, "post-downgrade round-trip drifted for:\n\(input)")
        }
    }

    func test_serialize_canonicalizesOrderedListNumbering() {
        // Non-sequential source numbers renumber from start on serialize.
        let doc = parse("3. a\n9. b\n2. c")
        let serialized = doc.serialized()
        XCTAssertEqual(serialized, "3. a\n4. b\n5. c")
    }

    func test_serialize_escapesMetacharacters_soTextRoundTrips() {
        // Literal text with markup chars must survive a round-trip as text.
        let doc1 = RichTextDocument([.paragraph([.text("price is 2*3 and a_b and `x`")])])
        let serialized = doc1.serialized()
        let doc2 = parse(serialized)
        XCTAssertEqual(doc2.blocks, [.paragraph([.text("price is 2*3 and a_b and `x`")])])
    }

    func test_serialize_codeWithBackticks_usesLongerFence() {
        let doc1 = RichTextDocument([.paragraph([.code("a`b")])])
        let serialized = doc1.serialized()
        let doc2 = parse(serialized)
        XCTAssertEqual(doc2.blocks, [.paragraph([.code("a`b")])])
    }

    // MARK: - Closed-vocabulary invariant (the load-bearing guarantee)

    func test_arbitraryInput_neverProducesOutOfVocabularyNode() {
        let pathological = """
        # H1 with <b>html</b>
        #### H4 downgrade
        ###### H6 downgrade

        | t1 | t2 |
        |----|----|
        | a  | b  |

        ![image](x.png) and [link](y.com)

        ```js
        var leaked = "code";
        ```

        > quote with **bold** and ![img](q.png)
        >
        > second quote para

        - bullet with `code` and <i>tag</i>
        - bullet two

        7) ordered paren marker
        8) ordered two

            indented code block line

        ---

        <script>alert(1)</script>

        plain *trailing* paragraph
        """
        let doc = parse(pathological)
        assertInVocabulary(doc)
        // And nothing leaked an image-as-link or HTML-as-text-tag.
        XCTAssertFalse(serializedContainsTag(doc), "HTML tag leaked into serialized output")
    }

    // MARK: - Helpers

    /// Walk every node and assert it is one of the allowed cases with allowed
    /// constraints (heading level in 1...3, no empty blocks). This is the
    /// closed-vocabulary contract: the IR is exhaustive by type, so the real
    /// teeth are the level clamp + the no-empty invariant.
    private func assertInVocabulary(_ doc: RichTextDocument) {
        for block in doc.blocks {
            switch block {
            case let .heading(level, inlines):
                XCTAssertTrue((1...RichBlock.maxHeadingLevel).contains(level),
                              "heading level \(level) out of allowed range")
                XCTAssertFalse(inlines.isEmpty, "empty heading should have been dropped")
                assertInlinesInVocabulary(inlines)
            case let .paragraph(inlines):
                XCTAssertFalse(inlines.isEmpty, "empty paragraph should have been dropped")
                assertInlinesInVocabulary(inlines)
            case let .bulletList(items):
                XCTAssertFalse(items.isEmpty)
                for it in items { assertInlinesInVocabulary(it.inlines) }
            case let .orderedList(start, items):
                XCTAssertGreaterThanOrEqual(start, 1)
                XCTAssertFalse(items.isEmpty)
                for it in items { assertInlinesInVocabulary(it.inlines) }
            case let .blockquote(paras):
                XCTAssertFalse(paras.isEmpty)
                for p in paras { assertInlinesInVocabulary(p) }
            case let .codeBlock(code):
                XCTAssertFalse(code.isEmpty)
            }
        }
    }

    private func assertInlinesInVocabulary(_ inlines: [RichInline]) {
        for inline in inlines {
            switch inline {
            case .text, .code:
                break
            case let .bold(c), let .italic(c), let .strike(c):
                assertInlinesInVocabulary(c)
            case let .link(text, url):
                XCTAssertFalse(url.isEmpty, "empty-URL link should have degraded to text")
                assertInlinesInVocabulary(text)
            }
        }
    }

    private func containsLink(_ doc: RichTextDocument) -> Bool {
        func inlineHasLink(_ inlines: [RichInline]) -> Bool {
            for i in inlines {
                switch i {
                case .link: return true
                case let .bold(c), let .italic(c), let .strike(c):
                    if inlineHasLink(c) { return true }
                default: break
                }
            }
            return false
        }
        for b in doc.blocks {
            switch b {
            case let .heading(_, inlines), let .paragraph(inlines):
                if inlineHasLink(inlines) { return true }
            case let .bulletList(items), let .orderedList(_, items):
                if items.contains(where: { inlineHasLink($0.inlines) }) { return true }
            case let .blockquote(paras):
                if paras.contains(where: inlineHasLink) { return true }
            case .codeBlock:
                break   // opaque literal text, no inline links
            }
        }
        return false
    }

    private func serializedContainsTag(_ doc: RichTextDocument) -> Bool {
        let s = doc.serialized()
        return s.contains("<b>") || s.contains("<i>") || s.contains("<script>")
            || s.contains("<div") || s.contains("<p>")
    }
}
