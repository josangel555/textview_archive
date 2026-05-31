import XCTest
@testable import ViewerCore

/// Behavior tests for the off-main store actor: refcount bookkeeping,
/// LRU-grace eviction order, cap enforcement, the snapshot equality
/// guard, timeout-keeps-prior-snapshot, and the concurrency gate.
///
/// Most tests use `_testInstall` to stage snapshots without spawning
/// git, so they're fast + deterministic. The few that exercise real git
/// build temp-dir fixtures.
final class TrackedReposStoreTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mdv-tracked-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func norm(_ u: URL) -> URL { TrackedReposReducer.normalize(u) }
    private func root(_ name: String) -> URL { norm(tmp.appendingPathComponent(name)) }

    private func snap(
        _ root: URL,
        statuses: [URL: GitStatusEntry.Status] = [:],
        head: GitClient.HeadInfo? = nil,
        generation: UInt64 = 1
    ) -> TrackedReposStore.RepoSnapshot {
        .init(root: root, statuses: statuses, head: head,
              isNestedRoot: false, timedOut: false,
              refreshedAt: Date(), generation: generation)
    }

    // MARK: - git fixture helper

    @discardableResult
    private func git(_ args: [String], in dir: URL) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.currentDirectoryURL = dir
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        try p.run(); p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    private func initRepo(at dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = try git(["init", "-q"], in: dir)
        _ = try git(["config", "user.email", "t@e.com"], in: dir)
        _ = try git(["config", "user.name", "T"], in: dir)
    }

    // MARK: - refcount

    func test_retain_release_refcountBookkeeping() async {
        let store = TrackedReposStore()
        let r = root("a")
        // Stage a snapshot so retain doesn't try to spawn git.
        await store._testInstall(snap(r))
        await store.retain(r)
        await store.retain(r)
        var counts = await store._testRefcounts()
        XCTAssertEqual(counts[r], 2)

        await store.release(r)
        counts = await store._testRefcounts()
        XCTAssertEqual(counts[r], 1)

        await store.release(r)
        counts = await store._testRefcounts()
        XCTAssertNil(counts[r], "at 0 the refcount entry is removed")
        let inGrace = await store.isInGrace(r)
        XCTAssertTrue(inGrace, "dropping to 0 enters grace, not eviction")
    }

    func test_releaseToZero_entersGrace_notEvicted() async {
        let store = TrackedReposStore()
        let r = root("a")
        await store._testInstall(snap(r))
        await store.retain(r)
        await store.release(r)
        // Still present (in grace), not evicted.
        let present = await store.snapshot(forRoot: r)
        XCTAssertNotNil(present)
        let count = await store._testTrackedCount
        XCTAssertEqual(count, 1)
    }

    func test_reRetainInGrace_cancelsEviction() async {
        let store = TrackedReposStore()
        let r = root("a")
        await store._testInstall(snap(r))
        await store.retain(r)
        await store.release(r)
        let inGraceBefore = await store.isInGrace(r)
        XCTAssertTrue(inGraceBefore)
        await store.retain(r)
        let inGraceAfter = await store.isInGrace(r)
        XCTAssertFalse(inGraceAfter, "re-retain clears zeroRefSince")
        // enforceCapAndGrace must NOT drop it now.
        let result = await store.enforceCapAndGrace(now: Date())
        XCTAssertFalse(result.dropped.contains(r))
    }

    // MARK: - eviction

    func test_enforceCapAndGrace_dropsGraceExpired() async {
        let store = TrackedReposStore()
        let r = root("a")
        await store._testInstall(snap(r))
        await store.retain(r)
        await store.release(r)
        // Backdate the grace timestamp past the window.
        await store._testSetZeroRefSince(r, Date().addingTimeInterval(-TrackedReposStore.graceWindow - 5))
        let result = await store.enforceCapAndGrace(now: Date())
        XCTAssertTrue(result.dropped.contains(r))
        let gone = await store.snapshot(forRoot: r)
        XCTAssertNil(gone, "grace-expired root fully dropped from byRoot")
    }

    func test_enforceCapAndGrace_capEviction_picksOldestZeroRef() async {
        // Build cap+1 zero-ref roots; oldest (insertion order) drops.
        let store = TrackedReposStore()
        var roots: [URL] = []
        for i in 0...(TrackedReposStore.cap) {
            let r = root("r\(i)")
            await store._testInstall(snap(r))
            await store.retain(r)
            await store.release(r)
            roots.append(r)
        }
        // All within grace window, but count (cap+1) exceeds cap → the
        // oldest gets dropped by the cap pass (or grace-slot overflow).
        let result = await store.enforceCapAndGrace(now: Date())
        XCTAssertTrue(result.dropped.contains(roots[0]),
                      "oldest zero-ref root evicted first")
        let remaining = await store._testTrackedCount
        XCTAssertLessThanOrEqual(remaining, TrackedReposStore.cap)
    }

    // MARK: - equality guard (real git)

    func test_refresh_idleSecondRefresh_noGenerationBump() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else {
            throw XCTSkip("git not available")
        }
        try initRepo(at: tmp)
        let file = tmp.appendingPathComponent("a.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        let store = TrackedReposStore()
        let r = norm(tmp)
        await store.refresh(root: r)
        let gen1 = await store._testGeneration
        XCTAssertGreaterThan(gen1, 0, "first fetch bumps generation")
        // Second refresh with no on-disk change → identical payload →
        // generation must NOT bump (idle-poll guard).
        await store.refresh(root: r)
        let gen2 = await store._testGeneration
        XCTAssertEqual(gen1, gen2, "identical status payload must not bump generation")
    }

    func test_refresh_realChange_bumpsGeneration() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else {
            throw XCTSkip("git not available")
        }
        try initRepo(at: tmp)
        let store = TrackedReposStore()
        let r = norm(tmp)
        await store.refresh(root: r)
        let gen1 = await store._testGeneration
        // Introduce an untracked file → status changes.
        try "new".write(to: tmp.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        await store.refresh(root: r)
        let gen2 = await store._testGeneration
        XCTAssertGreaterThan(gen2, gen1, "a real status change bumps generation")
        let s = await store.snapshot(forRoot: r)
        XCTAssertEqual(s?.statuses[norm(tmp.appendingPathComponent("new.txt"))], .untracked)
    }

    // MARK: - timeout keeps prior snapshot

    func test_refresh_timeout_keepsPriorSnapshot() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else {
            throw XCTSkip("git not available")
        }
        try initRepo(at: tmp)
        try "x".write(to: tmp.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        // First refresh with a normal timeout populates real status.
        let store = TrackedReposStore(statusTimeout: 5)
        let r = norm(tmp)
        await store.refresh(root: r)
        let before = await store.snapshot(forRoot: r)
        XCTAssertNotNil(before)
        XCTAssertFalse(before!.statuses.isEmpty, "has the untracked a.txt")

        // Now stage a snapshot via a store whose git call WOULD time out,
        // proving the keep-prior path. Use a tiny timeout against a
        // hanging shim is exercised in GitClientTimeoutTests; here we
        // assert the store-level contract by installing a prior snapshot
        // then asserting timedOut-marked refresh keeps statuses. We
        // simulate via a fresh store + an absurdly small timeout so the
        // real git is SIGTERM'd before producing output.
        let tinyStore = TrackedReposStore(statusTimeout: 0.0001)
        await tinyStore._testInstall(before!)
        await tinyStore.refresh(root: r)
        let after = await tinyStore.snapshot(forRoot: r)
        XCTAssertNotNil(after)
        // On timeout the prior statuses are retained (not blanked).
        XCTAssertEqual(after?.statuses, before?.statuses,
                       "timeout keeps prior badges, never blanks")
    }

    // MARK: - concurrency gate

    func test_concurrencyGate_neverExceedsTwo() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else {
            throw XCTSkip("git not available")
        }
        // Three separate repos refreshed concurrently. The gate caps
        // activeRefreshes at 2; we can't easily observe the peak from
        // outside, but we CAN assert that all three complete (no
        // deadlock in the slot hand-off) and the gate returns to 0.
        var roots: [URL] = []
        for i in 0..<3 {
            let dir = tmp.appendingPathComponent("repo\(i)")
            try initRepo(at: dir)
            try "x".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            roots.append(norm(dir))
        }
        let store = TrackedReposStore(maxConcurrentRefreshes: 2)
        await withTaskGroup(of: Void.self) { group in
            for r in roots {
                group.addTask { await store.refresh(root: r) }
            }
        }
        let active = await store._testActiveRefreshes
        XCTAssertEqual(active, 0, "all slots released after the batch (no leak / deadlock)")
        for r in roots {
            let s = await store.snapshot(forRoot: r)
            XCTAssertNotNil(s, "every repo refreshed")
        }
    }

    func test_refresh_inFlightDedup() async throws {
        // Two concurrent refreshes of the SAME root: the second is
        // dropped by the inFlight guard. We assert via no crash + final
        // count of one snapshot. (Tight timing — both may serialize, but
        // the guard must never produce a duplicate spawn storm.)
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else {
            throw XCTSkip("git not available")
        }
        try initRepo(at: tmp)
        try "x".write(to: tmp.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let store = TrackedReposStore()
        let r = norm(tmp)
        async let a: Void = store.refresh(root: r)
        async let b: Void = store.refresh(root: r)
        _ = await (a, b)
        let count = await store._testTrackedCount
        XCTAssertEqual(count, 1)
        let inFlight = await store._testInFlightCount
        XCTAssertEqual(inFlight, 0, "inFlight cleared after both return")
    }
}
