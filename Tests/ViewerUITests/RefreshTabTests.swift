import XCTest
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// Coverage for `DocumentModel.refreshTab(at:)` (bug6) — the right-click
/// tab → "Refresh" force-reload. Host-safe (no NSApplication); the
/// dirty-buffer NSAlert is stubbed via `editor.externalEditPromptOverride`.
/// Run with a class filter, not the unfiltered live-app sweep.
@MainActor
final class RefreshTabTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RefreshTabTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "RefreshTabTests-\(UUID().uuidString)"
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

    private func loadedContents(_ model: DocumentModel) -> String? {
        if case .loaded(let f) = model.currentState { return f.contents }
        return nil
    }

    // A clean tab force-reloads unconditionally — even when no watcher event
    // fired — and reflects the new on-disk bytes.
    func test_refreshTab_cleanTab_reloadsFromDisk() throws {
        let url = try writeFile("r_clean.txt", "original")
        let model = makeModel()
        model.open(url: url)
        XCTAssertEqual(loadedContents(model), "original")

        // Change the file behind the app's back, then force a refresh.
        try "updated on disk".write(to: url, atomically: true, encoding: .utf8)
        model.refreshTab(at: 0)

        XCTAssertEqual(loadedContents(model), "updated on disk",
            "refreshTab must reload a clean tab's bytes regardless of watcher state")
    }

    // A dirty editor buffer with "Discard & Reload" drops the edits and shows
    // the new disk bytes.
    func test_refreshTab_dirtyTab_discardAndReload_dropsEdits() throws {
        let url = try writeFile("r_discard.txt", "v1")
        let model = makeModel()
        model.open(url: url)
        let id = model.tabs.selected!.id
        _ = model.editor.editorBuffer(forTabID: id)
        model.editor.updateEditorText("my unsaved edits", forTabID: id)
        XCTAssertTrue(model.tabs.tabs[0].isDirty)

        try "v2 on disk".write(to: url, atomically: true, encoding: .utf8)
        model.editor.externalEditPromptOverride = { _ in .discardAndReload }
        model.refreshTab(at: 0)

        XCTAssertEqual(loadedContents(model), "v2 on disk",
            "Discard & Reload must replace the tab state with the on-disk bytes")
    }

    // A dirty editor buffer with "Keep My Edits" preserves the edits — a force
    // refresh must never silently clobber unsaved work.
    func test_refreshTab_dirtyTab_keepEdits_preservesBuffer() throws {
        let url = try writeFile("r_keep.txt", "v1")
        let model = makeModel()
        model.open(url: url)
        let id = model.tabs.selected!.id
        _ = model.editor.editorBuffer(forTabID: id)
        model.editor.updateEditorText("precious edits", forTabID: id)

        try "v2 on disk".write(to: url, atomically: true, encoding: .utf8)
        model.editor.externalEditPromptOverride = { _ in .keepEdits }
        model.refreshTab(at: 0)

        XCTAssertEqual(model.editor.editorBuffers[id]?.text, "precious edits",
            "Keep My Edits must leave the unsaved buffer intact")
        XCTAssertTrue(model.tabs.tabs[0].isDirty,
            "the tab must stay dirty after Keep My Edits")
    }

    // Out-of-bounds index is a safe no-op (no trap).
    func test_refreshTab_outOfBounds_isNoOp() {
        let model = makeModel()
        model.refreshTab(at: 5)   // no tabs open
        XCTAssertTrue(model.tabs.tabs.isEmpty)
    }
}
