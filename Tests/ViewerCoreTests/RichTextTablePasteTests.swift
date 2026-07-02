import XCTest
@testable import ViewerCore

/// TSK-1427: a rich-paste of an HTML <table> (browser/spreadsheet copy) must
/// become a GFM Markdown table, not collapse every cell into one run ("AB12").
/// LIVE via universalPaste's HTML→Markdown converter.
final class RichTextTablePasteTests: XCTestCase {
    func test_table_becomesGFMPipeTable() {
        let html = "<table><tr><th>A</th><th>B</th></tr><tr><td>1</td><td>2</td></tr></table>"
        let md = RichTextHTMLParser.markdown(fromHTML: html)
        XCTAssertEqual(md, "| A | B |\n| --- | --- |\n| 1 | 2 |", "got [\(md)]")
    }

    func test_theadTbody_wrappersSkipped() {
        let html = "<table><thead><tr><th>H</th></tr></thead><tbody><tr><td>x</td></tr></tbody></table>"
        let md = RichTextHTMLParser.markdown(fromHTML: html)
        XCTAssertEqual(md, "| H |\n| --- |\n| x |", "got [\(md)]")
    }

    func test_pipeInCell_isEscaped() {
        let html = "<table><tr><th>a|b</th></tr><tr><td>c</td></tr></table>"
        let md = RichTextHTMLParser.markdown(fromHTML: html)
        XCTAssertTrue(md.contains("a\\|b"), "a literal pipe in a cell must be escaped; got [\(md)]")
    }

    func test_raggedRow_paddedToHeaderWidth() {
        let html = "<table><tr><th>A</th><th>B</th></tr><tr><td>1</td></tr></table>"
        let md = RichTextHTMLParser.markdown(fromHTML: html)
        XCTAssertEqual(md, "| A | B |\n| --- | --- |\n| 1 |  |", "ragged row padded; got [\(md)]")
    }

    func test_serializerRoundTrip_table() {
        let doc = RichTextDocument([.table(header: [[.text("H")]], rows: [[[.text("v")]]])])
        XCTAssertEqual(RichTextSerializer.serialize(doc), "| H |\n| --- |\n| v |")
    }
}
