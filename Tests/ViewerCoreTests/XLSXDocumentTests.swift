import XCTest
@testable import ViewerCore

/// Host coverage for the XLSX parse/model foundation slice (TSK-682 — the XLSX
/// format of the RTF/DOCX/PDF/XLSX multi-format viewer epic). The pure parsers
/// are exercised on raw XML strings (no file I/O); the on-disk loader is built
/// against a REAL `.xlsx` fixture assembled with the system `zip` tool, the same
/// system-tools pattern `ArchiveCatalogTests` uses — so the unzip→parse pipe is
/// covered end-to-end on the host.
///
/// The table-lens render is a later VM slice; this suite is the model gate that
/// fails on any regression of cell-ref math, type resolution, shared-string
/// linkage, the dense-grid layout, or the workbook→rels part resolution.
final class XLSXDocumentTests: XCTestCase {

    // MARK: - A1 cell-reference math

    func test_cellRef_basicColumns() {
        XCTAssertEqual(XLSXCellRef.parse("A1").map { [$0.row, $0.col] }, [0, 0])
        XCTAssertEqual(XLSXCellRef.parse("B1").map { [$0.row, $0.col] }, [0, 1])
        XCTAssertEqual(XLSXCellRef.parse("Z1").map { [$0.row, $0.col] }, [0, 25])
        XCTAssertEqual(XLSXCellRef.parse("A2").map { [$0.row, $0.col] }, [1, 0])
    }

    func test_cellRef_multiLetterColumns() {
        // Bijective base-26: AA=26, AB=27, AZ=51, BA=52.
        XCTAssertEqual(XLSXCellRef.parse("AA1")?.col, 26)
        XCTAssertEqual(XLSXCellRef.parse("AB1")?.col, 27)
        XCTAssertEqual(XLSXCellRef.parse("AZ1")?.col, 51)
        XCTAssertEqual(XLSXCellRef.parse("BA1")?.col, 52)
        XCTAssertEqual(XLSXCellRef.parse("ZZ100")?.col, 701)
        XCTAssertEqual(XLSXCellRef.parse("ZZ100")?.row, 99)
    }

    func test_cellRef_malformed() {
        XCTAssertNil(XLSXCellRef.parse(""))
        XCTAssertNil(XLSXCellRef.parse("123"))   // no column letters
        XCTAssertNil(XLSXCellRef.parse("A"))      // no row
        XCTAssertNil(XLSXCellRef.parse("A0"))     // rows are 1-based
        XCTAssertNil(XLSXCellRef.parse("1A"))
    }

    // MARK: - Shared-string table

    func test_sharedStrings_singleRuns() {
        let xml = """
        <?xml version="1.0"?><sst><si><t>Hello</t></si><si><t>World</t></si></sst>
        """
        XCTAssertEqual(XLSXSharedStrings.parse(xml), ["Hello", "World"])
    }

    func test_sharedStrings_richRunsConcatenated() {
        // A rich-text <si> with multiple <r><t> runs concatenates to one string.
        let xml = """
        <sst><si><r><t>Hello </t></r><r><t>World</t></r></si><si><t>Solo</t></si></sst>
        """
        XCTAssertEqual(XLSXSharedStrings.parse(xml), ["Hello World", "Solo"])
    }

    func test_sharedStrings_preservesWhitespaceAndEntities() {
        let xml = "<sst><si><t> a &amp; b </t></si></sst>"
        XCTAssertEqual(XLSXSharedStrings.parse(xml), [" a & b "])
    }

    func test_sharedStrings_emptyAndMissing() {
        XCTAssertEqual(XLSXSharedStrings.parse(""), [])
        XCTAssertEqual(XLSXSharedStrings.parse("<sst></sst>"), [])
        // An empty <si> yields an empty entry (index slot must be preserved).
        XCTAssertEqual(XLSXSharedStrings.parse("<sst><si></si><si><t>x</t></si></sst>"),
                       ["", "x"])
    }

    // MARK: - Worksheet parse: cell types

