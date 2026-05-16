import XCTest
@testable import ViewerCore

/// Line-bookmark coverage for BookmarksStore (commit-pair with task
/// #122 — line bookmarks). Verifies the line-aware add / contains /
/// remove / toggle paths coexist with whole-file bookmarks of the
/// same URL.
final class LineBookmarksTests: XCTestCase {

    private var storeURL: URL!

    override func setUp() {
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LineBookmarks-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: storeURL)
    }

    private func makeStore() -> BookmarksStore {
        BookmarksStore(storeURL: storeURL, maxEntries: 100)
    }

    private let fileA = URL(fileURLWithPath: "/tmp/a.swift")

    // MARK: -

    func test_add_line_bookmark_does_not_conflict_with_file_bookmark() {
        let s = makeStore()
        s.add(url: fileA)               // whole-file
        s.add(url: fileA, line: 42)     // line
        XCTAssertEqual(s.all().count, 2,
                       "file and line bookmarks for the same URL should coexist")
        XCTAssertTrue(s.contains(url: fileA, line: nil))
        XCTAssertTrue(s.contains(url: fileA, line: 42))
    }

    func test_contains_line_aware_lookup() {
        let s = makeStore()
        s.add(url: fileA, line: 10)
        XCTAssertTrue(s.contains(url: fileA, line: 10))
        XCTAssertFalse(s.contains(url: fileA, line: 11),
                       "wrong line must not match")
        XCTAssertFalse(s.contains(url: fileA, line: nil),
                       "line bookmark must not satisfy file-level contains")
    }

    func test_legacy_contains_returns_true_for_any_entry_at_url() {
        // The single-arg `contains(_:)` is the existing star-indicator
        // check — true if ANY entry exists for that URL.
        let s = makeStore()
        s.add(url: fileA, line: 7)
        XCTAssertTrue(s.contains(fileA),
                      "URL-only contains must match line bookmarks too")
    }

    func test_remove_line_specific() {
        let s = makeStore()
        s.add(url: fileA, line: 1)
        s.add(url: fileA, line: 2)
        s.remove(url: fileA, line: 1)
        XCTAssertFalse(s.contains(url: fileA, line: 1))
        XCTAssertTrue(s.contains(url: fileA, line: 2))
    }

    func test_remove_file_level_keeps_line_bookmarks() {
        // Calling `remove(url:line:nil)` should only sweep the file-
        // level entry; line bookmarks survive.
        let s = makeStore()
        s.add(url: fileA)               // file
        s.add(url: fileA, line: 100)    // line
        s.remove(url: fileA, line: nil)
        XCTAssertFalse(s.contains(url: fileA, line: nil))
        XCTAssertTrue(s.contains(url: fileA, line: 100))
    }

    func test_toggle_line_bookmark() {
        let s = makeStore()
        XCTAssertTrue(s.toggle(url: fileA, line: 5),
                      "first toggle = added")
        XCTAssertTrue(s.contains(url: fileA, line: 5))
        XCTAssertFalse(s.toggle(url: fileA, line: 5),
                       "second toggle = removed")
        XCTAssertFalse(s.contains(url: fileA, line: 5))
    }

    func test_id_distinguishes_file_from_line() {
        let s = makeStore()
        let file = s.add(url: fileA)
        let line = s.add(url: fileA, line: 99)
        XCTAssertNotEqual(file.id, line.id,
                          "Identifiable id must distinguish whole-file from line bookmarks")
        XCTAssertTrue(line.id.contains("#L99"))
    }

    func test_codable_roundtrip_keeps_line_value() {
        var s = makeStore()
        s.add(url: fileA, line: 23)
        // Force a fresh load.
        s = BookmarksStore(storeURL: storeURL, maxEntries: 100)
        XCTAssertTrue(s.contains(url: fileA, line: 23))
        XCTAssertEqual(s.all().first?.line, 23)
    }

    func test_legacy_decoder_defaults_line_to_nil() throws {
        // Hand-write a pre-rename JSON file (no `line` field) and
        // verify it loads with line=nil instead of failing.
        let legacy = """
        [
          {
            "url": "file:///tmp/legacy.swift",
            "addedAt": "2024-01-01T00:00:00Z",
            "displayName": "legacy.swift"
          }
        ]
        """
        try legacy.write(to: storeURL, atomically: true, encoding: .utf8)
        let s = makeStore()
        XCTAssertEqual(s.all().count, 1)
        XCTAssertNil(s.all().first?.line)
    }
}
