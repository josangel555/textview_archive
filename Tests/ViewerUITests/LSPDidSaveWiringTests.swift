import XCTest
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// TSK-464 — `textDocument/didSave` wiring. The LSP client/pool have had
/// `didSave` since the LSP feature landed, but NOTHING called it: servers
/// never saw saves, so on-save format/lint/index behaviours were dead.
/// The fix routes the editor-save success path through the coordinator's
/// `onDidSaveToDisk` hook, which DocumentModel wires to `LSPPool.didSave`
/// (a no-op for files without a live LSP session, so safe for all types).
///
/// Headless: drives the REAL save path against a temp file and pins the
/// hook contract — fired exactly once per successful save, with the saved
/// URL and the saved text. The pool side's guards are covered by the LSP
/// pool suites; this file pins the previously-missing caller.
@MainActor
final class LSPDidSaveWiringTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LSPDidSaveWiringTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "LSPDidSaveWiringTests-\(UUID().uuidString)"
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

    private func writeFile(_ name: String, _ contents: String) throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func test_saveEditor_firesDidSaveHook_withSavedURLAndText() throws {
        let url = try writeFile("a.swift", "let x = 1\n")
        let model = makeModel()
        model.open(url: url)
        let id = model.tabs.selected!.id
        _ = model.editor.editorBuffer(forTabID: id)

        var fired: [(URL, String)] = []
        model.editor.onDidSaveToDisk = { fired.append(($0, $1)) }

        model.editor.updateEditorText("let x = 2\n", forTabID: id)
        XCTAssertTrue(model.editor.saveEditor(forTabID: id))

        XCTAssertEqual(fired.count, 1,
            "a successful save must fire the didSave hook exactly once (TSK-464)")
        XCTAssertEqual(fired.first?.0.standardizedFileURL, url.standardizedFileURL,
            "the hook must carry the SAVED file's URL")
        XCTAssertEqual(fired.first?.1, "let x = 2\n",
            "the hook must carry the saved text (didSave includeText payload)")
    }

    func test_saveWithNoBuffer_doesNotFireHook() throws {
        let url = try writeFile("b.swift", "let y = 1\n")
        let model = makeModel()
        model.open(url: url)
        // No editor buffer seeded → saveEditor returns false → no hook.
        var fired = 0
        model.editor.onDidSaveToDisk = { _, _ in fired += 1 }
        XCTAssertFalse(model.editor.saveEditor(forTabID: UUID()))
        XCTAssertEqual(fired, 0, "a no-op save must not announce a didSave")
    }

    func test_documentModel_wiresTheHookByDefault() throws {
        // The coordinator hook exists so DocumentModel can route it to
        // LSPPool.didSave — pin that the default wiring is installed (a
        // regression here silently re-kills on-save server behaviours
        // while the hook-contract test above stays green).
        let model = makeModel()
        XCTAssertNotNil(model.editor.onDidSaveToDisk,
            "DocumentModel must wire onDidSaveToDisk → LSPPool.didSave (TSK-464)")
    }
}