    func test_worksheet_sharedStringCells() {
        let sheet = """
        <worksheet><sheetData>
        <row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row>
        </sheetData></worksheet>
        """
        let result = XLSXWorksheet.parse(sheetXML: sheet, sharedStrings: ["Name", "Age"])
        XCTAssertEqual(result.rows, [["Name", "Age"]])
    }

    func test_worksheet_numbersBooleansFormulaErrors() {
        let sheet = """
        <worksheet><sheetData>
        <row r="1">
          <c r="A1"><v>42</v></c>
          <c r="B1" t="n"><v>3.14</v></c>
          <c r="C1" t="b"><v>1</v></c>
          <c r="D1" t="b"><v>0</v></c>
          <c r="E1" t="str"><v>=A1</v></c>
          <c r="F1" t="e"><v>#DIV/0!</v></c>
        </row>
        </sheetData></worksheet>
        """
        let result = XLSXWorksheet.parse(sheetXML: sheet, sharedStrings: [])
        XCTAssertEqual(result.rows, [["42", "3.14", "TRUE", "FALSE", "=A1", "#DIV/0!"]])
    }

    func test_worksheet_inlineString() {
        let sheet = """
        <worksheet><sheetData>
        <row r="1"><c r="A1" t="inlineStr"><is><t>Inline</t></is></c></row>
        </sheetData></worksheet>
        """
        let result = XLSXWorksheet.parse(sheetXML: sheet, sharedStrings: [])
        XCTAssertEqual(result.rows, [["Inline"]])
    }

    // MARK: - Worksheet parse: sparse grid layout

    func test_worksheet_sparseCellsPaddedToDenseGrid() {
        // A1 and C1 present, B1 absent; row 3 present, row 2 absent.
        let sheet = """
        <worksheet><sheetData>
        <row r="1"><c r="A1"><v>1</v></c><c r="C1"><v>3</v></c></row>
        <row r="3"><c r="B3"><v>x</v></c></row>
        </sheetData></worksheet>
        """
        let result = XLSXWorksheet.parse(sheetXML: sheet, sharedStrings: [])
        XCTAssertEqual(result.rows, [
            ["1", "", "3"],   // row 1: B1 padded
            ["", "", ""],     // row 2: entirely absent -> blank
            ["", "x", ""],    // row 3
        ])
        XCTAssertEqual(result.columnCount, 3)
        XCTAssertEqual(result.rowCount, 3)
    }

    func test_worksheet_missingSharedStringIndexDegradesToEmpty() {
        let sheet = """
        <worksheet><sheetData>
        <row r="1"><c r="A1" t="s"><v>5</v></c></row>
        </sheetData></worksheet>
        """
        let result = XLSXWorksheet.parse(sheetXML: sheet, sharedStrings: ["only"])
        XCTAssertEqual(result.rows, [[""]])
    }

    func test_worksheet_empty() {
        let result = XLSXWorksheet.parse(
            sheetXML: "<worksheet><sheetData></sheetData></worksheet>", sharedStrings: [])
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(result.columnCount, 0)
    }

    // MARK: - Workbook index + rels resolution

    func test_workbookParts_sheetDeclarations() {
        let xml = """
        <workbook xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <sheets>
            <sheet name="Data" sheetId="1" r:id="rId1"/>
            <sheet name="Summary" sheetId="2" r:id="rId2"/>
          </sheets>
        </workbook>
        """
        let refs = XLSXWorkbookParts.parseWorkbook(xml)
        XCTAssertEqual(refs.map(\.name), ["Data", "Summary"])
        XCTAssertEqual(refs.map(\.relationshipID), ["rId1", "rId2"])
    }

    func test_workbookParts_relsTargetMap() {
        let xml = """
        <Relationships>
          <Relationship Id="rId1" Target="worksheets/sheet1.xml"/>
          <Relationship Id="rId2" Target="/xl/worksheets/data.xml"/>
        </Relationships>
        """
        let map = XLSXWorkbookParts.parseRels(xml)
        XCTAssertEqual(map["rId1"], "worksheets/sheet1.xml")
        XCTAssertEqual(map["rId2"], "/xl/worksheets/data.xml")
    }

