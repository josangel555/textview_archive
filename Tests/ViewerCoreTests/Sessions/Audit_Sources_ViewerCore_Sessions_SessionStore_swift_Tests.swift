import XCTest
@testable import ViewerCore
import ViewerKit

/// Regression tests for two audit findings in
/// `Sources/ViewerCore/Sessions/SessionStore.swift`:
///
///   - **S2 (security):** the index / snapshot reads now pass an explicit
///     `maxSize:` (`maxIndexFileSize` / `maxSnapshotFileSize`) so an
///     oversized / tampered file degrades to the existing nil /
///     `.corrupt` start-empty path instead of being inflated into RAM.
///   - **S3 (race):** `saveSync` / `saveIndexSync` route through the serial
///     `writeQueue.sync` after evicting any pending coalesced value for the
///     same URL, so a sync write can't be overwritten by an in-flight async
///     block and no stale coalesced value survives a later `flushSync`.
///
/// Headless-safe (T1): pure filesystem + dispatch, no GUI / no bundle.
/// Per CLAUDE.md all scratch lives under `temporaryDirectory`.
final class Audit_Sources_ViewerCore_Sessions_SessionStore_swift_Tests: XCTestCase {

    private var tmp: URL!
    private var store: SessionStore!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mdv-session-audit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp, withIntermediateDirectories: true
        )
        store = SessionStore(directory: tmp)
    }

    override func tearDownWithError() throws {
        store.flushSync()
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: S2 — oversized files refuse to inflate ----------------------

    func testOversizedIndexFileDoesNotLoad() throws {
        // A syntactically-valid index whose padded size exceeds
        // `maxIndexFileSize` must be refused (nil / .corrupt), not read
        // whole into memory. We inflate via a giant displayName string.
        let id = UUID()
        let bigName = String(repeating: "A",
                             count: SessionStore.maxIndexFileSize + 1024)
        let idx = SessionIndex(
            sessions: [.init(id: id, rootPath: "/p",
                             displayName: bigName, lastActiveAt: Date())],
            lastActiveID: id
        )
        // Write the bytes directly (bypassing the size guard on write) so
        // the file genuinely exceeds the cap on disk.
        let data = try JSONFileStore.encoder.encode(idx)
        XCTAssertGreaterThan(data.count, SessionStore.maxIndexFileSize,
                             "fixture must actually exceed the cap")
        try data.write(to: tmp.appendingPathComponent("index.json"))

        XCTAssertNil(store.loadIndex(),
                     "an index larger than maxIndexFileSize must not load")
        // The classifier sees a present-but-unreadable file → .corrupt
        // (the size guard makes both the full decode and the probe nil).
        XCTAssertEqual(store.loadIndexResult(), .corrupt,
                       "oversized index degrades to the .corrupt start-empty path")
    }

    func testOversizedSnapshotFileDoesNotLoad() throws {
        let id = UUID()
        let bigName = String(repeating: "B",
                             count: SessionStore.maxSnapshotFileSize + 1024)
        let snap = SessionSnapshot(
            id: id, displayName: bigName,
            createdAt: Date(), lastActiveAt: Date(),
            sidebarRootPath: "/p", openTabs: [], selectedTabIndex: nil
        )
        let data = try JSONFileStore.encoder.encode(snap)
        XCTAssertGreaterThan(data.count, SessionStore.maxSnapshotFileSize,
                             "fixture must actually exceed the cap")
        try data.write(to: tmp.appendingPathComponent("\(id.uuidString).json"))

        XCTAssertNil(store.load(id: id),
                     "a snapshot larger than maxSnapshotFileSize must not load")
    }

    func testNormalSizedFilesStillLoadUnderTheCap() {
        // The cap must not regress the happy path: an ordinary index +
        // snapshot are far under the limit and round-trip fine.
        let id = UUID()
        store.saveIndexSync(SessionIndex(
            sessions: [.init(id: id, rootPath: "/p",
                             displayName: "ok", lastActiveAt: Date())],
            lastActiveID: id
        ))
        store.saveSync(SessionSnapshot(
            id: id, displayName: "ok-snap",
            createdAt: Date(), lastActiveAt: Date(),
            sidebarRootPath: "/p", openTabs: [], selectedTabIndex: 0
        ))
        XCTAssertEqual(store.loadIndex()?.sessions.first?.displayName, "ok")
        XCTAssertEqual(store.load(id: id)?.displayName, "ok-snap")
    }

    // MARK: S3 — saveSync is coherent with the coalescing queue ---------

    func testSaveSyncWinsOverPendingCoalescedEnqueue() {
        // Enqueue a value (becomes pending + dispatches an async block for
        // this URL), then immediately saveSync a DIFFERENT value to the
        // same URL. Because saveSync evicts pending under coalesceLock and
        // writes inside writeQueue.sync, it serializes after the async
        // block AND removes the coalesced value — so the sync value is the
        // truth, and a later flushSync can't resurrect the stale enqueue.
        let id = UUID()
        let enqueued = SessionSnapshot(
            id: id, displayName: "stale-enqueued",
            createdAt: Date(), lastActiveAt: Date(),
            sidebarRootPath: "/p", openTabs: [], selectedTabIndex: 1
        )
        let synced = SessionSnapshot(
            id: id, displayName: "fresh-sync",
            createdAt: Date(), lastActiveAt: Date(),
            sidebarRootPath: "/p", openTabs: [], selectedTabIndex: 2
        )
        store.enqueueSave(enqueued)
        XCTAssertTrue(store.saveSync(synced))

        // saveSync drained the queue + cleared pending: the fresh value is
        // already on disk with no flush needed.
        XCTAssertEqual(store.load(id: id)?.displayName, "fresh-sync")
        XCTAssertEqual(store.load(id: id)?.selectedTabIndex, 2)

        // And flushSync must NOT bring the stale coalesced value back.
        store.flushSync()
        XCTAssertEqual(store.load(id: id)?.displayName, "fresh-sync",
                       "evicted coalesced value must not survive flushSync")
    }

    func testSaveIndexSyncWinsOverPendingCoalescedEnqueue() {
        let id = UUID()
        store.enqueueSaveIndex(SessionIndex(
            sessions: [.init(id: id, rootPath: "/p",
                             displayName: "stale-idx", lastActiveAt: Date())],
            lastActiveID: id
        ))
        XCTAssertTrue(store.saveIndexSync(SessionIndex(
            sessions: [.init(id: id, rootPath: "/p",
                             displayName: "fresh-idx", lastActiveAt: Date())],
            lastActiveID: id
        )))

        XCTAssertEqual(store.loadIndex()?.sessions.first?.displayName, "fresh-idx")
        store.flushSync()
        XCTAssertEqual(store.loadIndex()?.sessions.first?.displayName, "fresh-idx",
                       "evicted coalesced index value must not survive flushSync")
    }

    func testSaveSyncStillRoundtripsWithNoPendingWrite() {
        // The simple case: no contending enqueue, saveSync still works.
        let id = UUID()
        XCTAssertTrue(store.saveSync(SessionSnapshot(
            id: id, displayName: "plain",
            createdAt: Date(), lastActiveAt: Date(),
            sidebarRootPath: "/p", openTabs: [], selectedTabIndex: nil
        )))
        XCTAssertEqual(store.load(id: id)?.displayName, "plain")
    }
}
