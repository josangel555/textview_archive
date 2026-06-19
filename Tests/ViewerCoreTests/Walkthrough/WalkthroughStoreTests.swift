import XCTest
@testable import ViewerCore

/// Host coverage for `WalkthroughStore` — the durable "save
/// walkthroughs" library (the retention half of TSK-778). Pure logic +
/// a temp library directory, so the full save/list/load/delete contract
/// is exercised on the host with no UI/VM.
///
/// The security-relevant property — an untrusted script `id` can never
/// produce a file outside the library dir — is pinned hardest, since a
/// `save` is reachable from the file-drop boundary.
final class WalkthroughStoreTests: XCTestCase {

    // MARK: - Fixtures

    private func tempLibrary() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("wt-store-\(UUID().uuidString)", isDirectory: true)
    }

    private func sampleScript(
        id: String,
        title: String = "Tour",
        createdAt: Date? = nil,
        steps: Int = 1
    ) -> WalkthroughScript {
        WalkthroughScript(
            id: id,
            title: title,
            author: "human:jos",
            createdAt: createdAt,
            rootHint: "/tmp/repo",
            steps: (0..<steps).map { i in
                Step(id: "s\(i)", narration: "step \(i)", actions: [.narrateOnly])
            }
        )
    }

    // MARK: - Save / load round-trip

    func test_save_thenLoad_roundTrips() throws {
        let dir = tempLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WalkthroughStore(libraryDirectory: dir)

        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let original = sampleScript(id: "engine-tour", title: "Engine tour",
                                    createdAt: created, steps: 3)
        let url = try store.save(original)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(url.lastPathComponent, "engine-tour.json")

        let loaded = try XCTUnwrap(store.load(id: "engine-tour"))
        XCTAssertEqual(loaded, original)
        XCTAssertEqual(loaded.steps.count, 3)
    }

    func test_save_createsLibraryDirectoryLazily() throws {
        let dir = tempLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path),
                       "precondition: library dir does not exist yet")
        let store = WalkthroughStore(libraryDirectory: dir)
        try store.save(sampleScript(id: "x"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
    }

    func test_save_isUpsert_overwritesSameID() throws {
        let dir = tempLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WalkthroughStore(libraryDirectory: dir)

        try store.save(sampleScript(id: "dup", title: "First", steps: 1))
        try store.save(sampleScript(id: "dup", title: "Second", steps: 5))

        let loaded = try XCTUnwrap(store.load(id: "dup"))
        XCTAssertEqual(loaded.title, "Second")
        XCTAssertEqual(loaded.steps.count, 5)
        XCTAssertEqual(store.list().count, 1, "upsert must not create a duplicate file")
    }

    func test_load_missing_returnsNil() throws {
        let dir = tempLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WalkthroughStore(libraryDirectory: dir)
        XCTAssertNil(try store.load(id: "nope"))
    }

    func test_load_corruptFile_throwsLoadFailed() throws {
        let dir = tempLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WalkthroughStore(libraryDirectory: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = try store.fileURL(forID: "bad")
        try Data("{ not valid json".utf8).write(to: url)

        XCTAssertThrowsError(try store.load(id: "bad")) { err in
            guard case StoreError.loadFailed = err else {
                return XCTFail("Expected .loadFailed, got \(err)")
            }
        }
    }

    // MARK: - List

    func test_list_emptyLibrary_returnsEmpty() {
        let dir = tempLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WalkthroughStore(libraryDirectory: dir)
        XCTAssertEqual(store.list(), [])
        XCTAssertEqual(store.listResult().skipped, 0)
    }

    func test_list_returnsMetadataWithoutFullSteps() throws {
        let dir = tempLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WalkthroughStore(libraryDirectory: dir)
        try store.save(sampleScript(id: "meta", title: "Meta tour", steps: 7))

        let rows = store.list()
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.id, "meta")
        XCTAssertEqual(row.title, "Meta tour")
        XCTAssertEqual(row.author, "human:jos")
        XCTAssertEqual(row.stepCount, 7)
        XCTAssertEqual(row.fileURL.lastPathComponent, "meta.json")
    }

    func test_list_sortsByCreatedAtDescending_thenID() throws {
        let dir = tempLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WalkthroughStore(libraryDirectory: dir)

        let old = Date(timeIntervalSince1970: 1_000)
        let new = Date(timeIntervalSince1970: 2_000)
        try store.save(sampleScript(id: "older", createdAt: old))
        try store.save(sampleScript(id: "newer", createdAt: new))
        try store.save(sampleScript(id: "zzz-undated", createdAt: nil))
        try store.save(sampleScript(id: "aaa-undated", createdAt: nil))

        let ids = store.list().map(\.id)
        // Dated newest-first, then undated by id ascending.
        XCTAssertEqual(ids, ["newer", "older", "aaa-undated", "zzz-undated"])
    }

    func test_list_skipsCorruptFiles_andCountsThem() throws {
        let dir = tempLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WalkthroughStore(libraryDirectory: dir)
        try store.save(sampleScript(id: "good"))
        // A corrupt sibling must not blank the whole listing.
        try Data("garbage".utf8).write(
            to: dir.appendingPathComponent("rotten.json"))

        let result = store.listResult()
        XCTAssertEqual(result.items.map(\.id), ["good"])
        XCTAssertEqual(result.skipped, 1)
    }

    func test_list_ignoresNonJSONFiles() throws {
        let dir = tempLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WalkthroughStore(libraryDirectory: dir)
        try store.save(sampleScript(id: "real"))
        try Data("note".utf8).write(to: dir.appendingPathComponent("README.txt"))

        XCTAssertEqual(store.list().map(\.id), ["real"])
        XCTAssertEqual(store.listResult().skipped, 0,
                       "a non-.json file is not a corrupt walkthrough")
    }

    // MARK: - Delete / exists

    func test_delete_removesFile_andIsIdempotent() throws {
        let dir = tempLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WalkthroughStore(libraryDirectory: dir)
        try store.save(sampleScript(id: "tmp"))

        XCTAssertTrue(store.exists(id: "tmp"))
        XCTAssertTrue(try store.delete(id: "tmp"))
        XCTAssertFalse(store.exists(id: "tmp"))
        XCTAssertNil(try store.load(id: "tmp"))
        // Second delete is a no-op, returns false.
        XCTAssertFalse(try store.delete(id: "tmp"))
    }

    func test_exists_falseForMissing() {
        let dir = tempLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WalkthroughStore(libraryDirectory: dir)
        XCTAssertFalse(store.exists(id: "ghost"))
    }

    // MARK: - id sanitization / path-traversal containment (security)

    func test_fileURL_alwaysInsideLibrary_evenForTraversalIDs() throws {
        let dir = tempLibrary().standardizedFileURL
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WalkthroughStore(libraryDirectory: dir)

        let nasty = [
            "normal-id",
            "with spaces and *weird* chars!",
            "../escape",
            "../../etc/passwd",
            "foo/bar/baz",
            "name.with.dots",
        ]
        for id in nasty {
            guard let url = try? store.fileURL(forID: id) else { continue }
            let resolved = url.standardizedFileURL.path
            XCTAssertTrue(
                resolved.hasPrefix(dir.path + "/"),
                "id \(id) escaped the library: \(resolved)")
            XCTAssertFalse(resolved.contains(".."),
                           "id \(id) left a .. component: \(resolved)")
            // Exactly one component below the library dir.
            XCTAssertEqual(
                url.deletingLastPathComponent().standardizedFileURL.path,
                dir.path,
                "id \(id) nested below the library: \(resolved)")
        }
    }

    func test_save_traversalID_landsInsideLibrary_notOutside() throws {
        let dir = tempLibrary().standardizedFileURL
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WalkthroughStore(libraryDirectory: dir)

        let url = try store.save(sampleScript(id: "../../escape-me"))
        XCTAssertTrue(url.standardizedFileURL.path.hasPrefix(dir.path + "/"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        // And the file did NOT appear at the traversal target.
        let escaped = dir.deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("escape-me.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: escaped.path))
    }

    func test_unsanitizableID_rejected() {
        let dir = tempLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WalkthroughStore(libraryDirectory: dir)

        // Ids that reduce to an empty safe filename.
        for empty in ["", "../", "...", "///", "!!!", "."] {
            XCTAssertThrowsError(try store.save(sampleScript(id: empty)),
                                 "id \(empty) should be rejected") { err in
                guard case StoreError.invalidID = err else {
                    return XCTFail("Expected .invalidID for \(empty), got \(err)")
                }
            }
        }
    }

    func test_sanitizedFilename_rules() {
        // Allowed chars survive; runs of disallowed collapse to one `_`.
        XCTAssertEqual(WalkthroughStore.sanitizedFilename(forID: "abc-123_DEF.json"),
                       "abc-123_DEF.json")
        XCTAssertEqual(WalkthroughStore.sanitizedFilename(forID: "a/b\\c"), "a_b_c")
        XCTAssertEqual(WalkthroughStore.sanitizedFilename(forID: "a   b"), "a_b")
        // Leading dots stripped (no dotfiles, no traversal).
        XCTAssertEqual(WalkthroughStore.sanitizedFilename(forID: ".hidden"), "hidden")
        XCTAssertEqual(WalkthroughStore.sanitizedFilename(forID: "..bad"), "bad")
        // Surrounding underscores trimmed.
        XCTAssertEqual(WalkthroughStore.sanitizedFilename(forID: "!leading"), "leading")
        XCTAssertEqual(WalkthroughStore.sanitizedFilename(forID: "trailing!"), "trailing")
        // Empties.
        XCTAssertEqual(WalkthroughStore.sanitizedFilename(forID: "../"), "")
        XCTAssertEqual(WalkthroughStore.sanitizedFilename(forID: "..."), "")
        // Length cap.
        XCTAssertEqual(
            WalkthroughStore.sanitizedFilename(forID: String(repeating: "a", count: 500)).count,
            120)
    }

    // MARK: - Canonical serialization

    func test_savedJSON_isSortedAndPretty() throws {
        let dir = tempLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WalkthroughStore(libraryDirectory: dir)
        let url = try store.save(sampleScript(id: "fmt"))
        let text = try String(contentsOf: url, encoding: .utf8)
        // Pretty-printed ⇒ newlines + indentation present.
        XCTAssertTrue(text.contains("\n"), "expected pretty-printed JSON")
        // Sorted keys ⇒ `author` precedes `id` precedes `schema` etc.
        guard let authorIdx = text.range(of: "\"author\"")?.lowerBound,
              let schemaIdx = text.range(of: "\"schema\"")?.lowerBound else {
            return XCTFail("expected author + schema keys in output")
        }
        XCTAssertLessThan(authorIdx, schemaIdx, "keys should be sorted")
    }

    // MARK: - Default library directory shape

    func test_defaultLibraryDirectory_isUnprefixedAppSupportSubdir() {
        let url = WalkthroughStore.defaultLibraryDirectory()
        XCTAssertEqual(url.lastPathComponent, "Walkthroughs")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent,
                       "MarkdownViewer",
                       "library must sit under the UN-prefixed MarkdownViewer dir")
        XCTAssertFalse(url.path.contains("com.markdownviewer.MarkdownViewer"),
                       "library must NOT be under the bundle-id-prefixed dir")
    }
}
