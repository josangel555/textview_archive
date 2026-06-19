import XCTest
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// TSK-705 — host coverage for `DocumentModel` snippet-session integration:
/// `insertSnippet` both posts the expanded text AND begins a tab-stop session
/// seeded from the active editor's caret; `snippetTab(forward:)` forwards to the
/// coordinator's walker. The CM6 Tab interception + caret rendering is the
/// editor/VM tail.
@MainActor
final class SnippetSessionModelTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnippetSessionModelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "SnippetSessionModelTests-\(UUID().uuidString)"
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

    func test_insertSnippet_withStops_beginsSessionAtCaret() throws {
        let model = makeModel()
        try openEditorTab(model)
        // Caret at offset 5 — the session base.
        let tid = model.tabs.tabs[0].id
        model.recordEditorCursor(
            CMCursorPosition(line: 1, column: 5, head: 5, rangeCount: 1), forTabID: tid)

        // "Markdown Link" = "[${1:text}](${2:https://})": $1 at offset 1 len 4.
        let link = SnippetLibrary.builtIns.first { $0.id == "md.link" }!
        XCTAssertTrue(model.insertSnippet(link))
        XCTAssertEqual(model.editorInsertRequest?.text, "[text](https://)")
        XCTAssertTrue(model.isSnippetSessionActive, "a snippet with stops opens a session")
        // First stop $1 = base(5) + 1, selecting the 4-char "text" default.
        XCTAssertEqual(model.editorSelectRequest?.anchor, 6)
        XCTAssertEqual(model.editorSelectRequest?.head, 10)
    }

    func test_insertSnippet_noStops_noSession() throws {
        let model = makeModel()
        try openEditorTab(model)
        // "TODO Comment" = "<!-- TODO: $0 -->" — single final stop $0 (still a
        // session, but tests below use a truly stop-free body for the no-op).
        let plain = Snippet(id: "x", name: "x", body: "plain no stops")
        XCTAssertTrue(model.insertSnippet(plain))
        XCTAssertEqual(model.editorInsertRequest?.text, "plain no stops")
        XCTAssertFalse(model.isSnippetSessionActive, "no stops ⇒ no session")
        XCTAssertNil(model.editorSelectRequest)
    }

    func test_snippetTab_walksTheSession() throws {
        let model = makeModel()
        try openEditorTab(model)
        let tid = model.tabs.tabs[0].id
        model.recordEditorCursor(
            CMCursorPosition(line: 1, column: 0, head: 0, rangeCount: 1), forTabID: tid)
        let link = SnippetLibrary.builtIns.first { $0.id == "md.link" }!
        XCTAssertTrue(model.insertSnippet(link))           // at $1
        XCTAssertEqual(model.editorSelectRequest?.anchor, 1)

        // Tab → $2 = "https://" at offset 7, length 8.
        XCTAssertTrue(model.snippetTab(forward: true))
        XCTAssertEqual(model.editorSelectRequest?.anchor, 7)
        XCTAssertEqual(model.editorSelectRequest?.head, 15)

        // Tab again → md.link has no $0, so $2 was the last stop; the session ends.
        XCTAssertTrue(model.snippetTab(forward: true))
        XCTAssertFalse(model.isSnippetSessionActive)
    }

    func test_snippetTab_notEditorMode_noActiveSession() throws {
        let model = makeModel()
        // No editor tab open at all; insertSnippet is a no-op and snippetTab
        // returns false (nothing to walk).
        XCTAssertFalse(model.insertSnippet(SnippetLibrary.builtIns[0]))
        XCTAssertFalse(model.snippetTab(forward: true))
    }
}
