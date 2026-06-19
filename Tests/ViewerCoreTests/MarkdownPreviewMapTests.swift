import XCTest
@testable import ViewerCore

/// TSK-704 — host tests for the side-by-side editor↔preview scroll-sync model.
///
/// These pin the line↔block mapping that drives scroll-sync: a given editor line
/// resolves to the expected preview block, the line→block and block→line maps
/// are inverse, and out-of-range queries clamp instead of crashing.
final class MarkdownPreviewMapTests: XCTestCase {

    private let renderer = HTMLRenderer()

    /// Build the map the way the UI will: source + the real rendered block count.
    private func map(_ markdown: String) -> MarkdownPreviewMap {
        let count = RenderedBlockDiff.splitBlocks(renderer.render(markdown)).count
        return MarkdownPreviewMap.build(source: markdown, renderedBlockCount: count)
    }

    // MARK: - Source block ranges

    func test_sourceBlocks_headingsParagraphsCode() {
        // 3 source blocks: H1 (line 1), paragraph (line 3), fenced code (5-8).
        let md = """
        # Title

        A paragraph of body text.

        ```swift
        let x = 1
        ```
        """
        let lines = MarkdownPreviewMap.splitLines(md)
        let ranges = MarkdownPreviewMap.sourceBlockRanges(lines)
        XCTAssertEqual(ranges.count, 3)
        XCTAssertEqual(ranges[0], .init(start: 1, end: 1))   // # Title
        XCTAssertEqual(ranges[1], .init(start: 3, end: 3))   // paragraph
        XCTAssertEqual(ranges[2], .init(start: 5, end: 7))   // fence incl. close
    }

