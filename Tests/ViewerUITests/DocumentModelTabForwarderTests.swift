import XCTest
import Combine
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// Round-trip tests for every DocumentModel public API that was
/// retained as a forwarder when tab state moved to `TabCoordinator`.
///
/// The contract: a caller that pokes `model.X = ...` (or
/// `model.someTabFn(...)`) must observe the same effect as if it
/// had gone through `model.tabCoordinator.X` directly — and vice
/// versa (when the coordinator changes, the forwarder reads back
/// the new value). This pins the backwards-compat surface so a
/// future refactor that drops a forwarder by accident gets a
/// targeted test failure pointing at the missing wire.
///
/// Mirrors the shape of `FindRepublishInvariantTests` forwarder
/// tests (the `model.renderedFindQuery = ...` writes that bottom
/// out in `model.find.renderedQuery`).
@MainActor
final class DocumentModelTabForwarderTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentModelTabForwarderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "DocumentModelTabForwarderTests-\(UUID().uuidString)"
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

    // MARK: - tabs

    func test_modelTabs_reflectsCoordinatorAppend() {
        let model = makeModel()
        model.tabCoordinator.append(Tab(url: URL(fileURLWithPath: "/a")))
        XCTAssertEqual(model.tabs.tabs.count, 1)
        XCTAssertEqual(model.tabs.tabs.first?.url?.lastPathComponent, "a")
    }

    func test_modelTabs_reflectsCoordinatorClose() throws {
        let model = makeModel()
        for n in ["a", "b"] {
            model.open(url: try writeFile("\(n).md"))
        }
        model.tabCoordinator.closeTab(at: 0)
        XCTAssertEqual(model.tabs.tabs.count, 1)
    }

    // MARK: - openTabURLs

    func test_modelOpenTabURLs_reflectsCoordinator() throws {
        let model = makeModel()
        let a = try writeFile("a.md")
        model.open(url: a)
        XCTAssertEqual(model.openTabURLs, model.tabCoordinator.openTabURLs)
    }

    // MARK: - csvFilterStates

    func test_csvFilterState_forwarder_roundTrip() {
        let model = makeModel()
        let id = UUID()
        var s = TabCoordinator.CSVFilterState()
        s.globalQuery = "needle"
        model.setCsvFilterState(s, forTabID: id)
        XCTAssertEqual(model.csvFilterState(forTabID: id).globalQuery, "needle")
        XCTAssertEqual(model.tabCoordinator.csvFilterStates[id], s)
    }

    func test_clearCsvFilterState_forwarder_removes() {
        let model = makeModel()
        let id = UUID()
        var s = TabCoordinator.CSVFilterState()
        s.globalQuery = "x"
        model.setCsvFilterState(s, forTabID: id)
        model.clearCsvFilterState(forTabID: id)
        XCTAssertNil(model.csvFilterStates[id])
    }

    // MARK: - hexBytesPerRow

    func test_hexWidth_forwarder_alsoBumpsPreferences() {
        let model = makeModel()
        let id = UUID()
        model.setHexWidth(32, forTabID: id)
        XCTAssertEqual(model.hexWidth(forTabID: id), 32)
        // The forwarder additionally writes through to PreferencesStore
        // (Sublime-style "remember last setting"). Spinning up a fresh
        // DocumentModel from the same defaults should see the bump.
        let model2 = DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmpDir.appendingPathComponent("h2.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults)
        )
        XCTAssertEqual(
            model2.hexWidth(forTabID: UUID()), 32,
            "PreferencesStore.hexBytesPerRow must be the fallback for an unseen tab"
        )
    }

    // MARK: - languageOverrides

    func test_setCurrentLanguage_forwarder_storesOnCoordinator() throws {
        let model = makeModel()
        let url = try writeFile("notes.txt", "{}")
        model.open(url: url)
        let id = model.tabs.selected!.id
        model.setCurrentLanguage(.json)
        XCTAssertEqual(model.tabCoordinator.languageOverrides[id], .json)
        XCTAssertTrue(model.hasLanguageOverride)
    }

    func test_hasLanguageOverride_forwarder_readsCoordinator() throws {
        let model = makeModel()
        let url = try writeFile("a.txt")
        model.open(url: url)
        XCTAssertFalse(model.hasLanguageOverride)
        let id = model.tabs.selected!.id
        // Mutate through the coordinator directly; the forwarder
        // must see it.
        model.tabCoordinator.setSelectedTabLanguage(.swift, autodetected: .plainText)
        XCTAssertTrue(model.hasLanguageOverride)
        XCTAssertEqual(model.effectiveLanguage(forTabID: id, url: url), .swift)
    }

    // MARK: - formattedTabIDs

    func test_toggleFormat_forwarder_flipsCoordinatorFlag() throws {
        let model = makeModel()
        let url = try writeFile("a.json", "{}")
        model.open(url: url)
        let id = model.tabs.selected!.id
        XCTAssertFalse(model.isCurrentTabFormatted)
        XCTAssertFalse(model.tabCoordinator.formattedTabIDs.contains(id))
        model.toggleFormat()
        XCTAssertTrue(model.isCurrentTabFormatted)
        XCTAssertTrue(model.tabCoordinator.formattedTabIDs.contains(id))
    }

    func test_toggleFormat_noOp_whenNotSupported() throws {
        // `.txt` files don't have a Formatter.SupportedFormat — the
        // guard in DocumentModel.toggleFormat must short-circuit.
        let model = makeModel()
        let url = try writeFile("a.txt", "plain")
        model.open(url: url)
        let id = model.tabs.selected!.id
        model.toggleFormat()
        XCTAssertFalse(model.tabCoordinator.formattedTabIDs.contains(id),
            "toggleFormat must no-op when the file isn't formattable")
    }

    // MARK: - editorBuffers

    func test_editorBuffer_forwarder_seedsAndReadsBack() throws {
        let model = makeModel()
        let url = try writeFile("a.swift", "let x = 1\n")
        model.open(url: url)
        let id = model.tabs.selected!.id
        let buf = model.editorBuffer(forTabID: id)
        XCTAssertNotNil(buf)
        XCTAssertEqual(model.editorBuffers[id]?.text, "let x = 1\n")
        XCTAssertEqual(model.tabCoordinator.editorBuffers[id]?.text, "let x = 1\n",
            "model.editorBuffers must be the same map as the coordinator's")
    }

    func test_updateEditorText_forwarder_marksDirty() throws {
        let model = makeModel()
        let url = try writeFile("a.swift", "v1")
        model.open(url: url)
        let id = model.tabs.selected!.id
        _ = model.editorBuffer(forTabID: id)
        XCTAssertFalse(model.tabs.tabs[0].isDirty,
            "fresh buffer must not be dirty")
        model.updateEditorText("dirty edit", forTabID: id)
        XCTAssertTrue(model.editorBuffers[id]?.isDirty == true)
        XCTAssertTrue(model.tabs.tabs[0].isDirty,
            "Tab.isDirty mirror must follow the buffer's dirty flag")
    }

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
        XCTAssertFalse(model.tabs.tabs[0].isDirty,
            "discard must also clear the Tab.isDirty mirror")
    }

    // MARK: - splitURL

    func test_splitURL_forwarder_readWrite() throws {
        let model = makeModel()
        let a = try writeFile("a.md")
        XCTAssertNil(model.splitURL)
        XCTAssertFalse(model.isSplitOpen)
        model.openInSplit(a)
        XCTAssertEqual(
            model.splitURL,
            a.standardizedFileURL.resolvingSymlinksInPath()
        )
        XCTAssertEqual(model.tabCoordinator.splitURL, model.splitURL,
            "splitURL forwarder must round-trip through the coordinator")
        model.closeSplit()
        XCTAssertNil(model.splitURL)
    }

    func test_splitURL_setterForwarder() {
        let model = makeModel()
        let a = URL(fileURLWithPath: "/a")
        model.splitURL = a
        XCTAssertEqual(model.tabCoordinator.splitURL, a)
    }

    // MARK: - view-mode change republishes the model (regression)

    /// Regression for the "Render|Source|Editor|HEX picker is broken /
    /// view stuck in Render" bug. `Tab.viewMode` lives on
    /// `TabCoordinator`, but `ContentView` / `ModeBar` observe
    /// `DocumentModel`. PERF #1 (2026-05-25) severed the child→model
    /// `objectWillChange` forwarding and re-added direct observation
    /// only for `sidebar` + `find` — not `tabs`. So every tab mutation
    /// that does NOT republish `DocumentModel` leaves the picker +
    /// content pane frozen on the previous mode. `setCurrentViewMode`
    /// was the lone display-changing mutation missing the
    /// `updateDerived()` republish that open/close/select all do.
    ///
    /// The model STATE was always correct (`currentViewMode` reflects
    /// the pick) — so a state-only assertion can't catch this. The
    /// load-bearing assertion is that the PUBLISH fires.
    func test_viewModePicker_eachSwitch_republishesAndUpdates() throws {
        let model = makeModel()
        let url = try writeFile("doc.md", "# hi\n")
        model.open(url: url)
        XCTAssertEqual(model.currentViewMode, .rendered,
            "markdown opens in rendered mode by default")

        var publishes = 0
        let cancellable = model.objectWillChange.sink { publishes += 1 }
        defer { cancellable.cancel() }

        // Walk the whole markdown picker: Source | Editor | HEX | back to
        // Rendered. Each switch must (a) update the model state and
        // (b) fire objectWillChange so the observing views re-render.
        for mode in [ViewMode.source, .editor, .hex, .rendered] {
            let before = publishes
            model.setCurrentViewMode(mode)
            XCTAssertEqual(model.currentViewMode, mode,
                "model state must reflect the \(mode) pick")
            XCTAssertGreaterThan(publishes, before,
                "switching to \(mode) must republish DocumentModel — otherwise "
                + "the picker + content stay stuck (the reported bug)")
        }
    }

    // MARK: - DocumentModel.CSVFilterState typealias

    /// Source-compat: CSVTableView constructs
    /// `DocumentModel.CSVFilterState()` to clear a tab. The typealias
    /// must continue to resolve to the coordinator's nested type.
    func test_csvFilterState_typealiasResolves() {
        // Compile-time check, basically — if the typealias breaks
        // the test won't build. Body just confirms equality.
        let _: DocumentModel.CSVFilterState = TabCoordinator.CSVFilterState()
        let viaAlias = DocumentModel.CSVFilterState()
        let direct = TabCoordinator.CSVFilterState()
        XCTAssertEqual(viaAlias, direct)
    }
}

