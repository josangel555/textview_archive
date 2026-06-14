import XCTest
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// TSK-705 (slice 3) — host coverage for `DocumentModel.insertSnippet`: in
/// editor mode it posts an insert request carrying the snippet's expanded plain
/// text; otherwise it's a no-op. The actual CM6 caret insertion (and future
/// tab-stop navigation) is the editor/VM render tail.
@MainActor
final class SnippetInsertModelTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnippetInsertTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "SnippetInsertTests-\(UUID().uuidString)"
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
            preferences: PreferencesStore(defaults: defaults))
    }

    private func openEditorTab(_ model: DocumentModel) throws {
        let url = tmpDir.appendingPathComponent("doc.md")
        try "x\n".write(to: url, atomically: true, encoding: .utf8)
        model.open(url: url)
        var t = model.tabs.tabs[0]
        t.viewMode = .editor
        model.tabCoordinator.replace(at: 0, with: t)
    }

    func test_insertSnippet_inEditor_postsExpandedText() throws {
        let model = makeModel()
        try openEditorTab(model)
        XCTAssertTrue(model.canInsertSnippet)
        let link = SnippetLibrary.builtIns.first { $0.id == "md.link" }!
        XCTAssertTrue(model.insertSnippet(link))
        XCTAssertEqual(model.editorInsertRequest?.text, "[text](https://)",
                       "the editor receives the snippet's expanded plain text")
    }

    func test_insertSnippet_notEditorMode_isNoOp() throws {
        let model = makeModel()
        let url = tmpDir.appendingPathComponent("doc.md")
        try "x\n".write(to: url, atomically: true, encoding: .utf8)
        model.open(url: url)  // default mode (rendered/source), NOT editor
        // Ensure not editor mode.
        if model.currentViewMode == .editor {
            var t = model.tabs.tabs[0]; t.viewMode = .source
            model.tabCoordinator.replace(at: 0, with: t)
        }
        XCTAssertFalse(model.canInsertSnippet)
        XCTAssertFalse(model.insertSnippet(SnippetLibrary.builtIns[0]))
        XCTAssertNil(model.editorInsertRequest, "no insert request posted off editor mode")
    }
}
