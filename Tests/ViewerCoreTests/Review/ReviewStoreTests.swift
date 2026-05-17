import XCTest
@testable import ViewerCore

/// Layer-2 tests from §9 of CODE_REVIEW_DESIGN.md.
///
/// Disk round-trip, list ordering, delete, atomic-write contract,
/// schema-version refusal, max-size guard.
final class ReviewStoreTests: XCTestCase {

    private var tmp: URL!
    private var store: ReviewStore!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mdv-rev-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        store = ReviewStore(directory: tmp)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - Fixtures

    // ISO-8601 has second-resolution. We pin to whole-second dates
    // so JSON round-trip is bit-exact; Date() captures sub-second
    // precision that drops on encode.
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeReview(
        id: String = ReviewID.generate(),
        title: String = "T",
        state: ReviewState = .draft,
        updatedAt: Date? = nil,
        comments: [ReviewComment] = []
    ) -> Review {
        Review(
            id: id,
            createdAt: t0,
            updatedAt: updatedAt ?? t0,
            title: title,
            scope: .commit(sha: "abc123"),
            repoRoot: "/tmp/repo",
            baseSha: nil, headSha: nil,
            state: state,
            comments: comments,
            author: ReviewAuthor(name: "Jos", email: "jos@x")
        )
    }

    private func makeComment(resolved: Bool = false) -> ReviewComment {
        ReviewComment(
            id: ReviewID.generate(),
            filePath: "a.swift",
            anchor: LineAnchor(side: .new, startLine: 1, endLine: 1),
            severity: .info,
            body: "body",
            createdAt: t0,
            updatedAt: t0,
            resolved: resolved,
            hunkContext: HunkContext(
                hunkHeader: "@@", preLines: [], anchoredLines: [], postLines: []
            )
        )
    }

    // MARK: - Round-trip

    func testSaveAndLoadRoundtrip() throws {
        let r = makeReview(title: "Round-trip test")
        XCTAssertTrue(store.save(r))
        let loaded = store.load(id: r.id)
        XCTAssertEqual(loaded, r)
    }

    func testLoadMissingReturnsNil() {
        XCTAssertNil(store.load(id: "01HXY0000000000000000000ZZ"))
    }

    // MARK: - list()

    func testListSortedByUpdatedAtDescending() throws {
        let oldR = makeReview(
            id: "01HXY0000000000000000000A1",
            title: "old",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let midR = makeReview(
            id: "01HXY0000000000000000000A2",
            title: "mid",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let newR = makeReview(
            id: "01HXY0000000000000000000A3",
            title: "new",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )

        // Write in scrambled order to prove sort comes from updatedAt,
        // not from filesystem enumeration order.
        store.save(midR)
        store.save(newR)
        store.save(oldR)

        let listed = store.list()
        XCTAssertEqual(listed.map(\.title), ["new", "mid", "old"])
    }

    func testListIncludesCommentCounts() {
        let r = makeReview(
            comments: [
                makeComment(resolved: false),
                makeComment(resolved: false),
                makeComment(resolved: true),
            ]
        )
        store.save(r)
        let listed = store.list()
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0].commentCount, 3)
        XCTAssertEqual(listed[0].unresolvedCount, 2)
    }

    func testListExcludesIndexFile() {
        let r = makeReview()
        store.save(r)
        let listed = store.list()
        XCTAssertEqual(listed.count, 1)
        // The _index.json must exist (rebuilt on save) but must not
        // appear as a "review".
        let indexURL = tmp.appendingPathComponent("_index.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: indexURL.path))
        XCTAssertFalse(listed.contains { $0.id.hasPrefix("_") })
    }

    func testListOnEmptyDirectoryIsEmpty() {
        XCTAssertEqual(store.list(), [])
    }

    // MARK: - delete()

    func testDeleteRemovesFromDiskAndIndex() {
        let r1 = makeReview(id: "01HXY0000000000000000000B1")
        let r2 = makeReview(id: "01HXY0000000000000000000B2")
        store.save(r1)
        store.save(r2)
        XCTAssertEqual(store.list().count, 2)

        store.delete(id: r1.id)
        let remaining = store.list()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining[0].id, r2.id)
        XCTAssertNil(store.load(id: r1.id))

        let path = tmp.appendingPathComponent("\(r1.id).json").path
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    // MARK: - Atomic write

    func testAtomicWriteReplacesCorruptFile() throws {
        // Pre-stage a corrupt file at the target path. The next save
        // should atomically replace it; the next load should return
        // the clean object, not partial garbage.
        let r = makeReview(id: "01HXY0000000000000000000C1")
        let url = tmp.appendingPathComponent("\(r.id).json")
        try "garbage not json".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertNil(store.load(id: r.id), "garbage should not decode")

        store.save(r)
        XCTAssertEqual(store.load(id: r.id), r)
    }

    // MARK: - Schema-version refusal

    func testSchemaVersionTooNewReturnsNil() throws {
        // Hand-craft a JSON file with a future schemaVersion. The
        // store must refuse it — silently surfacing as nil, matching
        // `JSONFileStore.read`'s never-throws contract.
        let id = "01HXY0000000000000000000D1"
        let url = tmp.appendingPathComponent("\(id).json")
        let json: [String: Any] = [
            "id": id,
            "schemaVersion": Review.currentSchema + 100,
            "createdAt": "2026-01-01T00:00:00Z",
            "updatedAt": "2026-01-01T00:00:00Z",
            "title": "future",
            "scope": ["kind": "commit", "sha": "abc"],
            "repoRoot": "/tmp",
            "state": "draft",
            "comments": [],
            "author": ["name": "Jos", "email": "x"],
            "exports": [],
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        try data.write(to: url)
        XCTAssertNil(store.load(id: id))
    }

    // MARK: - Max-size guard

    func testMaxSizeGuardReturnsNil() throws {
        // Synthesize a 15 MiB blob at the target path. The store
        // refuses to inflate anything bigger than maxReviewFileSize.
        let id = "01HXY0000000000000000000E1"
        let url = tmp.appendingPathComponent("\(id).json")
        let blob = Data(repeating: 0x20, count: 15 * 1024 * 1024)
        try blob.write(to: url)
        XCTAssertNil(store.load(id: id))
    }

    // MARK: - rebuildIndex()

    func testRebuildIndexRecoversFromOutOfBandDelete() throws {
        let r1 = makeReview(id: "01HXY0000000000000000000F1", title: "one")
        let r2 = makeReview(id: "01HXY0000000000000000000F2", title: "two")
        store.save(r1)
        store.save(r2)
        XCTAssertEqual(store.list().count, 2)

        // Out-of-band delete (e.g., user removed the file in Finder).
        try FileManager.default.removeItem(at: tmp.appendingPathComponent("\(r1.id).json"))

        // The index is now stale (says 2 files; only 1 on disk).
        // `list()` is documented to fall back to a scan when the
        // index disagrees with the directory.
        let listed = store.list()
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0].id, r2.id)
    }

    func testRebuildIndexExplicit() throws {
        let r = makeReview()
        store.save(r)
        // Stomp the index with garbage.
        let indexURL = tmp.appendingPathComponent("_index.json")
        try "[]".write(to: indexURL, atomically: true, encoding: .utf8)
        // Force a rebuild — index now reflects the real on-disk state.
        store.rebuildIndex()
        let listed = store.list()
        XCTAssertEqual(listed.count, 1)
    }
}
