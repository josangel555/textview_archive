import XCTest
import ViewerKit
@testable import ViewerUI

/// TSK-452 ("bottom file stats not updating on tab change", owner repro):
/// a file changed ON DISK while its tab was backgrounded kept load-time
/// stats/content after switching to it — the 0d design re-stat'd
/// signal-only. Now a switch to a stale-on-disk tab runs the SAME guarded
/// reload the watcher path uses: clean tabs refresh silently; dirty editor
/// buffers still route through the external-edit conflict prompt and are
/// never clobbered.
@MainActor
final class TabSwitchStaleReloadTests: HeadlessUITestCase {

    private var harness: HeadlessHarness!

    override func setUp() async throws {
        try await super.setUp()
        harness = HeadlessHarness(label: "TabSwitchStaleReload")
    }

    override func tearDown() async throws {
        harness?.cleanup()
        harness = nil
        try await super.tearDown()
    }

    private func switchTo(_ id: UUID, _ model: DocumentModel) {
        let idx = model.tabs.tabs.firstIndex { $0.id == id }!
        model.selectTab(at: idx)
    }

    func test_switchToCleanTab_whoseFileChangedOnDisk_reloadsStats() throws {
        let model = harness.model
        let urlB = try harness.writeFile("b.md", "short\n")          // 6 bytes
        model.open(url: urlB)
        let bTab = model.tabs.selected!.id
        let urlA = try harness.writeFile("a.md", "# A\n")
        model.open(url: urlA)                                         // B backgrounded

        try String(repeating: "x", count: 500).write(
            to: urlB, atomically: true, encoding: .utf8)
        switchTo(bTab, model)

        guard case .loaded(let f)? = model.tabs.selected?.state else {
            return XCTFail("B must be loaded")
        }
        XCTAssertEqual(f.byteCount, 500,
            "switching to a stale-on-disk CLEAN tab must surface current stats (TSK-452)")
        XCTAssertEqual(model.tabs.selected?.diskState, .fresh,
            "the reload clears the staleness signal")
    }

    func test_switchToDirtyEditorTab_neverClobbersTheBuffer() throws {
        let model = harness.model
        let urlB = try harness.writeFile("dirty.md", "original\n")
        model.open(url: urlB)
        let bTab = model.tabs.selected!.id
        // Materialize an editor buffer + make it dirty.
        _ = model.editor.editorBuffer(forTabID: bTab)
        model.updateEditorText("my unsaved work\n", forTabID: bTab)
        model.tabs.selected.map { XCTAssertTrue($0.isDirty) }
        // Route the conflict prompt to "keep mine" (the test seam — no NSAlert).
        model.editor.externalEditPromptOverride = { _ in .keepEdits }

        let urlA = try harness.writeFile("a2.md", "# A\n")
        model.open(url: urlA)                                         // B backgrounded
        try String(repeating: "y", count: 300).write(
            to: urlB, atomically: true, encoding: .utf8)
        switchTo(bTab, model)

        XCTAssertEqual(model.editor.editorBuffers[bTab]?.text, "my unsaved work\n",
            "a dirty buffer must SURVIVE the stale-switch reload path — the "
            + "conflict prompt governs, never a silent clobber")
    }
}
