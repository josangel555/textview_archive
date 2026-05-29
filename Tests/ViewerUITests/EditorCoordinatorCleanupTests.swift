import XCTest
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// Per-tab dict cleanup invariants for the EditorCoordinator dicts
/// across every close path (Quality #2, 2026-05-25).
///
/// The pre-extraction failure mode this prevents:
///   - `editorCursorByTab`, `editorScrollByTab`, `pendingEditorDiagnostics`
///     lived as plain @Published dicts on `DocumentModel`. None of the
///     three close paths (`closeTab`, `closeOtherTabs`, `closeTabsToRight`)
///     pruned them. Cursors and scroll positions for closed tabs leaked
///     until the DocumentModel itself was deallocated (i.e., process
///     exit for the single-window case). LSP-pushed diagnostics for a
///     closed tab persisted on the pending map.
///
/// The fix is the `TabCoordinator.addCloseHook(_:)` callback the
/// EditorCoordinator registers in its init — every close path now
/// drains these three dicts in lock-step with TabCoordinator's six
/// built-in drains.
///
/// Each matrix row = (close path × one editor-owned dict). Failures
/// name the specific dict + path combo.
@MainActor
final class EditorCoordinatorCleanupTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorCoordinatorCleanupTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "EditorCoordinatorCleanupTests-\(UUID().uuidString)"
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

    /// Seed three tabs with all three editor-owned dicts populated for
    /// the MIDDLE tab. Each matrix test runs a different close path and
    /// asserts the middle tab's entries are gone.
    private func seedThreeTabs() throws -> (model: DocumentModel,
                                            ids: (UUID, UUID, UUID)) {
        let model = makeModel()
        let a = try writeFile("a.swift", "let a = 1\n")
        let b = try writeFile("b.swift", "let b = 1\n")
        let c = try writeFile("c.swift", "let c = 1\n")
        model.open(url: a)
        model.open(url: b)
        model.open(url: c)
        let ids = (model.tabs.tabs[0].id,
                   model.tabs.tabs[1].id,
                   model.tabs.tabs[2].id)
        // Seed every editor-owned dict for the middle tab.
        model.recordEditorCursor(
            CMCursorPosition(line: 1, column: 0, head: 0, rangeCount: 1),
            forTabID: ids.1
        )
        model.recordEditorScroll(
            CMScrollPosition(top: 100, left: 0,
                             viewportFromLine: 1, viewportToLine: 25),
            forTabID: ids.1
        )
        model.editor.pendingEditorDiagnostics[ids.1] = [
            CMDiagnostic(from: 0, to: 1, severity: .error,
                         message: "boom", source: nil)
        ]
        model.editor.pendingEditorGutterMarkers[ids.1] = [
            CMGutterMarker(line: 1, kind: "added")
        ]
        // Verify seeds populated.
        XCTAssertNotNil(model.editor.editorCursorByTab[ids.1])
        XCTAssertNotNil(model.editor.editorScrollByTab[ids.1])
        XCTAssertNotNil(model.editor.pendingEditorDiagnostics[ids.1])
        XCTAssertNotNil(model.editor.pendingEditorGutterMarkers[ids.1])
        return (model, ids)
    }

    /// Assert all four editor-owned dicts are empty for `id`.
    /// Asserts spelled out so a failure names the leaking dict.
    private func assertAllEditorDictsEmpty(
        _ model: DocumentModel, forTabID id: UUID,
        line: UInt = #line
    ) {
        XCTAssertNil(model.editor.editorCursorByTab[id],
            "editorCursorByTab leaked for closed tab", line: line)
        XCTAssertNil(model.editor.editorScrollByTab[id],
            "editorScrollByTab leaked for closed tab", line: line)
        XCTAssertNil(model.editor.pendingEditorDiagnostics[id],
            "pendingEditorDiagnostics leaked for closed tab", line: line)
        XCTAssertNil(model.editor.pendingEditorGutterMarkers[id],
            "pendingEditorGutterMarkers leaked for closed tab", line: line)
    }

    // MARK: - closeTab(at:)

    func test_closeTab_drains_allEditorDicts() throws {
        let (model, ids) = try seedThreeTabs()
        model.closeTab(at: 1)
        assertAllEditorDictsEmpty(model, forTabID: ids.1)
    }

    // MARK: - closeOtherTabs(keeping:)

    func test_closeOtherTabs_drains_editorDictsForNonKept() throws {
        let (model, ids) = try seedThreeTabs()
        // Populate tab 2 as well so we can assert it's drained too.
        model.recordEditorCursor(
            CMCursorPosition(line: 9, column: 0, head: 0, rangeCount: 1),
            forTabID: ids.2
        )
        model.recordEditorScroll(
            CMScrollPosition(top: 200, left: 0,
                             viewportFromLine: 5, viewportToLine: 30),
            forTabID: ids.2
        )
        model.editor.pendingEditorDiagnostics[ids.2] = [
            CMDiagnostic(from: 0, to: 1, severity: .warning,
                         message: "x", source: nil)
        ]
        model.editor.pendingEditorGutterMarkers[ids.2] = [
            CMGutterMarker(line: 7, kind: "modified")
        ]
        model.closeOtherTabs(keeping: 0)
        assertAllEditorDictsEmpty(model, forTabID: ids.1)
        assertAllEditorDictsEmpty(model, forTabID: ids.2)
    }

    // MARK: - closeTabsToRight(of:)

    func test_closeTabsToRight_drains_editorDictsForRightTail() throws {
        let (model, ids) = try seedThreeTabs()
        // Add seed to tab 2 (right of the pivot we'll close from).
        model.recordEditorCursor(
            CMCursorPosition(line: 4, column: 2, head: 30, rangeCount: 1),
            forTabID: ids.2
        )
        model.recordEditorScroll(
            CMScrollPosition(top: 50, left: 0,
                             viewportFromLine: 1, viewportToLine: 20),
            forTabID: ids.2
        )
        model.editor.pendingEditorDiagnostics[ids.2] = [
            CMDiagnostic(from: 0, to: 1, severity: .info,
                         message: "x", source: nil)
        ]
        model.editor.pendingEditorGutterMarkers[ids.2] = [
            CMGutterMarker(line: 12, kind: "removed")
        ]
        // Pivot at 1; close everything right of 1 → just tab 2 dies.
        model.closeTabsToRight(of: 1)
        // Tab 1 (middle) must KEEP its state.
        XCTAssertNotNil(model.editor.editorCursorByTab[ids.1],
            "tab left of pivot must keep its cursor record")
        XCTAssertNotNil(model.editor.editorScrollByTab[ids.1],
            "tab left of pivot must keep its scroll record")
        XCTAssertNotNil(model.editor.pendingEditorDiagnostics[ids.1],
            "tab left of pivot must keep its pending diagnostics")
        XCTAssertNotNil(model.editor.pendingEditorGutterMarkers[ids.1],
            "tab left of pivot must keep its pending gutter markers")
        // Tab 2 must DROP everything.
        assertAllEditorDictsEmpty(model, forTabID: ids.2)
    }

    // MARK: - addCloseHook contract (TabCoordinator-side)

    /// The hook registration mechanism on TabCoordinator must invoke
    /// every registered closure in registration order on every close.
    /// Pinned directly so a future refactor that swaps the storage
    /// model gets a targeted failure.
    func test_addCloseHook_invokesOnSingleClose() {
        let tc = TabCoordinator()
        var seenIDs: [UUID] = []
        tc.addCloseHook { id in seenIDs.append(id) }
        let a = URL(fileURLWithPath: "/a")
        tc.append(Tab(url: a))
        let id = tc.selected!.id
        tc.closeTab(at: 0)
        XCTAssertEqual(seenIDs, [id])
    }

    func test_addCloseHook_invokesForEveryClosedTab_inCloseOthers() {
        let tc = TabCoordinator()
        var seenIDs: [UUID] = []
        tc.addCloseHook { id in seenIDs.append(id) }
        for n in ["a", "b", "c"] {
            tc.append(Tab(url: URL(fileURLWithPath: "/\(n)")))
        }
        let ids = (tc.tabs.tabs[0].id, tc.tabs.tabs[1].id, tc.tabs.tabs[2].id)
        tc.closeOtherTabs(keeping: 0)
        XCTAssertEqual(Set(seenIDs), Set([ids.1, ids.2]),
            "closeOtherTabs must invoke the hook for each non-kept tab")
    }

    func test_addCloseHook_invokesForRightTail_inCloseToRight() {
        let tc = TabCoordinator()
        var seenIDs: [UUID] = []
        tc.addCloseHook { id in seenIDs.append(id) }
        for n in ["a", "b", "c"] {
            tc.append(Tab(url: URL(fileURLWithPath: "/\(n)")))
        }
        let ids = (tc.tabs.tabs[0].id, tc.tabs.tabs[1].id, tc.tabs.tabs[2].id)
        tc.closeTabsToRight(of: 0)
        XCTAssertEqual(Set(seenIDs), Set([ids.1, ids.2]),
            "closeTabsToRight must invoke the hook for each closed tab")
    }

    func test_addCloseHook_multipleHooks_invokedInRegistrationOrder() {
        let tc = TabCoordinator()
        var order: [String] = []
        tc.addCloseHook { _ in order.append("first") }
        tc.addCloseHook { _ in order.append("second") }
        tc.append(Tab(url: URL(fileURLWithPath: "/a")))
        tc.closeTab(at: 0)
        XCTAssertEqual(order, ["first", "second"])
    }
}
