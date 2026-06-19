import XCTest
@testable import ViewerCore
import ViewerKit

/// Coordinator-level behavior tests. Drive the value-level
/// `SessionsCoordinator` through its public API and assert:
///
///   - openFolder creates-or-reveals (collapses two symlinks to the
///     same realpath into one session unless `forceNew`).
///   - activate / nextSession / previousSession honor the in-memory
///     ordering.
///   - close moves the snapshot to trash, updates the active pointer
///     to the LRU runner-up, and persists the new index.
///   - restore() reconstructs state from `index.json` and the
///     individual snapshot files.
///   - **Detach-before-mount invariant is preserved for every active
///     transition.** This is design-doc gap #2; we use a recording
///     `Lifecycle` stub to verify the exact ordering of mount/detach
///     calls.
///
/// Pure logic — no UI. Runs on host.
@MainActor
final class SessionsCoordinatorTests: XCTestCase {

    // Use `lazy var` for fixtures because Swift 6.1 rejects calls to
    // the non-isolated `super.setUp()` from a `@MainActor` test class
    // (see LESSONS.md — XCTestCase isn't Sendable). The lazy property
    // initializes on first access inside each test, where MainActor
    // context is already established.
    // Lazy initializers sidestep the Swift-6.1-vs-6.3 setUp isolation
    // divergence. On 6.1 (VM canary), class-level `@MainActor` doesn't
    // make `override func setUp()` actor-isolated, so accessing
    // `@MainActor`-isolated stored properties from setUp/tearDown is
    // rejected. Lazy vars owned by the MainActor-isolated class
    // get evaluated on first per-test access from a `@MainActor`
    // test method, which is what we want.
    private lazy var tmp: URL = {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mdv-coord-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true
        )
        return url
    }()
    private lazy var store: SessionStore = SessionStore(directory: tmp)
    private lazy var recorder: LifecycleRecorder = LifecycleRecorder()
    private lazy var coord: SessionsCoordinator =
        SessionsCoordinator(store: store, lifecycle: recorder)

    // tearDown stays nonisolated on 6.1 but we only touch values we
    // already evaluated; `flushSync()` on SessionStore is thread-safe.
    // Cleanup is best-effort — if a test never touched `tmp` the dir
    // was never created.
    override func tearDown() {
        // Re-create what we need without touching the @MainActor
        // properties — they may not have been initialized yet.
        super.tearDown()
    }

    // MARK: openFolder ------------------------------------------------

    func testOpenFolderCreatesNewSession() throws {
        let folder = try makeTmpFolder()
        let snap = coord.openFolder(folder)
        XCTAssertEqual(coord.sessions.count, 1)
        XCTAssertEqual(coord.activeID, snap.id)
        XCTAssertEqual(coord.active?.displayName, folder.lastPathComponent)
        // Lifecycle: nothing to detach (fresh), then mount the new one.
        XCTAssertEqual(recorder.events, [.mount(snap.id)])
    }

    func testOpenFolderCollapsesSamePathIntoExisting() throws {
        let folder = try makeTmpFolder()
        let first = coord.openFolder(folder)
        recorder.events.removeAll()
        let second = coord.openFolder(folder)
        // Same session reveals — no new entry, no extra mount.
        XCTAssertEqual(coord.sessions.count, 1)
        XCTAssertEqual(first.id, second.id)
        // activate() is a no-op when activeID==id, so no events.
        XCTAssertTrue(recorder.events.isEmpty)
    }

    func testForceNewBypassesPathMatch() throws {
        let folder = try makeTmpFolder()
        let first = coord.openFolder(folder)
        recorder.events.removeAll()
        let second = coord.openFolder(folder, forceNew: true)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(coord.sessions.count, 2)
        // Detach-before-mount on the active swap.
        XCTAssertEqual(recorder.events, [.detach(first.id), .mount(second.id)])
    }

    // MARK: activate --------------------------------------------------

    func testActivateSwitchesAndPreservesDetachBeforeMountOrder() throws {
        let a = try makeTmpFolder(name: "alpha")
        let b = try makeTmpFolder(name: "beta")
        let sA = coord.openFolder(a)
        let sB = coord.openFolder(b)
        XCTAssertEqual(coord.activeID, sB.id)
        recorder.events.removeAll()

        coord.activate(id: sA.id)
        // Strict ordering: outgoing detach FIRST, then incoming mount.
        // This is the design-doc-gap-#2 invariant: never mount-then-
        // detach (would briefly have two file watchers running).
        XCTAssertEqual(recorder.events, [.detach(sB.id), .mount(sA.id)])
        XCTAssertEqual(coord.activeID, sA.id)
    }

    /// S2-A: activate() bumps lastActiveAt on BOTH the outgoing AND
    /// the incoming session. Previously only the outgoing was bumped,
    /// so A → B → A then close(A) would re-activate B because A's
    /// timestamp was stale.
    func testActivateBumpsBothOutgoingAndIncomingLastActiveAt() throws {
        let a = try makeTmpFolder(name: "alpha")
        let b = try makeTmpFolder(name: "beta")
        let sA = coord.openFolder(a)
        let _  = coord.openFolder(b)  // sB becomes active
        // A → B already, switch back to A then close A.
        // Sleep tiny amount so timestamps are monotonically increasing
        // and the LRU sort has a stable distinction.
        Thread.sleep(forTimeInterval: 0.01)
        coord.activate(id: sA.id)
        // sA should now have the freshest lastActiveAt.
        let aSnap = coord.sessions.first(where: { $0.id == sA.id })!
        let bSnap = coord.sessions.first(where: { $0.displayName == "beta" })!
        XCTAssertGreaterThan(aSnap.lastActiveAt, bSnap.lastActiveAt,
            "incoming session must end up with the newest lastActiveAt")
    }

    func testActivateNoopWhenAlreadyActive() throws {
        let a = try makeTmpFolder()
        let sA = coord.openFolder(a)
        recorder.events.removeAll()
        coord.activate(id: sA.id)
        XCTAssertTrue(recorder.events.isEmpty)
    }

    func testActivateUnknownIDNoop() {
        let bogus = UUID()
        coord.activate(id: bogus)
        XCTAssertNil(coord.activeID)
        XCTAssertTrue(recorder.events.isEmpty)
    }

    func testActivateByIndex() throws {
        let a = try makeTmpFolder(name: "alpha")
        let b = try makeTmpFolder(name: "beta")
        _ = coord.openFolder(a)
        let sB = coord.openFolder(b)
        XCTAssertEqual(coord.activeID, sB.id)
        coord.activate(index: 0)
        XCTAssertEqual(coord.active?.displayName, "alpha")
        // Out-of-range silently ignored.
        coord.activate(index: 99)
        XCTAssertEqual(coord.active?.displayName, "alpha")
    }

    // MARK: navigation -----------------------------------------------

    func testNextAndPreviousWrapAroundCircularly() throws {
        let a = try makeTmpFolder(name: "alpha")
        let b = try makeTmpFolder(name: "beta")
        let c = try makeTmpFolder(name: "gamma")
        let sA = coord.openFolder(a)
        let sB = coord.openFolder(b)
        let sC = coord.openFolder(c)
        // Active is sC; next wraps to sA.
        coord.nextSession()
        XCTAssertEqual(coord.activeID, sA.id)
        coord.nextSession()
        XCTAssertEqual(coord.activeID, sB.id)
        coord.previousSession()
        XCTAssertEqual(coord.activeID, sA.id)
        coord.previousSession()  // wraps from index 0 back to sC
        XCTAssertEqual(coord.activeID, sC.id)
    }

    func testNextWithSingleSessionStaysPut() throws {
        let a = try makeTmpFolder()
        let sA = coord.openFolder(a)
        coord.nextSession()
        XCTAssertEqual(coord.activeID, sA.id)
    }

    // MARK: close ----------------------------------------------------

    func testCloseActiveSessionFallsBackToLRU() throws {
        let a = try makeTmpFolder(name: "alpha")
        let b = try makeTmpFolder(name: "beta")
        let sA = coord.openFolder(a)
        let sB = coord.openFolder(b)
        XCTAssertEqual(coord.activeID, sB.id)
        recorder.events.removeAll()

        coord.close(id: sB.id)
        XCTAssertEqual(coord.sessions.count, 1)
        XCTAssertEqual(coord.activeID, sA.id)
        // detach the closing one before mounting the runner-up.
        XCTAssertEqual(recorder.events, [.detach(sB.id), .mount(sA.id)])
        // Trash file present.
        let trashURL = tmp.appendingPathComponent("trash")
            .appendingPathComponent("\(sB.id.uuidString).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashURL.path))
    }

    func testCloseInactiveSessionDoesNotChangeActive() throws {
        let a = try makeTmpFolder(name: "alpha")
        let b = try makeTmpFolder(name: "beta")
        let sA = coord.openFolder(a)
        let sB = coord.openFolder(b)
        recorder.events.removeAll()
        coord.close(id: sA.id)
        XCTAssertEqual(coord.activeID, sB.id)
        // No detach/mount — we closed a background session.
        XCTAssertTrue(recorder.events.isEmpty)
    }

    func testCloseLastSessionClearsActive() throws {
        let a = try makeTmpFolder()
        let sA = coord.openFolder(a)
        coord.close(id: sA.id)
        XCTAssertNil(coord.activeID)
        XCTAssertTrue(coord.sessions.isEmpty)
    }

    func testCloseUnknownIDNoop() {
        coord.close(id: UUID())
        XCTAssertTrue(coord.sessions.isEmpty)
    }

    // MARK: restore --------------------------------------------------

    func testRestoreReconstructsFromDisk() throws {
        let a = try makeTmpFolder(name: "alpha")
        let b = try makeTmpFolder(name: "beta")
        let sA = coord.openFolder(a)
        let sB = coord.openFolder(b)
        // Force a sync write so the next coordinator sees them.
        coord.flushPersistenceSync()

        // Build a fresh coordinator against the same store.
        let recorder2 = LifecycleRecorder()
        let coord2 = SessionsCoordinator(store: store, lifecycle: recorder2)
        coord2.restore()

        XCTAssertEqual(coord2.sessions.count, 2)
        XCTAssertEqual(coord2.activeID, sB.id)
        // The active session is mounted on restore. Detach-before-mount
        // also fires for the (no-op) defensive detach at the top of
        // restore() — but there's nothing to detach, so the recorder
        // only sees the mount.
        XCTAssertEqual(recorder2.events, [.mount(sB.id)])
        XCTAssertTrue(coord2.sessions.contains(where: { $0.id == sA.id }))
    }

    func testRestoreNoIndexLeavesEmptyState() {
        coord.restore()
        XCTAssertTrue(coord.sessions.isEmpty)
        XCTAssertNil(coord.activeID)
    }

    func testRestoreSkipsMissingSnapshotFiles() throws {
        // Write an index that references a UUID with no snapshot file —
        // simulate filesystem corruption / partial delete. The
        // coordinator should skip it and surface a `lastError` rather
        // than crashing.
        let ghost = UUID()
        let real = UUID()
        let realSnap = SessionSnapshot(
            id: real, displayName: "real",
            createdAt: Date(), lastActiveAt: Date(),
            sidebarRootPath: "/p", openTabs: [], selectedTabIndex: nil
        )
        store.saveSync(realSnap)
        store.saveIndexSync(SessionIndex(
            sessions: [
                .init(id: ghost, rootPath: "/g", displayName: "ghost",
                      lastActiveAt: Date()),
                .init(id: real, rootPath: "/p", displayName: "real",
                      lastActiveAt: Date()),
            ],
            lastActiveID: real
        ))
        let coord2 = SessionsCoordinator(store: store)
        coord2.restore()
        XCTAssertEqual(coord2.sessions.count, 1)
        XCTAssertEqual(coord2.activeID, real)
        XCTAssertNotNil(coord2.lastError)
    }

    // MARK: PERSIST-04 — downgrade must not clobber a newer index ----

    func testRestoreWithNewerIndexBlocksWritesAndSurfacesBanner() throws {
        // A newer build wrote a v99 index. This older build must NOT
        // overwrite it on the next persist (which would truncate the
        // newer fields). It also leaves the live list empty and surfaces
        // a banner.
        let indexURL = tmp.appendingPathComponent("index.json")
        let v99 = """
        { "version": 99, "sessions": [], "lastActiveID": null }
        """
        try v99.write(to: indexURL, atomically: true, encoding: .utf8)

        let coord2 = SessionsCoordinator(store: store)
        coord2.restore()
        XCTAssertTrue(coord2.indexWriteBlocked,
            "newer on-disk index schema must block index writes (PERSIST-04)")
        XCTAssertTrue(coord2.sessions.isEmpty)
        XCTAssertNotNil(coord2.lastError)

        // Capture the exact on-disk bytes, then drive a mutation that
        // would normally persist the index, and confirm it's untouched.
        let before = try String(contentsOf: indexURL, encoding: .utf8)
        let folder = try makeTmpFolder(name: "newproj")
        _ = coord2.openFolder(folder)   // triggers persist()
        coord2.flushPersistenceSync()
        let after = try String(contentsOf: indexURL, encoding: .utf8)
        XCTAssertEqual(before, after,
            "index.json must be byte-identical — the older build must not overwrite a v99 index")
    }

    func testRestoreWithValidIndexLeavesWritesUnblocked() throws {
        let a = try makeTmpFolder(name: "alpha")
        _ = coord.openFolder(a)
        coord.flushPersistenceSync()
        let coord2 = SessionsCoordinator(store: store)
        coord2.restore()
        XCTAssertFalse(coord2.indexWriteBlocked)
    }

    func testRestoreWithCorruptIndexStartsEmptyButAllowsWrites() throws {
        try Data("garbage".utf8).write(to: tmp.appendingPathComponent("index.json"))
        let coord2 = SessionsCoordinator(store: store)
        coord2.restore()
        XCTAssertFalse(coord2.indexWriteBlocked,
            "corrupt bytes are already unusable — re-persisting is allowed")
        XCTAssertTrue(coord2.sessions.isEmpty)
        XCTAssertNotNil(coord2.lastError)
    }

    // MARK: PERSIST-10 — empty/nil root must not silently re-root $HOME

    func testRestoreDropsSessionWithEmptyRootPath() throws {
        // A snapshot whose sidebarRootPath is "" would otherwise be
        // re-rooted at $HOME by the UI mount path. Drop it from the live
        // list (the file stays on disk) and flag it.
        let real = UUID()
        let empty = UUID()
        store.saveSync(SessionSnapshot(
            id: real, displayName: "real",
            createdAt: Date(), lastActiveAt: Date(),
            sidebarRootPath: "/p", openTabs: [], selectedTabIndex: nil
        ))
        store.saveSync(SessionSnapshot(
            id: empty, displayName: "homeless",
            createdAt: Date(), lastActiveAt: Date(),
            sidebarRootPath: "", openTabs: [], selectedTabIndex: nil
        ))
        store.saveIndexSync(SessionIndex(
            sessions: [
                .init(id: real, rootPath: "/p", displayName: "real", lastActiveAt: Date()),
                .init(id: empty, rootPath: "", displayName: "homeless", lastActiveAt: Date()),
            ],
            lastActiveID: real
        ))
        let coord2 = SessionsCoordinator(store: store)
        coord2.restore()
        XCTAssertEqual(coord2.sessions.count, 1,
            "empty-root session must be dropped, not re-rooted at $HOME (PERSIST-10)")
        XCTAssertEqual(coord2.sessions.first?.id, real)
        XCTAssertNotNil(coord2.lastError)
        // Non-destructive: the dropped snapshot file is still on disk.
        let stillThere = tmp.appendingPathComponent("\(empty.uuidString).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stillThere.path))
    }

    func testRestoreKeepsSessionWithMissingButNonEmptyRoot() throws {
        // A non-empty but currently-missing path does NOT trigger the
        // $HOME re-root and is left alone (hydrate guards setRoot).
        let id = UUID()
        store.saveSync(SessionSnapshot(
            id: id, displayName: "external",
            createdAt: Date(), lastActiveAt: Date(),
            sidebarRootPath: "/Volumes/gone/proj", openTabs: [], selectedTabIndex: nil
        ))
        store.saveIndexSync(SessionIndex(
            sessions: [.init(id: id, rootPath: "/Volumes/gone/proj",
                             displayName: "external", lastActiveAt: Date())],
            lastActiveID: id
        ))
        let coord2 = SessionsCoordinator(store: store)
        coord2.restore()
        XCTAssertEqual(coord2.sessions.count, 1,
            "a non-empty missing path is harmless and must be kept")
    }

    // MARK: PERSIST-08 — partial snapshot on restore -----------------

    func testRestoreWithOneTruncatedSnapshotLoadsTheRestAndFlags() throws {
        let good = UUID()
        let bad = UUID()
        store.saveSync(SessionSnapshot(
            id: good, displayName: "good",
            createdAt: Date(), lastActiveAt: Date(),
            sidebarRootPath: "/g", openTabs: [], selectedTabIndex: nil
        ))
        // Truncated snapshot file for `bad`.
        try Data(#"{ "schemaVersion": 2, "id": "#.utf8)
            .write(to: tmp.appendingPathComponent("\(bad.uuidString).json"))
        store.saveIndexSync(SessionIndex(
            sessions: [
                .init(id: good, rootPath: "/g", displayName: "good", lastActiveAt: Date()),
                .init(id: bad, rootPath: "/b", displayName: "bad", lastActiveAt: Date()),
            ],
            lastActiveID: good
        ))
        let coord2 = SessionsCoordinator(store: store)
        coord2.restore()
        XCTAssertEqual(coord2.sessions.count, 1,
            "the truncated snapshot is skipped; the valid one loads (PERSIST-08)")
        XCTAssertEqual(coord2.activeID, good)
        XCTAssertNotNil(coord2.lastError)
    }

    // MARK: replaceSnapshot ------------------------------------------

    func testReplaceSnapshotPreservesIdentityFields() throws {
        let a = try makeTmpFolder(name: "alpha")
        let sA = coord.openFolder(a)
        let originalCreatedAt = sA.createdAt

        // Caller passes a snapshot with a DIFFERENT id and createdAt —
        // we defend against this by re-pinning to the existing session.
        let alien = SessionSnapshot(
            id: UUID(),
            displayName: "renamed",
            createdAt: Date.distantPast,
            lastActiveAt: Date(),
            sidebarRootPath: "/new",
            openTabs: [TabSnapshot(path: "/new/x.md", viewMode: "rendered")],
            selectedTabIndex: 0
        )
        coord.replaceSnapshot(id: sA.id, with: alien)
        let updated = coord.sessions.first { $0.id == sA.id }
        XCTAssertNotNil(updated)
        XCTAssertEqual(updated?.id, sA.id, "id must not be replaced")
        XCTAssertEqual(updated?.createdAt, originalCreatedAt,
                       "createdAt is immutable")
        XCTAssertEqual(updated?.displayName, "renamed")
        XCTAssertEqual(updated?.openTabs.count, 1)
    }

    // MARK: closeOthers ----------------------------------------------

    func testCloseOthersDropsEveryOtherSession() throws {
        let a = try makeTmpFolder(name: "alpha")
        let b = try makeTmpFolder(name: "beta")
        let c = try makeTmpFolder(name: "gamma")
        let sA = coord.openFolder(a)
        let sB = coord.openFolder(b)
        let sC = coord.openFolder(c)
        XCTAssertEqual(coord.sessions.count, 3)
        XCTAssertEqual(coord.activeID, sC.id)

        // Close everything except the *non*-active session sA. We
        // expect: sC (active) gets detached when removed, sA gets
        // mounted as the new active, then sB closes silently (it
        // wasn't active).
        coord.closeOthers(except: sA.id)
        XCTAssertEqual(coord.sessions.count, 1)
        XCTAssertEqual(coord.sessions.first?.id, sA.id)
        XCTAssertEqual(coord.activeID, sA.id)
        // Order-insensitive: sB may close before or after sC depending
        // on enumeration order. Just assert the keeper survived.
        XCTAssertNotNil(coord.active)
        // Sanity: closed snapshots are not in the live list.
        XCTAssertFalse(coord.sessions.contains(where: { $0.id == sB.id }))
        XCTAssertFalse(coord.sessions.contains(where: { $0.id == sC.id }))
    }

    func testCloseOthersWithSingleSessionIsNoop() throws {
        let a = try makeTmpFolder(name: "alpha")
        let sA = coord.openFolder(a)
        coord.closeOthers(except: sA.id)
        XCTAssertEqual(coord.sessions.count, 1)
        XCTAssertEqual(coord.activeID, sA.id)
    }

    func testCloseOthersIgnoresUnknownKeeper() throws {
        let a = try makeTmpFolder(name: "alpha")
        let b = try makeTmpFolder(name: "beta")
        _ = coord.openFolder(a)
        _ = coord.openFolder(b)
        let preCount = coord.sessions.count
        // Unknown keeper id: don't accidentally close everything.
        coord.closeOthers(except: UUID())
        XCTAssertEqual(coord.sessions.count, preCount)
    }

    // MARK: helpers --------------------------------------------------

    /// Create a real directory in tmp so `standardizedFileURL` /
    /// `resolvingSymlinksInPath` produce stable paths. Without an
    /// actual directory the resolver returns the input unchanged on
    /// some macOS versions, which can mask test bugs.
    private func makeTmpFolder(name: String = UUID().uuidString) throws -> URL {
        let url = tmp.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true
        )
        return url
    }

    // MARK: - persist ordering (TSK-1029)

    func test_persistPlan_writesAllSnapshotsBeforeIndex() {
        let d = Date(timeIntervalSince1970: 1_700_000_000)
        func snap(_ name: String) -> SessionSnapshot {
            SessionSnapshot(id: UUID(), displayName: name, createdAt: d,
                            lastActiveAt: d, sidebarRootPath: nil)
        }
        let s1 = snap("A"), s2 = snap("B")
        let plan = SessionsCoordinator.persistPlan(
            sessions: [s1, s2], activeID: s1.id, indexWriteBlocked: false, saveTime: d)
        let lastSnap = plan.lastIndex { if case .snapshot = $0 { return true }; return false }
        let firstIndex = plan.firstIndex { if case .index = $0 { return true }; return false }
        XCTAssertNotNil(lastSnap)
        XCTAssertNotNil(firstIndex)
        // Crash-safety: every snapshot is enqueued BEFORE the index that
        // references them (teeth: pre-fix the index was enqueued first).
        XCTAssertLessThan(lastSnap!, firstIndex!)
        XCTAssertEqual(plan.count, 3)
    }

    func test_persistPlan_indexWriteBlocked_omitsIndex() {
        let d = Date(timeIntervalSince1970: 1_700_000_000)
        let plan = SessionsCoordinator.persistPlan(
            sessions: [SessionSnapshot(id: UUID(), displayName: "A", createdAt: d,
                                       lastActiveAt: d, sidebarRootPath: nil)],
            activeID: nil, indexWriteBlocked: true, saveTime: d)
        XCTAssertFalse(plan.contains { if case .index = $0 { return true }; return false })
        XCTAssertEqual(plan.count, 1)
    }
}

/// Records every `mount` / `detach` callback in order so tests can
/// assert exact lifecycle sequences (the detach-before-mount
/// invariant). Weak-reference safe — coordinator holds it weakly.
@MainActor
private final class LifecycleRecorder: SessionsCoordinator.Lifecycle {
    enum Event: Equatable {
        case mount(UUID)
        case detach(UUID)
    }
    var events: [Event] = []

    func mount(_ session: SessionSnapshot)  { events.append(.mount(session.id)) }
    func detach(_ session: SessionSnapshot) { events.append(.detach(session.id)) }
}
