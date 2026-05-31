import XCTest
@testable import ViewerCore
import ViewerKit

/// Persistence-layer tests for `SessionStore`. Covers:
///
///   - Sync read/write round-trip + missing-file → nil.
///   - The serial-queue write coalescer: a burst of enqueueSave calls
///     to the same UUID collapses to a single disk write, and the
///     last-enqueued value wins.
///   - `flushSync()` actually waits for queued writes (regression
///     test for the `applicationWillTerminate` contract).
///   - Future-schema refusal: a v2 reader given a v3 file returns nil
///     rather than silently truncating the file's newer fields.
///   - Trash staging + 30-day TTL sweep.
///
/// All tests use a fresh `tmp/mdv-session-tests-<uuid>/` per-class
/// instance (cleaned up in tearDown). Per CLAUDE.md we never touch
/// `~/Library/Application Support` from automation; all FS state lives
/// under the per-user `temporaryDirectory`.
final class SessionStoreTests: XCTestCase {

    private var tmp: URL!
    private var store: SessionStore!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mdv-session-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp, withIntermediateDirectories: true
        )
        store = SessionStore(directory: tmp)
    }

    override func tearDownWithError() throws {
        // Drain anything we enqueued during the test so a slow coalescer
        // dispatch doesn't write into the tmp dir after we've removed
        // it. `flushSync()` returns once every previously-enqueued
        // block has run.
        store.flushSync()
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: Sync round-trip ------------------------------------------

    func testSaveSyncRoundtripsSnapshot() {
        let id = UUID()
        let snap = SessionSnapshot(
            id: id, displayName: "X",
            createdAt: Date(), lastActiveAt: Date(),
            sidebarRootPath: "/p",
            openTabs: [TabSnapshot(path: "/p/a.md", viewMode: "rendered")],
            selectedTabIndex: 0
        )
        XCTAssertTrue(store.saveSync(snap))
        let loaded = store.load(id: id)
        XCTAssertEqual(loaded?.id, id)
        XCTAssertEqual(loaded?.displayName, "X")
        XCTAssertEqual(loaded?.openTabs.count, 1)
    }

    func testLoadMissingReturnsNil() {
        XCTAssertNil(store.load(id: UUID()))
        XCTAssertNil(store.loadIndex())
    }

    func testIndexSyncRoundtrip() {
        let id = UUID()
        let idx = SessionIndex(
            sessions: [.init(id: id, rootPath: "/x",
                             displayName: "X", lastActiveAt: Date())],
            lastActiveID: id
        )
        XCTAssertTrue(store.saveIndexSync(idx))
        let back = store.loadIndex()
        XCTAssertEqual(back?.sessions.count, 1)
        XCTAssertEqual(back?.lastActiveID, id)
    }

    // MARK: Future-schema refusal ------------------------------------

    func testLoadRefusesNewerSnapshotSchema() throws {
        // Write a hand-crafted v3 JSON. The v2 reader must return nil
        // rather than decode-and-truncate on the next save (which would
        // silently destroy the v3 fields).
        let id = UUID()
        let url = tmp.appendingPathComponent("\(id.uuidString).json")
        let v3JSON = """
        {
          "schemaVersion": 99,
          "savedAt": "2030-01-01T00:00:00Z",
          "id": "\(id.uuidString)",
          "displayName": "Future",
          "createdAt": "2030-01-01T00:00:00Z",
          "lastActiveAt": "2030-01-01T00:00:00Z",
          "sidebarRootPath": "/p",
          "openTabs": [],
          "selectedTabIndex": null
        }
        """.data(using: .utf8)!
        try v3JSON.write(to: url)
        XCTAssertNil(store.load(id: id),
                     "v2 reader must refuse a v99 snapshot, not silently truncate")
    }

    func testLoadIndexRefusesNewerIndexSchema() throws {
        let v99JSON = """
        { "version": 99, "sessions": [], "lastActiveID": null }
        """.data(using: .utf8)!
        try v99JSON.write(to: tmp.appendingPathComponent("index.json"))
        XCTAssertNil(store.loadIndex())
    }

    // MARK: PERSIST-03 — classify the index load outcome ----------------

    func testLoadIndexResultAbsentWhenMissing() {
        XCTAssertEqual(store.loadIndexResult(), .absent)
    }

    func testLoadIndexResultLoadedForValidIndex() throws {
        let id = UUID()
        store.saveIndexSync(SessionIndex(
            sessions: [.init(id: id, rootPath: "/x", displayName: "X", lastActiveAt: Date())],
            lastActiveID: id
        ))
        guard case .loaded(let idx) = store.loadIndexResult() else {
            return XCTFail("expected .loaded")
        }
        XCTAssertEqual(idx.sessions.count, 1)
    }

    func testLoadIndexResultNewerSchemaForFutureVersion() throws {
        let v99JSON = """
        { "version": 99, "sessions": [], "lastActiveID": null }
        """.data(using: .utf8)!
        try v99JSON.write(to: tmp.appendingPathComponent("index.json"))
        XCTAssertEqual(store.loadIndexResult(), .newerSchema(foundVersion: 99))
    }

    func testLoadIndexResultNewerSchemaEvenWhenRequiredFieldsDrift() throws {
        // A newer build dropped/renamed a required field, so the full
        // SessionIndex decode fails — but the version probe still reads
        // 99. We must classify this as newerSchema, NOT corrupt, so the
        // coordinator blocks the overwrite (PERSIST-03/04).
        let weird = """
        { "version": 99, "totallyNewField": 7 }
        """.data(using: .utf8)!
        try weird.write(to: tmp.appendingPathComponent("index.json"))
        XCTAssertEqual(store.loadIndexResult(), .newerSchema(foundVersion: 99))
    }

    func testLoadIndexResultCorruptForGarbage() throws {
        try Data("not json".utf8).write(to: tmp.appendingPathComponent("index.json"))
        XCTAssertEqual(store.loadIndexResult(), .corrupt)
    }

    func testLoadIndexResultCorruptForTruncatedJSON() throws {
        try Data(#"{ "version": 1, "sessions": ["#.utf8)
            .write(to: tmp.appendingPathComponent("index.json"))
        XCTAssertEqual(store.loadIndexResult(), .corrupt)
    }

    // MARK: PERSIST-08 — truncated / partial / wrong-shape snapshots ----

    func testLoadTruncatedSnapshotReturnsNil() throws {
        let id = UUID()
        let url = tmp.appendingPathComponent("\(id.uuidString).json")
        try Data(#"{ "schemaVersion": 2, "id": "#.utf8).write(to: url)
        XCTAssertNil(store.load(id: id))
    }

    func testLoadZeroByteSnapshotReturnsNil() throws {
        let id = UUID()
        try Data().write(to: tmp.appendingPathComponent("\(id.uuidString).json"))
        XCTAssertNil(store.load(id: id))
    }

    func testLoadWrongShapeSnapshotReturnsNil() throws {
        let id = UUID()
        // An array where an object is expected.
        try Data("[]".utf8).write(to: tmp.appendingPathComponent("\(id.uuidString).json"))
        XCTAssertNil(store.load(id: id))
    }

    func testLoadStringSchemaVersionReturnsNil() throws {
        // schemaVersion as a string instead of an int → decode fails.
        let id = UUID()
        let url = tmp.appendingPathComponent("\(id.uuidString).json")
        let json = """
        {
          "schemaVersion": "two",
          "savedAt": "2026-01-01T00:00:00Z",
          "id": "\(id.uuidString)",
          "displayName": "X",
          "createdAt": "2026-01-01T00:00:00Z",
          "lastActiveAt": "2026-01-01T00:00:00Z",
          "sidebarRootPath": "/p",
          "openTabs": [],
          "selectedTabIndex": null
        }
        """
        try json.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertNil(store.load(id: id))
    }

    // MARK: Coalescing + flush ---------------------------------------

    func testCoalescerCollapsesBurstToSingleValue() {
        let id = UUID()
        // Enqueue 50 snapshots in rapid succession — each carries a
        // bumped `selectedTabIndex` so we can verify the *last* value
        // is the one on disk after flush. The coalescer should fold
        // everything in between into nothing.
        for i in 0..<50 {
            let snap = SessionSnapshot(
                id: id, displayName: "burst-\(i)",
                createdAt: Date(), lastActiveAt: Date(),
                sidebarRootPath: "/p",
                openTabs: [],
                selectedTabIndex: i
            )
            store.enqueueSave(snap)
        }
        store.flushSync()
        let loaded = store.load(id: id)
        XCTAssertNotNil(loaded)
        // The very last value (index 49) wins. The interesting property
        // isn't just "some value lands" — it's that the coalescer
        // doesn't drop the most-recent enqueue in favor of an older one.
        XCTAssertEqual(loaded?.selectedTabIndex, 49)
        XCTAssertEqual(loaded?.displayName, "burst-49")
    }

    func testFlushSyncWaitsForQueuedWrites() {
        // The contract: by the time flushSync() returns, every
        // previously-enqueued write is on disk. Verify by enqueueing
        // and immediately reading post-flush (no sleep / no polling).
        let id = UUID()
        let snap = SessionSnapshot(
            id: id, displayName: "flushed",
            createdAt: Date(), lastActiveAt: Date(),
            sidebarRootPath: "/p", openTabs: [], selectedTabIndex: nil
        )
        store.enqueueSave(snap)
        store.flushSync()
        // No retry, no asyncAfter — flushSync must guarantee the read
        // sees the write.
        XCTAssertEqual(store.load(id: id)?.displayName, "flushed")
    }

    // PERSIST-07: the terminate sequence is "enqueue latest state, then
    // flushSync". flushSync must land the just-enqueued value on disk
    // with no sleep/poll — including the index, which is enqueued
    // alongside per-session snapshots.
    func testFlushSyncLandsFinalStateForIndexAndSnapshotTogether() {
        let id = UUID()
        store.enqueueSaveIndex(SessionIndex(
            sessions: [.init(id: id, rootPath: "/p", displayName: "final",
                             lastActiveAt: Date())],
            lastActiveID: id
        ))
        store.enqueueSave(SessionSnapshot(
            id: id, displayName: "final-snap",
            createdAt: Date(), lastActiveAt: Date(),
            sidebarRootPath: "/p", openTabs: [], selectedTabIndex: 0
        ))
        store.flushSync()
        XCTAssertEqual(store.loadIndex()?.sessions.first?.displayName, "final")
        XCTAssertEqual(store.load(id: id)?.displayName, "final-snap")
    }

    // PERSIST-07: calling flushSync twice in a row must be safe and
    // idempotent (the fixpoint loop must terminate when nothing is
    // pending).
    func testFlushSyncIsIdempotent() {
        let id = UUID()
        store.enqueueSave(SessionSnapshot(
            id: id, displayName: "x",
            createdAt: Date(), lastActiveAt: Date(),
            sidebarRootPath: "/p", openTabs: [], selectedTabIndex: nil
        ))
        store.flushSync()
        store.flushSync()  // must not hang or re-error
        XCTAssertEqual(store.load(id: id)?.displayName, "x")
    }

    func testCoalescingIsPerURL() {
        // Two different UUIDs should NOT coalesce against each other.
        // Enqueue both, flush once, both files must be present.
        let idA = UUID(), idB = UUID()
        let snapA = SessionSnapshot(
            id: idA, displayName: "A",
            createdAt: Date(), lastActiveAt: Date(),
            sidebarRootPath: "/a", openTabs: [], selectedTabIndex: nil
        )
        let snapB = SessionSnapshot(
            id: idB, displayName: "B",
            createdAt: Date(), lastActiveAt: Date(),
            sidebarRootPath: "/b", openTabs: [], selectedTabIndex: nil
        )
        store.enqueueSave(snapA)
        store.enqueueSave(snapB)
        store.flushSync()
        XCTAssertEqual(store.load(id: idA)?.displayName, "A")
        XCTAssertEqual(store.load(id: idB)?.displayName, "B")
    }

    func testEnqueueSaveIndexCoalesces() {
        // Same property at the index level: 20 enqueues, last value wins.
        for i in 0..<20 {
            let idx = SessionIndex(
                sessions: [
                    .init(id: UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", i))")!,
                          rootPath: "/p",
                          displayName: "burst-\(i)",
                          lastActiveAt: Date())
                ],
                lastActiveID: nil
            )
            store.enqueueSaveIndex(idx)
        }
        store.flushSync()
        let loaded = store.loadIndex()
        XCTAssertEqual(loaded?.sessions.first?.displayName, "burst-19")
    }

    // MARK: Trash + TTL ----------------------------------------------

    func testMoveToTrashMovesFileAndSurvivesLoad() {
        let id = UUID()
        let snap = SessionSnapshot(
            id: id, displayName: "trashable",
            createdAt: Date(), lastActiveAt: Date(),
            sidebarRootPath: "/p", openTabs: [], selectedTabIndex: nil
        )
        store.saveSync(snap)
        XCTAssertNotNil(store.load(id: id))

        store.moveToTrash(id: id)
        // Live file gone, trashed file present.
        XCTAssertNil(store.load(id: id))
        let trashURL = tmp.appendingPathComponent("trash")
            .appendingPathComponent("\(id.uuidString).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashURL.path))
    }

    func testMoveToTrashOverwritesPriorTrashedFile() {
        // Close-then-restore-then-close-again cycle: the second trash
        // must replace, not error out. We don't expose "restore" yet,
        // but the destination-already-exists branch needs the same
        // safety.
        let id = UUID()
        let snap = SessionSnapshot(
            id: id, displayName: "v1",
            createdAt: Date(), lastActiveAt: Date(),
            sidebarRootPath: "/p", openTabs: [], selectedTabIndex: nil
        )
        store.saveSync(snap)
        store.moveToTrash(id: id)
        // Write again (simulating restore + re-close), trash again.
        store.saveSync(snap)
        store.moveToTrash(id: id)
        let trashURL = tmp.appendingPathComponent("trash")
            .appendingPathComponent("\(id.uuidString).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashURL.path))
    }

    func testMoveToTrashMissingFileIsSilent() {
        // Closing a never-saved session must not crash or throw.
        store.moveToTrash(id: UUID())
    }

    func testEmptyTrashSweepRespectsTTL() throws {
        let trash = tmp.appendingPathComponent("trash")
        let fm = FileManager.default
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)

        // Two trashed files: one fresh, one 60 days old.
        let oldURL = trash.appendingPathComponent(
            "\(UUID().uuidString).json")
        let freshURL = trash.appendingPathComponent(
            "\(UUID().uuidString).json")
        try Data("{}".utf8).write(to: oldURL)
        try Data("{}".utf8).write(to: freshURL)

        let sixtyDaysAgo = Date().addingTimeInterval(-60 * 86_400)
        try fm.setAttributes(
            [.modificationDate: sixtyDaysAgo], ofItemAtPath: oldURL.path
        )

        // 30-day cutoff: the 60-day-old one must be deleted; the fresh
        // one must survive.
        store.emptyTrashOlderThan(30)
        XCTAssertFalse(fm.fileExists(atPath: oldURL.path),
                       "60-day-old trash file should be swept")
        XCTAssertTrue(fm.fileExists(atPath: freshURL.path),
                      "fresh trash file should survive")
    }

    func testEmptyTrashOnEmptyDirectoryIsNoOp() {
        // No-op rather than throwing — emptyTrashOlderThan is called on
        // every launch, and a fresh install hasn't created trash/ yet.
        let untouched = SessionStore(directory: tmp.appendingPathComponent("blank"))
        untouched.emptyTrashOlderThan(30)
    }

}
