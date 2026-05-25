import XCTest
import Combine
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// Per-tab dict cleanup invariants for every close path.
///
/// The pre-refactor failure mode this prevents: a new per-tab map
/// gets added (CSV filter state, HEX width, ...) and only one or
/// two of the three close paths (`closeTab`, `closeOtherTabs`,
/// `closeTabsToRight`) gets the cleanup line — the missing path
/// leaks per-tab state across closes. Folding the cleanup into
/// `TabCoordinator.cleanupAfterClose(id:)` removes the divergence
/// at the source; these tests pin that contract so a future addition
/// (an EditorCoordinator-owned dict, a Phase-7 per-tab terminal
/// state, etc.) can't silently miss a path.
///
/// Each matrix row = one (close path × one per-tab dict). They run
/// off DocumentModel so we also exercise the forwarder + the
/// dirty-save / non-coordinator cache purge cooperation; pure-
/// coordinator state lives in `TabCoordinatorTests`.
@MainActor
final class TabCoordinatorCleanupTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TabCoordinatorCleanupTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "TabCoordinatorCleanupTests-\(UUID().uuidString)"
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

    /// Seed three tabs with EVERY per-tab dict populated for the
    /// MIDDLE tab. The matrix tests then run different close paths
    /// and assert the middle tab's entries are gone afterward.
    private func seedThreeTabs() throws -> (model: DocumentModel,
                                            ids: (UUID, UUID, UUID)) {
        let model = makeModel()
        let a = try writeFile("a.json", "{}")
        let b = try writeFile("b.json", "{}")
        let c = try writeFile("c.json", "{}")
        model.open(url: a)
        model.open(url: b)
        model.open(url: c)
        let ids = (model.tabs.tabs[0].id,
                   model.tabs.tabs[1].id,
                   model.tabs.tabs[2].id)
        // Populate every per-tab dict for the middle tab so the
        // various close paths each have something concrete to drop.
        var s = TabCoordinator.CSVFilterState()
        s.globalQuery = "needle"
        model.setCsvFilterState(s, forTabID: ids.1)
        model.setHexWidth(32, forTabID: ids.1)
        // Language override: switch to tab 1, set, then bring focus
        // back where the test expects.
        model.selectTab(at: 1)
        model.setCurrentLanguage(.swift)
        // formattedTabIDs: toggle via the API (autoselected tab is 1).
        model.toggleFormat()
        // formattedTextCache: drive a displayText() call so the
        // formatter caches the result for tab 1.
        if case .loaded(let f) = model.currentState {
            _ = model.displayText(for: f)
        }
        // editorBuffer: switch to editor mode + ensure on tab 1.
        if case .loaded(let f) = model.currentState {
            model.ensureEditorBuffer(for: f, tabID: ids.1)
        }
        // Verify the seed actually populated:
        XCTAssertNotNil(model.csvFilterStates[ids.1])
        XCTAssertNotNil(model.hexBytesPerRow[ids.1])
        XCTAssertTrue(model.tabCoordinator.languageOverrides[ids.1] != nil)
        XCTAssertTrue(model.tabCoordinator.formattedTabIDs.contains(ids.1))
        XCTAssertNotNil(model.tabCoordinator.formattedTextCache[ids.1])
        XCTAssertNotNil(model.editorBuffers[ids.1])
        return (model, ids)
    }

    /// Assert EVERY one of the six per-tab dicts is empty for `id`.
    /// The asserts are spelled out (rather than looped) so a failure
    /// names the specific dict that didn't drain.
    private func assertAllPerTabDictsEmpty(
        _ model: DocumentModel, forTabID id: UUID,
        line: UInt = #line
    ) {
        XCTAssertNil(model.csvFilterStates[id],
            "csvFilterStates leaked for closed tab", line: line)
        XCTAssertNil(model.hexBytesPerRow[id],
            "hexBytesPerRow leaked for closed tab", line: line)
        XCTAssertNil(model.tabCoordinator.languageOverrides[id],
            "languageOverrides leaked for closed tab", line: line)
        XCTAssertFalse(model.tabCoordinator.formattedTabIDs.contains(id),
            "formattedTabIDs leaked for closed tab", line: line)
        XCTAssertNil(model.tabCoordinator.formattedTextCache[id],
            "formattedTextCache leaked for closed tab", line: line)
        XCTAssertNil(model.editorBuffers[id],
            "editorBuffers leaked for closed tab", line: line)
    }

    // MARK: - closeTab(at:)

    func test_closeTab_drains_allSixDicts() throws {
        let (model, ids) = try seedThreeTabs()
        model.closeTab(at: 1)
        assertAllPerTabDictsEmpty(model, forTabID: ids.1)
    }

    // MARK: - closeOtherTabs(keeping:)

    func test_closeOtherTabs_drains_dictsForAllNonKept() throws {
        let (model, ids) = try seedThreeTabs()
        // Keep tab 0 (`a.json`). The middle (`b.json`) and end
        // (`c.json`) must lose their per-tab dict entries.
        model.closeOtherTabs(keeping: 0)
        assertAllPerTabDictsEmpty(model, forTabID: ids.1)
        assertAllPerTabDictsEmpty(model, forTabID: ids.2)
    }

    // MARK: - closeTabsToRight(of:)

    func test_closeTabsToRight_drains_dictsForRightTail() throws {
        let (model, ids) = try seedThreeTabs()
        // Keep tabs 0 and 1; drop 2.
        // We seeded the middle (1) only, so verify it survives AND
        // that an explicitly-seeded right-of-pivot tab disappears.
        // Tab 2 wasn't seeded by the helper, so seed it here.
        var s = TabCoordinator.CSVFilterState()
        s.globalQuery = "right"
        model.setCsvFilterState(s, forTabID: ids.2)
        model.setHexWidth(48, forTabID: ids.2)
        model.selectTab(at: 2)
        model.setCurrentLanguage(.swift)
        model.toggleFormat()
        if case .loaded(let f) = model.currentState {
            _ = model.displayText(for: f)
            model.ensureEditorBuffer(for: f, tabID: ids.2)
        }
        model.closeTabsToRight(of: 1)
        // Tab 1 must KEEP its state.
        XCTAssertNotNil(model.csvFilterStates[ids.1],
            "tab to the left of pivot must keep its CSV filter state")
        XCTAssertNotNil(model.editorBuffers[ids.1],
            "tab to the left of pivot must keep its editor buffer")
        // Tab 2 must DROP everything.
        assertAllPerTabDictsEmpty(model, forTabID: ids.2)
    }

    // MARK: - materializeTasks cleanup

    func test_closeTab_cancelsMaterializeTask() throws {
        let model = makeModel()
        let a = try writeFile("a.md", "v1")
        // Use lazy append so the tab has state .empty, then select
        // to kick a materialize that we close before it lands.
        model.appendLazyTab(url: a, viewMode: .source)
        let id = model.tabs.tabs[0].id
        model.selectTab(at: 0)
        // Slot should have a Task right after selectTab (read may
        // race; not asserting presence — only that close clears).
        model.closeTab(at: 0)
        XCTAssertNil(model.tabCoordinator.materializeTask(forTabID: id),
            "close must cancel + drop the materialize Task slot")
    }

    // MARK: - openTabURLs invariant across closes

    func test_openTabURLs_dropsClosedURL() throws {
        let model = makeModel()
        let a = try writeFile("a.md", "x")
        let b = try writeFile("b.md", "x")
        model.open(url: a)
        model.open(url: b)
        XCTAssertEqual(model.openTabURLs.count, 2)
        model.closeTab(at: 0)
        XCTAssertEqual(model.openTabURLs.count, 1,
            "closing a tab must drop its URL from the open-set")
        XCTAssertTrue(model.openTabURLs.contains(b.standardizedFileURL.resolvingSymlinksInPath()))
    }

    func test_openTabURLs_dropsAllForCloseOthers() throws {
        let model = makeModel()
        for n in ["a", "b", "c"] {
            model.open(url: try writeFile("\(n).md"))
        }
        XCTAssertEqual(model.openTabURLs.count, 3)
        model.closeOtherTabs(keeping: 1)
        XCTAssertEqual(model.openTabURLs.count, 1)
    }
}
