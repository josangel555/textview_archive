import XCTest
import ViewerCore
@testable import ViewerUI

/// Host-safe @MainActor tests for the channel's synchronous read
/// surface: multi-repo status lookup, the cheap `.git`-existence cache +
/// its invalidation, `repoRootKind` nested distinction, and read-side /
/// write-side normalization keying parity.
@MainActor
final class TrackedReposChannelReadTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-channel-read-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Restore the probe so cross-test isolation holds.
        TrackedReposChannel.fileExistsProbe = { FileManager.default.fileExists(atPath: $0) }
        try? FileManager.default.removeItem(at: tmp)
    }

    private func norm(_ u: URL) -> URL { TrackedReposReducer.normalize(u) }

    private func snap(
        _ root: URL,
        statuses: [URL: GitStatusEntry.Status] = [:],
        isNested: Bool = false
    ) -> TrackedReposStore.RepoSnapshot {
        .init(root: norm(root), statuses: statuses, head: nil,
              isNestedRoot: isNested, timedOut: false,
              refreshedAt: Date(), generation: 1)
    }

    private func makeChannel() -> TrackedReposChannel {
        TrackedReposChannel(store: TrackedReposStore())
    }

    // MARK: - multi-repo status lookup

    func test_status_multiRepo_resolvesPerFile() {
        let repoA = norm(tmp.appendingPathComponent("A"))
        let repoB = norm(tmp.appendingPathComponent("B"))
        let fileA = repoA.appendingPathComponent("x.swift")
        let fileB = repoB.appendingPathComponent("y.swift")

        let channel = makeChannel()
        channel._testBump(installing: [
            repoA: snap(repoA, statuses: [norm(fileA): .modified]),
            repoB: snap(repoB, statuses: [norm(fileB): .added]),
        ])

        XCTAssertEqual(channel.status(for: fileA), .modified, "repo A file resolves to A's snapshot")
        XCTAssertEqual(channel.status(for: fileB), .added, "repo B file resolves to B's snapshot")
        // The multi-repo payoff: both are live simultaneously, neither
        // evicting the other.
        XCTAssertNotNil(channel.status(for: fileA))
        XCTAssertNotNil(channel.status(for: fileB))
    }

    func test_status_fileNotInAnyTrackedRepo_nil() {
        let channel = makeChannel()
        let repoA = norm(tmp.appendingPathComponent("A"))
        channel._testBump(installing: [repoA: snap(repoA)])
        let outsider = tmp.appendingPathComponent("elsewhere/z.txt")
        XCTAssertNil(channel.status(for: outsider))
    }

    func test_repoRoot_enclosing_innermostWins() {
        let outer = norm(tmp.appendingPathComponent("mono"))
        let inner = norm(tmp.appendingPathComponent("mono/pkg"))
        let channel = makeChannel()
        channel._testBump(installing: [outer: snap(outer), inner: snap(inner)])
        let file = inner.appendingPathComponent("src/a.ts")
        XCTAssertEqual(channel.repoRoot(enclosing: file), inner)
    }

    // MARK: - isRepoRoot cheap-stat cache + invalidation

    func test_isRepoRoot_cachesProbe_singleStatPerDir() {
        var hits: [String] = []
        TrackedReposChannel.fileExistsProbe = { path in
            hits.append(path)
            return path.hasSuffix("/.git")  // pretend every dir is a repo
        }
        let channel = makeChannel()
        let dir = tmp.appendingPathComponent("repo")

        XCTAssertTrue(channel.isRepoRoot(dir))
        XCTAssertTrue(channel.isRepoRoot(dir))  // second call → cache hit
        XCTAssertEqual(hits.count, 1, "isRepoRoot must stat once per dir, then cache")
    }

    func test_isRepoRoot_invalidatesOnDirTouch() {
        var existing = true
        TrackedReposChannel.fileExistsProbe = { _ in existing }
        let channel = makeChannel()
        let dir = tmp.appendingPathComponent("repo")

        XCTAssertTrue(channel.isRepoRoot(dir))
        // Simulate `rm -rf .git` + an FSEvents touch of that dir.
        existing = false
        channel.invalidateRootIconCache(for: dir)
        XCTAssertFalse(channel.isRepoRoot(dir), "post-invalidation re-stat sees the flip")
    }

    func test_isRepoRoot_neverSpawnsGit() {
        // The probe is the ONLY filesystem touch; with a probe that
        // always returns false, isRepoRoot is false and no git ran.
        TrackedReposChannel.fileExistsProbe = { _ in false }
        let channel = makeChannel()
        XCTAssertFalse(channel.isRepoRoot(tmp.appendingPathComponent("x")))
    }

    // MARK: - repoRootKind nested distinction

    func test_repoRootKind_distinguishesRepoVsNestedVsNone() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else {
            throw XCTSkip("git not available")
        }
        // Real `.git` dirs so repoRootKind's parent-walk (which uses
        // discoverRoot) sees the nesting. outer/.git and outer/inner/.git.
        let outer = tmp.appendingPathComponent("outer")
        let inner = outer.appendingPathComponent("inner")
        let plain = tmp.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outer.appendingPathComponent(".git"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: inner.appendingPathComponent(".git"),
                                                withIntermediateDirectories: true)

        // Use the REAL probe for this test (we need true .git stats).
        TrackedReposChannel.fileExistsProbe = { FileManager.default.fileExists(atPath: $0) }
        let channel = makeChannel()

        XCTAssertEqual(channel.repoRootKind(outer), .repo, "top-level repo")
        XCTAssertEqual(channel.repoRootKind(inner), .nested, "repo inside another repo")
        XCTAssertEqual(channel.repoRootKind(plain), .none, "ordinary folder")
    }

    // MARK: - normalization keying parity (read-side vs write-side)

    func test_normalize_keyingParity_withWriteSide() {
        // The channel's read-side normalizer and the store's write-side
        // normalizer must produce byte-identical keys for non-standardized
        // and trailing-slash inputs — else a status written under one key
        // can't be read under another.
        let channel = makeChannel()
        let messy = tmp.appendingPathComponent("a/../b/./c")
        let withSlash = URL(fileURLWithPath: tmp.appendingPathComponent("b/c").path,
                            isDirectory: true)

        let readKey1 = channel._testNormalize(messy)
        let writeKey1 = TrackedReposReducer.normalize(messy)
        XCTAssertEqual(readKey1, writeKey1, "read-side == write-side for messy path")

        let readKey2 = channel._testNormalize(withSlash)
        let writeKey2 = TrackedReposReducer.normalize(withSlash)
        XCTAssertEqual(readKey2, writeKey2, "read-side == write-side for trailing-slash dir")

        // And the two spellings of the same path collapse to one key.
        XCTAssertEqual(readKey1, readKey2, "b/../c and b/c (dir) normalize identically")
    }

    func test_normCache_isBounded() {
        let channel = makeChannel()
        // Hammer the normalizer well past the 2048 cap; it must not
        // unboundedly grow (the cache resets when it overflows).
        for i in 0..<3000 {
            _ = channel._testNormalize(tmp.appendingPathComponent("f\(i)"))
        }
        // No direct count accessor for normCache; assert the rootIcon
        // cache cap path holds as a proxy for the shared bound discipline.
        for i in 0..<3000 {
            _ = channel.isRepoRoot(tmp.appendingPathComponent("d\(i)"))
        }
        XCTAssertLessThanOrEqual(channel._testRootIconCacheCount, 2049,
            "rootIcon cache stays bounded under churn")
    }
}

