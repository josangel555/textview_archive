import XCTest
@testable import ViewerCore

/// TSK-1017: durable per-file scroll + zoom memory.
final class ScrollMemoryStoreTests: XCTestCase {
    private var tmpDir: URL!
    private var storeURL: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScrollMemoryStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        storeURL = tmpDir.appendingPathComponent("scroll-memory.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // A clock that hands out strictly increasing timestamps so LRU order is
    // deterministic regardless of how fast the test runs.
    private final class StepClock {
        private var t: TimeInterval = 0
        func tick() -> Date { t += 1; return Date(timeIntervalSinceReferenceDate: t) }
    }

    private func fileURL(_ name: String) -> URL {
        // A real, existing file so `fileID(dev/inode)` is populated — exercises
        // the rename-robust identity path too.
        let u = tmpDir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: u.path, contents: Data("x".utf8))
        return u
    }

    // MARK: - put/get round-trip

    func test_remember_thenLookupByURL_hits() {
        let store = ScrollMemoryStore(storeURL: storeURL)
        let url = fileURL("a.md")
        store.remember(url: url, scrollTopLine: 42, zoomLevel: 1.5)

        let e = store.entry(for: url)
        XCTAssertEqual(e?.scrollTopLine, 42)
        XCTAssertEqual(e?.zoomLevel, 1.5)
        XCTAssertEqual(e?.path, ScrollMemoryStore.key(for: url))
    }

    func test_lookup_differentPath_misses() {
        let store = ScrollMemoryStore(storeURL: storeURL)
        store.remember(url: fileURL("a.md"), scrollTopLine: 10)
        XCTAssertNil(store.entry(for: fileURL("b.md")))
    }

    func test_lookup_missingFile_returnsNil() {
        let store = ScrollMemoryStore(storeURL: storeURL)
        store.remember(url: fileURL("a.md"), scrollTopLine: 10)
        // A path never recorded, and which doesn't exist on disk (no fileID),
        // returns nil — not someone else's entry.
        let gone = tmpDir.appendingPathComponent("never-existed.md")
        XCTAssertNil(store.entry(for: gone))
    }

    func test_persistenceRoundTrip_survivesReopen() {
        let s1 = ScrollMemoryStore(storeURL: storeURL)
        let url = fileURL("a.md")
        s1.remember(url: url, scrollTopLine: 99, zoomLevel: 2.0)
        s1.flush()   // drain the off-main coalesced write

        let s2 = ScrollMemoryStore(storeURL: storeURL)
        let e = s2.entry(for: url)
        XCTAssertEqual(e?.scrollTopLine, 99)
        XCTAssertEqual(e?.zoomLevel, 2.0)
    }

    // MARK: - identity keying / rename robustness

    func test_renamedFile_recoveredByFileID() {
        let store = ScrollMemoryStore(storeURL: storeURL)
        let original = fileURL("original.md")
        store.remember(url: original, scrollTopLine: 7)

        // Rename on disk: same (dev, inode), new path. The path key now misses,
        // so the fileID fallback must recover the entry.
        let renamed = tmpDir.appendingPathComponent("renamed.md")
        try? FileManager.default.moveItem(at: original, to: renamed)

        XCTAssertNil(store.entry(forPath: ScrollMemoryStore.key(for: renamed), fileID: nil),
                     "path-only lookup must miss after rename")
        let e = store.entry(for: renamed)   // resolves fileID off disk
        XCTAssertEqual(e?.scrollTopLine, 7, "fileID fallback should recover the renamed file")
    }

    // MARK: - LRU / count cap eviction (oldest savedAt first)

    func test_countCap_evictsOldestSavedAt() {
        let clock = StepClock()
        let store = ScrollMemoryStore(storeURL: storeURL, maxEntries: 3,
                                      now: clock.tick)
        // Insert 4 in time order a<b<c<d; cap is 3 → oldest (a) evicted.
        let a = fileURL("a.md"); let b = fileURL("b.md")
        let c = fileURL("c.md"); let d = fileURL("d.md")
        store.remember(url: a, scrollTopLine: 1)
        store.remember(url: b, scrollTopLine: 2)
        store.remember(url: c, scrollTopLine: 3)
        store.remember(url: d, scrollTopLine: 4)

        XCTAssertEqual(store.count, 3)
        XCTAssertNil(store.entry(for: a), "oldest must be evicted")
        XCTAssertEqual(store.entry(for: b)?.scrollTopLine, 2)
        XCTAssertEqual(store.entry(for: d)?.scrollTopLine, 4)
    }

    func test_reRemember_refreshesSavedAt_soItSurvivesEviction() {
        let clock = StepClock()
        let store = ScrollMemoryStore(storeURL: storeURL, maxEntries: 2,
                                      now: clock.tick)
        let a = fileURL("a.md"); let b = fileURL("b.md"); let c = fileURL("c.md")
        store.remember(url: a, scrollTopLine: 1)   // savedAt 1
        store.remember(url: b, scrollTopLine: 2)   // savedAt 2
        store.remember(url: a, scrollTopLine: 11)  // refreshes a → savedAt 3
        store.remember(url: c, scrollTopLine: 3)   // savedAt 4; cap 2 → evict oldest = b

        XCTAssertNil(store.entry(for: b), "b was now the oldest and must be evicted")
        XCTAssertEqual(store.entry(for: a)?.scrollTopLine, 11, "refreshed a survives")
        XCTAssertEqual(store.entry(for: c)?.scrollTopLine, 3)
    }

