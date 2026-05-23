import XCTest
@testable import ViewerCore

/// Restart-cycle persistence at the SessionStore level.
///
/// The full `SessionsAppCoordinator` restart path is exercised by
/// `Tests/ViewerUITests/Sessions/SessionTabPersistenceTests.swift`
/// (host-integration); these tests focus on the underlying
/// `SessionStore` + `SessionSnapshot` round-trip — what's actually on
/// disk between launches.
final class SessionTabPersistenceRestartTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionRestart-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func makeStore() -> SessionStore {
        SessionStore(directory: tmp)
    }

    // MARK: - Single-session round trip

    func test_singleSession_restoredOnNextLaunch() throws {
        let storeA = makeStore()
        let snap = SessionSnapshot(
            id: UUID(),
            displayName: "Proj",
            createdAt: Date(),
            lastActiveAt: Date(),
            sidebarRootPath: "/some/path",
            openTabs: [
                TabSnapshot(path: "/some/path/a.md", viewMode: "source"),
                TabSnapshot(path: "/some/path/b.md", viewMode: "rendered"),
            ],
            selectedTabIndex: 1
        )
        XCTAssertTrue(storeA.saveSync(snap))
        let idx = SessionIndex(
            sessions: [.init(id: snap.id, rootPath: "/some/path",
                             displayName: "Proj",
                             lastActiveAt: snap.lastActiveAt)],
            lastActiveID: snap.id)
        XCTAssertTrue(storeA.saveIndexSync(idx))

        // Simulate quit-and-restart: new SessionStore pointing at the
        // same directory. The new instance must see the persisted state.
        let storeB = makeStore()
        let loadedIdx = storeB.loadIndex()
        XCTAssertEqual(loadedIdx?.sessions.count, 1)
        XCTAssertEqual(loadedIdx?.lastActiveID, snap.id)
        let loadedSnap = storeB.load(id: snap.id)
        XCTAssertEqual(loadedSnap?.displayName, "Proj")
        XCTAssertEqual(loadedSnap?.openTabs.count, 2)
        XCTAssertEqual(loadedSnap?.openTabs.map(\.path),
                       ["/some/path/a.md", "/some/path/b.md"])
        XCTAssertEqual(loadedSnap?.selectedTabIndex, 1)
        XCTAssertEqual(loadedSnap?.sidebarRootPath, "/some/path")
    }

    // MARK: - Multi-session round trip

    func test_multipleSessions_restoredInOrder() throws {
        let store = makeStore()
        let s1 = SessionSnapshot(id: UUID(), displayName: "Alpha",
                                 createdAt: Date(), lastActiveAt: Date(),
                                 sidebarRootPath: "/a")
        let s2 = SessionSnapshot(id: UUID(), displayName: "Beta",
                                 createdAt: Date(), lastActiveAt: Date(),
                                 sidebarRootPath: "/b")
        _ = store.saveSync(s1)
        _ = store.saveSync(s2)
        _ = store.saveIndexSync(SessionIndex(
            sessions: [
                .init(id: s1.id, rootPath: "/a", displayName: "Alpha", lastActiveAt: s1.lastActiveAt),
                .init(id: s2.id, rootPath: "/b", displayName: "Beta",  lastActiveAt: s2.lastActiveAt),
            ],
            lastActiveID: s2.id))

        let store2 = makeStore()
        let loaded = store2.loadIndex()
        XCTAssertEqual(loaded?.sessions.count, 2)
        XCTAssertEqual(loaded?.sessions.map(\.displayName), ["Alpha", "Beta"])
        XCTAssertEqual(loaded?.lastActiveID, s2.id)
    }

    // MARK: - moveToTrash semantics

    func test_moveToTrash_removesActiveFile() throws {
        let store = makeStore()
        let snap = SessionSnapshot(id: UUID(), displayName: "Doomed",
                                   createdAt: Date(), lastActiveAt: Date(),
                                   sidebarRootPath: "/x")
        _ = store.saveSync(snap)
        XCTAssertNotNil(store.load(id: snap.id))

        store.moveToTrash(id: snap.id)
        XCTAssertNil(store.load(id: snap.id), "live snapshot should be removed")
    }

    func test_moveToTrash_unknownID_isNoOp() {
        let store = makeStore()
        store.moveToTrash(id: UUID())  // not a real session
        XCTAssertNil(store.loadIndex())  // no side effects
    }

    // MARK: - Legacy migration

    func test_legacyMigration_buildsSessionFromWorkspaceSnapshot() throws {
        let legacy = WorkspaceSnapshot(
            sidebarRootPath: "/legacy/proj",
            openTabs: [
                TabSnapshot(path: "/legacy/proj/a.md", viewMode: "source"),
            ],
            selectedTabIndex: 0,
            zoom: 1.2,
            wordWrap: true,
            themeOverride: nil
        )
        let migrated = SessionSnapshot.fromLegacy(legacy)
        XCTAssertEqual(migrated.sidebarRootPath, "/legacy/proj")
        XCTAssertEqual(migrated.openTabs.count, 1)
        XCTAssertEqual(migrated.openTabs[0].path, "/legacy/proj/a.md")
        XCTAssertEqual(migrated.selectedTabIndex, 0)
        XCTAssertEqual(migrated.zoom, 1.2)
        XCTAssertEqual(migrated.wordWrap, true)
        // Display name derived from path's last component.
        XCTAssertEqual(migrated.displayName, "proj")
    }

    func test_legacyMigration_emptyRoot_namedDefault() {
        let legacy = WorkspaceSnapshot(
            sidebarRootPath: nil,
            openTabs: [],
            selectedTabIndex: nil,
            zoom: nil, wordWrap: nil, themeOverride: nil)
        let migrated = SessionSnapshot.fromLegacy(legacy)
        XCTAssertEqual(migrated.displayName, "Default")
    }

    // MARK: - saveIndex / loadIndex idempotency

    func test_saveIndex_overwritesExisting() throws {
        let store = makeStore()
        let id1 = UUID()
        _ = store.saveIndexSync(SessionIndex(
            sessions: [.init(id: id1, rootPath: "/a", displayName: "A",
                             lastActiveAt: Date())],
            lastActiveID: id1))
        XCTAssertEqual(store.loadIndex()?.sessions.count, 1)

        let id2 = UUID()
        _ = store.saveIndexSync(SessionIndex(
            sessions: [
                .init(id: id1, rootPath: "/a", displayName: "A",
                      lastActiveAt: Date()),
                .init(id: id2, rootPath: "/b", displayName: "B",
                      lastActiveAt: Date())
            ],
            lastActiveID: id2))
        XCTAssertEqual(store.loadIndex()?.sessions.count, 2)
        XCTAssertEqual(store.loadIndex()?.lastActiveID, id2)
    }

    func test_loadIndex_missing_returnsNil() {
        let store = makeStore()
        XCTAssertNil(store.loadIndex())
    }

    func test_load_unknownID_returnsNil() {
        let store = makeStore()
        XCTAssertNil(store.load(id: UUID()))
    }
}
