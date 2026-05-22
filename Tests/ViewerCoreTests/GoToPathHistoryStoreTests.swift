import XCTest
@testable import ViewerCore

final class GoToPathHistoryStoreTests: XCTestCase {
    private var tmpDir: URL!
    private var storeURL: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GoToPathHistoryStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        storeURL = tmpDir.appendingPathComponent("recent-paths.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - record / FIFO / dedupe

    func test_record_addsEntry() {
        let store = GoToPathHistoryStore(storeURL: storeURL)
        store.record("/Users/me/foo.md")
        XCTAssertEqual(store.recent(), ["/Users/me/foo.md"])
    }

    func test_record_dedupesAndMovesToFront() {
        let store = GoToPathHistoryStore(storeURL: storeURL)
        store.record("/a")
        store.record("/b")
        store.record("/a")
        XCTAssertEqual(store.recent(), ["/a", "/b"])
    }

    func test_record_capsAtMax() {
        let store = GoToPathHistoryStore(storeURL: storeURL, maxEntries: 3)
        store.record("/a")
        store.record("/b")
        store.record("/c")
        store.record("/d")
        XCTAssertEqual(store.recent(), ["/d", "/c", "/b"])
        XCTAssertEqual(store.count, 3)
    }

    func test_record_ignoresEmpty() {
        let store = GoToPathHistoryStore(storeURL: storeURL)
        store.record("")
        XCTAssertEqual(store.recent(), [])
    }

    // MARK: - persistence

    func test_persistenceRoundTrip() {
        let s1 = GoToPathHistoryStore(storeURL: storeURL)
        s1.record("/a")
        s1.record("/b")

        let s2 = GoToPathHistoryStore(storeURL: storeURL)
        XCTAssertEqual(s2.recent(), ["/b", "/a"])
    }

    func test_load_missingFileYieldsEmpty() {
        let s = GoToPathHistoryStore(storeURL: storeURL)
        XCTAssertEqual(s.recent(), [])
    }

    func test_load_capsTrustedFileToMaxEntries() throws {
        // Simulate a tampered / out-of-spec file with > maxEntries.
        let big = (0..<50).map { "/p\($0)" }
        try JSONEncoder().encode(big).write(to: storeURL)

        let s = GoToPathHistoryStore(storeURL: storeURL, maxEntries: 10)
        XCTAssertEqual(s.recent().count, 10)
    }

    func test_clear_removesAllAndPersists() {
        let s1 = GoToPathHistoryStore(storeURL: storeURL)
        s1.record("/a")
        s1.clear()
        XCTAssertEqual(s1.recent(), [])

        let s2 = GoToPathHistoryStore(storeURL: storeURL)
        XCTAssertEqual(s2.recent(), [])
    }

    // MARK: - path expansion

    func test_expand_empty() {
        XCTAssertEqual(GoToPathExpansion.expand(""),  .failure(.empty))
        XCTAssertEqual(GoToPathExpansion.expand("   "), .failure(.empty))
    }

    func test_expand_relativeRejected() {
        XCTAssertEqual(GoToPathExpansion.expand("foo/bar"),    .failure(.relative))
        XCTAssertEqual(GoToPathExpansion.expand("./foo"),      .failure(.relative))
        XCTAssertEqual(GoToPathExpansion.expand("../foo"),     .failure(.relative))
    }

    func test_expand_absolutePassesThrough() {
        XCTAssertEqual(
            GoToPathExpansion.expand("/Users/me/foo.md"),
            .success("/Users/me/foo.md")
        )
    }

    func test_expand_trimsWhitespace() {
        XCTAssertEqual(
            GoToPathExpansion.expand("  /tmp/foo  "),
            .success("/tmp/foo")
        )
    }

    func test_expand_tildeExpands() {
        // NSString.expandingTildeInPath returns the user's home.
        let home = NSHomeDirectory()
        switch GoToPathExpansion.expand("~") {
        case .success(let p): XCTAssertEqual(p, home)
        case .failure(let e): XCTFail("expected success, got \(e)")
        }
        switch GoToPathExpansion.expand("~/Library") {
        case .success(let p): XCTAssertEqual(p, home + "/Library")
        case .failure(let e): XCTFail("expected success, got \(e)")
        }
    }

    func test_expand_unknownTildeUserIsRelative() {
        // `~nobodynamedlikethisexists` doesn't resolve → NSString
        // leaves the leading tilde in place → we classify as relative.
        switch GoToPathExpansion.expand("~doesnotexist-zzzz/foo") {
        case .failure(let e): XCTAssertEqual(e, .relative)
        case .success(let p):
            // On some systems "~user" may match an arbitrary entry —
            // accept either outcome but require the result is absolute.
            XCTAssertTrue(p.hasPrefix("/"))
        }
    }

    // MARK: - resolveExisting

    func test_resolveExisting_realFile() throws {
        let f = tmpDir.appendingPathComponent("hi.txt")
        try "x".write(to: f, atomically: true, encoding: .utf8)
        switch GoToPathExpansion.resolveExisting(f.path) {
        case .success(let u): XCTAssertEqual(u.path, f.path)
        case .failure(let e): XCTFail("expected success, got \(e)")
        }
    }

    func test_resolveExisting_missingPath() {
        let result = GoToPathExpansion.resolveExisting("/tmp/this-path-does-not-exist-\(UUID().uuidString)")
        XCTAssertEqual(result, .failure(.notFound))
    }

    func test_resolveExisting_relativeRejected() {
        XCTAssertEqual(
            GoToPathExpansion.resolveExisting("relative/path"),
            .failure(.relative)
        )
    }

    func test_isDirectory_detectsBoth() throws {
        let dir = tmpDir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = tmpDir.appendingPathComponent("file.md")
        try "x".write(to: file, atomically: true, encoding: .utf8)

        XCTAssertTrue(GoToPathExpansion.isDirectory(dir.path))
        XCTAssertFalse(GoToPathExpansion.isDirectory(file.path))
        XCTAssertFalse(GoToPathExpansion.isDirectory("/no/such/path-\(UUID().uuidString)"))
    }
}