    func test_sourceBlocks_fenceWithBlankLinesInside_isOneBlock() {
        let md = """
        ```
        line one

        line three
        ```
        """
        let ranges = MarkdownPreviewMap.sourceBlockRanges(MarkdownPreviewMap.splitLines(md))
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ranges[0], .init(start: 1, end: 5))
    }

    func test_sourceBlocks_listIsOneBlock() {
        let md = """
        - a
        - b
        - c
        """
        let ranges = MarkdownPreviewMap.sourceBlockRanges(MarkdownPreviewMap.splitLines(md))
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ranges[0], .init(start: 1, end: 3))
    }

    func test_sourceBlocks_thematicBreak_isOwnBlock() {
        let md = """
        before

        ---

        after
        """
        let ranges = MarkdownPreviewMap.sourceBlockRanges(MarkdownPreviewMap.splitLines(md))
        XCTAssertEqual(ranges.map { [$0.start, $0.end] },
                       [[1, 1], [3, 3], [5, 5]])
    }

    func test_sourceBlocks_setextUnderline_staysWithParagraph() {
        // A `---` directly under a text line is a setext H2 — one block, not a
        // paragraph + a thematic break.
        let md = """
        Setext Heading
        ---

        body
        """
        let ranges = MarkdownPreviewMap.sourceBlockRanges(MarkdownPreviewMap.splitLines(md))
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(ranges[0], .init(start: 1, end: 2))   // text + underline
        XCTAssertEqual(ranges[1], .init(start: 4, end: 4))   // body
    }

    func test_sourceBlocks_yamlFrontMatter_skipped() {
        let md = """
        ---
        title: Hi
        ---

        # Real heading
        """
        let ranges = MarkdownPreviewMap.sourceBlockRanges(MarkdownPreviewMap.splitLines(md))
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ranges[0], .init(start: 5, end: 5))   // the real heading
    }

    // MARK: - line → block

    func test_lineToBlock_resolvesToExpectedBlock() {
        let md = """
        # Title

        A paragraph of body text.

        ```swift
        let x = 1
        ```
        """
        let m = map(md)
        // The rendered side: h1, p, pre → 3 blocks.
        XCTAssertEqual(m.blockCount, 3)
        XCTAssertEqual(m.block(forLine: 1), 0)   // heading line → block 0
        XCTAssertEqual(m.block(forLine: 3), 1)   // paragraph → block 1
        XCTAssertEqual(m.block(forLine: 5), 2)   // fence open → block 2
        XCTAssertEqual(m.block(forLine: 6), 2)   // inside fence → block 2
        XCTAssertEqual(m.block(forLine: 7), 2)   // fence close → block 2
    }

    func test_lineToBlock_blankGap_anchorsOnFollowingBlock() {
        let md = """
        # Title

        Body.
        """
        let m = map(md)
        // Line 2 is the blank gap between the heading and the paragraph; it
        // anchors on the FOLLOWING block (the paragraph), so scrolling past the
        // heading reveals what comes next.
        XCTAssertEqual(m.block(forLine: 2), 1)
    }

    // MARK: - block → line

    func test_blockToLine_returnsBlockStartLine() {
        let md = """
        # Title

        A paragraph of body text.

        ```swift
        let x = 1
        ```
        """
        let m = map(md)
        XCTAssertEqual(m.line(forBlock: 0), 1)   // heading starts at line 1
        XCTAssertEqual(m.line(forBlock: 1), 3)   // paragraph at line 3
        XCTAssertEqual(m.line(forBlock: 2), 5)   // fence at line 5
    }

    // MARK: - Inverse property

    func test_inverse_lineToBlockToLine_isStableOnBlockStarts() {
        let md = """
        # H1

        para one

        ## H2

        para two

        ```
        code
        ```
        """
        let m = map(md)
        // For every block, block→line→block is the identity.
        for b in 0..<m.blockCount {
            guard let line = m.line(forBlock: b) else { return XCTFail("nil line for \(b)") }
            XCTAssertEqual(m.block(forLine: line), b, "block \(b) round-trip via line \(line)")
        }
    }

    func test_inverse_anyLineInBlockMapsToItsStart() {
        // Any line inside a block resolves to that block, and that block maps
        // back to its FIRST line (canonical representative).
        let md = """
        para line one
        para line two
        para line three

        next paragraph
        """
        let m = map(md)
        // First block spans lines 1-3.
        for line in 1...3 {
            let b = m.block(forLine: line)
            XCTAssertEqual(b, 0, "line \(line) should be block 0")
            XCTAssertEqual(m.line(forBlock: b!), 1, "block 0 canonical line is 1")
        }
    }

    // MARK: - Clamping

    func test_clamp_lineBelowOne_toFirstBlock() {
        let m = map("# Only\n\nbody")
        XCTAssertEqual(m.block(forLine: 0), 0)
        XCTAssertEqual(m.block(forLine: -5), 0)
    }

    func test_clamp_linePastEnd_toLastBlock() {
        let md = "# H\n\nbody\n\nmore"
        let m = map(md)
        let lastBlock = m.blockCount - 1
        XCTAssertEqual(m.block(forLine: 9999), lastBlock)
    }

    func test_clamp_blockOutOfRange() {
        let md = "# H\n\nbody"
        let m = map(md)
        XCTAssertEqual(m.line(forBlock: -3), m.line(forBlock: 0))     // clamp low
        XCTAssertEqual(m.line(forBlock: 9999), m.line(forBlock: m.blockCount - 1)) // clamp high
    }

    func test_empty_noBlocks_nilQueries() {
        let m = MarkdownPreviewMap.build(source: "", renderedBlockCount: 0)
        XCTAssertNil(m.block(forLine: 1))
        XCTAssertNil(m.line(forBlock: 0))
    }

    func test_crlf_lineCountingMatchesLF() {
        let lf = MarkdownPreviewMap.sourceBlockRanges(
            MarkdownPreviewMap.splitLines("# A\n\nbody\n"))
        let crlf = MarkdownPreviewMap.sourceBlockRanges(
            MarkdownPreviewMap.splitLines("# A\r\n\r\nbody\r\n"))
        XCTAssertEqual(lf, crlf, "CRLF must not collapse the document to one line")
    }

    // MARK: - Rendered-count alignment

    func test_renderedCountCap_clampsAlignment() {
        // If the renderer somehow produces FEWER blocks than the source parser,
        // the map must not point at a non-existent block index.
        let md = "# A\n\nB\n\nC"
        let m = MarkdownPreviewMap.build(source: md, renderedBlockCount: 2)
        for e in m.entries {
            XCTAssertLessThan(e.blockIndex, 2)
        }
        XCTAssertEqual(m.entries.count, 2)
    }
}
