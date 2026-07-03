import XCTest
@testable import ViewerCore

final class BookmarksStoreTests: XCTestCase {

    private var storeURL: URL!

    override func setUp() {
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Bookmarks-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: storeURL)
    }

    private func makeStore() -> BookmarksStore {
        // P2: `save()` is async/coalesced (off-main) — drain pending writes
        // from any prior store so a reopen reads the latest bytes from disk.
        JSONFileStore.flushSync()
        return BookmarksStore(storeURL: storeURL, maxEntries: 100)
    }

    func test_emptyStore_returnsNoBookmarks() {
        XCTAssertEqual(makeStore().all().count, 0)
    }

    func test_add_singleURL_appears() {
        let s = makeStore()
        s.add(url: URL(fileURLWithPath: "/tmp/a.md"))
        XCTAssertEqual(s.all().count, 1)
        XCTAssertTrue(s.contains(URL(fileURLWithPath: "/tmp/a.md")))
    }

    func test_add_duplicateURL_doesNotGrow() {
        let s = makeStore()
        s.add(url: URL(fileURLWithPath: "/tmp/a.md"))
        s.add(url: URL(fileURLWithPath: "/tmp/a.md"))
        XCTAssertEqual(s.all().count, 1)
    }

    // MARK: - Prune missing (TSK-1464)

    func test_pruneMissing_removesOnlyDeadTargets() {
        let s = makeStore()
        s.add(url: URL(fileURLWithPath: "/live/a.md"))
        s.add(url: URL(fileURLWithPath: "/dead/b.md"))
        s.add(url: URL(fileURLWithPath: "/live/c.md"), line: 12)
        s.add(url: URL(fileURLWithPath: "/dead/d.md"), line: 3)

        let removed = s.pruneMissing(fileExists: { $0.path.hasPrefix("/live/") })
        XCTAssertEqual(Set(removed.map(\.url.path)), ["/dead/b.md", "/dead/d.md"])
        XCTAssertEqual(Set(s.all().map(\.url.path)), ["/live/a.md", "/live/c.md"],
                       "live targets survive, including line bookmarks")
    }

    func test_pruneMissing_isUndoable_perEntry() {
        let s = makeStore()
        s.add(url: URL(fileURLWithPath: "/dead/a.md"))
        s.add(url: URL(fileURLWithPath: "/dead/b.md"))
        XCTAssertEqual(s.pruneMissing(fileExists: { _ in false }).count, 2)
        XCTAssertTrue(s.all().isEmpty)
        // Prune pushes onto the SAME undo stack as manual removes.
        XCTAssertTrue(s.canUndoRemoval)
        XCTAssertNotNil(s.undoLastRemoval())
        XCTAssertNotNil(s.undoLastRemoval())
        XCTAssertEqual(s.all().count, 2, "both pruned bookmarks restored via undo")
    }

    func test_pruneMissing_nothingMissing_isNoOp() {
        let s = makeStore()
        s.add(url: URL(fileURLWithPath: "/live/a.md"))
        XCTAssertTrue(s.pruneMissing(fileExists: { _ in true }).isEmpty)
        XCTAssertEqual(s.all().count, 1)
        XCTAssertFalse(s.canUndoRemoval, "a no-op prune must not pollute the undo stack")
    }

    func test_remove_urlGone() {
        let s = makeStore()
        let u = URL(fileURLWithPath: "/tmp/a.md")
        s.add(url: u)
        s.remove(url: u)
        XCTAssertFalse(s.contains(u))
    }

    /// Documents the "bookmark folders too" guarantee from Batch A.
    /// BookmarksStore is path-agnostic — it doesn't distinguish files
    /// from directories — so folder URLs work as long as the caller
    /// passes them in. Anti-regression for folder bookmarks dropping
    /// out of the store.
    func test_add_folderURL_appears() {
        let s = makeStore()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("a-folder-\(UUID().uuidString)", isDirectory: true)
        s.add(url: folder)
        XCTAssertTrue(s.contains(folder))
        XCTAssertEqual(s.all().count, 1)
    }

    func test_toggle_addsThenRemoves() {
        let s = makeStore()
        let u = URL(fileURLWithPath: "/tmp/a.md")
        XCTAssertTrue(s.toggle(url: u), "First toggle returns true (added)")
        XCTAssertTrue(s.contains(u))
        XCTAssertFalse(s.toggle(url: u), "Second toggle returns false (removed)")
        XCTAssertFalse(s.contains(u))
    }

    func test_persistAcrossInstances() {
        do {
            let s = makeStore()
            s.add(url: URL(fileURLWithPath: "/tmp/a.md"))
            s.add(url: URL(fileURLWithPath: "/tmp/b.md"))
        }
        let s2 = makeStore()
        XCTAssertEqual(s2.all().count, 2)
        XCTAssertTrue(s2.contains(URL(fileURLWithPath: "/tmp/a.md")))
    }

    func test_orderIsMostRecentlyAddedFirst() {
        let s = makeStore()
        s.add(url: URL(fileURLWithPath: "/tmp/first.md"))
        s.add(url: URL(fileURLWithPath: "/tmp/second.md"))
        s.add(url: URL(fileURLWithPath: "/tmp/third.md"))
        XCTAssertEqual(s.all().first?.url.lastPathComponent, "third.md")
    }

    func test_move_reorders() {
        let s = makeStore()
        s.add(url: URL(fileURLWithPath: "/tmp/first.md"))
        s.add(url: URL(fileURLWithPath: "/tmp/second.md"))
        s.add(url: URL(fileURLWithPath: "/tmp/third.md"))
        // Order: [third, second, first]
        s.move(from: 0, to: 2)
        // Now: [second, first, third]
        let names = s.all().map { $0.url.lastPathComponent }
        XCTAssertEqual(names, ["second.md", "first.md", "third.md"])
    }

    func test_clear_emptiesStore() {
        let s = makeStore()
        s.add(url: URL(fileURLWithPath: "/tmp/a.md"))
        s.add(url: URL(fileURLWithPath: "/tmp/b.md"))
        s.clear()
        XCTAssertEqual(s.all().count, 0)
    }

    func test_maxEntries_capped() {
        let s = BookmarksStore(storeURL: storeURL, maxEntries: 3)
        for i in 0..<10 {
            s.add(url: URL(fileURLWithPath: "/tmp/\(i).md"))
        }
        XCTAssertLessThanOrEqual(s.all().count, 3)
    }

    func test_decode_unparseableAddedAt_fallsBackToDistantPast() throws {
        // TSK-1030: a bad/unparseable addedAt sorts to the bottom
        // (.distantPast), NOT "now" (which would jump it to the top of the
        // addedAt-sorted Recent/Created sections).
        let json = Data(#"{"url":"file:///tmp/x.md","addedAt":"not-a-real-date","displayName":"x"}"#.utf8)
        let entry = try JSONFileStore.decoder.decode(BookmarkEntry.self, from: json)
        XCTAssertEqual(entry.addedAt, .distantPast)
    }
}
