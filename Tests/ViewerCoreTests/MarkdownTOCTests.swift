import XCTest
@testable import ViewerCore

/// Teeth for the Markdown table-of-contents generator + idempotent insert
/// (TSK-675). A pure consumer of `MarkdownOutline.headings`.
final class MarkdownTOCTests: XCTestCase {

    private func h(_ level: Int, _ title: String, _ line: Int = 1) -> MarkdownHeading {
        MarkdownHeading(level: level, title: title, line: line)
    }

    // MARK: slug (GitHub-style)

    func test_slug_collapsesPunctuationRuns_lowercases_matchesRenderer() {
        XCTAssertEqual(MarkdownTOC.slug("Hello, World!"), "hello-world")
        // Punctuation runs COLLAPSE to one dash (matching the rendered heading id),
        // NOT dropped — "Setup & Config" renders as id="setup-config".
        XCTAssertEqual(MarkdownTOC.slug("Setup & Config"), "setup-config")
        XCTAssertEqual(MarkdownTOC.slug("C++ Guide"), "c-guide")
        XCTAssertEqual(MarkdownTOC.slug("Keep-Hyphen"), "keep-hyphen")
    }

    func test_slug_keepsUnicodeLettersAndDigits() {
        XCTAssertEqual(MarkdownTOC.slug("Café 2"), "café-2")
    }

    /// The load-bearing contract: a TOC link target MUST equal the id the renderer
    /// gives the heading, or clicking the link navigates nowhere. Pins MarkdownTOC's
    /// slug to HTMLVisitor.baseSlug (≡ rust-core unique_slug) for tricky titles.
    func test_slug_matchesRendererHeadingId() {
        for title in ["Q&A: Setup", "Setup & Config", "Hello,  World!!!", "  Spaced  Out  ",
                      "Trailing punctuation...", "C++ / Rust", "100% Done", "émojis 🎉 here"] {
            XCTAssertEqual(MarkdownTOC.slug(title), HTMLVisitor.baseSlug(for: title),
                           "TOC anchor must match the rendered heading id for '\(title)'")
        }
    }

    func test_generate_dedupeMatchesRendererSuffixes() {
        // Two headings with the same slug → `#dup`, `#dup-1` (renderer's scheme),
        // so both TOC links resolve.
        let toc = MarkdownTOC.generate(from: [h(1, "Dup"), h(1, "Dup")])
        XCTAssertEqual(toc, "- [Dup](#dup)\n- [Dup](#dup-1)")
    }

    // MARK: generate

    func test_generate_nestsByLevel_relativeToShallowest() {
        let toc = MarkdownTOC.generate(from: [h(1, "Intro"), h(2, "Setup"), h(3, "Deep")])
        XCTAssertEqual(toc, """
        - [Intro](#intro)
          - [Setup](#setup)
            - [Deep](#deep)
        """)
    }

    func test_generate_startsAtMinLevel_noLeadingIndent() {
        // A doc whose shallowest heading is H2 → its items start un-indented.
        let toc = MarkdownTOC.generate(from: [h(2, "A"), h(3, "B")])
        XCTAssertEqual(toc, "- [A](#a)\n  - [B](#b)")
    }

    func test_generate_dedupesSlugs_githubStyle() {
        let toc = MarkdownTOC.generate(from: [h(1, "Setup"), h(1, "Setup"), h(1, "Setup")])
        XCTAssertEqual(toc, "- [Setup](#setup)\n- [Setup](#setup-1)\n- [Setup](#setup-2)")
    }

    func test_generate_escapesBracketsInLinkText() {
        let toc = MarkdownTOC.generate(from: [h(1, "Step [1]")])
        XCTAssertEqual(toc, "- [Step \\[1\\]](#step-1)")
    }

    func test_generate_empty() {
        XCTAssertEqual(MarkdownTOC.generate(from: []), "")
    }

    // MARK: insert

    func test_insert_noMarkers_insertsAtTop() {
        let text = "# Title\n\nbody\n"
        let out = MarkdownTOC.insert(into: text, headings: MarkdownOutline.headings(in: text))
        XCTAssertTrue(out.hasPrefix("<!-- toc -->\n- [Title](#title)\n<!-- /toc -->\n\n# Title"))
    }

    func test_insert_isIdempotent_replacesInPlace() {
        let text = "# A\n## B\ncontent\n"
        let headings = MarkdownOutline.headings(in: text)
        let once = MarkdownTOC.insert(into: text, headings: headings)
        let twice = MarkdownTOC.insert(into: once, headings: MarkdownOutline.headings(in: once))
        XCTAssertEqual(once, twice, "re-running replaces the marked block, never stacks")
        XCTAssertEqual(once.components(separatedBy: MarkdownTOC.openMarker).count - 1, 1,
                       "exactly one TOC block")
    }

    func test_insert_afterYAMLFrontMatter() {
        let text = "---\ntitle: X\n---\n# H1\nbody\n"
        let out = MarkdownTOC.insert(into: text, headings: MarkdownOutline.headings(in: text))
        XCTAssertTrue(out.hasPrefix("---\ntitle: X\n---\n<!-- toc -->"),
                      "front-matter stays first; TOC goes after it")
    }

    func test_insert_noHeadings_noMarkers_isNoOp() {
        let text = "just paragraphs, no headings\n"
        XCTAssertEqual(MarkdownTOC.insert(into: text, headings: []), text)
    }

    func test_insert_refreshesAfterHeadingChange() {
        let v1 = MarkdownTOC.insert(into: "# A\n", headings: MarkdownOutline.headings(in: "# A\n"))
        // user adds a heading inside the marked doc, re-runs:
        let edited = v1 + "\n## B\n"
        let v2 = MarkdownTOC.insert(into: edited, headings: MarkdownOutline.headings(in: edited))
        XCTAssertTrue(v2.contains("- [A](#a)"))
        XCTAssertTrue(v2.contains("  - [B](#b)"))
        XCTAssertEqual(v2.components(separatedBy: MarkdownTOC.openMarker).count - 1, 1)
    }
}
