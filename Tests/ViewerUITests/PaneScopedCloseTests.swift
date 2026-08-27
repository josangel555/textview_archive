import XCTest
import ViewerCore
@testable import ViewerUI

/// Owner 2026-08-27 — the close variants are PANE-SCOPED in a split:
/// "Close Other Tabs" closes the other tabs of THAT pane only, and
/// "Close Tabs to the Right" walks the pane's STRIP order (the flat store
/// order interleaves panes — it used to close tabs in the other pane the
/// user couldn't even see "to the right"). Un-split, the single pane holds
/// every tab, so classic behavior is unchanged (pinned by the existing
/// close-variant suites).
@MainActor
final class PaneScopedCloseTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaneScopedClose-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "PaneScopedClose-\(UUID().uuidString)"
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

    private func open(_ model: DocumentModel, _ name: String) throws -> UUID {
        let url = tmpDir.appendingPathComponent(name)
        try "# \(name)".write(to: url, atomically: true, encoding: .utf8)
        model.open(url: url)
        return try XCTUnwrap(model.tabs.selected?.id)
    }

    /// Split fixture: pane 1 = [left], pane 2 (focused) = [anchor, extra].
    private func makeSplitFixture(_ model: DocumentModel) throws
        -> (left: UUID, anchor: UUID, extra: UUID) {
        let left = try open(model, "left.md")
        let anchor = try open(model, "anchor.md")
        model.tabCoordinator.splitFocusedPane(movingSelected: true)
        let extra = try open(model, "extra.md")
        let panes = model.tabCoordinator.paneAssignment.panes
        XCTAssertEqual(panes.count, 2)
        XCTAssertEqual(panes[0].tabIDs, [left], "precondition: pane 1 holds left")
        XCTAssertEqual(panes[1].tabIDs, [anchor, extra], "precondition: pane 2 holds anchor+extra")
        return (left, anchor, extra)
    }

    func test_closeOtherTabs_inSplit_closesOnlyThatPanesTabs() throws {
        let model = makeModel()
        let (left, anchor, extra) = try makeSplitFixture(model)

        // "Close Other Tabs" on `anchor` (pane 2): only `extra` dies.
        let anchorIndex = try XCTUnwrap(model.tabs.tabs.firstIndex { $0.id == anchor })
        model.closeOtherTabs(keeping: anchorIndex)

        let survivors = Set(model.tabs.tabs.map(\.id))
        XCTAssertTrue(survivors.contains(left),
            "the OTHER pane's tab must survive Close Other Tabs (pane-scoped)")
        XCTAssertTrue(survivors.contains(anchor))
        XCTAssertFalse(survivors.contains(extra), "the same-pane sibling closes")
        XCTAssertEqual(model.tabCoordinator.paneAssignment.panes.count, 2,
            "the split itself survives — the other pane was never emptied")
    }

    func test_closeTabsToRight_inSplit_walksPaneStripOrder() throws {
        let model = makeModel()
        let (left, anchor, extra) = try makeSplitFixture(model)

        // "Close Tabs to the Right" on `anchor` (pane 2 strip = [anchor,
        // extra]): closes `extra`; pane 1's `left` — which sits BEFORE
        // anchor in the flat store — is untouched either way, and nothing
        // outside pane 2 may close.
        let anchorIndex = try XCTUnwrap(model.tabs.tabs.firstIndex { $0.id == anchor })
        model.closeTabsToRight(of: anchorIndex)

        let survivors = Set(model.tabs.tabs.map(\.id))
        XCTAssertEqual(survivors, [left, anchor],
            "to-the-right is the PANE's order: extra closes, left survives")
    }

    /// A restored split's UNFOCUSED pane must materialize its lazy visible
    /// tab without a click — materialization only rode `selectTab`, so the
    /// pane showed a permanent placeholder (the visible ≠ selected class).
    func test_unfocusedPane_lazyVisibleTab_materializesWithoutClick() throws {
        let model = makeModel()
        let urlA = tmpDir.appendingPathComponent("lazy-a.md")
        let urlB = tmpDir.appendingPathComponent("lazy-b.md")
        try "# a".write(to: urlA, atomically: true, encoding: .utf8)
        try "# b".write(to: urlB, atomically: true, encoding: .utf8)
        // Session-restore shape: LAZY tabs, then a split, then the derived
        // update that activation ends with.
        model.appendLazyTab(url: urlA, viewMode: .source)
        model.appendLazyTab(url: urlB, viewMode: .source)
        model.tabCoordinator.splitFocusedPane(movingSelected: true)
        model.updateDerived()

        // The unfocused pane's visible tab (lazy-a) must leave `.empty`
        // (→ .loading, then loaded) with no click.
        let a = model.tabCoordinator.paneAssignment.panes[0]
        let visID = try XCTUnwrap(a.selectedTabID)
        let vis = try XCTUnwrap(model.tabs.tabs.first { $0.id == visID })
        if case .empty = vis.state {
            XCTFail("the unfocused pane's visible tab stayed a lazy placeholder — nothing materialized it")
        }
    }

    /// Move Tab Left/Right walks the PANE-strip order while split (the old
    /// flat-store swap was invisible — each pane owns its strip order).
    func test_moveCurrentTabLeftRight_inSplit_walksPaneStripOrder() throws {
        let model = makeModel()
        let (left, anchor, extra) = try makeSplitFixture(model)
        // Focused pane 2 strip = [anchor, extra]; `extra` is selected.
        model.moveCurrentTabLeft()
        XCTAssertEqual(
            model.tabCoordinator.paneAssignment.panes[1].tabIDs, [extra, anchor],
            "move-left swaps within the pane strip")
        XCTAssertEqual(model.tabCoordinator.paneAssignment.panes[0].tabIDs, [left],
            "the other pane is untouched")
        model.moveCurrentTabRight()
        XCTAssertEqual(
            model.tabCoordinator.paneAssignment.panes[1].tabIDs, [anchor, extra],
            "move-right swaps back")
    }

    func test_closeOthers_whenSelectionWasDoomed_selectsTheKeptTab() throws {
        let model = makeModel()
        let (_, anchor, extra) = try makeSplitFixture(model)
        // Select `extra` (the doomed sibling), then close-others keeping anchor.
        let extraIndex = try XCTUnwrap(model.tabs.tabs.firstIndex { $0.id == extra })
        model.selectTab(at: extraIndex)
        let anchorIndex = try XCTUnwrap(model.tabs.tabs.firstIndex { $0.id == anchor })

        model.closeOtherTabs(keeping: anchorIndex)

        XCTAssertEqual(model.tabs.selected?.id, anchor,
            "selection lands on the kept tab through the full selectTab pipeline")
    }
}
