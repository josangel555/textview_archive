import XCTest
@testable import ViewerCore

/// TSK-752 — teeth for the centralized disk-backed scratch store and its prune
/// policy. The eviction MATH (`entriesToEvict`) is pure and exercised directly;
/// `prune` is exercised against a real temp directory.
final class ScratchStoreTests: XCTestCase {

    // MARK: - cacheSubdir path resolution

    func test_cacheSubdir_resolvesUnderMarkdownViewerCaches() {
        let dir = ScratchStore.cacheSubdir("diffs", create: false)
        // Always ends in MarkdownViewer/<name>, regardless of the base.
        XCTAssertEqual(dir.lastPathComponent, "diffs")
        XCTAssertEqual(dir.deletingLastPathComponent().lastPathComponent, "MarkdownViewer")
    }

    func test_cacheSubdir_create_materializesDirectory() {
        let unique = "scratch-test-\(UUID().uuidString)"
        let dir = ScratchStore.cacheSubdir(unique, create: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    // MARK: - entriesToEvict: age cap

    func test_evict_byAge_dropsOnlyEntriesOlderThanMaxAge() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let fresh = entry("fresh", ageSeconds: 60, size: 1, now: now)     // 1 min old
        let stale = entry("stale", ageSeconds: 3600, size: 1, now: now)   // 1 hr old
        let policy = ScratchStore.PrunePolicy(maxAge: 600)                // 10 min

        let evicted = ScratchStore.entriesToEvict([fresh, stale], policy: policy, now: now)

        XCTAssertEqual(evicted.map(\.url.lastPathComponent), ["stale"],
            "only the entry older than maxAge is evicted")
    }

    func test_evict_byAge_exactlyAtBoundary_isKept() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let onBoundary = entry("edge", ageSeconds: 600, size: 1, now: now)
        let policy = ScratchStore.PrunePolicy(maxAge: 600)
        // strictly-greater-than test → an entry exactly at the cap survives.
        XCTAssertTrue(
            ScratchStore.entriesToEvict([onBoundary], policy: policy, now: now).isEmpty)
    }

    // MARK: - entriesToEvict: count cap

    func test_evict_byCount_keepsMostRecentN() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        // Three entries, distinct ages; cap to 2 → the oldest is evicted.
        let a = entry("a", ageSeconds: 10, size: 1, now: now)  // newest
        let b = entry("b", ageSeconds: 20, size: 1, now: now)
        let c = entry("c", ageSeconds: 30, size: 1, now: now)  // oldest
        let policy = ScratchStore.PrunePolicy(maxCount: 2)

        let evicted = ScratchStore.entriesToEvict([b, a, c], policy: policy, now: now)

