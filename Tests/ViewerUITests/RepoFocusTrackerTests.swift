import XCTest
import Combine
import ViewerCore
@testable import ViewerUI

/// Host-safe @MainActor bookkeeping tests for RepoFocusTracker: the
/// watchers map must track the live-root count, evicted roots' watchers
/// must be stopped, and focusedRoot must follow the selected tab's repo.
///
/// These exercise the MAP and the demand diff, NOT live FSEvents streams
/// (that's VM-only — see test_plan). A real FolderWatcher IS created per
/// retained root here, but we only assert on counts / membership, never
/// on a fired callback.
@MainActor
final class RepoFocusTrackerTests: XCTestCase {

    private var tmp: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else {
            throw XCTSkip("git not available")
        }
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-repofocus-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        suiteName = "mdv-repofocus-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
        defaults?.removePersistentDomain(forName: suiteName)
    }

    @discardableResult
    private func runGit(_ args: [String], in dir: URL) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.currentDirectoryURL = dir
        p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        try p.run(); p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    private func makeRepo(_ name: String) throws -> URL {
        let dir = tmp.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = try runGit(["init", "-q"], in: dir)
        _ = try runGit(["config", "user.email", "t@e.com"], in: dir)
        _ = try runGit(["config", "user.name", "T"], in: dir)
        return dir
    }

    private func makeModel() -> DocumentModel {
        DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmp.appendingPathComponent("h.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults)
        )
    }

    /// Open a file + wait for the async recompute Task to settle.
    private func openAndSettle(_ model: DocumentModel, _ url: URL) async {
        model.open(url: url)
        try? await Task.sleep(nanoseconds: 400_000_000)
        await Task.yield()
    }

    // MARK: - watcher count tracks live roots

    func test_watcherCount_tracksLiveRoots() async throws {
        let repoA = try makeRepo("A")
        let repoB = try makeRepo("B")
        let fileA = repoA.appendingPathComponent("a.txt")
        let fileB = repoB.appendingPathComponent("b.txt")
        try "1".write(to: fileA, atomically: true, encoding: .utf8)
        try "2".write(to: fileB, atomically: true, encoding: .utf8)

        let model = makeModel()
        await openAndSettle(model, fileA)
        XCTAssertEqual(model.repoFocus.watcherCount, 1, "one tracked repo → one watcher")
        XCTAssertTrue(model.repoFocus._testHasWatcher(for: repoA))

        await openAndSettle(model, fileB)
        XCTAssertEqual(model.repoFocus.watcherCount, 2, "two tracked repos → two watchers")
        XCTAssertTrue(model.repoFocus._testHasWatcher(for: repoB))
    }

    // MARK: - evicted root's watcher is stopped

    func test_closingLastTab_thenGraceExpiry_stopsWatcher() async throws {
        let repoA = try makeRepo("A")
        let fileA = repoA.appendingPathComponent("a.txt")
        try "1".write(to: fileA, atomically: true, encoding: .utf8)

        let model = makeModel()
        await openAndSettle(model, fileA)
        XCTAssertEqual(model.repoFocus.watcherCount, 1)

        // Force the store's grace timestamp into the past, then close the
        // tab so release() + enforceCapAndGrace() evicts the root and the
        // tracker stops its watcher.
        let normRoot = TrackedReposReducer.normalize(repoA)
        // Demand for repoA = open tab (+1) AND the sidebar selection/root
        // that `open()` set to the file (+1). To FULLY release the repo
        // we must drop every demand source: close the tab AND clear the
        // sidebar. (This is the registry working correctly — a sidebar
        // still pointing into a repo legitimately keeps it tracked.)
        while !model.tabs.tabs.isEmpty { model.closeTab(at: 0) }
        model.sidebar.setSelected(nil)
        model.sidebar.setRoot(nil)
        model.repoFocus.recompute()
        try? await Task.sleep(nanoseconds: 500_000_000)
        await Task.yield()
        let rcAfter = await model.repoFocus.store._testRefcounts()
        XCTAssertNil(rcAfter[normRoot], "refcount cleared after dropping every demand source")
        let inGrace = await model.repoFocus.store.isInGrace(normRoot)
        XCTAssertTrue(inGrace, "dropping the last demand source puts the root into grace")
        // Backdate grace past the window, then recompute → eviction sweep.
        await model.repoFocus.store._testSetZeroRefSince(
            normRoot, Date().addingTimeInterval(-TrackedReposStore.graceWindow - 5)
        )
        model.repoFocus.recompute()
        try? await Task.sleep(nanoseconds: 500_000_000)
        await Task.yield()

        XCTAssertEqual(model.repoFocus.watcherCount, 0,
            "fully-evicted root's watcher must be stopped (no FSEvent leak)")
        XCTAssertFalse(model.repoFocus._testHasWatcher(for: repoA))
    }

    // MARK: - focusedRoot follows the selected tab's repo

    func test_focusedRoot_followsSelectedTab() async throws {
        let repoA = try makeRepo("A")
        let repoB = try makeRepo("B")
        let fileA = repoA.appendingPathComponent("a.txt")
        let fileB = repoB.appendingPathComponent("b.txt")
        try "1".write(to: fileA, atomically: true, encoding: .utf8)
        try "2".write(to: fileB, atomically: true, encoding: .utf8)

        let model = makeModel()
        await openAndSettle(model, fileA)
        await openAndSettle(model, fileB)
        // fileB is the selected tab now → focus follows B.
        XCTAssertEqual(model.repoFocus.focusedRoot, TrackedReposReducer.normalize(repoB))
    }

    // MARK: - focus change on the churn-guard path ticks the channel version

    /// Regression for the GP-01 occluded-launch bug: `GitPanelSection`
    /// reads `focusedRoot` (a NON-observed property) only on a
    /// `channel.version` tick. When `recompute()` resolves a NEW focus on
    /// the churn-guard-#1 path — identical demand, so `handoffMirror()`
    /// (the usual version-bump source) is SKIPPED — the focus flip would
    /// otherwise land silently and the mounted section would never re-run
    /// `syncRepo`. `updateFocusedRoot()` must call
    /// `channel.notifyFocusChanged()` to wake it.
    ///
    /// Scenario: two repos both tracked (so the tracked set is stable and
    /// a re-`recompute()` hits the churn guard). Switch the selected tab
    /// from B to A, then `recompute()` — demand is unchanged, so only the
    /// focus flips. The version MUST tick on that recompute.
    func test_focusFlipOnChurnGuardPath_ticksChannelVersion() async throws {
        let repoA = try makeRepo("A")
        let repoB = try makeRepo("B")
        let fileA = repoA.appendingPathComponent("a.txt")
        let fileB = repoB.appendingPathComponent("b.txt")
        try "1".write(to: fileA, atomically: true, encoding: .utf8)
        try "2".write(to: fileB, atomically: true, encoding: .utf8)

        let model = makeModel()
        await openAndSettle(model, fileA)
        await openAndSettle(model, fileB)
        // fileB is the selected tab → focus is B.
        XCTAssertEqual(model.repoFocus.focusedRoot, TrackedReposReducer.normalize(repoB))

        // Switch the selected tab back to A WITHOUT changing the tracked
        // set or any auto-recompute demand source. The pending desired set
        // is now identical to the previous one → the next recompute takes
        // the churn-guard-#1 branch (no mirror handoff, no version bump
        // from `applyMirror`). Focus must still flip B → A and tick the
        // version via `notifyFocusChanged`.
        let aIndex = model.tabs.tabs.firstIndex { $0.url == fileA }!
        model.selectTab(at: aIndex)
        let vBefore = model.trackedRepos.version
        model.repoFocus.recompute()
        try? await Task.sleep(nanoseconds: 300_000_000)
        await Task.yield()

        XCTAssertEqual(model.repoFocus.focusedRoot, TrackedReposReducer.normalize(repoA),
            "focus follows the now-selected tab into repo A")
        XCTAssertGreaterThan(model.trackedRepos.version, vBefore,
            "a nil-less focus flip on the churn-guard path must still tick "
            + "channel.version to wake the mounted GitPanelSection")
    }

    // MARK: - pin keeps a repo tracked with no open tab

    func test_pin_keepsRepoTrackedWithNoOpenTab() async throws {
        let repoA = try makeRepo("A")
        let fileA = repoA.appendingPathComponent("a.txt")
        try "1".write(to: fileA, atomically: true, encoding: .utf8)

        let model = makeModel()
        await openAndSettle(model, fileA)
        // Pin it, then drop EVERY other demand source (tab + sidebar) so
        // the pin is the only thing keeping it tracked. The pin must keep
        // it referenced (and watched) even past the grace window.
        model.repoFocus.togglePin(repoA)
        try? await Task.sleep(nanoseconds: 200_000_000)
        while !model.tabs.tabs.isEmpty { model.closeTab(at: 0) }
        model.sidebar.setSelected(nil)
        model.sidebar.setRoot(nil)
        let normRoot = TrackedReposReducer.normalize(repoA)
        // Backdate any grace so a sweep would evict an unpinned root —
        // proving the pin (not just grace) is what keeps it.
        await model.repoFocus.store._testSetZeroRefSince(
            normRoot, Date().addingTimeInterval(-TrackedReposStore.graceWindow - 5)
        )
        model.repoFocus.recompute()
        try? await Task.sleep(nanoseconds: 500_000_000)
        await Task.yield()

        let count = await model.repoFocus.store._testRefcounts()
        XCTAssertEqual(count[normRoot], 1,
            "pinned repo stays referenced after every other demand source drops")
        XCTAssertTrue(model.repoFocus._testHasWatcher(for: repoA),
            "pinned repo keeps its watcher")
    }
}
