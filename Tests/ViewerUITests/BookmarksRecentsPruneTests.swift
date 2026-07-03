import XCTest
import ViewerCore
@testable import ViewerUI

/// TSK-1464 — bookmarks & recents surfacing: the ⌘D command path
/// (`toggle-bookmark` ScriptVerb → store), the prune-missing model wrappers
/// (published arrays refresh; undo preserved), and remove-from-recents.
/// Hermetic via `HeadlessHarness` (per-run temp stores — never user state).
@MainActor
final class BookmarksRecentsPruneTests: HeadlessUITestCase {

    private var harness: HeadlessHarness!

    override func setUp() async throws {
        harness = HeadlessHarness(label: "BookmarksRecentsPruneTests")
    }

    override func tearDown() async throws {
        harness.cleanup()
        harness = nil
    }

    private func writeFixture(_ name: String, _ content: String = "# x\n") throws -> URL {
        let url = harness.tmpDir.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - ⌘D command path (the menu item's action, verb-driven)

    func test_toggleBookmarkVerb_addsThenRemoves_forActiveFile() throws {
        let url = try writeFixture("doc.md")
        harness.model.open(url: url)

        XCTAssertTrue(ScriptVerb.apply(verb: "toggle-bookmark",
                                       to: harness.model, sessions: harness.sessions))
        XCTAssertTrue(harness.model.bookmarksStore.contains(url),
                      "first ⌘D bookmarks the active file")
        XCTAssertEqual(harness.model.bookmarks.count, 1,
                       "the published array the sidebar renders is refreshed")

        XCTAssertTrue(ScriptVerb.apply(verb: "toggle-bookmark",
                                       to: harness.model, sessions: harness.sessions))
        XCTAssertFalse(harness.model.bookmarksStore.contains(url),
                       "second ⌘D unbookmarks")
        XCTAssertTrue(harness.model.bookmarks.isEmpty)
    }

    // MARK: - Prune missing (model wrappers)

    func test_pruneMissingBookmarks_removesDead_publishes_andIsUndoable() throws {
        let live = try writeFixture("live.md")
        let dead = try writeFixture("dead.md")
        _ = harness.model.bookmarksStore.add(url: live)
        _ = harness.model.bookmarksStore.add(url: dead)
        harness.model.refreshBookmarks()
        try FileManager.default.removeItem(at: dead)

        XCTAssertEqual(harness.model.pruneMissingBookmarks(), 1)
        XCTAssertEqual(harness.model.bookmarks.map(\.url.lastPathComponent), ["live.md"],
                       "the published array drops the dead entry immediately")
        // A prune is a removal like any other — ⌘Z brings it back.
        XCTAssertTrue(harness.model.canUndoBookmarkRemoval)
        XCTAssertTrue(harness.model.undoLastBookmarkRemoval())
        XCTAssertEqual(harness.model.bookmarks.count, 2)
    }

    func test_pruneMissingBookmarks_nothingMissing_returnsZero() throws {
        let live = try writeFixture("live.md")
        _ = harness.model.bookmarksStore.add(url: live)
        harness.model.refreshBookmarks()
        XCTAssertEqual(harness.model.pruneMissingBookmarks(), 0)
        XCTAssertEqual(harness.model.bookmarks.count, 1)
    }

    func test_pruneMissingRecents_removesDead_refreshesPublishedArray() throws {
        let live = try writeFixture("live.md")
        let dead = try writeFixture("dead.md")
        harness.model.open(url: live)
        harness.model.open(url: dead)
        XCTAssertEqual(harness.model.recents.count, 2, "opens are recorded")
        try FileManager.default.removeItem(at: dead)

        XCTAssertEqual(harness.model.pruneMissingRecents(), 1)
        XCTAssertEqual(harness.model.recents.map(\.url.lastPathComponent), ["live.md"])
    }

    // MARK: - Remove one recent

    func test_removeRecent_dropsSingleEntry() throws {
        let a = try writeFixture("a.md")
        let b = try writeFixture("b.md")
        harness.model.open(url: a)
        harness.model.open(url: b)

        harness.model.removeRecent(a)
        XCTAssertEqual(harness.model.recents.map(\.url.lastPathComponent), ["b.md"])
    }
}