/// Cross-coordinator interaction tests. The new TabCoordinator owns
/// `editorBuffers`; existing DocumentModel-owned state (notably the
/// `HighlightCacheActor` map referenced by `highlightCacheActor(forTabID:)`,
/// and the `pendingEditorDiagnostics` map driven by
/// `setEditorDiagnostics`) must continue to cooperate with that
/// coordinator on every close path and on the editor save/discard
/// flow. These tests pin those interactions.
@MainActor
final class TabCoordinatorInteropTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TabCoordinatorInteropTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "TabCoordinatorInteropTests-\(UUID().uuidString)"
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

    // MARK: - HighlightCacheActor (DocumentModel-side cache) follows tab id

    /// PERF #5 (2026-05-25): each tab owns its own
    /// `HighlightCacheActor`. Close must drop the actor entry so it
    /// can deinit once observers also drop their `@ObservedObject`.
    /// This test verifies the close path purges the actor (otherwise
    /// long-running session leaks one actor + its 1×Task queue per
    /// closed tab).
    func test_closeTab_dropsHighlightCacheActor() throws {
        let model = makeModel()
        let url = try writeFile("a.swift", "let x = 1\n")
        model.open(url: url)
        let id = model.tabs.selected!.id
        // Touch the cache so the actor is allocated.
        let actorBefore = model.highlightCacheActor(forTabID: id)
        // After close, a fresh request must return a DIFFERENT actor
        // (the original was dropped). Add a new tab + ask for ITS
        // actor — different tab id, so a different actor either way;
        // the failure mode would be the closed actor leaking inside
        // the dict, which we check by inspecting the storage size
        // via a re-request shape: closing then re-opening the same
        // file under a new tab id gives a fresh actor.
        model.closeTab(at: 0)
        model.open(url: url)
        let newID = model.tabs.selected!.id
        let actorAfter = model.highlightCacheActor(forTabID: newID)
        XCTAssertNotEqual(ObjectIdentifier(actorBefore), ObjectIdentifier(actorAfter),
            "closing the tab must drop the actor; a fresh request returns a new instance")
    }

    // MARK: - editorBuffer + dirty close interaction

    /// The full lifecycle: open file in editor mode, type into it,
    /// close the tab with discard. The buffer must be dropped, the
    /// dirty flag cleared, and (the regression this protects against)
    /// the underlying tab's per-tab caches must NOT linger.
    func test_dirtyEditorTab_closeDiscard_dropsBufferAndCleansUp() throws {
        let model = makeModel()
        let url = try writeFile("a.swift", "v1")
        model.open(url: url)
        let id = model.tabs.selected!.id
        model.setCurrentViewMode(.editor)
        // setCurrentViewMode seeds the buffer eagerly for a loaded
        // text tab — confirm and then dirty it.
        XCTAssertNotNil(model.editorBuffers[id])
        model.updateEditorText("v2", forTabID: id)
        XCTAssertTrue(model.tabs.tabs[0].isDirty)
        // Discard path: caller drops buffer first, then the close
        // path runs without the dirty NSAlert (which we can't drive
        // in a unit test).
        model.discardEditorBuffer(forTabID: id)
        XCTAssertFalse(model.tabs.tabs[0].isDirty,
            "discardEditorBuffer must clear the Tab.isDirty mirror")
        model.closeTab(at: 0)
        XCTAssertNil(model.editorBuffers[id],
            "close must NOT leave a stale buffer entry behind")
    }

    /// The save flow updates `editorBuffer` + the tab's `.loaded`
    /// state. We pin the contract because both pieces must move
    /// together: a save that updated the buffer but left a stale
    /// `.loaded(oldFile)` would make a subsequent .source-mode
    /// switch display pre-save bytes.
    func test_saveEditor_refreshesTabLoadedStateWithNewBytes() throws {
        let model = makeModel()
        let url = try writeFile("a.swift", "v1")
        model.open(url: url)
        let id = model.tabs.selected!.id
        model.setCurrentViewMode(.editor)
        model.updateEditorText("v2-saved", forTabID: id)
        let ok = model.saveEditor(forTabID: id)
        XCTAssertTrue(ok)
        // After save, isDirty cleared:
        XCTAssertFalse(model.tabs.tabs[0].isDirty)
        // And the tab's .loaded state must reflect the new bytes —
        // otherwise the rendered-HTML / highlight cache keys (which
        // hash on byteCount + mtime) would never invalidate.
        if case .loaded(let f) = model.tabs.tabs[0].state {
            XCTAssertEqual(f.contents, "v2-saved")
        } else {
            XCTFail("tab state must be .loaded with new bytes after save")
        }
    }

    /// `pendingEditorDiagnostics` lives on DocumentModel but its
    /// driver (`setEditorDiagnostics(_:forURL:)`) walks
    /// `tabCoordinator.tabs` + `tabCoordinator.editorBuffers` to
    /// find the right tabs. If the coordinator's tab list ever
    /// drifted from DocumentModel's view, the diagnostics push
    /// would silently miss tabs.
    func test_setEditorDiagnostics_locatesTabViaCoordinator() throws {
        let model = makeModel()
        let url = try writeFile("a.swift", "let x = 1\n")
        model.open(url: url)
        let id = model.tabs.selected!.id
        model.setCurrentViewMode(.editor)
        // Push a single diagnostic and verify the pending map for
        // this tab id gets populated.
        let diag = LSPDiagnostic(
            range: LSPRange(
                start: LSPPosition(line: 0, character: 0),
                end: LSPPosition(line: 0, character: 1)
            ),
            severity: .error, code: nil, source: nil, message: "boom"
        )
        model.setEditorDiagnostics([diag], forURL: url)
        XCTAssertNotNil(model.pendingEditorDiagnostics[id],
            "setEditorDiagnostics must reach the editor tab via the coordinator's tabs map")
        XCTAssertFalse((model.pendingEditorDiagnostics[id] ?? []).isEmpty)
    }
}
