import XCTest
@testable import ViewerCore

/// Coverage for removal-undo (owner ask 2026-06-04: Delete-to-remove + undo).
/// Pure in-memory model behavior — no persistence round-trip needed.
final class BookmarkUndoTests: XCTestCase {

    private var storeURL: URL!
    override func setUp() {
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookmarkUndo-\(UUID().uuidString).json")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: storeURL) }

    private func makeStore() -> BookmarksStore {
        JSONFileStore.flushSync()
        return BookmarksStore(storeURL: storeURL, maxEntries: 100)
    }
    private func u(_ p: String) -> URL { URL(fileURLWithPath: p) }

    func test_removeThenUndo_restoresEntry() {
        let s = makeStore()
        s.add(url: u("/tmp/a.md"))
        XCTAssertFalse(s.canUndoRemoval)
        s.remove(url: u("/tmp/a.md"))
        XCTAssertEqual(s.all().count, 0)
        XCTAssertTrue(s.canUndoRemoval)
        let restored = s.undoLastRemoval()
        XCTAssertEqual(restored?.url, u("/tmp/a.md").standardizedFileURL.resolvingSymlinksInPath())
        XCTAssertTrue(s.contains(u("/tmp/a.md")))
        XCTAssertFalse(s.canUndoRemoval, "stack consumed")
    }

    func test_undo_restoresOriginalPosition() {
        let s = makeStore()
        // add a,b,c → insert-at-0 yields order [c, b, a]; b is index 1.
        s.add(url: u("/tmp/a.md")); s.add(url: u("/tmp/b.md")); s.add(url: u("/tmp/c.md"))
        XCTAssertEqual(s.all().map { $0.url.lastPathComponent }, ["c.md", "b.md", "a.md"])
        s.remove(url: u("/tmp/b.md"))
        XCTAssertEqual(s.all().map { $0.url.lastPathComponent }, ["c.md", "a.md"])
        s.undoLastRemoval()
        XCTAssertEqual(s.all().map { $0.url.lastPathComponent }, ["c.md", "b.md", "a.md"],
                       "undo restores b.md at its original middle index")
    }

    func test_undo_emptyStack_returnsNil() {
        let s = makeStore()
        XCTAssertNil(s.undoLastRemoval())
    }

    func test_undo_skipsWhenReadded_noDuplicate() {
        let s = makeStore()
        s.add(url: u("/tmp/a.md"))
        s.remove(url: u("/tmp/a.md"))
        s.add(url: u("/tmp/a.md"))           // re-added before undo
        XCTAssertNil(s.undoLastRemoval(), "undo must not duplicate a re-added bookmark")
        XCTAssertEqual(s.all().count, 1)
    }

    func test_undo_lifoAcrossMultipleRemovals() {
        let s = makeStore()
        s.add(url: u("/tmp/a.md")); s.add(url: u("/tmp/b.md"))
        s.remove(url: u("/tmp/a.md"))
        s.remove(url: u("/tmp/b.md"))
        XCTAssertEqual(s.all().count, 0)
        XCTAssertEqual(s.undoLastRemoval()?.url.lastPathComponent, "b.md") // last-out first
        XCTAssertEqual(s.undoLastRemoval()?.url.lastPathComponent, "a.md")
        XCTAssertEqual(s.all().count, 2)
    }

    func test_clear_wipesUndoStack() {
        let s = makeStore()
        s.add(url: u("/tmp/a.md"))
        s.remove(url: u("/tmp/a.md"))
        s.clear()
        XCTAssertFalse(s.canUndoRemoval)
        XCTAssertNil(s.undoLastRemoval(), "clear() is a deliberate wipe — nothing resurrectable")
    }

    func test_lineBookmarkUndo_independentOfFileBookmark() {
        let s = makeStore()
        s.add(url: u("/tmp/a.swift"))            // file-level
        s.add(url: u("/tmp/a.swift"), line: 42)  // line-level
        s.remove(url: u("/tmp/a.swift"), line: 42)
        XCTAssertTrue(s.contains(url: u("/tmp/a.swift"), line: nil))
        XCTAssertFalse(s.contains(url: u("/tmp/a.swift"), line: 42))
        s.undoLastRemoval()
        XCTAssertTrue(s.contains(url: u("/tmp/a.swift"), line: 42))
    }
}
