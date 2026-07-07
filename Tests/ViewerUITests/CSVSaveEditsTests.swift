import XCTest
import ViewerCore
@testable import ViewerUI

/// TSK-1472 — the CSV grid's explicit save flow. `DocumentModel.saveCSVEdits`
/// routes the serialized edited table through the EDITOR save chokepoint, so
/// the grid's Save button inherits the atomic write + local-history snapshot
/// path. Host-tested end-to-end against a real temp file; the on-screen bar
/// is the render tail (surface matrix: the CSV lens rides TSK-1551).
@MainActor
final class CSVSaveEditsTests: XCTestCase {

    private var tmpDir: URL!
    private let suiteName = "CSVSaveEditsTests-\(UUID().uuidString)"
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("csv-save-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
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

    func test_saveCSVEdits_writesSerializedTableToDisk() throws {
        let url = tmpDir.appendingPathComponent("t.csv")
        try "a,b\n1,2\n3,4\n".write(to: url, atomically: true, encoding: .utf8)
        let model = makeModel()
        model.open(url: url)
        let id = try XCTUnwrap(model.tabs.selected?.id)

        // The grid's edit path: parse → overlay an edit → serialize → save.
        var edited = EditableCSVModel(RustCSVAdapter.parse("a,b\n1,2\n3,4\n"))
        XCTAssertTrue(edited.setCell(row: 1, column: 0, to: "99"))
        XCTAssertTrue(edited.isDirty)

        XCTAssertTrue(model.saveCSVEdits(edited.serialize(), forTabID: id),
                      "the save chokepoint must accept the CSV write")

        let onDisk = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(onDisk.contains("99,2"), "the edited cell reaches disk: \(onDisk)")
        XCTAssertTrue(onDisk.hasPrefix("a,b"), "header preserved")
        // Round-trip: the saved bytes reparse to the edited grid.
        let reparsed = RustCSVAdapter.parse(onDisk)
        XCTAssertEqual(reparsed.rows.first?.first, "99")
    }

    func test_saveCSVEdits_unknownTab_failsWithoutWriting() throws {
        let url = tmpDir.appendingPathComponent("keep.csv")
        try "x,y\n5,6\n".write(to: url, atomically: true, encoding: .utf8)
        let model = makeModel()
        XCTAssertFalse(model.saveCSVEdits("evil\n", forTabID: UUID()),
                       "no tab ⇒ no write")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "x,y\n5,6\n")
    }
}
