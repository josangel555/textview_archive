import XCTest
import ViewerKit
@testable import ViewerCore

/// TSK-1338 — DOCX renders WITH STRUCTURE: OOXML → Markdown (headings via
/// w:pStyle, bold/italic via w:rPr, lists via w:numPr, reusing the escaping
/// RichTextSerializer) + .docx routes to the .markdown category so it renders
/// instead of showing flat raw text in the source view.
final class DocxMarkdownTests: XCTestCase {

    private let sample = """
    <w:document><w:body>
      <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Title</w:t></w:r></w:p>
      <w:p><w:r><w:rPr><w:b/></w:rPr><w:t>bold text</w:t></w:r></w:p>
      <w:p><w:pPr><w:numPr><w:ilvl w:val="0"/></w:numPr></w:pPr><w:r><w:t>one</w:t></w:r></w:p>
      <w:p><w:pPr><w:numPr><w:ilvl w:val="0"/></w:numPr></w:pPr><w:r><w:t>two</w:t></w:r></w:p>
      <w:p><w:r><w:t>plain para</w:t></w:r></w:p>
    </w:body></w:document>
    """

    func test_docxRoutesToMarkdownCategory() {
        XCTAssertEqual(FileTypeDetector.category(for: URL(fileURLWithPath: "/x/report.docx")), .markdown,
                       ".docx renders as Markdown (structure visible), not the flat source view")
    }

    func test_docxDefaultsToRenderedView() {
        // The structure-visible win: .docx must OPEN rendered, not in the raw
        // source view (which would show "#"/"**" syntax). Pins the default mode
        // so the re-route is a render, not a raw-text regression.
        XCTAssertEqual(ViewModeOptions.defaultMode(for: URL(fileURLWithPath: "/x/report.docx")), ViewMode.rendered,
                       ".docx opens RENDERED (markdown structure visible)")
    }

    func test_markdown_preservesStructure() {
        let md = DocxTextExtractor.markdown(documentXML: sample)
        XCTAssertTrue(md.contains("# Title"), "Heading1 paragraph → '# ' (got: \(md))")
        XCTAssertTrue(md.contains("**bold text**"), "w:b run → bold (got: \(md))")
        XCTAssertTrue(md.contains("- one") && md.contains("- two"),
                      "consecutive w:numPr paragraphs → one bullet list (got: \(md))")
        XCTAssertTrue(md.contains("plain para"), "plain paragraph preserved")
    }

    func test_markdown_escapesBodyText_noAccidentalHeading() {
        // A NON-heading paragraph whose text starts with '#' must not become a heading
        // (the serializer escapes body markdown-special chars — the safety the
        // structured path buys over naive string templating).
        let xml = "<w:document><w:body><w:p><w:r><w:t># not a heading</w:t></w:r></w:p></w:body></w:document>"
        let md = DocxTextExtractor.markdown(documentXML: xml)
        XCTAssertFalse(md.hasPrefix("# "), "body '#' must be escaped, not a heading (got: \(md))")
        XCTAssertTrue(md.contains("not a heading"), "the text is preserved")
    }
}
