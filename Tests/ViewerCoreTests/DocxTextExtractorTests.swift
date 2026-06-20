import XCTest
@testable import ViewerCore

/// .docx text extraction (multi-format viewer). Host-tested with teeth.
final class DocxTextExtractorTests: XCTestCase {

    private func doc(_ body: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <w:document xmlns:w="urn:w"><w:body>
        \(body)
        </w:body></w:document>
        """
    }
    private func p(_ runs: String) -> String { "<w:p>\(runs)</w:p>" }
    private func r(_ text: String) -> String { "<w:r><w:t>\(text)</w:t></w:r>" }

    func test_paragraphs_inOrder() {
        let xml = doc(p(r("First")) + p(r("Second")))
        XCTAssertEqual(DocxTextExtractor.paragraphs(documentXML: xml), ["First", "Second"])
    }

    func test_multipleRuns_concatenateWithinParagraph() {
        let xml = doc(p(r("Hello, ") + r("world")))
        XCTAssertEqual(DocxTextExtractor.paragraphs(documentXML: xml), ["Hello, world"])
    }

    func test_tabAndBreak_withinParagraph() {
        let xml = doc(p(r("a") + "<w:tab/>" + r("b") + "<w:br/>" + r("c")))
        XCTAssertEqual(DocxTextExtractor.paragraphs(documentXML: xml), ["a\tb\nc"])
    }

    func test_emptyParagraph_isPreservedAsBlank() {
        let xml = doc(p(r("top")) + p("") + p(r("bottom")))
        XCTAssertEqual(DocxTextExtractor.paragraphs(documentXML: xml), ["top", "", "bottom"])
    }

    func test_plainText_joinsParagraphsWithNewline() {
        let xml = doc(p(r("one")) + p(r("two")))
        XCTAssertEqual(DocxTextExtractor.plainText(documentXML: xml), "one\ntwo")
    }

    func test_textOutsideRun_isIgnoredUntilWT() {
        // Stray characters not inside a w:t (e.g. between runs) must not leak.
        let xml = doc("<w:p><w:r><w:t>kept</w:t></w:r>  stray  </w:p>")
        XCTAssertEqual(DocxTextExtractor.paragraphs(documentXML: xml), ["kept"])
    }
}
