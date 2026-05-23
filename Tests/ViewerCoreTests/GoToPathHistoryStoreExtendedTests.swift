import XCTest
@testable import ViewerCore

/// Additional coverage for `GoToPathHistoryStore` — corruption
/// tolerance, ordering invariants, and dedupe semantics that the base
/// suite doesn't exercise.
final class GoToPathHistoryStoreExtendedTests: XCTestCase {

    private var tmpDir: URL!
    private var storeURL: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GoToPathHistoryStoreExt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        storeURL = tmpDir.appendingPathComponent("recent-paths.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - Corruption tolerance

    func test_corruptedJSON_yieldsEmpty_doesNotCrash() throws {
        // Write garbage to the store; the loader must tolerate it.
        try "this is not JSON {{{".data(using: .utf8)!.write(to: storeURL)
        let s = GoToPathHistoryStore(storeURL: storeURL)
        XCTAssertEqual(s.recent(), [])
        // Subsequent record still works — load failure shouldn't lock
        // the store out of the disk path.
        s.record("/recovery")
        XCTAssertEqual(s.recent(), ["/recovery"])
    }

    func test_truncatedJSON_yieldsEmpty() throws {
        try "[\"/a\", \"/b".data(using: .utf8)!.write(to: storeURL)
        let s = GoToPathHistoryStore(storeURL: storeURL)
        XCTAssertEqual(s.recent(), [])
    }

    func test_unexpectedTopLevelType_yieldsEmpty() throws {
        // A dictionary at the top is not what we expect — defensive
        // decoder should fall through to empty rather than crash.
        try #"{"unexpected": "shape"}"#.data(using: .utf8)!.write(to: storeURL)
        let s = GoToPathHistoryStore(storeURL: storeURL)
        XCTAssertEqual(s.recent(), [])
    }

    func test_oversizedFile_isRejected() throws {
        // Build a JSON array that exceeds the 64 KiB ceiling.
        let big = (0..<2_000).map { "/path/with/a/really-long-segment-\($0)-padding-padding-padding" }
        try JSONEncoder().encode(big).write(to: storeURL)
        let attrs = try FileManager.default.attributesOfItem(atPath: storeURL.path)
        XCTAssertGreaterThan(attrs[.size] as? Int ?? 0, 64 * 1024)

        let s = GoToPathHistoryStore(storeURL: storeURL)
        XCTAssertEqual(s.recent(), [], "oversize file should reject, not load")
    }

    // MARK: - Ordering invariants

    func test_recentOrdering_mostRecentFirst() {
        let s = GoToPathHistoryStore(storeURL: storeURL)
        s.record("/one")
        s.record("/two")
        s.record("/three")
        XCTAssertEqual(s.recent(), ["/three", "/two", "/one"])
    }

    func test_reAddingMiddle_movesToFront_preservesRest() {
        let s = GoToPathHistoryStore(storeURL: storeURL)
        s.record("/one")
        s.record("/two")
        s.record("/three")
        s.record("/two")
        XCTAssertEqual(s.recent(), ["/two", "/three", "/one"])
    }

    func test_reAddingMostRecent_isNoOp_inEffect() {
        let s = GoToPathHistoryStore(storeURL: storeURL)
        s.record("/a")
        s.record("/b")
        s.record("/b")  // re-adding head
        XCTAssertEqual(s.recent(), ["/b", "/a"])
    }

    // MARK: - Dedupe semantics

    func test_dedupe_isExactStringMatch_notNormalized() {
        // The store doesn't normalize "~/foo" vs "/Users/me/foo" — it
        // dedupes by exact string. Documenting this here so anyone who
        // changes that behavior must update the test.
        let s = GoToPathHistoryStore(storeURL: storeURL)
        s.record("/Users/me/Documents/foo.md")
        s.record("/Users/me/Documents/foo.md/")  // trailing slash
        XCTAssertEqual(s.recent().count, 2, "different strings = different entries")
    }

    func test_trimSemantics_emptyAfterTrim_isIgnored_atRecordLevel() {
        // record() guards against empty path but does NOT trim whitespace
        // — callers (typically GoToPathExpansion.expand) are expected to
        // produce a clean absolute path. Document by asserting.
        let s = GoToPathHistoryStore(storeURL: storeURL)
        s.record("  ")  // recorded as-is (whitespace string is not empty)
        XCTAssertEqual(s.recent(), ["  "])
    }

    // MARK: - Cap interaction with persistence

    func test_capRespected_acrossReloads() {
        let s1 = GoToPathHistoryStore(storeURL: storeURL, maxEntries: 3)
        s1.record("/a")
        s1.record("/b")
        s1.record("/c")
        s1.record("/d")

        let s2 = GoToPathHistoryStore(storeURL: storeURL, maxEntries: 3)
        XCTAssertEqual(s2.recent(), ["/d", "/c", "/b"])
        XCTAssertEqual(s2.count, 3)
    }

    func test_smallerCapOnReload_truncates() {
        let s1 = GoToPathHistoryStore(storeURL: storeURL, maxEntries: 10)
        for i in 0..<8 { s1.record("/p\(i)") }
        XCTAssertEqual(s1.count, 8)

        let s2 = GoToPathHistoryStore(storeURL: storeURL, maxEntries: 3)
        XCTAssertEqual(s2.count, 3, "load-side cap must trim down")
        XCTAssertEqual(s2.recent(), ["/p7", "/p6", "/p5"])
    }
}
