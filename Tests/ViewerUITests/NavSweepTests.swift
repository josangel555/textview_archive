import XCTest
import ViewerCore
import ViewerKit
@testable import ViewerUI

/// TSK-603 — pins the NavSweep profiling driver's behavior headlessly:
/// the VM capture's validity depends on the sweep actually performing
/// the advertised interactions and leaving the model where it found it
/// (a sweep that drifts state would make back-to-back captures
/// incomparable). Signpost emission itself is env-gated (MDV_SIGNPOSTS)
/// and inert here; the trace-side check is the VM lane.
@MainActor
final class NavSweepTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var model: DocumentModel!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NavSweep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "NavSweep-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        model = DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmpDir.appendingPathComponent("history.json")),
            bookmarks: BookmarksStore(storeURL: tmpDir.appendingPathComponent("bookmarks.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults)
        )
        // One real open + two lazy appends — the workspace-restore shape
        // the VM driver script mirrors, so the tab walk includes the
        // lazy-materialize path.
        let first = tmpDir.appendingPathComponent("a.md")
        try "# a\n".write(to: first, atomically: true, encoding: .utf8)
        model.openPath(first)
        for name in ["b.txt", "c.txt"] {
            let url = tmpDir.appendingPathComponent(name)
            try "\(name) body\n".write(to: url, atomically: true, encoding: .utf8)
            model.appendLazyTab(url: url, viewMode: ViewModeOptions.defaultMode(for: url))
        }
    }

    override func tearDown() async throws {
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
        if let suiteName, let defaults {
            defaults.removePersistentDomain(forName: suiteName)
        }
        try await super.tearDown()
    }

    func test_performsAdvertisedInteractionCount() async {
        let tabs = model.tabs.tabs.count
        XCTAssertEqual(tabs, 3, "fixture should hold 3 tabs")
        // Per cycle: every tab + 2 sidebar toggles + 2 view toggles.
        let performed = await NavSweep.run(
            model: model, cycles: 2, interactionDelayNanos: 0)
        XCTAssertEqual(performed, 2 * (tabs + 4))
    }

    func test_sweepIsStateNeutral() async {
        model.selectTab(at: 0)
        let selectedBefore = model.tabs.selectedIndex
        let sidebarBefore = model.sidebar.isVisible
        let modeBefore = model.currentViewMode

        await NavSweep.run(model: model, cycles: 1, interactionDelayNanos: 0)

        XCTAssertEqual(model.tabs.selectedIndex, selectedBefore,
                       "sweep must restore the originally-selected tab")
        XCTAssertEqual(model.sidebar.isVisible, sidebarBefore,
                       "even toggle count must restore sidebar visibility")
        XCTAssertEqual(model.currentViewMode, modeBefore,
                       "even toggle count must restore the view mode")
    }

    func test_zeroAndNegativeCyclesClampToOne() async {
        let tabs = model.tabs.tabs.count
        let performed = await NavSweep.run(
            model: model, cycles: 0, interactionDelayNanos: 0)
        XCTAssertEqual(performed, tabs + 4, "cycles clamps to 1")
    }
}
