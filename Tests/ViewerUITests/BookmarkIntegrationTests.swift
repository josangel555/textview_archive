import XCTest
import AppKit
import SwiftUI
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// L3 integration tests for bookmarks via DocumentModel.
@MainActor
final class BookmarkIntegrationTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Bookmarks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "Bookmarks-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeModel() -> DocumentModel {
        DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmpDir.appendingPathComponent("h.json")),
            bookmarks: BookmarksStore(storeURL: tmpDir.appendingPathComponent("b.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults)
        )
    }

    private func writeFile(_ name: String) throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try "# x\n".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func test_initialState_noBookmarks() throws {
        XCTAssertEqual(makeModel().bookmarks.count, 0)
    }

    func test_toggleBookmark_addsCurrentTab() throws {
        let model = makeModel()
        let url = try writeFile("pin.md")
        model.open(url: url)
        XCTAssertFalse(model.isCurrentTabBookmarked)
        model.toggleCurrentTabBookmark()
        XCTAssertTrue(model.isCurrentTabBookmarked)
        XCTAssertEqual(model.bookmarks.count, 1)
    }

    func test_toggleAgain_removes() throws {
        let model = makeModel()
        let url = try writeFile("pin.md")
        model.open(url: url)
        model.toggleCurrentTabBookmark()
        model.toggleCurrentTabBookmark()
        XCTAssertFalse(model.isCurrentTabBookmarked)
        XCTAssertEqual(model.bookmarks.count, 0)
    }

    func test_toggleBookmark_noCurrentTab_isNoOp() throws {
        let model = makeModel()
        XCTAssertEqual(model.tabs.tabs.count, 0)
        model.toggleCurrentTabBookmark()
        XCTAssertEqual(model.bookmarks.count, 0)
    }

    func test_bookmark_persistsToDisk() throws {
        let bookmarksURL = tmpDir.appendingPathComponent("b.json")
        // First model: add a bookmark.
        do {
            let url = try writeFile("p.md")
            let model = DocumentModel(
                controller: DocumentController(),
                history: HistoryStore(storeURL: tmpDir.appendingPathComponent("h1.json")),
                bookmarks: BookmarksStore(storeURL: bookmarksURL),
                sidebar: SidebarModel(),
                preferences: PreferencesStore(defaults: defaults)
            )
            model.open(url: url)
            model.toggleCurrentTabBookmark()
        }
        // Second model: should see the bookmark (loaded from disk).
        let model2 = DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmpDir.appendingPathComponent("h2.json")),
            bookmarks: BookmarksStore(storeURL: bookmarksURL),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults)
        )
        XCTAssertEqual(model2.bookmarks.count, 1)
    }

    func test_clearBookmarks_empties() throws {
        let model = makeModel()
        let a = try writeFile("a.md")
        let b = try writeFile("b.md")
        model.open(url: a)
        model.toggleCurrentTabBookmark()
        model.open(url: b)
        model.toggleCurrentTabBookmark()
        XCTAssertEqual(model.bookmarks.count, 2)
        model.clearBookmarks()
        XCTAssertEqual(model.bookmarks.count, 0)
    }
}
