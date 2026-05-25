import XCTest
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// Round-trip tests for every DocumentModel public API that was
/// retained as a forwarder when editor state moved to
/// `EditorCoordinator` (Quality #2, 2026-05-25).
///
/// Contract: a caller that pokes `model.editorGotoLine = ...` (or
/// `model.recordEditorCursor(_:forTabID:)`, etc.) must observe the
/// same effect as if they'd gone through `model.editor.X` directly —
/// and vice versa. Pins the backwards-compat surface so a future
/// refactor that drops a forwarder gets a targeted test failure.
///
/// Mirrors `DocumentModelTabForwarderTests`.
@MainActor
final class DocumentModelEditorForwarderTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentModelEditorForwarderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "DocumentModelEditorForwarderTests-\(UUID().uuidString)"
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
    private func writeFile(_ name: String, _ contents: String = "x") throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - editorGotoLine

    func test_editorGotoLine_setter_writesToEditor() {
        let model = makeModel()
        let req = CMGotoLineRequest(line: 42)
        model.editorGotoLine = req
        XCTAssertEqual(model.editor.editorGotoLine, req,
            "model.editorGotoLine setter must write through to editor coordinator")
    }

    func test_editorGotoLine_setOnCoordinator_readsBackThroughForwarder() {
        let model = makeModel()
        let req = CMGotoLineRequest(line: 7, select: true)
        model.editor.editorGotoLine = req
        XCTAssertEqual(model.editorGotoLine, req,
            "forwarder must read live value from coordinator")
    }

    // MARK: - editorIndentation

    func test_editorIndentation_forwarder_roundTrip() {
        let model = makeModel()
        XCTAssertEqual(model.editorIndentation, .spaces(2),
            "default indentation matches CM6 bundle's applySetIndentation default")
        model.editorIndentation = .tabs(width: 4)
        XCTAssertEqual(model.editor.editorIndentation, .tabs(width: 4))
        model.editor.editorIndentation = .spaces(8)
        XCTAssertEqual(model.editorIndentation, .spaces(8))
    }

    // MARK: - saveEditorOnBlur

    func test_saveEditorOnBlur_forwarder_roundTrip() {
        let model = makeModel()
        XCTAssertFalse(model.saveEditorOnBlur)
        model.saveEditorOnBlur = true
        XCTAssertTrue(model.editor.saveEditorOnBlur)
        model.editor.saveEditorOnBlur = false
        XCTAssertFalse(model.saveEditorOnBlur)
    }

    // MARK: - editorCursorByTab / editorScrollByTab

    func test_recordEditorCursor_forwarder_storesAndMirrors() throws {
        let model = makeModel()
        let url = try writeFile("a.swift", "let x = 1\n")
        model.open(url: url)
        let id = model.tabs.selected!.id
        let pos = CMCursorPosition(line: 9, column: 3, head: 80, rangeCount: 1)
        model.recordEditorCursor(pos, forTabID: id)
        XCTAssertEqual(model.editorCursorByTab[id]?.line, 9,
            "forwarder must populate coordinator's per-tab cursor dict")
        XCTAssertEqual(model.editor.editorCursorByTab[id]?.line, 9)
        // The DocumentModel-side cursor-mirror hook also pushes onto
        // `sourceSelection` so the status bar L:C readout works in
        // editor mode without a separate channel.
        XCTAssertEqual(model.sourceSelection.line, 9,
            "cursor mirror must populate sourceSelection for status bar L:C")
        XCTAssertEqual(model.sourceSelection.column, 3)
    }

    func test_recordEditorScroll_forwarder_stores() throws {
        let model = makeModel()
        let url = try writeFile("a.swift", "let x = 1\n")
        model.open(url: url)
        let id = model.tabs.selected!.id
        let pos = CMScrollPosition(top: 200, left: 0,
                                   viewportFromLine: 1, viewportToLine: 25)
        model.recordEditorScroll(pos, forTabID: id)
        XCTAssertEqual(model.editorScrollByTab[id]?.top, 200)
        XCTAssertEqual(model.editor.editorScrollByTab[id]?.top, 200)
    }

    func test_editorCursorByTab_getter_readsCoordinator() throws {
        let model = makeModel()
        let id = UUID()
        let pos = CMCursorPosition(line: 1, column: 0, head: 0, rangeCount: 1)
        // Mutate via coordinator directly; the forwarder must reflect it.
        model.editor.recordEditorCursor(pos, forTabID: id)
        XCTAssertEqual(model.editorCursorByTab[id]?.line, 1)
    }

    // MARK: - pendingEditorDiagnostics + setEditorDiagnostics

    func test_pendingEditorDiagnostics_forwarder_readsCoordinator() {
        let model = makeModel()
        let id = UUID()
        let diag = CMDiagnostic(
            from: 0, to: 1, severity: .error, message: "x", source: nil
        )
        model.editor.pendingEditorDiagnostics[id] = [diag]
        XCTAssertEqual(model.pendingEditorDiagnostics[id]?.count, 1)
    }

    func test_setEditorDiagnostics_forwarder_routesThroughCoordinator() throws {
        let model = makeModel()
        let url = try writeFile("a.swift", "let x = 1\n")
        model.open(url: url)
        let id = model.tabs.selected!.id
        // Materialize buffer so position translation has a doc.
        _ = model.editorBuffer(forTabID: id)
        let lspDiag = LSPDiagnostic(
            range: LSPRange(
                start: LSPPosition(line: 0, character: 0),
                end: LSPPosition(line: 0, character: 1)
            ),
            severity: .error, code: nil, source: nil, message: "boom"
        )
        // Call via the forwarder.
        model.setEditorDiagnostics([lspDiag], forURL: url)
        XCTAssertNotNil(model.editor.pendingEditorDiagnostics[id],
            "forwarder must reach the coordinator's pending map")
        XCTAssertFalse((model.editor.pendingEditorDiagnostics[id] ?? []).isEmpty)
    }

    func test_consumePendingEditorDiagnostics_forwarder_clearsCoordinator() {
        let model = makeModel()
        let id = UUID()
        let diag = CMDiagnostic(
            from: 0, to: 1, severity: .error, message: "x", source: nil
        )
        model.editor.pendingEditorDiagnostics[id] = [diag]
        model.consumePendingEditorDiagnostics(forTabID: id)
        XCTAssertNil(model.editor.pendingEditorDiagnostics[id])
    }

    // MARK: - editorBuffers / editorBuffer / ensureEditorBuffer / updateEditorText

    func test_editorBuffers_forwarder_readsTabCoordinator() throws {
        let model = makeModel()
        let url = try writeFile("a.swift", "v1")
        model.open(url: url)
        let id = model.tabs.selected!.id
        _ = model.editorBuffer(forTabID: id)
        XCTAssertNotNil(model.editorBuffers[id])
        // Editor-coordinator forwarder must surface the same dict.
        XCTAssertEqual(model.editor.editorBuffers[id]?.text,
                       model.editorBuffers[id]?.text)
    }

    func test_updateEditorText_forwarder_marksDirty() throws {
        let model = makeModel()
        let url = try writeFile("a.swift", "v1")
        model.open(url: url)
        let id = model.tabs.selected!.id
        _ = model.editorBuffer(forTabID: id)
        XCTAssertFalse(model.tabs.tabs[0].isDirty)
        // Call through DocumentModel forwarder.
        model.updateEditorText("dirty", forTabID: id)
        XCTAssertTrue(model.tabs.tabs[0].isDirty)
        XCTAssertTrue(model.editor.editorBuffers[id]?.isDirty == true)
    }

    // MARK: - DirtyClosePrompt typealias

    func test_dirtyClosePrompt_typealias_resolves() {
        // Source-compat: app delegate switches on
        // `DocumentModel.DirtyClosePrompt`. The typealias must continue
        // to resolve to EditorCoordinator's nested enum.
        let _: DocumentModel.DirtyClosePrompt = .save
        let viaAlias = DocumentModel.DirtyClosePrompt.discard
        let direct = EditorCoordinator.DirtyClosePrompt.discard
        XCTAssertEqual(viaAlias, direct)
    }

    // MARK: - confirmCloseIfDirty forwarder

    func test_confirmCloseIfDirty_forwarder_returnsNilForCleanTab() throws {
        let model = makeModel()
        let url = try writeFile("a.swift", "v1")
        model.open(url: url)
        XCTAssertNil(model.confirmCloseIfDirty(at: 0),
            "clean tab via DocumentModel forwarder must short-circuit")
    }

    func test_confirmCloseIfDirty_forwarder_runsOverride() throws {
        let model = makeModel()
        let url = try writeFile("a.swift", "v1")
        model.open(url: url)
        let id = model.tabs.selected!.id
        _ = model.editorBuffer(forTabID: id)
        model.updateEditorText("dirty", forTabID: id)
        model.editor.dirtyClosePromptOverride = { _ in .save }
        XCTAssertEqual(model.confirmCloseIfDirty(at: 0), .save)
    }

    // MARK: - hasAnyUnsavedEdits forwarder

    func test_hasAnyUnsavedEdits_forwarder_followsCoordinator() throws {
        let model = makeModel()
        let url = try writeFile("a.swift", "v1")
        model.open(url: url)
        let id = model.tabs.selected!.id
        XCTAssertFalse(model.hasAnyUnsavedEdits)
        XCTAssertEqual(model.hasAnyUnsavedEdits, model.editor.hasAnyUnsavedEdits)
        _ = model.editorBuffer(forTabID: id)
        model.updateEditorText("dirty", forTabID: id)
        XCTAssertTrue(model.hasAnyUnsavedEdits)
        XCTAssertTrue(model.editor.hasAnyUnsavedEdits)
    }

    // MARK: - saveActiveEditor / saveEditor forwarders

    func test_saveActiveEditor_forwarder_writesActiveTab() throws {
        let model = makeModel()
        let url = try writeFile("a.txt", "before")
        model.open(url: url)
        let id = model.tabs.selected!.id
        _ = model.editorBuffer(forTabID: id)
        model.updateEditorText("after", forTabID: id)
        XCTAssertTrue(model.saveActiveEditor())
        XCTAssertEqual(try? String(contentsOf: url, encoding: .utf8), "after")
        XCTAssertFalse(model.tabs.tabs[0].isDirty)
    }

    func test_saveEditor_forwarder_writesSpecificTab() throws {
        let model = makeModel()
        let url = try writeFile("a.txt", "before")
        model.open(url: url)
        let id = model.tabs.selected!.id
        _ = model.editorBuffer(forTabID: id)
        model.updateEditorText("specific", forTabID: id)
        XCTAssertTrue(model.saveEditor(forTabID: id))
        XCTAssertEqual(try? String(contentsOf: url, encoding: .utf8), "specific")
    }

    // MARK: - discardEditorBuffer forwarder

    func test_discardEditorBuffer_forwarder_dropsAndClearsDirty() throws {
        let model = makeModel()
        let url = try writeFile("a.swift", "v1")
        model.open(url: url)
        let id = model.tabs.selected!.id
        _ = model.editorBuffer(forTabID: id)
        model.updateEditorText("dirty", forTabID: id)
        XCTAssertTrue(model.tabs.tabs[0].isDirty)
        model.discardEditorBuffer(forTabID: id)
        XCTAssertNil(model.editorBuffers[id])
        XCTAssertFalse(model.tabs.tabs[0].isDirty)
    }

    // MARK: - ensureEditorBuffer forwarder

    func test_ensureEditorBuffer_forwarder_seedsViaTabCoordinator() throws {
        let model = makeModel()
        let url = try writeFile("a.swift", "let x = 1\n")
        model.open(url: url)
        let id = model.tabs.selected!.id
        if case .loaded(let file) = model.currentState {
            model.ensureEditorBuffer(for: file, tabID: id)
            XCTAssertNotNil(model.editorBuffers[id])
        } else {
            XCTFail("tab should be .loaded after open()")
        }
    }
}
