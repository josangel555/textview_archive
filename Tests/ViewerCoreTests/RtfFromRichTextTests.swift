import XCTest
@testable import ViewerCore

/// TSK-1144 — teeth for the RichTextDocument → RTF projection (the converter that
/// lets RtfExporter consume Markdown via RichTextParser).
final class RtfFromRichTextTests: XCTestCase {

    func test_blocks_mapHeadingAndEmphasis() {
        let blocks = RtfExporter.blocks(from: RichTextParser.parse("# Title\n\nHello **bold** x"))
        guard case let .heading(level, hruns) = blocks.first else {
            return XCTFail("first block should be a heading")
        }
        XCTAssertEqual(level, 1)
        XCTAssertEqual(hruns.first?.text, "Title")
        guard case let .paragraph(pruns) = blocks[1] else {
            return XCTFail("second block should be a paragraph")
        }
        XCTAssertTrue(pruns.contains { $0.text == "bold" && $0.bold }, "bold run carried through")
    }

    func test_blocks_orderedListBecomesPrefixedParagraphs() {
        let blocks = RtfExporter.blocks(from: RichTextParser.parse("1. a\n2. b"))
        XCTAssertEqual(blocks.count, 2)
        if case let .paragraph(runs) = blocks[0] {
            XCTAssertEqual(runs.first?.text, "1.\u{00A0}")
        } else { XCTFail("ordered-list item should be a paragraph") }
    }

    func test_export_doc_producesRTFWithBold() {
        let rtf = RtfExporter.export(RichTextParser.parse("Hello **bold**"))
        XCTAssertTrue(rtf.hasPrefix("{\\rtf1"))
        XCTAssertTrue(rtf.contains("bold"))
        XCTAssertTrue(rtf.contains("\\b "), "bold control word emitted")
    }
}
