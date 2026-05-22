import XCTest
import ViewerCore
import ViewerKit
@testable import ViewerUI

/// Regression tests for the bug where switching between sessions loses
/// the outgoing session's tab list (and other per-session UI state).
///
/// Pre-fix behavior, as the user reported:
///   - Open folder A → open file → switch to a new session B
///   - Switch back to A → tab list is empty
///
/// Root cause: `SessionsAppCoordinator.switchSessionFaçade` drops the
/// DocumentModel's tabs without first persisting an outgoing snapshot,
/// and never calls `SessionState.hydrate(from:)` on the incoming
/// session — so even if a snapshot existed, it wouldn't be applied.
///
/// These tests cover the full per-session state surface, not just
/// `openTabs`:
///   - openTabs + selectedTabIndex
///   - sidebarRootPath
///   - zoom
///   - sourceWordWrap
///   - themeOverride
///
/// Pure-logic tests. No NSApplication / NSWindow. Safe on host.
/// Filter: `swift test --filter ViewerUITests.SessionTabPersistence`
@MainActor
final class SessionTabPersistenceTests: XCTestCase {

    // MARK: Fixtures ---------------------------------------------------

    private lazy var tmpRoot: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionTabPersistenceTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true
        )
        return url
    }()

    /// Make a folder + a couple of files in it. Returns (folder, [files]).
    private func makeWorkspace(named: String, files: [String]) -> (URL, [URL]) {
        let folder = tmpRoot.appendingPathComponent(named, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true
        )
        var urls: [URL] = []
        for name in files {
            let url = folder.appendingPathComponent(name)
            try? Data("// \(name)\n".utf8).write(to: url)
            urls.append(url)
        }
        return (folder, urls)
    }

    /// Build a fresh `SessionsAppCoordinator` rooted at a per-test
    /// stores directory so the test doesn't touch the real
    /// `~/Library/Application Support` slot.
    private func makeCoordinator() -> SessionsAppCoordinator {
        let storesDir = tmpRoot.appendingPathComponent(
            "stores-\(UUID().uuidString)"
        )
        try? FileManager.default.createDirectory(
            at: storesDir, withIntermediateDirectories: true
        )
        let sessionsDir = storesDir.appendingPathComponent("Sessions")
        let workspaceDir = storesDir.appendingPathComponent("Workspaces")
        try? FileManager.default.createDirectory(
            at: sessionsDir, withIntermediateDirectories: true
        )
        try? FileManager.default.createDirectory(
            at: workspaceDir, withIntermediateDirectories: true
        )
        let store = SessionStore(directory: sessionsDir)
        let workspace = WorkspaceStore(directory: workspaceDir)
        let model = DocumentModel()
        let coord = SessionsAppCoordinator(
            model: model, store: store, workspace: workspace,
            initialRoot: nil
        )
        coord.bootstrap()
        return coord
    }

    // MARK: openTabs persistence on session switch ---------------------

    /// The headline bug. Open two sessions, each with a tab; switch
    /// back and forth; assert both sessions keep their tab.
    func test_switchSessions_preservesOpenTabsInEachSession() {
        let coord = makeCoordinator()
        let (folderA, filesA) = makeWorkspace(
            named: "A", files: ["a1.md", "a2.md"])
        let (folderB, filesB) = makeWorkspace(
            named: "B", files: ["b1.md", "b2.md"])

        // Open session A + tabs.
        coord.openFolder(folderA, forceNew: true)
        coord.model.appendLazyTab(url: filesA[0], viewMode: .source)
        coord.model.appendLazyTab(url: filesA[1], viewMode: .source)
        XCTAssertEqual(coord.model.tabs.tabs.count, 2,
            "session A should have 2 tabs after appending")
        let aID = coord.core.activeID

        // Open session B + a different tab — this switches coords away
        // from A.
        coord.openFolder(folderB, forceNew: true)
        coord.model.appendLazyTab(url: filesB[0], viewMode: .source)
        XCTAssertEqual(coord.model.tabs.tabs.count, 1,
            "session B should have 1 tab; A's tabs must not leak")
        let bID = coord.core.activeID

        // Back to A. Tabs should reappear.
        XCTAssertNotNil(aID)
        coord.activate(id: aID!)
        XCTAssertEqual(coord.model.tabs.tabs.count, 2,
            "switching back to A must restore A's 2 tabs (bug: empty)")
        XCTAssertEqual(
            coord.model.tabs.tabs.compactMap { $0.url?.lastPathComponent },
            ["a1.md", "a2.md"])

        // And once more to B. B's tab should also be intact.
        coord.activate(id: bID!)
        XCTAssertEqual(coord.model.tabs.tabs.count, 1)
        XCTAssertEqual(
            coord.model.tabs.tabs.first?.url?.lastPathComponent, "b1.md")
    }

    func test_switchSessions_preservesSelectedTabIndex() {
        let coord = makeCoordinator()
        let (folderA, filesA) = makeWorkspace(
            named: "A", files: ["a1.md", "a2.md", "a3.md"])
        let (folderB, _) = makeWorkspace(named: "B", files: ["b1.md"])

        coord.openFolder(folderA, forceNew: true)
        for u in filesA { coord.model.appendLazyTab(url: u, viewMode: .source) }
        // Select the middle tab.
        coord.model.selectTab(at: 1)
        XCTAssertEqual(coord.model.tabs.selectedIndex, 1)
        let aID = coord.core.activeID!

        coord.openFolder(folderB, forceNew: true)
        coord.activate(id: aID)

        XCTAssertEqual(coord.model.tabs.selectedIndex, 1,
            "selectedTabIndex must round-trip across a session switch")
    }

    // MARK: Other per-session state ------------------------------------

    func test_switchSessions_preservesSidebarRoot() {
        let coord = makeCoordinator()
        let (folderA, _) = makeWorkspace(named: "A", files: [])
        let (folderB, _) = makeWorkspace(named: "B", files: [])

        coord.openFolder(folderA, forceNew: true)
        let aID = coord.core.activeID!
        coord.openFolder(folderB, forceNew: true)
        coord.activate(id: aID)

        XCTAssertEqual(
            coord.model.sidebar.rootURL?.standardizedFileURL.path,
            folderA.standardizedFileURL.path,
            "sidebar root must point at session A's folder after switching back")
    }

    func test_switchSessions_preservesZoom() {
        let coord = makeCoordinator()
        let (folderA, _) = makeWorkspace(named: "A", files: [])
        let (folderB, _) = makeWorkspace(named: "B", files: [])

        coord.openFolder(folderA, forceNew: true)
        coord.model.zoom = 1.35
        let aID = coord.core.activeID!
        coord.openFolder(folderB, forceNew: true)
        coord.model.zoom = 0.85
        coord.activate(id: aID)
        XCTAssertEqual(coord.model.zoom, 1.35, accuracy: 0.001,
            "zoom must restore to A's last value (1.35) after switching back")
    }

    func test_switchSessions_preservesWordWrap() {
        let coord = makeCoordinator()
        let (folderA, _) = makeWorkspace(named: "A", files: [])
        let (folderB, _) = makeWorkspace(named: "B", files: [])

        coord.openFolder(folderA, forceNew: true)
        coord.model.sourceWordWrap = true
        let aID = coord.core.activeID!
        coord.openFolder(folderB, forceNew: true)
        coord.model.sourceWordWrap = false
        coord.activate(id: aID)
        XCTAssertTrue(coord.model.sourceWordWrap,
            "wordWrap must restore to A's last value (true) after switching back")
    }

    func test_switchSessions_preservesThemeOverride() {
        let coord = makeCoordinator()
        let (folderA, _) = makeWorkspace(named: "A", files: [])
        let (folderB, _) = makeWorkspace(named: "B", files: [])

        coord.openFolder(folderA, forceNew: true)
        coord.model.themeOverride = .xcodeLight
        let aID = coord.core.activeID!
        coord.openFolder(folderB, forceNew: true)
        coord.model.themeOverride = .xcodeDark
        coord.activate(id: aID)
        XCTAssertEqual(coord.model.themeOverride, .xcodeLight,
            "themeOverride must restore to A's last value (.xcodeLight) after switching back")
    }

    // MARK: View mode on individual tabs --------------------------------

    func test_switchSessions_preservesPerTabViewMode() {
        let coord = makeCoordinator()
        let (folderA, filesA) = makeWorkspace(
            named: "A", files: ["a.md", "b.json"])
        let (folderB, _) = makeWorkspace(named: "B", files: [])

        coord.openFolder(folderA, forceNew: true)
        coord.model.appendLazyTab(url: filesA[0], viewMode: .hex)
        coord.model.appendLazyTab(url: filesA[1], viewMode: .formatted)
        let aID = coord.core.activeID!

        coord.openFolder(folderB, forceNew: true)
        coord.activate(id: aID)

        XCTAssertEqual(coord.model.tabs.tabs[0].viewMode, .hex)
        XCTAssertEqual(coord.model.tabs.tabs[1].viewMode, .formatted)
    }

    // MARK: Edge cases -------------------------------------------------

    /// Activating the same session that's already active is a no-op —
    /// must not lose the live (unsaved-since-bootstrap) tab list.
    func test_activateSameSession_doesNotDropTabs() {
        let coord = makeCoordinator()
        let (folderA, filesA) = makeWorkspace(
            named: "A", files: ["a1.md"])
        coord.openFolder(folderA, forceNew: true)
        coord.model.appendLazyTab(url: filesA[0], viewMode: .source)
        let aID = coord.core.activeID!
        coord.activate(id: aID)   // no-op
        XCTAssertEqual(coord.model.tabs.tabs.count, 1)
    }

    /// Closing a non-active session must not touch the active
    /// session's tabs.
    func test_closeOtherSession_leavesActiveTabsIntact() {
        let coord = makeCoordinator()
        let (folderA, filesA) = makeWorkspace(
            named: "A", files: ["a1.md"])
        let (folderB, _) = makeWorkspace(named: "B", files: [])

        coord.openFolder(folderA, forceNew: true)
        coord.model.appendLazyTab(url: filesA[0], viewMode: .source)
        let aID = coord.core.activeID!
        coord.openFolder(folderB, forceNew: true)
        let bID = coord.core.activeID!
        // Now active = B. Closing A (the inactive one) must not affect
        // B's tabs (which is the new session, currently empty).
        coord.core.close(id: aID)
        XCTAssertEqual(coord.core.activeID, bID)
        XCTAssertEqual(coord.model.tabs.tabs.count, 0)
    }
}
