import XCTest
@testable import ViewerCore

/// Teeth for `LocalHistoryStore` (TSK-301) — on-disk file-version snapshots.
/// End-to-end against a temp dir (the store does real IO, like ReviewStore):
/// snapshot/list/restore round-trip, dedup, oldest-first prune at the cap,
/// size ceiling, per-file isolation, clear, and the stable path-hash.
/// Time is injected (`at:`) so ordering/pruning are deterministic.
final class LocalHistoryStoreTests: XCTestCase {

    private var dir: URL!
    private var store: LocalHistoryStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-localhist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = LocalHistoryStore(directory: dir)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private let path = "/Users/me/notes.md"
    private func date(_ s: TimeInterval) -> Date { Date(timeIntervalSince1970: s) }

    func test_snapshotThenListAndRestore_roundTrip() {
        let v1 = store.snapshot(path: path, content: "alpha", at: date(1_700_000_000))
        XCTAssertNotNil(v1)
        XCTAssertEqual(v1?.byteSize, 5)

        let versions = store.versions(for: path)
        XCTAssertEqual(versions.count, 1)
        XCTAssertEqual(store.contentString(of: versions[0], for: path), "alpha")
        XCTAssertEqual(versions[0].savedAt, date(1_700_000_000))
    }

    func test_versions_areNewestFirst() {
        store.snapshot(path: path, content: "v1", at: date(1_700_000_000))
        store.snapshot(path: path, content: "v2", at: date(1_700_000_100))
        store.snapshot(path: path, content: "v3", at: date(1_700_000_200))
        let versions = store.versions(for: path)
        XCTAssertEqual(versions.count, 3)
        // Newest first.
        XCTAssertEqual(store.contentString(of: versions[0], for: path), "v3")
        XCTAssertEqual(store.contentString(of: versions[2], for: path), "v1")
        XCTAssertGreaterThan(versions[0].savedAt, versions[1].savedAt)
    }

    func test_dedup_identicalToLatest_isNoOp() {
        XCTAssertNotNil(store.snapshot(path: path, content: "same", at: date(1_700_000_000)))
        // Same content as the latest → skipped (returns nil, count unchanged).
        XCTAssertNil(store.snapshot(path: path, content: "same", at: date(1_700_000_050)))
        XCTAssertEqual(store.versions(for: path).count, 1)
        // A different content DOES snapshot; then the original content again is
        // a NEW version (it differs from the now-latest), not deduped away.
        XCTAssertNotNil(store.snapshot(path: path, content: "diff", at: date(1_700_000_100)))
        XCTAssertNotNil(store.snapshot(path: path, content: "same", at: date(1_700_000_200)))
        XCTAssertEqual(store.versions(for: path).count, 3)
    }

    func test_prune_keepsNewestUpToCap_dropsOldest() {
        let cap = LocalHistoryStore.maxVersionsPerFile
        // cap + 5 distinct versions, ascending time; each content unique to
        // avoid dedup.
        for i in 0..<(cap + 5) {
            store.snapshot(path: path, content: "rev-\(i)",
                           at: date(1_700_000_000 + TimeInterval(i)))
        }
        let versions = store.versions(for: path)
        XCTAssertEqual(versions.count, cap, "history is capped at maxVersionsPerFile")
        // The 5 oldest (rev-0..rev-4) were pruned; newest (rev-cap+4) survives.
        XCTAssertEqual(store.contentString(of: versions[0], for: path), "rev-\(cap + 4)")
        let allContents = versions.compactMap { store.contentString(of: $0, for: path) }
        XCTAssertFalse(allContents.contains("rev-0"), "oldest pruned")
        XCTAssertTrue(allContents.contains("rev-5"), "rev-5 is the oldest survivor")
    }

    func test_oversizeContent_isSkipped() {
        let big = String(repeating: "x", count: LocalHistoryStore.maxSnapshotBytes + 1)
        XCTAssertNil(store.snapshot(path: path, content: big, at: date(1_700_000_000)))
        XCTAssertTrue(store.versions(for: path).isEmpty)
    }

    func test_perFileIsolation() {
        let other = "/Users/me/other.md"
        store.snapshot(path: path, content: "mine", at: date(1_700_000_000))
        store.snapshot(path: other, content: "theirs", at: date(1_700_000_000))
        XCTAssertEqual(store.versions(for: path).count, 1)
        XCTAssertEqual(store.versions(for: other).count, 1)
        XCTAssertEqual(store.contentString(of: store.versions(for: path)[0], for: path), "mine")
        XCTAssertEqual(store.contentString(of: store.versions(for: other)[0], for: other), "theirs")
    }

    func test_clear_dropsHistory() {
        store.snapshot(path: path, content: "a", at: date(1_700_000_000))
        store.snapshot(path: path, content: "b", at: date(1_700_000_100))
        XCTAssertEqual(store.versions(for: path).count, 2)
        store.clear(for: path)
        XCTAssertTrue(store.versions(for: path).isEmpty)
    }

    func test_sameMillisecond_doesNotCollide() {
        // Two snapshots at the exact same instant but different content must
        // both persist (the id bumps with a `_N` suffix).
        XCTAssertNotNil(store.snapshot(path: path, content: "first", at: date(1_700_000_000)))
        XCTAssertNotNil(store.snapshot(path: path, content: "second", at: date(1_700_000_000)))
        XCTAssertEqual(store.versions(for: path).count, 2)
    }

    func test_versionsForUnknownPath_isEmpty() {
        XCTAssertTrue(store.versions(for: "/nope/missing.txt").isEmpty)
    }

    func test_pathKey_isStableAndPathSpecific() {
        XCTAssertEqual(LocalHistoryStore.pathKey(path), LocalHistoryStore.pathKey(path),
                       "deterministic across calls")
        XCTAssertNotEqual(LocalHistoryStore.pathKey("/a"), LocalHistoryStore.pathKey("/b"))
    }

    func test_collisionGuard_dirBelongingToAnotherPath_servesNoHistory() throws {
        // TSK-1027: snapshot for `path`, then make the dir's `_path` sidecar
        // name a DIFFERENT file (simulating an FNV-1a-64 hash collision — a real
        // one is infeasible to construct). The store must refuse to serve (or
        // pollute) `path`'s history from a dir that now claims to belong elsewhere.
        let v = store.snapshot(path: path, content: "alpha", at: date(1_700_000_000))
        XCTAssertNotNil(v)
        XCTAssertEqual(store.versions(for: path).count, 1)   // sanity (matches)

        let sidecar = store.fileDirectory(for: path).appendingPathComponent("_path")
        try Data("/some/other/file.md".utf8).write(to: sidecar)

        // TEETH: pre-fix versions/contentString ignored `_path` and served it.
        XCTAssertEqual(store.versions(for: path), [], "must not serve a colliding dir's history")
        XCTAssertNil(store.contentString(of: v!, for: path))
        // A new snapshot must not pollute the foreign dir either.
        XCTAssertNil(store.snapshot(path: path, content: "beta", at: date(1_700_000_200)))
    }
}
