import XCTest
@testable import RustCore
@testable import ViewerCore
import ViewerKit

/// A/B parity (TSK-631): the Rust core's `mdvcore_markdown_render` (via
/// `mdvCoreMarkdownRender` + the host enrichment splice) vs the SHIPPING
/// Swift `HTMLRenderer.render`, byte-for-byte over a curated corpus.
///
/// The splice applies the SAME host code paths the Swift visitor uses
/// (HTMLSanitizer / renderMermaidHost / TreeSitter spans), so the comparison
/// isolates exactly what the port owns: structure, slugs, escaping, the URL
/// allowlist, and the chunk extraction boundaries.
///
/// Out of corpus by design (documented divergences): parser-engine corner
/// cases where cmark-gfm and pulldown-cmark disagree on the PARSE (not the
/// rendering), PARSE-03 truncation inputs (pulldown renders deep nesting
/// fully), and `<ol start>` (both sides drop it).
final class MarkdownRenderABTests: XCTestCase {

    /// The PRODUCTION enrichment (TSK-648: `RustMarkdownAdapter.enrich`),
    /// with one test-only tripwire: the retired `mermaid` kind reappearing
    /// means the rust side regressed to the chunk path (TSK-661).
    private func enrich(_ chunk: CoreMarkdownChunk) -> String {
        if chunk.kind == "mermaid" {
            XCTFail("'mermaid' chunk kind is retired — core renders the host div")
            return ""
        }
        return RustMarkdownAdapter.enrich(chunk)
    }

    private func assertParity(
        _ markdown: String, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let swift = HTMLRenderer().render(markdown)
        let rendered = try mdvCoreMarkdownRender(text: markdown)
        let rust = rendered.spliced { self.enrich($0) }
        XCTAssertEqual(rust, swift,
                       "parity diverged for markdown:\n\(markdown.prefix(200))",
                       file: file, line: line)
    }

    func test_structure_corpus() throws {
        try assertParity("# Title\n\nA paragraph with *em*, **strong**, ~~del~~ and `code`.")
        try assertParity("## Dup\n\n## Dup\n\n### Symbols !!!\n")
        try assertParity("# Unicode Köpfe 标题\n\ntext")
        try assertParity("> quote\n>\n> more\n\n---\n\npara after rule")
        try assertParity("- a\n- b\n  - nested\n- c")
        try assertParity("- loose\n\n- list\n")
        try assertParity("1. one\n2. two\n")
        try assertParity("- [x] done\n- [ ] todo\n")
        try assertParity("| h1 | h2 |\n|----|----|\n| a | b |\n| c | d |\n")
        try assertParity("soft\nbreak and hard  \nbreak")
        try assertParity("")
    }

    func test_links_and_images_corpus() throws {
        try assertParity("[ok](https://example.com) and [titled](https://e.com \"T\")")
        try assertParity("[evil](javascript:alert(1)) [f](file:///etc/passwd) [m](mailto:a@b.c)")
        try assertParity("[frag](#sec) [rel](docs/x.md)")
        try assertParity("![alt](https://e.com/i.png) ![local](file:///tmp/i.png)")
        try assertParity("![good](data:image/png;base64,AA) ![bad](data:text/html,x)")
        try assertParity("![**bold** alt](https://e.com/i.png)")
        try assertParity("text with & < > \" ' entities")
    }

    func test_code_fence_corpus_plain_highlighted_mermaid() throws {
        // Plain fence (no info) — rendered inline by the core, no chunk.
        try assertParity("```\nplain <code> & such\n```")
        // Indented code block.
        try assertParity("    indented line\n")
        // Highlighted fence — the chunk path through real TreeSitter spans.
        try assertParity("```swift\nlet x: Int = 1 // comment\n```")
        try assertParity("```json\n{\"k\": [1, true, null]}\n```")
        // Unknown language — chunk falls back to plain escape.
        try assertParity("```nosuchlang\na < b\n```")
        // Mermaid host div — rendered ENTIRELY in rust since TSK-661; the
        // byte-equal comparison vs the Swift renderMermaidHost output is
        // the parity oracle for the hand-rolled SHA-256 hash, the steps
        // JSON byte shape, and the attribute order.
        try assertParity("```mermaid\ngraph TD; A-->B;\n```")
        try assertParity("```Mermaid\nsequenceDiagram\n  A->>B: hi\n```")
        try assertParity("```mermaid\n%% @id flow-1\n%% @step 1\nA-->B\n%% @step 2\nB-->C\n```")
        // And the retired kind never crosses the wire.
        let out = try mdvCoreMarkdownRender(text: "```mermaid\nA-->B\n```")
        XCTAssertFalse(out.chunks.contains { $0.kind == "mermaid" })
        XCTAssertTrue(out.html.contains("data-mdv-src-hash"))
    }

    func test_raw_html_corpus_sanitizer_barrier() throws {
        // Block html: script stripped by the SAME sanitizer on both sides.
        try assertParity("<div class=\"x\">\n<script>evil()</script>\n<p>kept</p>\n</div>\n\npara")
        // Inline html.
        try assertParity("a <b>bold</b> and <span class=\"y\">span</span> c")
        // The structural html must never carry raw markup before the splice.
        let out = try mdvCoreMarkdownRender(text: "<script>evil()</script>\n\nx")
        XCTAssertFalse(out.html.contains("<script>"),
                       "raw html leaked into structural html")
        XCTAssertTrue(out.chunks.contains { $0.kind == "raw_html" })
    }

    func test_mixed_document_end_to_end() throws {
        try assertParity("""
        # Doc Title

        Intro with [a link](https://example.com) and `inline`.

        ## Section

        - point one
        - point two with **bold**
          - [x] sub-task

        > a quote with *emphasis*

        ```swift
        struct S { let v: Int }
        ```

        | col | val |
        |-----|-----|
        | a   | 1   |

        ![diagram](file:///tmp/d.png)

        ```mermaid
        graph LR; X-->Y;
        ```

        Done & dusted.
        """)
    }

    func test_capability_bit_advertised() {
        XCTAssertTrue(CoreABI.capabilities.contains(.markdown))
    }
}
