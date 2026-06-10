import XCTest
import ViewerCore
import ViewerKit
@testable import ViewerUI

/// T1m isolation tests for the SESSIONS refactor (#184).
///
/// These pin the per-session-independence guarantee on the surface the
/// refactor newly carries per-session — sidebar expansion, include-hidden,
/// split pane, and the shoulder-rail panel layout — plus the inverse: that
/// zoom / word-wrap / theme are SHARED (GLOBAL, owner LOCKED), and that
/// session types SEED a per-kind layout ONCE on creation without becoming
/// a live override.
///
/// Switching is exercised through the real `SessionsAppCoordinator`
/// (Phase-1 façade: one shared `DocumentModel`), so these tests catch the
/// shared-model "leak across switch" class as well as the round-trip.
///
/// Pure-logic; no NSApplication / NSWindow. Safe on host.
/// Filter: `swift test --filter ViewerUITests.SessionIsolation`
@MainActor
final class SessionIsolationTests: XCTestCase {

    private lazy var tmpRoot: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionIsolationTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true
        )
        return url
    }()

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpRoot)
    }

    /// Folder + named subfolders + files. Returns the root folder.
    @discardableResult
    private func makeWorkspace(named: String,
                              subdirs: [String] = [],
                              files: [String] = []) -> URL {
        let folder = tmpRoot.appendingPathComponent(named, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true)
        for d in subdirs {
            try? FileManager.default.createDirectory(
                at: folder.appendingPathComponent(d, isDirectory: true),
                withIntermediateDirectories: true)
        }
        for f in files {
            try? Data("// \(f)\n".utf8).write(to: folder.appendingPathComponent(f))
        }
        return folder
    }

    private func makeCoordinator() -> SessionsAppCoordinator {
        let storesDir = tmpRoot.appendingPathComponent("stores-\(UUID().uuidString)")
        let sessionsDir = storesDir.appendingPathComponent("Sessions")
        try? FileManager.default.createDirectory(
            at: sessionsDir, withIntermediateDirectories: true)
        let store = SessionStore(directory: sessionsDir)
        let coord = SessionsAppCoordinator(
            model: DocumentModel(), store: store, initialRoot: nil)
        coord.bootstrap()
        return coord
    }

    // MARK: Sidebar expansion is per-session ---------------------------

    func test_switchSessions_preservesSidebarExpansion_independently() {
        let coord = makeCoordinator()
        let folderA = makeWorkspace(named: "A", subdirs: ["src", "tests"])
        let folderB = makeWorkspace(named: "B", subdirs: ["lib"])

        coord.openFolder(folderA, forceNew: true)
        // Expand A/src (root is auto-expanded by setRoot).
        coord.model.sidebar.toggleExpansion(folderA.appendingPathComponent("src"))
        let aID = coord.core.activeID!
        XCTAssertTrue(coord.model.sidebar.isExpanded(folderA.appendingPathComponent("src")))

        coord.openFolder(folderB, forceNew: true)
        // B does not have A/src — and A's expansion must not leak.
        XCTAssertFalse(coord.model.sidebar.isExpanded(folderA.appendingPathComponent("src")),
            "A's expanded dir must not leak into B (shared-model leak guard)")
        coord.model.sidebar.toggleExpansion(folderB.appendingPathComponent("lib"))

        coord.activate(id: aID)
        XCTAssertTrue(coord.model.sidebar.isExpanded(folderA.appendingPathComponent("src")),
            "switching back to A must restore A's expanded dir")
        XCTAssertFalse(coord.model.sidebar.isExpanded(folderB.appendingPathComponent("lib")),
            "B's expansion must not bleed into A")
    }

    // MARK: include-hidden is ALWAYS ON (TSK-363) -----------------------

    func test_switchSessions_includeHidden_alwaysTrue() {
        let coord = makeCoordinator()
        let folderA = makeWorkspace(named: "A")
        let folderB = makeWorkspace(named: "B")

        coord.openFolder(folderA, forceNew: true)
        let aID = coord.core.activeID!

        // Simulate stale state (the eye toggle is gone — nothing in the UI
        // can do this anymore, but a pre-removal session could have).
        coord.model.sidebar.includeHidden = false

        coord.openFolder(folderB, forceNew: true)
        XCTAssertTrue(coord.model.sidebar.includeHidden,
            "hydrate must force include-hidden back ON — there is no button left to recover")

        coord.activate(id: aID)
        XCTAssertTrue(coord.model.sidebar.includeHidden,
            "A restores with include-hidden ON regardless of what it had before")
    }

    // MARK: split pane is per-session ----------------------------------

    func test_switchSessions_preservesSplit_independently() {
        let coord = makeCoordinator()
        let folderA = makeWorkspace(named: "A", files: ["a1.md", "a2.md"])
        let folderB = makeWorkspace(named: "B", files: ["b1.md"])
        let aSplit = folderA.appendingPathComponent("a2.md")

        coord.openFolder(folderA, forceNew: true)
        coord.model.appendLazyTab(url: folderA.appendingPathComponent("a1.md"), viewMode: .source)
        coord.model.openInSplit(aSplit)
        let aID = coord.core.activeID!
        XCTAssertEqual(coord.model.splitURL?.standardizedFileURL.resolvingSymlinksInPath().path,
                       aSplit.standardizedFileURL.resolvingSymlinksInPath().path)

        coord.openFolder(folderB, forceNew: true)
        // Leak guard: B has no split.
        XCTAssertNil(coord.model.splitURL,
            "B must start with no split; A's split must not leak")

        coord.activate(id: aID)
        XCTAssertEqual(coord.model.splitURL?.standardizedFileURL.resolvingSymlinksInPath().path,
                       aSplit.standardizedFileURL.resolvingSymlinksInPath().path,
            "switching back to A must restore A's split pane")
    }

    // MARK: panel layout is per-session --------------------------------

    func test_switchSessions_preservesPanelLayout_independently() {
        let coord = makeCoordinator()
        let folderA = makeWorkspace(named: "A")
        let folderB = makeWorkspace(named: "B")

        coord.openFolder(folderA, forceNew: true)
        // Give A an explicit override that differs from the default.
        coord.model.panelLayout.setOverride(.git, .shown)
        coord.model.panelLayout.setEdge(.bookmarks, .right)
        let aID = coord.core.activeID!
        let aSnapshot = coord.model.panelLayout.snapshot()

        coord.openFolder(folderB, forceNew: true)
        // Leak guard: B (a plain new project) starts at the default layout.
        XCTAssertTrue(coord.model.panelLayout.snapshot().isDefault,
            "B must start at the default panel layout; A's must not leak")
        // Give B a DIFFERENT override.
        coord.model.panelLayout.setOverride(.lspProblems, .hidden)

        coord.activate(id: aID)
        XCTAssertEqual(coord.model.panelLayout.snapshot(), aSnapshot,
            "switching back to A must restore A's full panel layout")
        XCTAssertEqual(coord.model.panelLayout.override(for: .lspProblems), .auto,
            "B's lspProblems override must not bleed into A")
    }

    // MARK: zoom / wrap / theme are SHARED (GLOBAL) --------------------

    func test_switchSessions_zoomWrapTheme_areShared_notPerSession() {
        let coord = makeCoordinator()
        let folderA = makeWorkspace(named: "A")
        let folderB = makeWorkspace(named: "B")

        coord.openFolder(folderA, forceNew: true)
        coord.model.zoom = 1.5
        coord.model.sourceWordWrap = true
        coord.model.themeOverride = .xcodeLight
        let aID = coord.core.activeID!

        coord.openFolder(folderB, forceNew: true)
        // GLOBAL: B sees A's app-wide values — they were NOT reset by the
        // switch (a session does not own zoom/wrap/theme).
        XCTAssertEqual(coord.model.zoom, 1.5, accuracy: 0.001,
            "zoom is GLOBAL — carries across the session switch")
        XCTAssertTrue(coord.model.sourceWordWrap, "wordWrap is GLOBAL")
        XCTAssertEqual(coord.model.themeOverride, .xcodeLight, "theme is GLOBAL")

        // Change them in B; switching back to A keeps the new app-wide value.
        coord.model.zoom = 0.9
        coord.model.sourceWordWrap = false
        coord.model.themeOverride = .xcodeDark
        coord.activate(id: aID)
        XCTAssertEqual(coord.model.zoom, 0.9, accuracy: 0.001,
            "zoom is GLOBAL — A does NOT restore its own 1.5")
        XCTAssertFalse(coord.model.sourceWordWrap, "wordWrap is GLOBAL — not restored per-session")
        XCTAssertEqual(coord.model.themeOverride, .xcodeDark, "theme is GLOBAL — not restored per-session")
    }

    // MARK: combined independence (all four together) ------------------

    func test_switchSessions_allPerSessionFields_independentTogether() {
        let coord = makeCoordinator()
        let folderA = makeWorkspace(named: "A", subdirs: ["src"], files: ["a1.md", "a2.md"])
        let folderB = makeWorkspace(named: "B", subdirs: ["lib"], files: ["b1.md"])

        // Session A: tab + split + expansion + panel override.
        coord.openFolder(folderA, forceNew: true)
        coord.model.appendLazyTab(url: folderA.appendingPathComponent("a1.md"), viewMode: .source)
        coord.model.openInSplit(folderA.appendingPathComponent("a2.md"))
        coord.model.sidebar.toggleExpansion(folderA.appendingPathComponent("src"))
        coord.model.panelLayout.setOverride(.git, .shown)
        let aID = coord.core.activeID!

        // Session B: a single tab, nothing else.
        coord.openFolder(folderB, forceNew: true)
        coord.model.appendLazyTab(url: folderB.appendingPathComponent("b1.md"), viewMode: .source)

        // B should be a clean slate for every per-session field.
        // (include-hidden is NOT per-session anymore — always true, TSK-363.)
        XCTAssertNil(coord.model.splitURL)
        XCTAssertTrue(coord.model.sidebar.includeHidden)
        XCTAssertFalse(coord.model.sidebar.isExpanded(folderA.appendingPathComponent("src")))
        XCTAssertTrue(coord.model.panelLayout.snapshot().isDefault)
        XCTAssertEqual(coord.model.tabs.tabs.compactMap { $0.url?.lastPathComponent }, ["b1.md"])

        // Back to A: everything restored.
        coord.activate(id: aID)
        XCTAssertEqual(coord.model.splitURL?.lastPathComponent, "a2.md")
        XCTAssertTrue(coord.model.sidebar.includeHidden)
        XCTAssertTrue(coord.model.sidebar.isExpanded(folderA.appendingPathComponent("src")))
        XCTAssertEqual(coord.model.panelLayout.override(for: .git), .shown)
        XCTAssertEqual(coord.model.tabs.tabs.compactMap { $0.url?.lastPathComponent }, ["a1.md"])
    }
}