    func test_sheetPartPath_resolution() {
        let rels = ["rId1": "worksheets/sheet1.xml", "rId2": "/xl/worksheets/data.xml"]
        let ref1 = XLSXWorkbookParts.SheetRef(name: "A", relationshipID: "rId1")
        let ref2 = XLSXWorkbookParts.SheetRef(name: "B", relationshipID: "rId2")
        let ref3 = XLSXWorkbookParts.SheetRef(name: "C", relationshipID: "missing")
        // Relative target -> prefixed with xl/.
        XCTAssertEqual(XLSXDocument.sheetPartPath(for: ref1, rels: rels, index: 0),
                       "xl/worksheets/sheet1.xml")
        // Absolute target -> leading slash stripped.
        XCTAssertEqual(XLSXDocument.sheetPartPath(for: ref2, rels: rels, index: 1),
                       "xl/worksheets/data.xml")
        // No rels match -> conventional fallback by index.
        XCTAssertEqual(XLSXDocument.sheetPartPath(for: ref3, rels: rels, index: 2),
                       "xl/worksheets/sheet3.xml")
    }

    // MARK: - isXLSX gate

    func test_isXLSX_recognition() {
        XCTAssertTrue(XLSXDocument.isXLSX(URL(fileURLWithPath: "/t/book.xlsx")))
        XCTAssertTrue(XLSXDocument.isXLSX(URL(fileURLWithPath: "/t/MACRO.XLSM")))
        XCTAssertFalse(XLSXDocument.isXLSX(URL(fileURLWithPath: "/t/book.xls")))
        XCTAssertFalse(XLSXDocument.isXLSX(URL(fileURLWithPath: "/t/book.csv")))
        XCTAssertFalse(XLSXDocument.isXLSX(URL(fileURLWithPath: "/t/book.xlsb")))
    }

    // MARK: - End-to-end on-disk load (real .xlsx via system zip)

    func test_load_realXLSXFixture() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("XLSXDocumentTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("xl/worksheets"),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("xl/_rels"),
            withIntermediateDirectories: true)

        try write(dir, "xl/sharedStrings.xml",
            #"<?xml version="1.0"?><sst><si><t>Name</t></si><si><t>City</t></si><si><t>Ann</t></si></sst>"#)
        try write(dir, "xl/workbook.xml",
            #"<workbook xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="People" sheetId="1" r:id="rId1"/></sheets></workbook>"#)
        try write(dir, "xl/_rels/workbook.xml.rels",
            #"<Relationships><Relationship Id="rId1" Target="worksheets/sheet1.xml"/></Relationships>"#)
        try write(dir, "xl/worksheets/sheet1.xml", """
            <?xml version="1.0"?><worksheet><sheetData>
            <row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row>
            <row r="2"><c r="A2" t="s"><v>2</v></c><c r="B2"><v>100</v></c></row>
            </sheetData></worksheet>
            """)

        let xlsx = dir.appendingPathComponent("book.xlsx")
        XCTAssertEqual(try shell("/usr/bin/zip", ["-q", "-r", xlsx.path, "xl"], cwd: dir), 0)

        let workbook = try XLSXDocument.load(xlsx)
        XCTAssertEqual(workbook.sheets.count, 1)
        let sheet = try XCTUnwrap(workbook.firstSheet)
        XCTAssertEqual(sheet.name, "People")
        XCTAssertEqual(sheet.rows, [
            ["Name", "City"],
            ["Ann", "100"],
        ])
    }

    func test_load_rejectsNonXLSX() {
        let url = URL(fileURLWithPath: "/t/data.csv")
        XCTAssertThrowsError(try XLSXDocument.load(url)) { error in
            XCTAssertEqual(error as? XLSXDocument.LoadError, .notXLSX)
        }
    }

    // MARK: - Helpers

    private func write(_ base: URL, _ rel: String, _ contents: String) throws {
        try Data(contents.utf8).write(to: base.appendingPathComponent(rel))
    }

    @discardableResult
    private func shell(_ tool: String, _ args: [String], cwd: URL) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.currentDirectoryURL = cwd
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        return p.terminationStatus
    }
}
