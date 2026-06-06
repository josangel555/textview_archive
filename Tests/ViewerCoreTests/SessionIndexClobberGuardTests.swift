import XCTest
@testable import ViewerCore

/// Headless coverage for the session-index clobber guard (TSK-438): the store
/// must refuse to persist an EMPTY index while per-session snapshot files still
/// live on disk — that exact write made the whole session-tab strip vanish on
/// the owner's machine (empty `index.json` next to ~40 intact snapshots).
final class SessionIndexClobberGuardTests: XCTestCase {

    private var dir: URL!
    private var store: SessionStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-sess-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("trash"), withIntermediateDirectories: true)
        store = SessionStore(directory: dir)
    }

    override func tearDownWithError() throws {
        store.flushSync()
        try? FileManager.default.removeItem(at: dir)
    }

    private func touchSnapshot(_ id: UUID, inTrash: Bool = false) throws {
        let base: URL = inTrash ? dir.appendingPathComponent("trash") : dir
        try Data("{}".utf8).write(to: base.appendingPathComponent("\(id.uuidString).json"))
    }

    private func index(_ ids: [UUID]) -> SessionIndex {
        SessionIndex(sessions: ids.map {
            .init(id: $0, rootPath: "/tmp/x", displayName: "x", lastActiveAt: .distantPast)
        }, lastActiveID: ids.first)
    }

    func test_liveSnapshotIDs_listsSnapshots_excludesIndexAndTrash() throws {
        let a = UUID(), b = UUID(), trashed = UUID()
        try touchSnapshot(a)
        try touchSnapshot(b)
        try touchSnapshot(trashed, inTrash: true)
        store.saveIndexSync(index([a, b]))   // writes index.json — must be excluded
        let live = Set(store.liveSnapshotIDs())
        XCTAssertEqual(live, [a, b])
        XCTAssertFalse(live.contains(trashed), "trashed snapshots are not live")
    }

    func test_emptyIndex_refused_whenSnapshotsLive_priorIndexPreserved() throws {
        let a = UUID()
        try touchSnapshot(a)
        XCTAssertTrue(store.saveIndexSync(index([a])), "non-empty write should succeed")
        // The clobber: try to persist an empty list while a's snapshot still lives.
        XCTAssertFalse(store.saveIndexSync(SessionIndex(sessions: [])),
                       "empty index must be REFUSED while snapshots live")
        // Prior non-empty index survives → strip won't vanish on next launch.
        XCTAssertEqual(store.loadIndex()?.sessions.map(\.id), [a])
    }

    func test_emptyIndex_allowed_whenNoSnapshots() {
        // Genuine "closed the last session": snapshot already trashed → no live
        // snapshots → empty write proceeds.
        XCTAssertTrue(store.saveIndexSync(SessionIndex(sessions: [])))
        XCTAssertEqual(store.loadIndex()?.sessions.count, 0)
    }

    func test_nonEmptyIndex_alwaysAllowed_evenWithSnapshots() throws {
        let a = UUID(), b = UUID()
        try touchSnapshot(a)
        XCTAssertTrue(store.saveIndexSync(index([a, b])))
        XCTAssertEqual(store.loadIndex()?.sessions.count, 2)
    }

    func test_enqueueEmptyIndex_refused_whenSnapshotsLive() throws {
        let a = UUID()
        try touchSnapshot(a)
        store.saveIndexSync(index([a]))
        store.enqueueSaveIndex(SessionIndex(sessions: []))   // should be dropped
        store.flushSync()
        XCTAssertEqual(store.loadIndex()?.sessions.map(\.id), [a],
                       "enqueued empty clobber must not reach disk")
    }
}
