import XCTest
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// Host coverage for `DocumentModel.selectedLoadedTextPrefix` (TSK-1241) — the
/// bounded loaded-source-text accessor backing the diagnostic dump's
/// `loadedTextPrefix`. A VM UAT reads that field to assert WHAT loaded into the
/// source view (e.g. a routed `.rtf`/`.docx` shows its extracted text, not raw
/// container bytes), since `editorText` is `""` for an un-edited read-only tab
/// (the editor buffer isn't materialized until an edit). These pin the
/// model-layer contract host-side so a regression of the accessor fails the gate.
@MainActor
final class DocumentModelLoadedTextPrefixTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentModelLoadedTextPrefixTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "DocumentModelLoadedTextPrefixTests-\(UUID().uuidString)"
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

    func test_noTabLoaded_returnsEmpty() {
        // No file opened → no loaded tab → empty, never a crash.
        XCTAssertEqual(makeModel().selectedLoadedTextPrefix, "",
            "with no loaded tab the prefix must be empty")
    }

    func test_loadedFile_exposesItsContents() throws {
        let model = makeModel()
        let url = try writeFile("a.txt", "hello loaded text\nsecond line\n")
        model.open(url: url)
        XCTAssertTrue(model.selectedLoadedTextPrefix.contains("hello loaded text"),
            "the selected tab's loaded contents must be visible via the prefix (this is what a UAT asserts for routed-doc extraction)")
    }

    func test_prefixIsBounded() throws {
        let model = makeModel()
        let url = try writeFile("big.txt", String(repeating: "x", count: 5000))
        model.open(url: url)
        XCTAssertEqual(model.selectedLoadedTextPrefix.count, 400,
            "the prefix must be capped at 400 so the per-step diagnostic dump stays small")
    }
}
