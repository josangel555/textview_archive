import XCTest
@testable import ViewerCore

/// TSK-674: OpenDocument (.ods) content.xml → grid parser. Host-tested with
/// teeth — including the trailing-empty repeat OOM guard (real .ods pads with
/// huge `number-*-repeated` counts).
final class ODSContentParserTests: XCTestCase {

    private func ods(_ rows: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content xmlns:office="urn:o" xmlns:table="urn:t" xmlns:text="urn:x">
        <office:body><office:spreadsheet>
        <table:table table:name="Sheet1">
        \(rows)
        </table:table>
        </office:spreadsheet></office:body></office:document-content>
        """
    }
    private func cell(_ v: String) -> String { "<table:table-cell><text:p>\(v)</text:p></table:table-cell>" }
    private func row(_ cells: String) -> String { "<table:table-row>\(cells)</table:table-row>" }

    func test_basicGrid() {
        let xml = ods(row(cell("A") + cell("B")) + row(cell("C") + cell("D")))
        XCTAssertEqual(ODSContentParser.parseFirstTableGrid(contentXML: xml),
                       [["A", "B"], ["C", "D"]])
    }

    func test_columnRepeat_expands() {
        let xml = ods(row(#"<table:table-cell table:number-columns-repeated="3"><text:p>X</text:p></table:table-cell>"# + cell("Y")))
        XCTAssertEqual(ODSContentParser.parseFirstTableGrid(contentXML: xml),
                       [["X", "X", "X", "Y"]])
    }

    func test_rowRepeat_expands() {
        let xml = ods(#"<table:table-row table:number-rows-repeated="2">"# + cell("R") + "</table:table-row>")
        XCTAssertEqual(ODSContentParser.parseFirstTableGrid(contentXML: xml),
                       [["R"], ["R"]])
    }

    func test_trailingEmptyColumns_areNotMaterialized() {
        // A then 1000 empty padding cells → row stays ["A"], not 1001 wide.
        let xml = ods(row(cell("A") + #"<table:table-cell table:number-columns-repeated="1000"/>"#))
        XCTAssertEqual(ODSContentParser.parseFirstTableGrid(contentXML: xml), [["A"]])
    }

    func test_gapEmptyColumns_areFlushedBeforeRealValue() {
        // A, 2 empties, B → the gap is real (a non-empty value follows).
        let xml = ods(row(cell("A") + #"<table:table-cell table:number-columns-repeated="2"/>"# + cell("B")))
        XCTAssertEqual(ODSContentParser.parseFirstTableGrid(contentXML: xml),
                       [["A", "", "", "B"]])
    }

    func test_trailingEmptyRows_areNotMaterialized() {
        // A real row, then an empty row repeated 1000 → grid stays [["A"]].
        let xml = ods(row(cell("A"))
                      + #"<table:table-row table:number-rows-repeated="1000"><table:table-cell/></table:table-row>"#)
        XCTAssertEqual(ODSContentParser.parseFirstTableGrid(contentXML: xml), [["A"]])
    }

    func test_emptyRowGap_isFlushedBeforeRealRow() {
        let xml = ods(row(cell("A"))
                      + #"<table:table-row><table:table-cell/></table:table-row>"#
                      + row(cell("B")))
        XCTAssertEqual(ODSContentParser.parseFirstTableGrid(contentXML: xml),
                       [["A"], [""], ["B"]])
    }
}
