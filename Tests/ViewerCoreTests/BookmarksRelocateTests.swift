import XCTest
@testable import ViewerCore

/// TSK-283 — bookmarks follow a file/folder rename (exact + folder-prefix),
/// so a renamed item's star/links don't go stale.
final class BookmarksRelocateTests: XCTestCase {

    private var storeURL: URL!
    override func setUp() {
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BMReloc-\(UUID().uuidString).json")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: storeURL) }

    private func makeStore() -> BookmarksStore {
        JSONFileStore.flushSync()
        return BookmarksStore(storeURL: storeURL, maxEntries: 100)
    }

    func test_exactFileRename_repointsBookmark_andRefreshesDisplayName() {
        let s = makeStore()
        let old = URL(fileURLWithPath: "/tmp/proj/old.md")
        s.add(url: old, displayName: "old.md")
        let new = URL(fileURLWithPath: "/tmp/proj/new.md")

        XCTAssertEqual(s.relocate(from: old, to: new), 1)
        XCTAssertFalse(s.contains(old), "old URL no longer bookmarked")
        XCTAssertTrue(s.contains(new), "new URL is bookmarked")
        XCTAssertEqual(s.all().first?.displayName, "new.md",
                       "the display name follows an exact-file rename")
    }

    func test_folderRename_rebasesDescendants_keepsTheirOwnNames() {
        let s = makeStore()
        let f1 = URL(fileURLWithPath: "/tmp/proj/src/a.swift")
        let f2 = URL(fileURLWithPath: "/tmp/proj/src/deep/b.swift")
        let outside = URL(fileURLWithPath: "/tmp/proj/other/c.swift")
        s.add(url: f1); s.add(url: f2); s.add(url: outside)

        let moved = s.relocate(from: URL(fileURLWithPath: "/tmp/proj/src"),
                               to: URL(fileURLWithPath: "/tmp/proj/lib"))
        XCTAssertEqual(moved, 2, "both descendants rebased; the outside one is untouched")
        XCTAssertTrue(s.contains(URL(fileURLWithPath: "/tmp/proj/lib/a.swift")))
        XCTAssertTrue(s.contains(URL(fileURLWithPath: "/tmp/proj/lib/deep/b.swift")))
        XCTAssertTrue(s.contains(outside), "a sibling outside the renamed folder stays put")
    }

    func test_noMatchingBookmark_returnsZero_andDoesNotChurn() {
        let s = makeStore()
        s.add(url: URL(fileURLWithPath: "/tmp/proj/keep.md"))
        XCTAssertEqual(s.relocate(from: URL(fileURLWithPath: "/tmp/proj/absent.md"),
                                  to: URL(fileURLWithPath: "/tmp/proj/x.md")), 0)
        XCTAssertEqual(s.all().count, 1)
    }

    /// A prefix that only partially matches a path component (`/tmp/proj/sr`
    /// vs `/tmp/proj/src/...`) must NOT rebase — the guard is a path-boundary
    /// prefix, not a raw string prefix.
    func test_partialComponentPrefix_doesNotRebase() {
        let s = makeStore()
        s.add(url: URL(fileURLWithPath: "/tmp/proj/source/a.swift"))
        XCTAssertEqual(s.relocate(from: URL(fileURLWithPath: "/tmp/proj/sour"),
                                  to: URL(fileURLWithPath: "/tmp/proj/x")), 0,
                       "‘sour’ is not a path-boundary ancestor of ‘source’")
    }
}
