import Foundation
import XCTest
@testable import ViewerCore

/// PERSIST-02 (audit THEME 1): `BookmarksStore` decoded its array STRICTLY, so
/// a single malformed entry failed the whole decode → `entries` stayed empty →
/// the next bookmark toggle SAVED that empty list over the file. One bad row
/// silently destroyed every bookmark, permanently.
///
/// `HistoryStore` / `FeedSubscriptionStore` already read leniently; bookmarks
/// were the outlier.
final class BookmarksLenientDecodeTests: XCTestCase {

    private var dir: URL!
    private var storeURL: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookmarksLenient-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storeURL = dir.appendingPathComponent("bookmarks.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// A file whose entries are all valid still loads completely.
    func test_validFile_loadsEveryEntry() throws {
        try write("""
        [{"url":"file:///a.md","addedAt":1},{"url":"file:///b.md","addedAt":2}]
        """)
        XCTAssertEqual(BookmarksStore(storeURL: storeURL).all().count, 2)
    }

    /// THE FIX: one unparseable row must cost only that row.
    func test_oneMalformedEntry_keepsTheOthers_insteadOfWipingAll() throws {
        try write("""
        [{"url":"file:///a.md","addedAt":1},
         {"nonsense":true},
         {"url":"file:///c.md","addedAt":3}]
        """)
        let store = BookmarksStore(storeURL: storeURL)
        XCTAssertEqual(store.all().count, 2,
                       "the two good bookmarks must survive one bad row")
        XCTAssertTrue(store.all().contains { $0.url.path.hasSuffix("a.md") })
        XCTAssertTrue(store.all().contains { $0.url.path.hasSuffix("c.md") })
    }

    /// The destructive sequence the bug actually produced: load wipes → a
    /// toggle saves the empty list → the survivors are gone from DISK too.
    func test_survivorsAreNotClobberedByTheNextWrite() throws {
        try write("""
        [{"url":"file:///a.md","addedAt":1},{"broken":1},{"url":"file:///c.md","addedAt":3}]
        """)
        let store = BookmarksStore(storeURL: storeURL)
        _ = store.toggle(url: URL(fileURLWithPath: "/d.md"))     // forces a save()

        // Re-read from disk with a fresh store: the survivors must still be
        // there. (Whether the toggle itself added a row is beside the point —
        // what the bug destroyed was the EXISTING bookmarks.)
        let reloaded = BookmarksStore(storeURL: storeURL)
        XCTAssertTrue(reloaded.all().contains { $0.url.path.hasSuffix("a.md") },
                      "a save after a partial load must not erase the survivors")
        XCTAssertTrue(reloaded.all().contains { $0.url.path.hasSuffix("c.md") })
    }

    private func write(_ json: String) throws {
        try Data(json.utf8).write(to: storeURL)
    }
}
