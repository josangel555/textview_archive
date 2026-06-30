import XCTest
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// TSK-1161 — host coverage for the Structural Search DocumentModel glue (the path to
/// validated, complementing the view-model tests + the VM render test). Pins
/// openStructuralSearch's seeding (content + effective language) + the show flag.
@MainActor
final class DocumentModelStructuralSearchTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DMStructSearchTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "DMStructSearchTests-\(UUID().uuidString)"
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

    func test_openStructuralSearch_noActiveTab_showsEmptyPanel() {
        let model = makeModel()
        XCTAssertFalse(model.showStructuralSearch)
        model.openStructuralSearch()
        XCTAssertTrue(model.showStructuralSearch)
        XCTAssertNotNil(model.structuralSearchVM)
        XCTAssertEqual(model.structuralSearchVM?.inputText, "")
    }

    func test_openStructuralSearch_seedsContentAndLanguage_fromActiveFile() throws {
        let model = makeModel()
        let url = try writeFile("code.swift", "func f() { }")
        model.open(url: url)
        model.openStructuralSearch()
        XCTAssertTrue(model.showStructuralSearch)
        XCTAssertEqual(model.structuralSearchVM?.inputText, "func f() { }",
                       "seeds from the active file's content")
        XCTAssertEqual(model.structuralSearchVM?.language, .swift,
                       ".swift extension → effective language .swift")
    }
}