    // MARK: - byte budget eviction

    func test_byteBudget_evictsOldestUntilUnderBudget() {
        let clock = StepClock()
        // A small byte budget (room for only a handful of heavy entries)
        // forces eviction long before the count cap. Each entry encodes to a
        // few hundred bytes (long path + dev/inode + ISO date), so ~2 KiB
        // holds a single-digit number of entries.
        let store = ScrollMemoryStore(storeURL: storeURL,
                                      maxEntries: 1000,
                                      maxStoreFileBytes: 2048,
                                      now: clock.tick)
        // Long paths so each entry is heavy; insert many in time order.
        for i in 0..<40 {
            store.remember(url: fileURL("file-with-a-fairly-long-name-\(i).md"),
                           scrollTopLine: i + 1)
        }
        XCTAssertLessThan(store.count, 40, "byte budget must have evicted some entries")
        XCTAssertGreaterThan(store.count, 0, "budget shouldn't nuke everything")
        // The freshest insert must survive; an early one must be gone.
        XCTAssertNotNil(store.entry(forPath: ScrollMemoryStore.key(for:
            tmpDir.appendingPathComponent("file-with-a-fairly-long-name-39.md")),
            fileID: nil))
    }

    func test_load_trimsOversizedFileBackToCap() throws {
        // Hand-write a file with more entries than the cap, then load.
        var raw: [String: ScrollMemoryStore.Entry] = [:]
        let base = Date(timeIntervalSinceReferenceDate: 0)
        for i in 0..<10 {
            let p = "/tmp/scroll-cap-\(i).md"
            raw[p] = ScrollMemoryStore.Entry(
                path: p, scrollTopLine: i + 1,
                savedAt: base.addingTimeInterval(TimeInterval(i)))
        }
        XCTAssertTrue(JSONFileStore.write(raw, to: storeURL))

        let store = ScrollMemoryStore(storeURL: storeURL, maxEntries: 4)
        XCTAssertEqual(store.count, 4, "load must trim to the count cap")
        // The 4 freshest (highest savedAt) survive: indices 6..9.
        XCTAssertNotNil(store.entry(forPath: "/tmp/scroll-cap-9.md", fileID: nil))
        XCTAssertNil(store.entry(forPath: "/tmp/scroll-cap-0.md", fileID: nil))
    }

    // MARK: - save-decision predicate (only-if-scrolled-or-zoomed)

    func test_shouldPersist_skipsUntouchedTopOfFile() {
        // No prior restore + nothing to remember ⇒ no write.
        let candidate = ScrollMemoryStore.Entry(path: "/a", savedAt: Date())
        XCTAssertFalse(ScrollMemoryStore.shouldPersist(restored: nil, candidate: candidate))
    }

    func test_shouldPersist_firstScrollWithNoBaseline_writes() {
        let candidate = ScrollMemoryStore.Entry(path: "/a", scrollTopLine: 5, savedAt: Date())
        XCTAssertTrue(ScrollMemoryStore.shouldPersist(restored: nil, candidate: candidate))
    }

    func test_shouldPersist_skipsWhenUnchangedFromRestoredBaseline() {
        let restored = ScrollMemoryStore.Entry(path: "/a", scrollTopLine: 5,
                                               zoomLevel: 1.5, savedAt: Date())
        // Same position + zoom the user was restored to ⇒ untouched ⇒ skip.
        let candidate = ScrollMemoryStore.Entry(path: "/a", scrollTopLine: 5,
                                                zoomLevel: 1.5, savedAt: Date())
        XCTAssertFalse(ScrollMemoryStore.shouldPersist(restored: restored, candidate: candidate))
    }

    func test_shouldPersist_writesWhenScrolledAwayFromBaseline() {
        let restored = ScrollMemoryStore.Entry(path: "/a", scrollTopLine: 5, savedAt: Date())
        let candidate = ScrollMemoryStore.Entry(path: "/a", scrollTopLine: 50, savedAt: Date())
        XCTAssertTrue(ScrollMemoryStore.shouldPersist(restored: restored, candidate: candidate))
    }

    func test_shouldPersist_writesWhenZoomChanged() {
        let restored = ScrollMemoryStore.Entry(path: "/a", scrollTopLine: 5,
                                               zoomLevel: 1.0, savedAt: Date())
        let candidate = ScrollMemoryStore.Entry(path: "/a", scrollTopLine: 5,
                                                zoomLevel: 2.0, savedAt: Date())
        XCTAssertTrue(ScrollMemoryStore.shouldPersist(restored: restored, candidate: candidate))
    }

    // MARK: - empty candidate clears an existing entry

    func test_remember_emptyCandidate_clearsExistingEntry() {
        let store = ScrollMemoryStore(storeURL: storeURL)
        let url = fileURL("a.md")
        store.remember(url: url, scrollTopLine: 30)
        XCTAssertNotNil(store.entry(for: url))
        // Scroll back to the top (line 0) with default zoom ⇒ forget.
        store.remember(url: url, scrollTopLine: 0)
        XCTAssertNil(store.entry(for: url), "reset-to-top should forget, not store a husk")
    }

    // MARK: - clear

    func test_clear_removesEverything() {
        let store = ScrollMemoryStore(storeURL: storeURL)
        store.remember(url: fileURL("a.md"), scrollTopLine: 1)
        store.remember(url: fileURL("b.md"), scrollTopLine: 2)
        XCTAssertEqual(store.count, 2)
        store.clear()
        XCTAssertEqual(store.count, 0)
    }
}
