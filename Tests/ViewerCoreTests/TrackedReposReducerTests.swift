import XCTest
@testable import ViewerCore

/// Pure-logic tests for the multi-repo registry's policy core. No live
/// FSEvents, no @MainActor — temp-dir git fixtures only for the
/// resolveRoot/desiredRepoSet cases that need a real `.git`.
final class TrackedReposReducerTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else {
            throw XCTSkip("/usr/bin/git not available")
        }
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mdv-tracked-reducer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - Helpers

    @discardableResult
    private func git(_ args: [String], in dir: URL) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.currentDirectoryURL = dir
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    private func initRepo(at dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = try git(["init", "-q"], in: dir)
        _ = try git(["config", "user.email", "t@e.com"], in: dir)
        _ = try git(["config", "user.name", "T"], in: dir)
    }

    private func norm(_ u: URL) -> URL { TrackedReposReducer.normalize(u) }

    // MARK: - resolveRoot (innermost wins)

    func test_resolveRoot_file_walksFromParent() throws {
        try initRepo(at: tmp)
        let nested = tmp.appendingPathComponent("src/app")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let file = nested.appendingPathComponent("main.swift")
        try "x".write(to: file, atomically: true, encoding: .utf8)

        let root = TrackedReposReducer.resolveRoot(for: file, isDirectory: false)
        XCTAssertEqual(root?.path, norm(tmp).path)
    }

    func test_resolveRoot_folder_walksFromSelf() throws {
        try initRepo(at: tmp)
        let sub = tmp.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let root = TrackedReposReducer.resolveRoot(for: sub, isDirectory: true)
        XCTAssertEqual(root?.path, norm(tmp).path)
    }

    func test_resolveRoot_innermostWins_nestedRepo() throws {
        // Outer repo, with an inner repo created via a `.git` FILE
        // (submodule/worktree shape — discoverRoot must stop at it).
        try initRepo(at: tmp)
        let inner = tmp.appendingPathComponent("vendor/lib")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        // Simulate a submodule's `.git` FILE pointing elsewhere.
        let gitFile = inner.appendingPathComponent(".git")
        try "gitdir: /somewhere/else\n".write(to: gitFile, atomically: true, encoding: .utf8)

        let innerFile = inner.appendingPathComponent("a.c")
        try "y".write(to: innerFile, atomically: true, encoding: .utf8)
        let root = TrackedReposReducer.resolveRoot(for: innerFile, isDirectory: false)
        XCTAssertEqual(root?.path, norm(inner).path,
                       "innermost repo (the .git FILE) must win over the outer .git dir")
    }

    func test_resolveRoot_outsideRepo_isNil() {
        XCTAssertNil(TrackedReposReducer.resolveRoot(for: URL(fileURLWithPath: "/"), isDirectory: true))
    }

    // MARK: - desiredRepoSet (refcount math)

    func test_desiredRepoSet_twoTabsSameRepo_refcountTwo() throws {
        try initRepo(at: tmp)
        let a = tmp.appendingPathComponent("a.txt")
        let b = tmp.appendingPathComponent("b.txt")
        try "1".write(to: a, atomically: true, encoding: .utf8)
        try "2".write(to: b, atomically: true, encoding: .utf8)

        let set = TrackedReposReducer.desiredRepoSet(
            tabURLs: [a, b], splitURL: nil, sidebarFolder: nil, pinned: []
        )
        XCTAssertEqual(set.count, 1, "both tabs map to one root")
        XCTAssertEqual(set[norm(tmp)], 2, "refcount accumulates per contributor")
    }

    func test_desiredRepoSet_tabSplitFolderAcrossTwoRepos_twoRoots() throws {
        let repoA = tmp.appendingPathComponent("A")
        let repoB = tmp.appendingPathComponent("B")
        try initRepo(at: repoA)
        try initRepo(at: repoB)
        let fileA = repoA.appendingPathComponent("x.txt")
        let fileB = repoB.appendingPathComponent("y.txt")
        try "x".write(to: fileA, atomically: true, encoding: .utf8)
        try "y".write(to: fileB, atomically: true, encoding: .utf8)

        let set = TrackedReposReducer.desiredRepoSet(
            tabURLs: [fileA], splitURL: fileB, sidebarFolder: repoA, pinned: []
        )
        XCTAssertEqual(set.count, 2)
        XCTAssertEqual(set[norm(repoA)], 2, "tab + sidebar folder in repo A")
        XCTAssertEqual(set[norm(repoB)], 1, "split pane in repo B")
    }

    func test_desiredRepoSet_pinnedRoot_counts() throws {
        try initRepo(at: tmp)
        let set = TrackedReposReducer.desiredRepoSet(
            tabURLs: [], splitURL: nil, sidebarFolder: nil, pinned: [tmp]
        )
        XCTAssertEqual(set[norm(tmp)], 1, "a pin contributes +1 even with no open tab")
    }

    func test_desiredRepoSet_filesOutsideAnyRepo_empty() throws {
        let loose = tmp.appendingPathComponent("loose.txt")
        try "x".write(to: loose, atomically: true, encoding: .utf8)
        let set = TrackedReposReducer.desiredRepoSet(
            tabURLs: [loose], splitURL: nil, sidebarFolder: nil, pinned: []
        )
        XCTAssertTrue(set.isEmpty)
    }

    // MARK: - evictionPlan

    private func mkRoot(_ name: String) -> URL {
        norm(tmp.appendingPathComponent(name))
    }

    func test_evictionPlan_referencedRoot_neverDropped() {
        let a = mkRoot("a")
        let plan = TrackedReposReducer.evictionPlan(
            refcounts: [a: 1], zeroRefSince: [:], lruOrder: [a],
            pinned: [], now: Date(), graceWindow: 30, cap: 8, graceSlots: 4
        )
        XCTAssertTrue(plan.drop.isEmpty)
    }

    func test_evictionPlan_pinnedRoot_neverDropped_evenZeroRefPastGrace() {
        let a = mkRoot("a")
        let now = Date()
        let plan = TrackedReposReducer.evictionPlan(
            refcounts: [:], zeroRefSince: [a: now.addingTimeInterval(-1000)],
            lruOrder: [a], pinned: [a], now: now,
            graceWindow: 30, cap: 8, graceSlots: 4
        )
        XCTAssertTrue(plan.drop.isEmpty, "pinned roots survive grace expiry")
    }

    func test_evictionPlan_zeroRefPastGrace_dropped() {
        let a = mkRoot("a")
        let now = Date()
        let plan = TrackedReposReducer.evictionPlan(
            refcounts: [:], zeroRefSince: [a: now.addingTimeInterval(-31)],
            lruOrder: [a], pinned: [], now: now,
            graceWindow: 30, cap: 8, graceSlots: 4
        )
        XCTAssertEqual(plan.drop, [a])
    }

    func test_evictionPlan_zeroRefWithinGrace_kept() {
        let a = mkRoot("a")
        let now = Date()
        let plan = TrackedReposReducer.evictionPlan(
            refcounts: [:], zeroRefSince: [a: now.addingTimeInterval(-5)],
            lruOrder: [a], pinned: [], now: now,
            graceWindow: 30, cap: 8, graceSlots: 4
        )
        XCTAssertTrue(plan.drop.isEmpty, "within grace window → kept")
    }

    func test_evictionPlan_graceSlotOverflow_dropsOldestFirst() {
        // 5 zero-ref roots within grace, graceSlots=4 → oldest one dropped.
        let now = Date()
        let roots = (0..<5).map { mkRoot("r\($0)") }
        var zeroRef: [URL: Date] = [:]
        for r in roots { zeroRef[r] = now.addingTimeInterval(-5) }
        let plan = TrackedReposReducer.evictionPlan(
            refcounts: [:], zeroRefSince: zeroRef, lruOrder: roots,
            pinned: [], now: now, graceWindow: 30, cap: 8, graceSlots: 4
        )
        XCTAssertEqual(plan.drop, [roots[0]], "oldest (insertion-order) grace overflow dropped")
    }

    func test_evictionPlan_capExceeded_dropsOldestZeroRef_keepsLive() {
        // cap=2. 2 live + 1 zero-ref → drop the zero-ref to get under cap.
        let now = Date()
        let live1 = mkRoot("live1")
        let live2 = mkRoot("live2")
        let zero = mkRoot("zero")
        let plan = TrackedReposReducer.evictionPlan(
            refcounts: [live1: 1, live2: 1],
            zeroRefSince: [zero: now.addingTimeInterval(-1)],
            lruOrder: [zero, live1, live2],
            pinned: [], now: now, graceWindow: 30, cap: 2, graceSlots: 4
        )
        XCTAssertEqual(plan.drop, [zero])
        XCTAssertTrue(plan.keepStaleWatcherless.isEmpty)
    }

    func test_evictionPlan_capExceeded_allLive_freezesOldestAsStaleWatcherless() {
        // cap=2. 3 live roots, none droppable → freeze the oldest.
        let r0 = mkRoot("r0"); let r1 = mkRoot("r1"); let r2 = mkRoot("r2")
        let plan = TrackedReposReducer.evictionPlan(
            refcounts: [r0: 1, r1: 1, r2: 1], zeroRefSince: [:],
            lruOrder: [r0, r1, r2], pinned: [], now: Date(),
            graceWindow: 30, cap: 2, graceSlots: 4
        )
        XCTAssertTrue(plan.drop.isEmpty, "live roots never dropped (correctness > memory)")
        XCTAssertEqual(plan.keepStaleWatcherless, [r0], "oldest live overflow frozen")
    }

    func test_evictionPlan_capExceeded_pinnedNeverFrozen() {
        // cap=1. 2 live, one pinned → the pinned one keeps its watcher.
        let pinnedR = mkRoot("pinned"); let liveR = mkRoot("live")
        let plan = TrackedReposReducer.evictionPlan(
            refcounts: [pinnedR: 1, liveR: 1], zeroRefSince: [:],
            lruOrder: [pinnedR, liveR], pinned: [pinnedR], now: Date(),
            graceWindow: 30, cap: 1, graceSlots: 4
        )
        XCTAssertEqual(plan.keepStaleWatcherless, [liveR],
                       "pinned root is last to lose its watcher")
    }

    // MARK: - trackedRoot(enclosing:)

    func test_trackedRoot_prefixMatch_innermostWins() {
        let outer = mkRoot("mono")
        let inner = mkRoot("mono/packages/app")
        let dir = mkRoot("mono/packages/app/src")
        let match = TrackedReposReducer.trackedRoot(
            enclosing: dir, trackedRoots: [outer, inner]
        )
        XCTAssertEqual(match, inner, "longest (innermost) matching root wins")
    }

    func test_trackedRoot_exactMatch() {
        let r = mkRoot("repo")
        XCTAssertEqual(TrackedReposReducer.trackedRoot(enclosing: r, trackedRoots: [r]), r)
    }

    func test_trackedRoot_noMatch_nil() {
        let r = mkRoot("repo")
        let other = mkRoot("elsewhere/file")
        XCTAssertNil(TrackedReposReducer.trackedRoot(enclosing: other, trackedRoots: [r]))
    }

    func test_trackedRoot_siblingPrefix_doesNotFalseMatch() {
        // /repo must NOT match /repo-other (prefix-without-slash trap).
        let repo = mkRoot("repo")
        let sibling = mkRoot("repo-other/file.txt")
        XCTAssertNil(TrackedReposReducer.trackedRoot(enclosing: sibling, trackedRoots: [repo]))
    }

    // MARK: - isRefreshWorthy (.git storm filter)

    private func wp(_ rel: String) -> String {
        norm(tmp).appendingPathComponent(rel).path
    }

    func test_isRefreshWorthy_worktreeFile_yes() {
        XCTAssertTrue(TrackedReposReducer.isRefreshWorthy(changedPath: wp("src/main.swift"), repoRoot: tmp))
    }

    func test_isRefreshWorthy_gitHEAD_yes() {
        XCTAssertTrue(TrackedReposReducer.isRefreshWorthy(changedPath: wp(".git/HEAD"), repoRoot: tmp))
    }

    func test_isRefreshWorthy_gitIndex_yes() {
        XCTAssertTrue(TrackedReposReducer.isRefreshWorthy(changedPath: wp(".git/index"), repoRoot: tmp))
    }

    func test_isRefreshWorthy_gitRefs_yes() {
        XCTAssertTrue(TrackedReposReducer.isRefreshWorthy(changedPath: wp(".git/refs/heads/main"), repoRoot: tmp))
    }

    func test_isRefreshWorthy_packedRefs_yes() {
        XCTAssertTrue(TrackedReposReducer.isRefreshWorthy(changedPath: wp(".git/packed-refs"), repoRoot: tmp))
    }

    func test_isRefreshWorthy_gitObjects_no() {
        XCTAssertFalse(TrackedReposReducer.isRefreshWorthy(
            changedPath: wp(".git/objects/ab/cdef0123456789"), repoRoot: tmp))
    }

    func test_isRefreshWorthy_gitLFS_no() {
        XCTAssertFalse(TrackedReposReducer.isRefreshWorthy(
            changedPath: wp(".git/lfs/objects/aa/bb/deadbeef"), repoRoot: tmp))
    }

    func test_isRefreshWorthy_lockFile_no() {
        XCTAssertFalse(TrackedReposReducer.isRefreshWorthy(
            changedPath: wp(".git/index.lock"), repoRoot: tmp))
        XCTAssertFalse(TrackedReposReducer.isRefreshWorthy(
            changedPath: wp(".git/refs/heads/main.lock"), repoRoot: tmp))
    }

    func test_isRefreshWorthy_gitConfig_no() {
        // config / logs / hooks aren't status-worthy on their own.
        XCTAssertFalse(TrackedReposReducer.isRefreshWorthy(changedPath: wp(".git/config"), repoRoot: tmp))
        XCTAssertFalse(TrackedReposReducer.isRefreshWorthy(changedPath: wp(".git/logs/HEAD"), repoRoot: tmp))
    }

    func test_isRefreshWorthy_mergeHead_yes() {
        XCTAssertTrue(TrackedReposReducer.isRefreshWorthy(changedPath: wp(".git/MERGE_HEAD"), repoRoot: tmp))
    }

    // MARK: - touchesDotGitExistence

    func test_touchesDotGitExistence() {
        XCTAssertTrue(TrackedReposReducer.touchesDotGitExistence(changedPath: wp("newrepo/.git")))
        XCTAssertFalse(TrackedReposReducer.touchesDotGitExistence(changedPath: wp("newrepo/.gitignore")))
        XCTAssertFalse(TrackedReposReducer.touchesDotGitExistence(changedPath: wp("src/file.swift")))
    }

    // MARK: - normalize parity

    func test_normalize_isIdempotent() {
        let r = norm(tmp.appendingPathComponent("a/../b"))
        XCTAssertEqual(norm(r), r)
    }
}
