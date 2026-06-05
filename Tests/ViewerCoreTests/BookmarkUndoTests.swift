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

    /// The undo stack is bounded at `maxUndoDepth` (20) and evicts FIFO:
    /// after >20 removals the OLDEST removal falls off and is no longer
    /// resurrectable, while the 20 most-recent stay undoable (LIFO out).
    /// Pins line 105 (`if removalUndoStack.count > maxUndoDepth { removeFirst() }`),
    /// which had no coverage.
    func test_undoStack_boundedAtMaxDepth_evictsOldestFIFO() {
        let s = makeStore()
        // 21 distinct removals; the store re-adds before each remove so every
        // pop has something to restore (and to keep entries non-empty).
        let total = 21
        for i in 0..<total {
            let url = u("/tmp/f\(i).md")
            s.add(url: url)
            s.remove(url: url)
        }
        // Drain the whole stack. With depth 20, only the 20 newest survive:
        // f20 (newest) down to f1. f0 (oldest) was evicted — never returned.
        var restored: [String] = []
        while let e = s.undoLastRemoval() { restored.append(e.url.lastPathComponent) }
        XCTAssertEqual(restored.count, 20, "stack is bounded to maxUndoDepth=20")
        XCTAssertEqual(restored.first, "f20.md", "newest removal pops first (LIFO)")
        XCTAssertEqual(restored.last, "f1.md", "20th-from-newest is the floor")
        XCTAssertFalse(restored.contains("f0.md"),
                       "oldest removal was FIFO-evicted, not resurrectable")
    }

    /// A removal captures the index the entry sat at; by undo time the list
    /// may be shorter than that index. The restore clamps with
    /// `min(last.index, entries.count)` so the insert stays in-bounds —
    /// here the stored index lands exactly at `entries.count`, i.e. an
    /// insert-at-tail. Pins line 122's clamp branch, previously uncovered
    /// (the existing position test only restored into a still-large list).
    func test_undo_restoreIndexClampedToTailWhenListShrank() {
        let s = makeStore()
        // order after the three adds: [c, b, a]; a is index 2.
        s.add(url: u("/tmp/a.md")); s.add(url: u("/tmp/b.md")); s.add(url: u("/tmp/c.md"))
        s.remove(url: u("/tmp/a.md"))          // captured index 2 → [c, b]
        s.remove(url: u("/tmp/b.md"))          // → [c]
        s.remove(url: u("/tmp/c.md"))          // → []
        // LIFO undo re-grows the list as we pop c then b; when a (stored
        // index 2) is finally restored, entries.count == 2, so the clamp
        // resolves to an insert at the tail (index == count) rather than a's
        // original middle slot.
        XCTAssertEqual(s.undoLastRemoval()?.url.lastPathComponent, "c.md") // [c]
        XCTAssertEqual(s.undoLastRemoval()?.url.lastPathComponent, "b.md") // [c, b]
        let a = s.undoLastRemoval()
        XCTAssertEqual(a?.url.lastPathComponent, "a.md",
                       "stale at-count index is clamped, not a trap")
        XCTAssertEqual(s.all().map { $0.url.lastPathComponent }, ["c.md", "b.md", "a.md"],
                       "clamped insert lands at the tail (index == count)")
    }
}
