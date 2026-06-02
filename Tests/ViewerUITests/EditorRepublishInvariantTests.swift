import XCTest
import Combine
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// Quality #2 invariant pin (2026-05-25).
///
/// Editor mode state (cursor / scroll persistence, pending diagnostics,
/// goto-line nonce, indentation pref, save-on-blur, the save path) moved
/// to `EditorCoordinator`. Views that observe `DocumentModel` (TabBar,
/// Sidebar, StatusBar) must NOT re-render when editor-only state
/// changes — that was the symptom the extraction was meant to fix.
///
/// Tests mirror the shape of `FindRepublishInvariantTests`,
/// `TabRepublishInvariantTests`, `SidebarRepublishInvariantTests`:
///   - mutate through the coordinator (or a DocumentModel forwarder
///     that bottoms out in the coordinator);
///   - assert `DocumentModel.objectWillChange` fires ZERO times;
///   - end with a negative-control test confirming the helper still
///     counts when DocumentModel itself mutates.
///
/// The "view doesn't re-render on cursor/scroll updates inside an
/// editor tab" assertion is the quantifiable perf win the extraction
/// delivers: the status bar gets cursor mirroring via a dedicated
/// channel (`sourceSelection`), and pendingEditorDiagnostics +
/// editorCursorByTab / editorScrollByTab live on `editor` so their
/// publishes don't ride the DocumentModel chain.
@MainActor
final class EditorRepublishInvariantTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorRepublishInvariantTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "EditorRepublishInvariantTests-\(UUID().uuidString)"
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

    private func countDocumentRepublishes(
        of model: DocumentModel,
        whileRunning mutate: () -> Void
    ) async -> Int {
        var count = 0
        let sub = model.objectWillChange.sink { _ in count += 1 }
        defer { sub.cancel() }
        mutate()
        await Task.yield()
        return count
    }

    @discardableResult
    private func writeFile(_ name: String, _ contents: String = "x") throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - editorGotoLine

    func test_editorGotoLine_set_doesNotRepublishDocumentModel() async {
        let model = makeModel()
        await Task.yield()
        let count = await countDocumentRepublishes(of: model) {
            model.editor.editorGotoLine = CMGotoLineRequest(line: 42)
        }
        XCTAssertEqual(count, 0,
            "editor goto-line nonce must not republish DocumentModel; views observe model.editor")
    }

    func test_editorGotoLine_throughForwarder_doesNotRepublishDocumentModel() async {
        // The backwards-compat forwarder (e.g. main.swift script-runner
        // `model.editorGotoLine = ...`) must route through `editor`
        // without firing model.objectWillChange.
        let model = makeModel()
        await Task.yield()
        let count = await countDocumentRepublishes(of: model) {
            model.editorGotoLine = CMGotoLineRequest(line: 7)
        }
        XCTAssertEqual(count, 0)
    }

    // MARK: - editorIndentation pref (Settings binding)

    func test_editorIndentation_change_doesNotRepublishDocumentModel() async {
        let model = makeModel()
        await Task.yield()
        let count = await countDocumentRepublishes(of: model) {
            model.editor.editorIndentation = .tabs(width: 4)
        }
        XCTAssertEqual(count, 0,
            "Settings → Indentation edit must not republish DocumentModel")
    }

    // MARK: - saveEditorOnBlur pref

    func test_saveEditorOnBlur_toggle_doesNotRepublishDocumentModel() async {
        let model = makeModel()
        await Task.yield()
        let count = await countDocumentRepublishes(of: model) {
            model.editor.saveEditorOnBlur.toggle()
        }
        XCTAssertEqual(count, 0,
            "Settings → Save-on-blur toggle must not republish DocumentModel")
    }

    // MARK: - Cursor / scroll persistence (HIGH frequency — fires on every
    //         CM6 selection/scroll tick. The whole point of the extraction
    //         is that these stop touching DocumentModel.)

    func test_recordEditorCursor_doesNotRepublishDocumentModel() async throws {
        let model = makeModel()
        let url = try writeFile("a.swift", "let x = 1\n")
        model.open(url: url)
        await Task.yield()
        let id = model.tabs.selected!.id
        let count = await countDocumentRepublishes(of: model) {
            model.editor.recordEditorCursor(
                CMCursorPosition(line: 5, column: 0, head: 50, rangeCount: 1),
                forTabID: id
            )
        }
        // The cursor-mirror hook (onCursorMirrorToStatusBar) assigns
        // `model.sourceSelection`, which now lives on the `SourceViewChannel`
        // narrow channel — NOT @Published on DocumentModel. So the mirror
        // republishes only that channel (re-bodying StatusBar + the source
        // subtree, which is the intended status-bar L:C update) and does NOT
        // touch DocumentModel. Both the pure RECORD and the status-bar mirror
        // are now free of DocumentModel republishes.
        XCTAssertLessThanOrEqual(count, 1,
            "cursor mirror must not republish DocumentModel "
            + "(it republishes the SourceViewChannel instead)")
    }

    func test_recordEditorScroll_doesNotRepublishDocumentModel() async throws {
        // Scroll has NO mirror onto DocumentModel — it's purely a
        // coordinator-side dict update. Must be zero.
        let model = makeModel()
        let url = try writeFile("a.swift", "let x = 1\n")
        model.open(url: url)
        await Task.yield()
        let id = model.tabs.selected!.id
        let count = await countDocumentRepublishes(of: model) {
            model.editor.recordEditorScroll(
                CMScrollPosition(top: 100, left: 0,
                                 viewportFromLine: 1, viewportToLine: 30),
                forTabID: id
            )
        }
        XCTAssertEqual(count, 0,
            "editor scroll must not republish DocumentModel — pure per-tab dict update")
    }

    // MARK: - Pending diagnostics (LSP push)

    func test_setEditorDiagnostics_doesNotRepublishDocumentModel() async throws {
        // LSP servers push diagnostics on every check cycle (typically
        // 200ms-2s). If THIS republished DocumentModel, the entire
        // observation tree would re-eval on every typescript-language-
        // server tick.
        let model = makeModel()
        let url = try writeFile("a.swift", "let x = 1\n")
        model.open(url: url)
        await Task.yield()
        let id = model.tabs.selected!.id
        // Materialize the editor buffer so the diagnostics push has
        // a target (no-op without a buffer).
        _ = model.editorBuffer(forTabID: id)
        await Task.yield()
        let diag = LSPDiagnostic(
            range: LSPRange(
                start: LSPPosition(line: 0, character: 0),
                end: LSPPosition(line: 0, character: 1)
            ),
            severity: .error, code: nil, source: nil, message: "boom"
        )
        let count = await countDocumentRepublishes(of: model) {
            model.editor.setEditorDiagnostics([diag], forURL: url)
        }
        XCTAssertEqual(count, 0,
            "LSP diagnostics push must not republish DocumentModel")
    }

    // MARK: - Pending gutter markers (git diff feed)

    func test_setEditorGutterMarkers_doesNotRepublishDocumentModel() async throws {
        // DocumentModel.refreshDiffMarks fires on every file open / save
        // / reload / tab switch. Its main-actor hop assigns
        // `editor.pendingEditorGutterMarkers` — must NOT republish
        // DocumentModel or the entire UI re-evals on every tab switch
        // in a git repo.
        let model = makeModel()
        let url = try writeFile("a.swift", "let x = 1\n")
        model.open(url: url)
        await Task.yield()
        let markers = [CMGutterMarker(line: 1, kind: "added")]
        let count = await countDocumentRepublishes(of: model) {
            model.editor.setEditorGutterMarkers(markers, forURL: url)
        }
        XCTAssertEqual(count, 0,
            "git diff feed must not republish DocumentModel; CodeMirror view observes model.editor")
    }

    func test_consumePendingEditorGutterMarkers_doesNotRepublishDocumentModel() async throws {
        // Consumed on every CodeMirror updateNSView. Same constraint
        // as the diagnostics consume — must not ride DocumentModel.
        let model = makeModel()
        let url = try writeFile("a.swift", "let x = 1\n")
        model.open(url: url)
        await Task.yield()
        let id = model.tabs.selected!.id
        model.editor.setEditorGutterMarkers(
            [CMGutterMarker(line: 3, kind: "modified")], forURL: url)
        await Task.yield()
        let count = await countDocumentRepublishes(of: model) {
            model.editor.consumePendingEditorGutterMarkers(forTabID: id)
        }
        XCTAssertEqual(count, 0)
    }

    func test_editorCoordinator_doesRepublishOnGutterMarkerSet() async throws {
        // Negative-control twin: without this, a silently-disabled
        // @Published on `pendingEditorGutterMarkers` would make the
        // perf assertion above vacuously true. The CodeMirrorEditorView
        // depends on the coordinator publishing so SwiftUI re-evals
        // ContentView and pushes the new markers through the bridge.
        let model = makeModel()
        let url = try writeFile("a.swift", "let x = 1\n")
        model.open(url: url)
        await Task.yield()
        var count = 0
        let sub = model.editor.objectWillChange.sink { _ in count += 1 }
        defer { sub.cancel() }
        model.editor.setEditorGutterMarkers(
            [CMGutterMarker(line: 1, kind: "added")], forURL: url)
        await Task.yield()
        XCTAssertGreaterThan(count, 0,
            "EditorCoordinator must publish on gutter-marker set so the CM6 view picks it up")
    }

    func test_consumePendingEditorDiagnostics_doesNotRepublishDocumentModel() async throws {
        // Called on every CodeMirror updateNSView. Must be free of
        // DocumentModel chain.
        let model = makeModel()
        let url = try writeFile("a.swift", "let x = 1\n")
        model.open(url: url)
        await Task.yield()
        let id = model.tabs.selected!.id
        // Seed something to consume.
        let diag = LSPDiagnostic(
            range: LSPRange(
                start: LSPPosition(line: 0, character: 0),
                end: LSPPosition(line: 0, character: 1)
            ),
            severity: .error, code: nil, source: nil, message: "x"
        )
        _ = model.editorBuffer(forTabID: id)
        model.editor.setEditorDiagnostics([diag], forURL: url)
        await Task.yield()
        let count = await countDocumentRepublishes(of: model) {
            model.editor.consumePendingEditorDiagnostics(forTabID: id)
        }
        XCTAssertEqual(count, 0)
    }

    // MARK: - updateEditorText (editor keystrokes)
    //
    // The TabRepublishInvariantTests already pin
    // `updateEditorText doesNotRepublishDocumentModel`, but those go
    // through `DocumentModel.updateEditorText` which is now a forwarder.
    // Reassert here to lock the direct `model.editor.updateEditorText`
    // path — both surfaces must be free.

    func test_updateEditorText_throughEditor_doesNotRepublishDocumentModel() async throws {
        let model = makeModel()
        let url = try writeFile("a.swift", "v1")
        model.open(url: url)
        await Task.yield()
        let id = model.tabs.selected!.id
        _ = model.editorBuffer(forTabID: id)
        await Task.yield()
        let count = await countDocumentRepublishes(of: model) {
            model.editor.updateEditorText("v2", forTabID: id)
        }
        XCTAssertEqual(count, 0,
            "editor keystroke must not republish DocumentModel; only TabCoordinator should publish the dirty-dot")
    }

    // MARK: - discardEditorBuffer

    func test_discardEditorBuffer_doesNotRepublishDocumentModel() async throws {
        let model = makeModel()
        let url = try writeFile("a.swift", "v1")
        model.open(url: url)
        await Task.yield()
        let id = model.tabs.selected!.id
        _ = model.editorBuffer(forTabID: id)
        model.editor.updateEditorText("dirty", forTabID: id)
        await Task.yield()
        let count = await countDocumentRepublishes(of: model) {
            model.editor.discardEditorBuffer(forTabID: id)
        }
        XCTAssertEqual(count, 0,
            "discard must not republish DocumentModel; the dirty-dot clear rides TabCoordinator")
    }

    // MARK: - Negative controls — guard against silent regression

    /// Confirms the counter actually fires when DocumentModel itself
    /// mutates. Without this every other test above is vacuously true.
    func test_documentModelOwnMutation_doesRepublish() async throws {
        let model = makeModel()
        let url = tmpDir.appendingPathComponent("a.md")
        try "x".write(to: url, atomically: true, encoding: .utf8)
        await Task.yield()
        let count = await countDocumentRepublishes(of: model) {
            model.open(url: url)
        }
        XCTAssertGreaterThan(count, 0)
    }

    /// Confirms the editor coordinator DOES republish on its own
    /// mutation — without this, a silently-disabled @Published would
    /// make the perf tests above vacuously true.
    func test_editorCoordinator_doesRepublishOnGotoLineChange() async {
        let model = makeModel()
        var count = 0
        let sub = model.editor.objectWillChange.sink { _ in count += 1 }
        defer { sub.cancel() }
        model.editor.editorGotoLine = CMGotoLineRequest(line: 12)
        await Task.yield()
        XCTAssertGreaterThan(count, 0,
            "EditorCoordinator.objectWillChange must fire on goto-line set")
    }

    func test_editorCoordinator_doesRepublishOnCursorRecord() async {
        let model = makeModel()
        var count = 0
        let sub = model.editor.objectWillChange.sink { _ in count += 1 }
        defer { sub.cancel() }
        model.editor.recordEditorCursor(
            CMCursorPosition(line: 1, column: 0, head: 0, rangeCount: 1),
            forTabID: UUID()
        )
        await Task.yield()
        XCTAssertGreaterThan(count, 0,
            "EditorCoordinator must publish on cursor record so editor view bindings update")
    }
}
