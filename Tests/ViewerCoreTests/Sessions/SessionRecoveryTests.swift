import XCTest
@testable import ViewerCore

/// Headless coverage for TSK-438 self-heal: when the session index is
/// empty/absent/corrupt but substantial snapshot files survive on disk (the
/// clobber outcome), `restore()` rebuilds the live list + index from them.
/// Stubs (no open tabs, or a root that no longer exists) and intentionally
/// closed sessions (no live snapshot) must NOT be resurrected.
@MainActor
final class SessionRecoveryTests: XCTestCase {

    private lazy var dir: URL = {
        let u = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-recover-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(
            at: u.appendingPathComponent("trash"), withIntermediateDirectories: true)
        return u
    }()
    private lazy var store = SessionStore(directory: dir)
    private lazy var rec = RecLifecycle()
    private lazy var coord = SessionsCoordinator(store: store, lifecycle: rec)

    private func realRoot(_ name: String) -> URL {
        let u = dir.appendingPathComponent("root-\(name)", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    @discardableResult
    private func writeSnapshot(root: URL?, tabs: [TabSnapshot],
                              lastActive: Date = Date()) -> SessionSnapshot {
        let snap = SessionSnapshot(
            id: UUID(),
            displayName: root?.lastPathComponent ?? "x",
            createdAt: Date.distantPast,
            lastActiveAt: lastActive,
            sidebarRootPath: root?.path,
            openTabs: tabs,
            selectedTabIndex: tabs.isEmpty ? nil : 0)
        store.saveSync(snap)
        return snap
    }

    func test_recoversSubstantialSnapshot_whenIndexAbsent() {
        let root = realRoot("alpha")
        let want = writeSnapshot(root: root,
                                 tabs: [TabSnapshot(path: root.appendingPathComponent("a.md").path,
                                                    viewMode: "rendered")])
        // No index.json written → .absent. Snapshot lives on disk.
        coord.restore()
        XCTAssertEqual(coord.sessions.map(\.id), [want.id], "lost session should self-heal")
        XCTAssertEqual(coord.activeID, want.id)
        // Index rebuilt + persisted so next launch is clean.
        XCTAssertEqual(store.loadIndex()?.sessions.map(\.id), [want.id])
        XCTAssertTrue(rec.mounted.contains(want.id), "recovered active session must mount")
    }

    func test_skipsStubs_noTabs_andDeadRoot() {
        let root = realRoot("real")
        let good = writeSnapshot(root: root,
                                 tabs: [TabSnapshot(path: root.appendingPathComponent("x.md").path,
                                                    viewMode: "rendered")])
        writeSnapshot(root: root.appendingPathComponent("x.md"),   // has tabs but...
                      tabs: [])                                     // no tabs → stub
        writeSnapshot(root: URL(fileURLWithPath: "/nope/gone-\(UUID().uuidString)"),
                      tabs: [TabSnapshot(path: "/nope/x.md", viewMode: "rendered")]) // dead root
        coord.restore()
        XCTAssertEqual(coord.sessions.map(\.id), [good.id],
                       "only the substantial, live-root session recovers")
    }

    func test_noLiveSnapshots_staysEmpty() {
        coord.restore()
        XCTAssertTrue(coord.sessions.isEmpty)
        XCTAssertNil(coord.activeID)
    }

    func test_dedupesByRoot_newestWins() {
        let root = realRoot("dup")
        let older = writeSnapshot(root: root,
                                  tabs: [TabSnapshot(path: root.appendingPathComponent("a").path, viewMode: "rendered")],
                                  lastActive: Date(timeIntervalSince1970: 1000))
        let newer = writeSnapshot(root: root,
                                  tabs: [TabSnapshot(path: root.appendingPathComponent("b").path, viewMode: "rendered")],
                                  lastActive: Date(timeIntervalSince1970: 9000))
        coord.restore()
        XCTAssertEqual(coord.sessions.map(\.id), [newer.id],
                       "same root → keep the most-recently-active snapshot only")
        XCTAssertNotEqual(coord.sessions.first?.id, older.id)
    }
}

@MainActor
private final class RecLifecycle: SessionsCoordinator.Lifecycle {
    var mounted: [UUID] = []
    func mount(_ session: SessionSnapshot)  { mounted.append(session.id) }
    func detach(_ session: SessionSnapshot) {}
}
