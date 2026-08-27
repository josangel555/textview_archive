import XCTest
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// Tier 1 (T1m, host-safe) wiring guard for perf Fix#1 (TSK-108): the
/// `DocumentModel` ↔ `MountedPanesLRU` plumbing. The LRU eviction *ordering*
/// is unit-tested WKWebView-free in `MountedPanesLRUTests`; THIS suite proves
/// the model actually DRIVES it correctly from the real open / select / close
/// paths (all funnel through `updateDerived → noteActiveTabForRetention`).
///
/// The headline invariant — switching A→B→A keeps B MOUNTED — is what makes
/// the view layer skip the WKWebView teardown+reload. The view-layer
/// 0-remount proof (real WKWebViews) lives in the `MDV_RUN_WEBVIEW_TESTS` /
/// VM lane + the `build-app.sh` live gate; it cannot run on the bare host
/// (#192 WebContent exhaustion). This model-side guard is the bare-gate teeth.
@MainActor
final class MountedPanesWiringTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MountedPanesWiring-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "MountedPanesWiring-\(UUID().uuidString)"
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
    private func writeFile(_ name: String, _ contents: String) throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func drain() async {
        for _ in 0..<3 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 20_000_000)
        for _ in 0..<3 { await Task.yield() }
    }

    /// Opening tabs enrolls each into the mounted set; the selection sits at
    /// the MRU front.
    func test_open_enrollsTabsInMountedSet() async throws {
        let model = makeModel()
        model.open(url: try writeFile("a.txt", "alpha"))
        model.open(url: try writeFile("b.txt", "bravo"))
        await drain()

        XCTAssertEqual(model.tabs.tabs.count, 2)
        let a = model.tabs.tabs[0].id
        let b = model.tabs.tabs[1].id
        XCTAssertTrue(model.mountedPanes.contains(a), "tab A not mounted after open")
        XCTAssertTrue(model.mountedPanes.contains(b), "tab B not mounted after open")
        // B was opened last → it's the selected, MRU-front pane.
        XCTAssertEqual(model.mountedPanes.ids.first, b, "last-opened tab is not MRU-front")
        XCTAssertEqual(model.mountedTabs.map(\.id), model.mountedPanes.ids,
                       "mountedTabs must mirror mountedPanes order")
    }

    /// THE headline retention invariant: A→B→A keeps B mounted (no teardown)
    /// AND moves A to the front. Mutating `noteActiveTabForRetention` to drop
    /// non-active panes breaks this — the test then fails (teeth).
    func test_switchAtoBtoA_retainsBothPanes() async throws {
        let model = makeModel()
        model.open(url: try writeFile("a.txt", "alpha"))
        model.open(url: try writeFile("b.txt", "bravo"))
        await drain()
        let a = model.tabs.tabs[0].id
        let b = model.tabs.tabs[1].id

        model.selectTab(at: 0)   // A
        model.selectTab(at: 1)   // B
        model.selectTab(at: 0)   // back to A
        await drain()

        XCTAssertTrue(model.mountedPanes.contains(a), "active tab A not mounted")
        XCTAssertTrue(model.mountedPanes.contains(b),
                      "tab B was evicted on switch-away — it would reload on switch-back (the bug)")
        XCTAssertEqual(model.mountedPanes.ids.first, a, "A not MRU-front after re-selecting it")
        XCTAssertEqual(model.mountedTabs.count, 2)
    }

    /// Owner bug 2026-08-27 (the WHITE pane): with a split, opening new docs
    /// in the focused pane must NEVER evict the OTHER pane's visible tab —
    /// it is on screen; eviction dismantles its webview mid-display and
    /// frees its mounted-gated rendered-HTML entry (white until a click
    /// re-selects it). Every pane's selectedTabID is retention-pinned.
    func test_split_opensInOnePane_neverEvictTheOtherPanesVisibleTab() async throws {
        let model = makeModel()
        model.open(url: try writeFile("left.md", "# left"))
        model.open(url: try writeFile("right.md", "# right"))
        await drain()
        let left = model.tabs.tabs[0].id

        // Split tearing the selected (right.md) into a new focused pane;
        // left.md stays visible in the original (unfocused) pane.
        model.tabCoordinator.splitFocusedPane(movingSelected: true)
        XCTAssertEqual(
            model.tabCoordinator.paneAssignment.panes.first?.selectedTabID, left,
            "precondition: left.md is the unfocused pane's visible tab")

        // Open enough new docs in the focused pane to overflow the LRU
        // (capacity 4) several times over.
        for i in 0..<6 {
            model.open(url: try writeFile("new-\(i).md", "# \(i)"))
        }
        await drain()

        XCTAssertTrue(model.mountedPanes.contains(left),
            "the unfocused pane's ON-SCREEN tab was evicted by opens in the other pane — its webview dismantles mid-display (the white pane)")
        // The focused pane's visible tab (the last open) is MRU-front.
        XCTAssertEqual(model.mountedPanes.ids.first, model.tabs.selected?.id)
    }

    /// Closing a tab removes its pane from the mounted set (the one place a
    /// pane is allowed to unmount, besides LRU eviction).
    func test_close_removesPaneFromMountedSet() async throws {
        let model = makeModel()
        model.open(url: try writeFile("a.txt", "alpha"))
        model.open(url: try writeFile("b.txt", "bravo"))
        await drain()
        let a = model.tabs.tabs[0].id
        let b = model.tabs.tabs[1].id

        model.closeTab(at: 1)    // close B
        await drain()

        XCTAssertFalse(model.mountedPanes.contains(b), "closed tab B still mounted (leak)")
        XCTAssertTrue(model.mountedPanes.contains(a), "surviving tab A unexpectedly dropped")
        XCTAssertEqual(model.mountedTabs.map(\.id), [a])
    }

    /// The set is capacity-bounded: opening more tabs than `capacity` (4)
    /// never grows the mounted set past the cap — the LRU tail evicts.
    func test_mountedSet_isCapacityBounded() async throws {
        let model = makeModel()
        for i in 0..<6 { model.open(url: try writeFile("f\(i).txt", "body \(i)")) }
        await drain()

        XCTAssertEqual(model.tabs.tabs.count, 6)
        XCTAssertLessThanOrEqual(model.mountedPanes.count, 4,
                                 "mounted set grew past the LRU capacity — unbounded webview retention")
        // The currently-selected tab is always retained.
        if let sel = model.tabs.selected?.id {
            XCTAssertTrue(model.mountedPanes.contains(sel), "active tab not retained")
        }
    }

    /// Closing every tab empties the mounted set (so `content` falls back to
    /// the empty-state render path rather than a stale ZStack).
    func test_closingAllTabs_emptiesMountedSet() async throws {
        let model = makeModel()
        model.open(url: try writeFile("a.txt", "alpha"))
        model.open(url: try writeFile("b.txt", "bravo"))
        await drain()
        while model.tabs.tabs.count > 0 {
            model.closeTab(at: model.tabs.tabs.count - 1)
        }
        await drain()
        XCTAssertTrue(model.mountedTabs.isEmpty, "mounted set not empty after closing all tabs")
    }
}