        XCTAssertEqual(evicted.map(\.url.lastPathComponent), ["c"],
            "count cap evicts the OLDEST beyond N, regardless of input order")
    }

    // MARK: - entriesToEvict: size cap

    func test_evict_byTotalBytes_keepsRecentUntilCapHit() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let a = entry("a", ageSeconds: 10, size: 40, now: now)  // newest
        let b = entry("b", ageSeconds: 20, size: 40, now: now)
        let c = entry("c", ageSeconds: 30, size: 40, now: now)  // oldest
        let policy = ScratchStore.PrunePolicy(maxTotalBytes: 100)

        let evicted = ScratchStore.entriesToEvict([a, b, c], policy: policy, now: now)

        // a(40) + b(40) = 80 <= 100; adding c(40) → 120 > 100 → c evicted.
        XCTAssertEqual(evicted.map(\.url.lastPathComponent), ["c"])
    }

    func test_evict_singleEntryLargerThanCap_isEvicted() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let big = entry("big", ageSeconds: 10, size: 1000, now: now)
        let policy = ScratchStore.PrunePolicy(maxTotalBytes: 100)
        XCTAssertEqual(
            ScratchStore.entriesToEvict([big], policy: policy, now: now)
                .map(\.url.lastPathComponent),
            ["big"], "a lone entry over the byte cap is still evicted")
    }

    // MARK: - entriesToEvict: combined caps + no-op

    func test_evict_emptyPolicy_keepsEverything() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let entries = (0..<5).map { entry("e\($0)", ageSeconds: Double($0), size: 1000, now: now) }
        XCTAssertTrue(
            ScratchStore.entriesToEvict(entries, policy: .init(), now: now).isEmpty,
            "a policy with no caps evicts nothing")
    }

    func test_evict_combinedCaps_ageDominatesEvenUnderCount() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let fresh = entry("fresh", ageSeconds: 1, size: 1, now: now)
        let stale = entry("stale", ageSeconds: 10_000, size: 1, now: now)
        // count cap alone would keep both; age cap removes the stale one.
        let policy = ScratchStore.PrunePolicy(maxAge: 600, maxCount: 100)
        XCTAssertEqual(
            ScratchStore.entriesToEvict([fresh, stale], policy: policy, now: now)
                .map(\.url.lastPathComponent),
            ["stale"])
    }

    func test_evict_isDeterministic_onModifiedTies() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        // Two entries with the SAME modified date; count cap 1 → the tiebreak
        // (url.path) decides which survives, deterministically.
        let z = entry("z", ageSeconds: 100, size: 1, now: now)
        let a = entry("a", ageSeconds: 100, size: 1, now: now)
        let policy = ScratchStore.PrunePolicy(maxCount: 1)
        // "a" < "z" → "a" kept, "z" evicted, repeatably.
        XCTAssertEqual(
            ScratchStore.entriesToEvict([z, a], policy: policy, now: now)
                .map(\.url.lastPathComponent),
            ["z"])
        XCTAssertEqual(
            ScratchStore.entriesToEvict([a, z], policy: policy, now: now)
                .map(\.url.lastPathComponent),
            ["z"], "result is independent of input order")
    }

    // MARK: - prune against a real directory

    func test_prune_deletesOldFilesOnDisk_keepsRecent() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("ScratchPrune-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let now = Date()
        let recent = dir.appendingPathComponent("recent.diff")
        let old = dir.appendingPathComponent("old.diff")
        try "r".write(to: recent, atomically: true, encoding: .utf8)
        try "o".write(to: old, atomically: true, encoding: .utf8)
        // Backdate "old" well past the cap.
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-10_000)],
                             ofItemAtPath: old.path)
        try fm.setAttributes([.modificationDate: now], ofItemAtPath: recent.path)

        let removed = ScratchStore.prune(
            directory: dir,
            policy: .init(maxAge: 600),
            now: now)

        XCTAssertEqual(removed.map(\.lastPathComponent), ["old.diff"])
        XCTAssertTrue(fm.fileExists(atPath: recent.path), "recent file survives")
        XCTAssertFalse(fm.fileExists(atPath: old.path), "stale file is deleted")
    }

    func test_prune_ignoresSubdirectories() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("ScratchSub-\(UUID().uuidString)")
        let sub = dir.appendingPathComponent("nested", isDirectory: true)
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        // An ancient subdirectory must NOT be deleted even under an aggressive
        // age cap — prune only touches regular files.
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)],
                             ofItemAtPath: sub.path)

        let removed = ScratchStore.prune(
            directory: dir, policy: .init(maxAge: 1), now: Date())

        XCTAssertTrue(removed.isEmpty, "prune must not delete subdirectories")
        XCTAssertTrue(fm.fileExists(atPath: sub.path), "nested dir survives")
    }

    func test_prune_missingDirectory_returnsEmpty() {
        let bogus = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString)")
        XCTAssertTrue(ScratchStore.prune(directory: bogus).isEmpty,
            "pruning a nonexistent directory is a safe no-op")
    }

    func test_scratchDefaultPolicy_hasAllThreeCaps() {
        let p = ScratchStore.PrunePolicy.scratchDefault
        XCTAssertEqual(p.maxAge, 7 * 24 * 60 * 60)
        XCTAssertEqual(p.maxCount, 200)
        XCTAssertEqual(p.maxTotalBytes, 64 * 1024 * 1024)
    }

    // MARK: - helpers

    private func entry(_ name: String, ageSeconds: TimeInterval, size: Int, now: Date)
        -> ScratchStore.Entry {
        ScratchStore.Entry(
            url: URL(fileURLWithPath: "/scratch/\(name)"),
            modified: now.addingTimeInterval(-ageSeconds),
            size: size)
    }
}
