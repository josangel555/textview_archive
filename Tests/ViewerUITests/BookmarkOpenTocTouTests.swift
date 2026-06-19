import XCTest
@testable import ViewerUI
@testable import ViewerCore

/// Model-level behaviour of `DocumentModel.openBookmark` under a TOCTOU swap
/// (TSK-309). The store-level validator is unit-tested in
/// `BookmarkTocTouTests`; here we pin the DocumentModel wiring: a swapped or
/// deleted target must be REFUSED (no tab opened) and surface
/// `lastBookmarkOpenWarning`, while an unchanged target opens normally and
/// clears any prior warning.
///
/// Host-safe: this is pure model/state — no window, no VM. Scratch under
/// `FileManager.temporaryDirectory` per CLAUDE.md.
@MainActor
final class BookmarkOpenTocTouTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookmarkOpenTocTou-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeModel() -> DocumentModel {
        let storeURL = root.appendingPathComponent("bookmarks.json")
        JSONFileStore.flushSync()
        let store = BookmarksStore(storeURL: storeURL, maxEntries: 100)
        return DocumentModel(bookmarks: store)
    }

    func test_openBookmark_unchangedTarget_opensAndClearsWarning() throws {
        let f = root.appendingPathComponent("doc.md")
        try "# hi\n".write(to: f, atomically: true, encoding: .utf8)
        let model = makeModel()
        let entry = model.bookmarksStore.add(url: f)
        model.refreshBookmarks()

        model.openBookmark(entry)

        XCTAssertNil(model.lastBookmarkOpenWarning,
                     "an unchanged bookmark must open with no warning")
        XCTAssertEqual(model.currentURL?.standardizedFileURL.resolvingSymlinksInPath(),
                       f.standardizedFileURL.resolvingSymlinksInPath(),
                       "the unchanged bookmark target should be the current tab")
    }

    func test_openBookmark_swappedTarget_isRefusedAndWarns() throws {
        let f = root.appendingPathComponent("doc.md")
        try "v1".write(to: f, atomically: true, encoding: .utf8)
        let model = makeModel()
        let entry = model.bookmarksStore.add(url: f)
        model.refreshBookmarks()

        // TOCTOU: replace the same path with a different inode after add.
        try FileManager.default.removeItem(at: f)
        try "v2-attacker".write(to: f, atomically: true, encoding: .utf8)

        model.openBookmark(entry)

        XCTAssertNotNil(model.lastBookmarkOpenWarning,
                        "a swapped bookmark target must surface a warning")
        XCTAssertNil(model.currentURL,
                     "the swapped target must NOT be opened into a tab")
        XCTAssertTrue(model.lastBookmarkOpenWarning?.contains("target changed") ?? false,
                      "warning text should name the identity change")
    }

    func test_openBookmark_deletedTarget_isRefusedAndWarns() throws {
        let f = root.appendingPathComponent("doc.md")
        try "v1".write(to: f, atomically: true, encoding: .utf8)
        let model = makeModel()
        let entry = model.bookmarksStore.add(url: f)
        model.refreshBookmarks()

        try FileManager.default.removeItem(at: f)

        model.openBookmark(entry)

        XCTAssertNotNil(model.lastBookmarkOpenWarning)
        XCTAssertNil(model.currentURL)
        XCTAssertTrue(model.lastBookmarkOpenWarning?.contains("no longer be found") ?? false)
    }

    func test_dismissWarning_clearsIt() throws {
        let f = root.appendingPathComponent("doc.md")
        try "v1".write(to: f, atomically: true, encoding: .utf8)
        let model = makeModel()
        let entry = model.bookmarksStore.add(url: f)
        model.refreshBookmarks()
        try FileManager.default.removeItem(at: f)
        model.openBookmark(entry)
        XCTAssertNotNil(model.lastBookmarkOpenWarning)

        model.dismissBookmarkOpenWarning()
        XCTAssertNil(model.lastBookmarkOpenWarning,
                     "dismiss must clear the warning banner")
    }

    func test_openBookmark_successAfterRefusal_clearsWarning() throws {
        // After a refused open, opening a valid bookmark clears the warning.
        let bad = root.appendingPathComponent("bad.md")
        try "x".write(to: bad, atomically: true, encoding: .utf8)
        let good = root.appendingPathComponent("good.md")
        try "y".write(to: good, atomically: true, encoding: .utf8)
        let model = makeModel()
        let badEntry = model.bookmarksStore.add(url: bad)
        let goodEntry = model.bookmarksStore.add(url: good)
        model.refreshBookmarks()

        try FileManager.default.removeItem(at: bad)
        model.openBookmark(badEntry)
        XCTAssertNotNil(model.lastBookmarkOpenWarning)

        model.openBookmark(goodEntry)
        XCTAssertNil(model.lastBookmarkOpenWarning,
                     "a successful open must clear the prior refusal warning")
    }
}
