import XCTest
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// Host coverage for the JSON-tools MODEL wiring (TSK-1229, continuing the
/// TSK-1113.. drain): `minifyActiveJSON()` (compact the active JSON file) and
/// `activeJSONAsCSV()` (JSON array-of-objects → CSV). The canMinifyActiveJSON
/// GATE is already tested, and the Formatter / JsonConvert engines have their own
/// tests — but the model wiring (the minify WRITE-action and the CSV conversion
/// routing) had NO host coverage. These pin that wiring with teeth: minify writes
/// the engine's compact form to disk + is a no-op when already compact + gated to
/// JSON; the CSV conversion routes through JsonConvert and is nil for non-array /
/// non-JSON input.
@MainActor
final class DocumentModelJSONToolsTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentModelJSONToolsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "DocumentModelJSONToolsTests-\(UUID().uuidString)"
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

    private func diskContents(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Minify (write action)

    func test_minifyActiveJSON_writesEngineCompactFormToDisk_returnsTrue() throws {
        let model = makeModel()
        let pretty = "{\n  \"a\": 1,\n  \"b\": 2\n}\n"
        let url = try writeFile("data.json", pretty)
        model.open(url: url)
        XCTAssertTrue(model.minifyActiveJSON())
        XCTAssertEqual(diskContents(url), Formatter.minifyJSON(pretty),
            "the active file must be rewritten to Formatter.minifyJSON's compact output")
        XCTAssertFalse(diskContents(url)?.contains("  ") == true, "no indentation remains after minify")
    }

    func test_minifyActiveJSON_isNoOp_whenAlreadyCompact_returnsFalse() throws {
        let model = makeModel()
        let compact = Formatter.minifyJSON("{\"a\":1}")   // already in target form
        let url = try writeFile("data.json", compact)
        model.open(url: url)
        XCTAssertFalse(model.minifyActiveJSON(), "already-compact JSON is a no-op → false")
        XCTAssertEqual(diskContents(url), compact, "no-op must not rewrite the file")
    }

    func test_minifyActiveJSON_returnsFalse_forNonJSONFile() throws {
        let model = makeModel()
        let url = try writeFile("notes.txt", "the quick brown fox jumps\n")
        model.open(url: url)
        XCTAssertFalse(model.minifyActiveJSON(), "minify is gated to JSON content")
    }

    func test_minifyActiveJSON_returnsFalse_whenNoActiveFile() {
        let model = makeModel()
        XCTAssertFalse(model.minifyActiveJSON())
    }

    // MARK: - JSON → CSV

    func test_activeJSONAsCSV_routesArrayOfObjectsThroughEngine() throws {
        let model = makeModel()
        let json = "[{\"a\":1,\"b\":2},{\"a\":3,\"b\":4}]"
        let url = try writeFile("data.json", json)
        model.open(url: url)
        let got = model.activeJSONAsCSV()
        XCTAssertEqual(got, JsonConvert.toCSV(json),
            "model must route the active JSON through JsonConvert.toCSV")
        XCTAssertTrue(got?.contains("a") == true && got?.contains("b") == true,
            "the CSV carries the object keys as the header")
    }

    func test_activeJSONAsCSV_isNil_forNonArrayJSON() throws {
        let model = makeModel()
        let url = try writeFile("data.json", "{\"a\":1}")   // object, not array-of-objects
        model.open(url: url)
        XCTAssertNil(model.activeJSONAsCSV(),
            "a JSON object (not an array of objects) has no table shape → nil")
    }

    func test_activeJSONAsCSV_isNil_forNonJSONAndNoFile() throws {
        let model = makeModel()
        let url = try writeFile("notes.txt", "not json at all\n")
        model.open(url: url)
        XCTAssertNil(model.activeJSONAsCSV(), "prose .txt → nil")
        let empty = makeModel()
        XCTAssertNil(empty.activeJSONAsCSV(), "no active file → nil")
    }
}