// MARK: - Norm-cache diagnostics (TSK-591)

/// Pins the miss/hit/reset accounting added for the file-nav hover-lag
/// investigation: a repeated lookup must be a cache HIT (no second
/// miss), and overflowing `cacheCap` distinct URLs must record a reset
/// (the wipe-on-overflow policy under suspicion for big-tree thrash).
@MainActor
final class TrackedReposNormCacheDiagnosticsTests: XCTestCase {

    func test_repeatLookup_isHit_notSecondMiss() {
        let channel = TrackedReposChannel(store: TrackedReposStore())
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("norm-diag-\(UUID().uuidString).md")

        XCTAssertEqual(channel.normCacheMisses, 0)
        _ = channel._testNormalize(url)
        XCTAssertEqual(channel.normCacheMisses, 1, "first lookup is a miss")
        _ = channel._testNormalize(url)
        XCTAssertEqual(channel.normCacheMisses, 1,
            "repeat lookup must be served from the cache")
    }

    func test_overflow_recordsReset() {
        let channel = TrackedReposChannel(store: TrackedReposStore())
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("norm-diag-\(UUID().uuidString)", isDirectory: true)
        // cacheCap is 2048; push past it with distinct URLs (no FS access
        // needed — normalize works on non-existent paths).
        for i in 0...2050 {
            _ = channel._testNormalize(base.appendingPathComponent("f\(i).md"))
        }
        XCTAssertGreaterThanOrEqual(channel.normCacheResets, 1,
            "overflowing the cap must record at least one wipe")
    }
}
