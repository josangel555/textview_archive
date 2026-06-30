import XCTest
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// TSK-698 — host coverage for the Script Console's DocumentModel glue (the path to
/// validated, complementing the model tests + the VM render test). Pins openScriptConsole's
/// seeding/flag behavior and applyScriptConsoleOutput's open-in-new-tab. Pure model layer
/// (no rendering) → host-testable.
@MainActor
final class DocumentModelScriptConsoleTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DMScriptConsoleTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "DMScriptConsoleTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
        if let suiteName, let defaults { defaults.removePersistentDomain(forName: suiteName) }
    }

    private func makeModel() -> DocumentModel {
        DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmpDir.appendingPathComponent("history.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults))
    }

    @discardableResult
    private func writeFile(_ name: String, _ contents: String) throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func test_openScriptConsole_noActiveTab_showsEmptyConsole() {
        let model = makeModel()
        XCTAssertFalse(model.showScriptConsole)
        model.openScriptConsole()
        XCTAssertTrue(model.showScriptConsole, "openScriptConsole must show the panel")
        XCTAssertNotNil(model.scriptConsoleVM, "openScriptConsole must create the controller")
        XCTAssertEqual(model.scriptConsoleVM?.inputContent, "", "no active tab → empty input")
    }

    func test_openScriptConsole_seedsContentAndFormat_fromActiveFile() throws {
        let model = makeModel()
        let url = try writeFile("data.csv", "name,status\na,OK\n")
        model.open(url: url)
        model.openScriptConsole()
        XCTAssertTrue(model.showScriptConsole)
        XCTAssertEqual(model.scriptConsoleVM?.inputContent, "name,status\na,OK\n",
                       "seeds from the active file's content (live buffer or file fallback)")
        XCTAssertEqual(model.scriptConsoleVM?.inputFormat, .csv,
                       ".csv extension → CSV input format")
    }

    func test_applyScriptConsoleOutput_opensResultInNewTab() {
        let model = makeModel()
        let before = model.tabs.tabs.count
        model.applyScriptConsoleOutput("[\n  1,\n  2\n]")
        XCTAssertGreaterThan(model.tabs.tabs.count, before,
                             "applying the output opens it in a new tab")
    }

    func test_applyScriptConsoleOutput_empty_isNoOp() {
        let model = makeModel()
        let before = model.tabs.tabs.count
        model.applyScriptConsoleOutput("")
        XCTAssertEqual(model.tabs.tabs.count, before, "empty output opens no tab")
    }
}
