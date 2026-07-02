import XCTest
@testable import ViewerCore

/// TSK-1427: a Word .docx with a table must open as a Markdown table (structure
/// preserved), not flatten its cells into loose paragraphs. Uses the same .table
/// IR + serializer as the HTML-paste path.
final class DocxTableImportTests: XCTestCase {
    private func cell(_ t: String) -> String { "<w:tc><w:p><w:r><w:t>\(t)</w:t></w:r></w:p></w:tc>" }
    private func row(_ cells: [String]) -> String { "<w:tr>" + cells.map(cell).joined() + "</w:tr>" }
    private func doc(_ body: String) -> String {
        "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body>\(body)</w:body></w:document>"
    }

    func test_docxTable_becomesMarkdownTable() {
        let xml = doc("<w:tbl>" + row(["A", "B"]) + row(["1", "2"]) + "</w:tbl>")
        XCTAssertEqual(DocxTextExtractor.markdown(documentXML: xml),
                       "| A | B |\n| --- | --- |\n| 1 | 2 |")
    }

    func test_docxTable_coexistsWithParagraphs() {
        let xml = doc("<w:p><w:r><w:t>Intro</w:t></w:r></w:p>"
            + "<w:tbl>" + row(["H"]) + row(["v"]) + "</w:tbl>")
        let md = DocxTextExtractor.markdown(documentXML: xml)
        XCTAssertEqual(md, "Intro\n\n| H |\n| --- |\n| v |")   // blocks join with a blank line
    }

    func test_docxPlainParagraphs_stillWork() {
        let xml = doc("<w:p><w:r><w:t>Hello</w:t></w:r></w:p>")
        XCTAssertEqual(DocxTextExtractor.markdown(documentXML: xml), "Hello")
    }
}
