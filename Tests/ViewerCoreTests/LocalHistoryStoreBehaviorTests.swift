import XCTest
@testable import ViewerCore

/// TSK-1181 — split out of `LocalHistoryStoreTests` (was the suite's slowest class
/// at ~41.5s/30 tests; `swift test --parallel` schedules per CLASS, so this half
/// now runs on its own worker). These are the behavioral tests (toggle/dedup/
/// isolation/clear/ids/collision/diff) — they need only `setUp` + `date()`; the
/// storage-format/byte-cap/reconstruct tests (which use the on-disk helpers) stay
/// in `LocalHistoryStoreTests`. Time is injected (`at:`) for determinism.
final class LocalHistoryStoreBehaviorTests: XCTestCase {

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

    // MARK: - Default-on + toggle

    func test_default_isOn_capturesByDefault() {
        XCTAssertNotNil(store.snapshot(path: path, content: "hello", at: date(1_700_000_000)))
        XCTAssertEqual(store.versions(for: path).count, 1)
    }

    func test_toggleOff_suppressesCapture() {
        let offStore = LocalHistoryStore(directory: dir, isEnabled: { false })
        XCTAssertNil(offStore.snapshot(path: path, content: "hello", at: date(1_700_000_000)))
        XCTAssertTrue(offStore.versions(for: path).isEmpty)
    }

    func test_toggle_isReadLive_perSnapshot() {
        final class Box: @unchecked Sendable { var on = true }
        let box = Box()
        let s = LocalHistoryStore(directory: dir, isEnabled: { box.on })
        XCTAssertNotNil(s.snapshot(path: path, content: "one", at: date(1_700_000_000)))
        box.on = false
        XCTAssertNil(s.snapshot(path: path, content: "two", at: date(1_700_000_100)))
        box.on = true
        XCTAssertNotNil(s.snapshot(path: path, content: "three", at: date(1_700_000_200)))
        XCTAssertEqual(s.versions(for: path).count, 2)     // "two" was suppressed
    }

    // MARK: - Dedup, isolation, clear, ids

    func test_dedup_identicalToLatest_isNoOp() {
        XCTAssertNotNil(store.snapshot(path: path, content: "same\nx", at: date(1_700_000_000)))
        XCTAssertNil(store.snapshot(path: path, content: "same\nx", at: date(1_700_000_050)))
        XCTAssertEqual(store.versions(for: path).count, 1)
        XCTAssertNotNil(store.snapshot(path: path, content: "diff\nx", at: date(1_700_000_100)))
        XCTAssertNotNil(store.snapshot(path: path, content: "same\nx", at: date(1_700_000_200)))
        XCTAssertEqual(store.versions(for: path).count, 3)
    }

    func test_oversizeContent_isSkipped() {
        let big = String(repeating: "x", count: LocalHistoryStore.maxSnapshotBytes + 1)
        XCTAssertNil(store.snapshot(path: path, content: big, at: date(1_700_000_000)))
        XCTAssertTrue(store.versions(for: path).isEmpty)
    }

    func test_emptyContent_isSkipped() {
        XCTAssertNil(store.snapshot(path: path, content: "", at: date(1_700_000_000)))
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
        XCTAssertNotNil(store.snapshot(path: path, content: "first", at: date(1_700_000_000)))
        XCTAssertNotNil(store.snapshot(path: path, content: "second", at: date(1_700_000_000)))
        XCTAssertEqual(store.versions(for: path).count, 2)
    }

    func test_versionsForUnknownPath_isEmpty() {
        XCTAssertTrue(store.versions(for: "/nope/missing.txt").isEmpty)
    }

    func test_pathKey_isStableAndPathSpecific() {
        XCTAssertEqual(LocalHistoryStore.pathKey(path), LocalHistoryStore.pathKey(path))
        XCTAssertNotEqual(LocalHistoryStore.pathKey("/a"), LocalHistoryStore.pathKey("/b"))
    }

    func test_collisionGuard_dirBelongingToAnotherPath_servesNoHistory() throws {
        let v = store.snapshot(path: path, content: "alpha", at: date(1_700_000_000))
        XCTAssertNotNil(v)
        XCTAssertEqual(store.versions(for: path).count, 1)

        let sidecar = store.fileDirectory(for: path).appendingPathComponent("_path")
        try Data("/some/other/file.md".utf8).write(to: sidecar)

        XCTAssertEqual(store.versions(for: path), [], "must not serve a colliding dir's history")
        XCTAssertNil(store.contentString(of: v!, for: path))
        XCTAssertNil(store.snapshot(path: path, content: "beta", at: date(1_700_000_200)))
    }

    // MARK: - Diff API (for the UI)

    func test_diff_betweenTwoVersions_reportsTheChangedLine() {
        let v1 = store.snapshot(path: path, content: "a\nb\nc", at: date(1_700_000_000))!
        let v2 = store.snapshot(path: path, content: "a\nB\nc", at: date(1_700_000_100))!
        let hunks = store.diff(from: v1, to: v2, for: path)
        XCTAssertNotNil(hunks)
        let kinds = hunks!.flatMap { $0.lines }.filter { $0.kind != .context }
        XCTAssertTrue(kinds.contains { $0.kind == .removed && $0.content == "b" })
        XCTAssertTrue(kinds.contains { $0.kind == .added && $0.content == "B" })
    }

    func test_diff_versionAgainstCurrent_text() {
        let v1 = store.snapshot(path: path, content: "x\ny\nz", at: date(1_700_000_000))!
        let hunks = store.diff(version: v1, againstCurrent: "x\ny\nz\nNEW", for: path)
        XCTAssertNotNil(hunks)
        let added = hunks!.flatMap { $0.lines }.filter { $0.kind == .added }
        XCTAssertEqual(added.map(\.content), ["NEW"])
    }

    func test_diff_identical_isEmpty() {
        let v1 = store.snapshot(path: path, content: "same\nlines", at: date(1_700_000_000))!
        XCTAssertEqual(store.diff(version: v1, againstCurrent: "same\nlines", for: path), [])
    }
}
