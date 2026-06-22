import XCTest
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// Host coverage for the CSV-export MODEL wiring (TSK-1226): the DocumentModel
/// methods `activeCSVAsMarkdownTable()`, `activeCSVAsJSON()`, `activeCSVSummary()`
/// that back the Copy-as-Markdown-Table / JSON / Summary actions. The
/// CsvConvert / CsvSummary / CSVParser engines have their own tests, and the
/// menu/clipboard is render — but the model wiring (the `canConvertActiveCSV`
/// gate + active-file routing + the TSK-901 content-sniff for a misnamed CSV)
/// had NO host coverage. These pin that wiring with teeth: a .csv routes through
/// the engine (output equals the engine for the same parse + contains the data);
/// a prose .txt is gated out (nil); a .txt that *holds* CSV is sniffed in.
@MainActor
final class DocumentModelCSVExportTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentModelCSVExportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "DocumentModelCSVExportTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeModel() -> DocumentModel {
        DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmpDir.appendingPathComponent("history.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults)
        )
    }

    @discardableResult
    private func writeFile(_ name: String, _ contents: String) throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private let csv = "a,b\n1,2\n3,4\n"

    // MARK: - Markdown table

    func test_activeCSVAsMarkdownTable_routesActiveCSVThroughEngine() throws {
        let model = makeModel()
        let url = try writeFile("data.csv", csv)
        model.open(url: url)
        let r = CSVParser.parse(csv)
        let expected = CsvConvert.toMarkdownTable(header: r.header, rows: r.rows)
        let got = model.activeCSVAsMarkdownTable()
        XCTAssertEqual(got, expected, "model must route the active CSV through CsvConvert.toMarkdownTable")
        XCTAssertTrue(got?.contains("a") == true && got?.contains("b") == true,
            "the table must carry the header cells")
    }

    // MARK: - JSON

    func test_activeCSVAsJSON_routesActiveCSVThroughEngine() throws {
        let model = makeModel()
        let url = try writeFile("data.csv", csv)
        model.open(url: url)
        let r = CSVParser.parse(csv)
        XCTAssertEqual(model.activeCSVAsJSON(),
                       CsvConvert.toJSON(header: r.header, rows: r.rows))
    }

    // MARK: - Summary

    func test_activeCSVSummary_routesActiveCSVThroughEngine() throws {
        let model = makeModel()
        let url = try writeFile("data.csv", csv)
        model.open(url: url)
        let r = CSVParser.parse(csv)
        XCTAssertEqual(model.activeCSVSummary(),
                       CsvSummary.report(header: r.header, rows: r.rows))
    }

    // MARK: - Gate: non-CSV prose is excluded

    func test_csvExports_returnNil_forProseTextFile() throws {
        let model = makeModel()
        let url = try writeFile("notes.txt", "the quick brown fox\njumps over the lazy dog\n")
        model.open(url: url)
        XCTAssertNil(model.activeCSVAsMarkdownTable(), "prose .txt is not CSV → nil")
        XCTAssertNil(model.activeCSVAsJSON())
        XCTAssertNil(model.activeCSVSummary())
    }

    // MARK: - Gate: no active file

    func test_csvExports_returnNil_whenNoActiveFile() {
        let model = makeModel()
        XCTAssertNil(model.activeCSVAsMarkdownTable())
        XCTAssertNil(model.activeCSVAsJSON())
        XCTAssertNil(model.activeCSVSummary())
    }

    // MARK: - TSK-901 content-sniff: a .txt that holds CSV is converted

    func test_activeCSVAsMarkdownTable_sniffsMisnamedCSV_txtHoldingCSV() throws {
        let model = makeModel()
        let url = try writeFile("misnamed.txt", "x,y,z\n1,2,3\n4,5,6\n7,8,9\n")
        model.open(url: url)
        XCTAssertNotNil(model.activeCSVAsMarkdownTable(),
            "a .txt whose content sniffs as CSV is convertible (TSK-901 content-sniff)")
    }
}
