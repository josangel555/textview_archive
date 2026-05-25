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
    //
    // Trash-cycle coverage lives in `SessionStoreTests` (testMoveToTrash*)
    // — that file owns the deep tests including over-write semantics
    // and missing-file silence. The earlier duplicates here ran the
    // same store-level CRUD twice; removed during the 2026-05 audit.

    // MARK: - Legacy migration
    //
    // Legacy-snapshot bridging is owned by `SessionStoreTests`
    // (testMigrateLegacyReturnsValidSession) and the dedicated
    // `SessionsMigrationTests`. The two test_legacyMigration_* methods
    // here duplicated that coverage and were removed during the
    // 2026-05 audit.

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
