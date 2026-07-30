import XCTest
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// Audit THEME 1 sibling (fixed 2026-07-29): the CSV grid's cell-edit overlay
/// was view-local `@State` — the model saw a CLEAN tab while unsaved cell
/// edits existed, so an external file change silently reloaded over them and
/// close/quit never prompted. The grid now mirrors the serialized overlay
/// into the tab's editor buffer, inheriting the text machinery wholesale.
///
/// The mirror itself is a SwiftUI `.onChange` (view state, not host-drivable),
/// so this pins (a) the wiring in source and (b) the model-level guarantees
/// the mirror relies on.
@MainActor
final class CSVOverlayMirrorTests: HeadlessUITestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CSVMirror-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "CSVMirror-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    private func makeModel() -> DocumentModel {
        DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmpDir.appendingPathComponent("history.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults)
        )
    }

    /// What the mirror buys: once the serialized overlay is in the buffer,
    /// the tab is DIRTY — so the close-confirm gate and the watcher's
    /// conflict branch (both keyed on that state) now stand between the
    /// user's cell edits and every silent-loss path.
    func test_mirroredOverlay_makesTheTabDirty_soTheGuardsEngage() throws {
        let url = tmpDir.appendingPathComponent("t.csv")
        try Data("a,b\n1,2\n".utf8).write(to: url)
        let model = makeModel()
        model.open(url: url)
        let id = try XCTUnwrap(model.tabs.selected?.id)
        XCTAssertEqual(model.tabs.selected?.isDirty, false)

        model.updateEditorText("a,b\n1,EDITED\n", forTabID: id)   // the mirror's call

        XCTAssertEqual(model.tabs.selected?.isDirty, true,
                       "unsaved cell edits must be visible to the model")
        XCTAssertEqual(model.editor.editorBuffers[id]?.isDirty, true)

        // And the mirror's discard branch clears both.
        model.discardEditorBuffer(forTabID: id)
        XCTAssertEqual(model.tabs.selected?.isDirty, false)
    }

    /// The wiring pin: the grid must mirror overlay changes and clean up on
    /// discard, and the split pane's pseudo-id must stay excluded.
    func test_grid_mirrorsTheOverlay_inSource() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let src = try String(
            contentsOf: root.appendingPathComponent("Sources/ViewerUI/CSVTableView.swift"),
            encoding: .utf8)
        XCTAssertTrue(src.contains("editModel?.editedCells.count"),
                      "the grid must react to every overlay mutation")
        XCTAssertTrue(src.contains("model.updateEditorText(m.serialize(), forTabID: tabID)"),
                      "dirty overlay → mirrored into the editor buffer")
        XCTAssertTrue(src.contains("model.discardEditorBuffer(forTabID: tabID)"),
                      "clean overlay (Discard) → the mirror is dropped")
        XCTAssertTrue(src.contains("model.tabs.tabs.contains(where: { $0.id == tabID })"),
                      "the split pane's pseudo tab id must not grow orphan buffers")
    }
}
