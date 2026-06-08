import XCTest
@testable import ViewerCore

/// Stage 1 (CODE_REVIEW_V2_DESIGN_2026-06-01.md §7): the project-local
/// `.textview/reviews/` store resolver. Asserts path resolution, the
/// `MDV_TEXTVIEW_DIR` override, full CRUD round-trip in a temp `.textview/`,
/// and that the format is byte-for-byte the existing `ReviewStore` shape
/// (parity-with-global) — proving the ONLY change is the directory.
final class ReviewStoreProjectLocalTests: XCTestCase {

    private var repoRoot: URL!

    override func setUpWithError() throws {
        repoRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-rev-pl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repoRoot)
    }

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeReview(id: String = ReviewID.generate(), title: String = "T") -> Review {
        Review(
            id: id, createdAt: t0, updatedAt: t0, title: title,
            scope: .commit(sha: "abc123"), repoRoot: repoRoot.path,
            baseSha: nil, headSha: nil, state: .draft, comments: [],
            author: ReviewAuthor(name: "Jos", email: "jos@x")
        )
    }

    // MARK: - Path resolution

    func test_projectLocalDirectory_resolvesTo_dotTextviewReviews() {
        let dir = ReviewStore.projectLocalDirectory(repoRoot: repoRoot, environment: [:])
        XCTAssertEqual(
            dir.standardizedFileURL.path,
            repoRoot.appendingPathComponent(".textview/reviews").standardizedFileURL.path
        )
    }

    func test_projectLocal_createsTheReviewsDirectoryEagerly() {
        _ = ReviewStore.projectLocal(repoRoot: repoRoot, environment: [:])
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: repoRoot.appendingPathComponent(".textview/reviews").path,
            isDirectory: &isDir
        )
        XCTAssertTrue(exists)
        XCTAssertTrue(isDir.boolValue)
    }

    func test_envOverride_relocatesTheSidecar() {
        let override = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-override-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: override) }

        let env = [ReviewStore.sidecarDirEnvVar: override.path]
        let dir = ReviewStore.projectLocalDirectory(repoRoot: repoRoot, environment: env)
        XCTAssertEqual(
            dir.standardizedFileURL.path,
            override.appendingPathComponent("reviews").standardizedFileURL.path
        )
        // The repo's own .textview must NOT be used when overridden.
        XCTAssertFalse(dir.path.contains(repoRoot.lastPathComponent))
    }

    func test_emptyOrWhitespaceOverride_isIgnored_fallsBackToRepoLocal() {
        for bad in ["", "   "] {
            let env = [ReviewStore.sidecarDirEnvVar: bad]
            let dir = ReviewStore.projectLocalDirectory(repoRoot: repoRoot, environment: env)
            XCTAssertEqual(
                dir.standardizedFileURL.path,
                repoRoot.appendingPathComponent(".textview/reviews").standardizedFileURL.path
            )
        }
    }

    // MARK: - CRUD round-trip in the project-local dir

    func test_saveLoadList_delete_roundTrip_inProjectLocalDir() {
        let store = ReviewStore.projectLocal(repoRoot: repoRoot, environment: [:])
        let r = makeReview(title: "Round trip")

        XCTAssertTrue(store.save(r))
        XCTAssertEqual(store.load(id: r.id), r)

        let list = store.list()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?.id, r.id)
        XCTAssertEqual(list.first?.title, "Round trip")

        store.delete(id: r.id)
        XCTAssertNil(store.load(id: r.id))
        XCTAssertTrue(store.list().isEmpty)
    }

    func test_savedFileLandsUnder_dotTextviewReviews() {
        let store = ReviewStore.projectLocal(repoRoot: repoRoot, environment: [:])
        let r = makeReview()
        XCTAssertTrue(store.save(r))

        let expected = repoRoot
            .appendingPathComponent(".textview/reviews/\(r.id).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path))
    }

    // MARK: - Parity with the global store (only the directory changed)

    func test_onDiskBytes_identicalToGlobalStore_forSameReview() throws {
        let r = makeReview(id: "01HF7QABCDEFGHJKMNPQRSTVWX", title: "Parity")

        // Project-local write.
        let plStore = ReviewStore.projectLocal(repoRoot: repoRoot, environment: [:])
        XCTAssertTrue(plStore.save(r))
        let plURL = repoRoot.appendingPathComponent(".textview/reviews/\(r.id).json")
        let plBytes = try Data(contentsOf: plURL)

        // Global-style write into an arbitrary injected directory.
        let globalDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-global-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: globalDir) }
        try FileManager.default.createDirectory(at: globalDir, withIntermediateDirectories: true)
        let gStore = ReviewStore(directory: globalDir)
        XCTAssertTrue(gStore.save(r))
        let gURL = globalDir.appendingPathComponent("\(r.id).json")
        let gBytes = try Data(contentsOf: gURL)

        XCTAssertEqual(plBytes, gBytes, "project-local format must be byte-identical to global")
    }

    // MARK: - Corruption tolerance (inherited from ReviewStore, re-pinned here)

    func test_oversizeFile_isRefused_inProjectLocalDir() throws {
        let store = ReviewStore.projectLocal(repoRoot: repoRoot, environment: [:])
        let id = "01HF7QABCDEFGHJKMNPQRSTVWX"
        let url = repoRoot.appendingPathComponent(".textview/reviews/\(id).json")
        // 11 MiB of junk — over the 10 MiB guard.
        let big = Data(count: 11 * 1024 * 1024)
        try big.write(to: url)
        XCTAssertNil(store.load(id: id))
    }

    /// Teeth for TSK-180 ([S3][security]): `loadIndex()` reads `_index.json`
    /// — the index-tab boot path — and that read MUST be size-capped, exactly
    /// like the per-review-file read. The dir is user-writable, so a
    /// tampered/runaway `_index.json` would otherwise inflate unbounded into
    /// memory on every `list()`.
    ///
    /// Distinct from `test_oversizeFile_isRefused_inProjectLocalDir`, which
    /// guards the per-review `<id>.json` read. This writes a *valid but
    /// oversized* `_index.json` whose single cached summary shares the real
    /// review's id (so the consistency check `Set(cached.id) == onDiskIDs`
    /// would PASS) but carries a bogus title. With the cap, `loadIndex`
    /// returns nil → `list()` falls back to rebuild-by-scan and returns the
    /// REAL on-disk title. Without the cap (regression), `list()` would
    /// trust the oversized cache and return the bogus title — so this assert
    /// goes red the moment the `maxSize:` is dropped.
    func test_oversizeIndex_isRefused_listFallsBackToScan() throws {
        let store = ReviewStore.projectLocal(repoRoot: repoRoot, environment: [:])
        let real = makeReview(id: "01HF7QABCDEFGHJKMNPQRSTVWX", title: "Real on-disk title")
        XCTAssertTrue(store.save(real))  // writes <id>.json AND _index.json

        // Overwrite _index.json with a VALID [ReviewSummary] that is >10 MiB:
        // one entry, same id (so the consistency check would accept it),
        // bogus 11 MiB title.
        let bogusTitle = String(repeating: "A", count: 11 * 1024 * 1024)
        let oversized = [ReviewSummary(
            id: real.id, title: bogusTitle, state: .draft,
            updatedAt: t0, commentCount: 0, unresolvedCount: 0
        )]
        // Encode with the store's OWN encoder (ISO-8601 dates) so the index
        // is genuinely decodable — otherwise `loadIndex` fails to decode for
        // an unrelated reason and the cap isn't what's being exercised.
        let encoded = try JSONFileStore.encoder.encode(oversized)
        XCTAssertGreaterThan(
            encoded.count, ReviewStore.maxReviewFileSize,
            "test fixture must exceed the cap or it proves nothing"
        )
        let indexURL = repoRoot.appendingPathComponent(".textview/reviews/_index.json")
        try encoded.write(to: indexURL)

        // The cap refuses the oversized index → scan path wins → real title.
        // Compare via a bool so a regression doesn't dump the 11 MiB bogus
        // title into the failure log.
        let list = store.list()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?.id, real.id)
        XCTAssertTrue(
            list.first?.title == "Real on-disk title",
            "list() returned the oversized _index.json's cached entry instead of rebuilding from disk — the size cap on loadIndex was bypassed"
        )
    }

    func test_corruptJSON_loadsAsNil_listSurvives() throws {
        let store = ReviewStore.projectLocal(repoRoot: repoRoot, environment: [:])
        let good = makeReview()
        XCTAssertTrue(store.save(good))

        // Drop a corrupt sibling.
        let badURL = repoRoot
            .appendingPathComponent(".textview/reviews/01HF7QABCDEFGHJKMNPQRSTVWX.json")
        try Data("{ not json".utf8).write(to: badURL)

        XCTAssertNil(store.load(id: "01HF7QABCDEFGHJKMNPQRSTVWX"))
        // The good review still lists (rebuildIndex skips the unreadable one).
        store.rebuildIndex()
        XCTAssertTrue(store.list().contains { $0.id == good.id })
    }
}
