import XCTest
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// TSK-823 follow-up — the Edit menu's LSP commands (Format Document / Rename
/// Symbol… / Code Actions…) dispatch `formatActiveEditorViaLSP` /
/// `showLSPRenamePrompt` / `showCodeActionPicker`. The menu items are
/// editor-mode-gated by `validateMenuItem`, but this pins the SAFETY contract
/// that lets them exist: each is a guarded no-op (no crash, presents nothing) in
/// a non-editor / no-language-server context, so a stray invocation can't blow
/// up or pop an empty prompt.
///
/// Host-safe (T1m): drives the model directly. The actual format/rename/
/// code-action apply is host-tested elsewhere (TSK-627/640); the menu RENDER +
/// a live LSP round-trip are the VM/live-tail.
@MainActor
final class LSPEditActionSafetyTests: XCTestCase {
    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LSPEditSafety-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "LSPEditSafety-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
        if let suiteName, let defaults { defaults.removePersistentDomain(forName: suiteName) }
        try await super.tearDown()
    }

    private func makeModel() -> DocumentModel {
        DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmpDir.appendingPathComponent("history.json")),
            bookmarks: BookmarksStore(storeURL: tmpDir.appendingPathComponent("bookmarks.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults))
    }

    func test_format_noEditor_isGracefulFalse() {
        XCTAssertFalse(makeModel().formatActiveEditorViaLSP(),
                       "Format Document with no editor/LSP → safe false, not a crash")
    }

    func test_renamePrompt_guarded_doesNotPresent() {
        let m = makeModel()
        XCTAssertFalse(m.canRenameActiveEditorSymbol)
        m.showLSPRenamePrompt()
        XCTAssertFalse(m.isLSPRenamePromptPresented,
                       "no rename-able context → the prompt is NOT presented (guarded)")
    }

    func test_codeActions_guarded_doesNotLoad() {
        let m = makeModel()
        XCTAssertFalse(m.canRequestCodeActions)
        m.showCodeActionPicker()
        XCTAssertEqual(m.codeActionPicker, .hidden,
                       "no code-action context → the picker stays hidden (not .loading)")
    }
}
