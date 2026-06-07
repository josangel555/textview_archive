import XCTest
import Combine
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// Coverage for the CM6 editor fold pipeline (TSK-466 step 2/3):
///
/// - `EditorCoordinator.setEditorFoldRanges` — per-tab routing, the
///   unknown-tab no-op, the equality-guarded republish suppression, and
///   the close-hook drain.
/// - `DocumentModel.refreshEditorFolds` — the end-to-end producer:
///   TreeSitter `FoldRegion` → `SyntaxFoldRangeMapping` → the per-tab
///   `editorFoldRangesByTab` dict that `ContentView` reads into
///   `CodeMirrorEditorView(foldingRanges:)`.
///
/// The CM6 *render* of the fold gutter is VM-validation-only; everything
/// below is the host-testable model layer.
@MainActor
final class EditorFoldRangesTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorFoldRangesTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "EditorFoldRangesTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
        defaults.removePersistentDomain(forName: suiteName)
    }

    @discardableResult
    private func writeFile(_ name: String, _ contents: String) throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func loadedTab(_ tc: TabCoordinator, name: String, contents: String) throws -> UUID {
        let url = try writeFile(name, contents)
        let file = TextFile(url: url, contents: contents, encoding: .utf8,
                            byteCount: contents.utf8.count, modifiedTime: nil)
        tc.append(Tab(url: url, state: .loaded(file)))
        return tc.selected!.id
    }

    private func makeModel() -> DocumentModel {
        DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmpDir.appendingPathComponent("history.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults)
        )
    }

    /// Poll until `cond` holds or `timeout` elapses (the fold compute is
    /// off-main + async; small JSON parses in well under the budget).
    private func waitUntil(timeout: TimeInterval = 4,
                           _ cond: () -> Bool) async {
        let start = Date()
        while !cond() {
            if Date().timeIntervalSince(start) > timeout { return }
            try? await Task.sleep(nanoseconds: 20_000_000) // 20 ms
        }
    }

    private func wireMinimal(_ ec: EditorCoordinator, _ tc: TabCoordinator) {
        ec.tabsSnapshot = { [tc] in tc.tabs.tabs }
        ec.activeTabIDSnapshot = { [tc] in tc.tabs.selected?.id }
    }

    // MARK: - EditorCoordinator.setEditorFoldRanges routing

    func test_setEditorFoldRanges_setsForOpenTab() throws {
        let tc = TabCoordinator()
        let ec = EditorCoordinator(tabCoordinator: tc)
        wireMinimal(ec, tc)
        let id = try loadedTab(tc, name: "a.json", contents: "{}")
        let ranges = [CMFoldRange(from: 0, to: 5, kind: "object")]
        ec.setEditorFoldRanges(ranges, forTabID: id)
        XCTAssertEqual(ec.editorFoldRangesByTab[id], ranges)
    }

    func test_setEditorFoldRanges_unknownTab_isNoOp() {
        let tc = TabCoordinator()
        let ec = EditorCoordinator(tabCoordinator: tc)
        wireMinimal(ec, tc)
        ec.setEditorFoldRanges([CMFoldRange(from: 0, to: 5, kind: nil)], forTabID: UUID())
        XCTAssertTrue(ec.editorFoldRangesByTab.isEmpty,
                      "a compute that finished after the tab closed must not resurrect an entry")
    }

    func test_setEditorFoldRanges_identicalValue_doesNotRepublish() throws {
        let tc = TabCoordinator()
        let ec = EditorCoordinator(tabCoordinator: tc)
        wireMinimal(ec, tc)
        let id = try loadedTab(tc, name: "a.json", contents: "{}")
        let ranges = [CMFoldRange(from: 0, to: 5, kind: "object")]
        ec.setEditorFoldRanges(ranges, forTabID: id)

        var emissions = 0
        let c = ec.$editorFoldRangesByTab.dropFirst().sink { _ in emissions += 1 }
        ec.setEditorFoldRanges(ranges, forTabID: id) // identical → guarded
        c.cancel()
        XCTAssertEqual(emissions, 0, "identical fold set must not republish @Published")

        var emissions2 = 0
        let c2 = ec.$editorFoldRangesByTab.dropFirst().sink { _ in emissions2 += 1 }
        ec.setEditorFoldRanges([CMFoldRange(from: 1, to: 9, kind: "array")], forTabID: id)
        c2.cancel()
        XCTAssertEqual(emissions2, 1, "a changed value must still republish")
    }

    func test_closingTab_drainsFoldRanges() throws {
        let tc = TabCoordinator()
        let ec = EditorCoordinator(tabCoordinator: tc)
        wireMinimal(ec, tc)
        let id = try loadedTab(tc, name: "a.json", contents: "{}")
        ec.setEditorFoldRanges([CMFoldRange(from: 0, to: 5, kind: nil)], forTabID: id)
        XCTAssertNotNil(ec.editorFoldRangesByTab[id])
        _ = tc.closeTab(at: 0) // fires the close hook registered in EditorCoordinator.init
        XCTAssertNil(ec.editorFoldRangesByTab[id],
                     "close hook must drain the fold dict in lock-step with the other editor dicts")
    }

    // MARK: - DocumentModel.refreshEditorFolds (end-to-end producer)

    func test_refreshEditorFolds_populatesFoldsForJSONInEditorMode() async throws {
        let model = makeModel()
        let json = """
        {
          "items": [
            1,
            2,
            3
          ]
        }
        """
        let url = try writeFile("doc.json", json)
        model.open(url: url)
        let id = model.tabs.selected!.id
        model.setCurrentViewMode(.editor)

        model.refreshEditorFolds()
        await waitUntil { model.editorFoldRangesByTab[id] != nil }

        let folds = model.editorFoldRangesByTab[id] ?? []
        XCTAssertFalse(folds.isEmpty,
            "a multi-line JSON object/array must yield at least one CM6 fold range")
        // Every emitted range must be well-formed (from < to) — the
        // mapping drops degenerate ranges, so any survivor is valid.
        XCTAssertTrue(folds.allSatisfy { $0.from < $0.to })
    }

    func test_refreshEditorFolds_noOpOutsideEditorMode() async throws {
        let model = makeModel()
        let json = "{\n  \"a\": [1, 2]\n}\n"
        let url = try writeFile("doc.json", json)
        model.open(url: url)
        let id = model.tabs.selected!.id
        // Deliberately NOT editor mode — folds are only consumed by the
        // CM6 editor, so the producer must skip the compute entirely.
        model.setCurrentViewMode(.source)

        model.refreshEditorFolds()
        // Give any (incorrectly-launched) task a chance to land.
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(model.editorFoldRangesByTab[id],
            "refreshEditorFolds must be a no-op when the selected tab isn't in editor mode")
    }

    func test_refreshEditorFolds_recomputesAfterEdit() async throws {
        let model = makeModel()
        // Start with a flat doc (no nested foldable block).
        let url = try writeFile("doc.json", "{ \"a\": 1 }\n")
        model.open(url: url)
        let id = model.tabs.selected!.id
        model.setCurrentViewMode(.editor)
        _ = model.editorBuffer(forTabID: id)

        // Edit into a multi-line nested structure — updateEditorText must
        // trigger a recompute that now yields folds.
        let edited = "{\n  \"a\": [\n    1,\n    2\n  ]\n}\n"
        model.updateEditorText(edited, forTabID: id)
        await waitUntil {
            !(model.editorFoldRangesByTab[id] ?? []).isEmpty
        }
        XCTAssertFalse((model.editorFoldRangesByTab[id] ?? []).isEmpty,
            "editing into a nested block must recompute folds via updateEditorText")
    }
}
