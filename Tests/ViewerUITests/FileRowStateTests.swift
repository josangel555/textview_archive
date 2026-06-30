import XCTest
import ViewerCore
import ViewerKit
@testable import ViewerUI

/// TSK-613 — pins the sidebar row SKIP CONTRACT. `FileRowView` is
/// `.equatable()` over `FileRowState`; SwiftUI skips a row's body
/// exactly when its state compares equal across a model republish.
/// So the perf fix's correctness is two-sided and both sides are
/// asserted here headlessly:
///   - UNCHANGED rows must produce an EQUAL state (else no perf win),
///   - rows whose visuals depend on the change must produce a
///     DIFFERENT state (else stale UI — the dangerous direction).
@MainActor
final class FileRowStateTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var model: DocumentModel!
    private var sidebar: SidebarModel!
    private var trackedRepos: TrackedReposChannel!
    private var fileA: URL!
    private var fileB: URL!
    private var fileC: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileRowState-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "FileRowState-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        sidebar = SidebarModel()
        model = DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmpDir.appendingPathComponent("history.json")),
            bookmarks: BookmarksStore(storeURL: tmpDir.appendingPathComponent("bookmarks.json")),
            sidebar: sidebar,
            preferences: PreferencesStore(defaults: defaults)
        )
        trackedRepos = TrackedReposChannel(store: TrackedReposStore())
        (fileA, fileB, fileC) = (
            tmpDir.appendingPathComponent("a.txt"),
            tmpDir.appendingPathComponent("b.txt"),
            tmpDir.appendingPathComponent("c.txt")
        )
        for url in [fileA!, fileB!, fileC!] {
            try "body of \(url.lastPathComponent)\n".write(to: url, atomically: true, encoding: .utf8)
        }
        model.openPath(fileA)
        model.openPath(fileB)
    }

    override func tearDown() async throws {
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
        if let suiteName, let defaults {
            defaults.removePersistentDomain(forName: suiteName)
        }
        try await super.tearDown()
    }

    private func node(_ url: URL) -> FileNode {
        FileNode(url: url, name: url.lastPathComponent, isDirectory: false)
    }

    private func state(_ url: URL) -> FileRowState {
        FileRowState.make(
            node: node(url), model: model, sidebar: sidebar,
            trackedRepos: trackedRepos, recencyMode: .modified)
    }

    func test_tabSwitch_changesOnlyInvolvedRows() {
        model.selectTab(at: 1)  // current = B
        let beforeA = state(fileA)
        let beforeB = state(fileB)
        let beforeC = state(fileC)

        model.selectTab(at: 0)  // switch B -> A

        XCTAssertNotEqual(state(fileA), beforeA, "A became current — must re-body")
        XCTAssertNotEqual(state(fileB), beforeB, "B lost current — must re-body")
        XCTAssertEqual(state(fileC), beforeC,
                       "C is uninvolved — equal state is the SKIP that buys the perf win")
    }

    func test_sidebarSelection_flipsOnlySelectedRows() {
        sidebar.setSelected(fileA)
        let beforeA = state(fileA)
        let beforeC = state(fileC)

        sidebar.setSelected(fileC)

        XCTAssertNotEqual(state(fileA), beforeA, "A lost selection")
        XCTAssertNotEqual(state(fileC), beforeC, "C gained selection")
    }

    func test_bookmarkToggle_reflectsInState() {
        let before = state(fileA)
        model.bookmarksStore.add(url: fileA)
        XCTAssertNotEqual(state(fileA), before, "bookmark star must re-body the row")
        XCTAssertTrue(state(fileA).isBookmarked)
    }

    // TSK-1152: the file-nav lock badge — FileRowState must carry the lock so
    // the indicator re-bodies on lock-change (a body-time model read wouldn't,
    // FileRowView being .equatable). Both directions of the skip contract.
    func test_viewModeLockToggle_reflectsInState() {
        let before = state(fileA)
        XCTAssertFalse(before.isViewModeLocked)
        model.lockViewMode(fileA, to: .source)
        let after = state(fileA)
        XCTAssertNotEqual(after, before, "the lock badge must re-body the row")
        XCTAssertTrue(after.isViewModeLocked)
        model.unlockViewMode(fileA)
        XCTAssertFalse(state(fileA).isViewModeLocked, "unlock clears the badge")
    }

    func test_directory_neverCarriesViewModeLock() {
        // A directory has no view mode, so its row never shows the lock badge
        // even if an (impossible) lock were keyed to its name.
        let dir = FileNode(url: tmpDir, name: tmpDir.lastPathComponent, isDirectory: true)
        let s = FileRowState.make(
            node: dir, model: model, sidebar: sidebar,
            trackedRepos: trackedRepos, recencyMode: .modified)
        XCTAssertFalse(s.isViewModeLocked)
    }

    func test_zoomChange_changesEveryRowState() {
        let before = state(fileC)
        model.zoom = model.zoom + 0.2
        XCTAssertNotEqual(state(fileC), before,
                          "uiSize-driven layout must re-body on zoom")
    }

    func test_openInOtherTab_tracksCurrentTab() {
        model.selectTab(at: 0)  // current = A, B open elsewhere
        XCTAssertTrue(state(fileB).isOpenInOtherTab)
        XCTAssertFalse(state(fileA).isOpenInOtherTab, "the current tab is not 'other'")
        XCTAssertFalse(state(fileC).isOpenInOtherTab, "not open at all")
    }
}
