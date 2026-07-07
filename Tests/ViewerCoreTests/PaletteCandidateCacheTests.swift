import XCTest
@testable import ViewerCore

/// TSK-1179 — the palette candidate merge (dedup) + the generation-keyed memo.
final class PaletteCandidateCacheTests: XCTestCase {

    private func entry(_ path: String, name: String? = nil) -> HistoryEntry {
        HistoryEntry(url: URL(fileURLWithPath: path), kind: .file,
                     lastOpenedAt: Date(timeIntervalSince1970: 0), displayName: name)
    }

    // MARK: merge

    func test_merge_bookmarksFirst_thenNonDuplicateRecents() {
        let bookmarks = [entry("/a"), entry("/b")]
        let recents = [entry("/b"), entry("/c")]   // /b duplicates a bookmark
        let merged = PaletteCandidates.merge(bookmarkEntries: bookmarks, recents: recents)
        XCTAssertEqual(merged.map(\.url.path), ["/a", "/b", "/c"],
                       "bookmarks first; /b not repeated; /c appended")
    }

    func test_merge_preservesOrderWithinEachGroup() {
        let bookmarks = [entry("/z"), entry("/a")]  // NOT sorted — order kept
        let recents = [entry("/m"), entry("/x")]
        let merged = PaletteCandidates.merge(bookmarkEntries: bookmarks, recents: recents)
        XCTAssertEqual(merged.map(\.url.path), ["/z", "/a", "/m", "/x"])
    }

    func test_merge_emptyInputs() {
        XCTAssertTrue(PaletteCandidates.merge(bookmarkEntries: [], recents: []).isEmpty)
        XCTAssertEqual(
            PaletteCandidates.merge(bookmarkEntries: [], recents: [entry("/r")]).map(\.url.path),
            ["/r"])
    }

    // MARK: cache

    func test_cache_rebuildsOnceAcrossSameGeneration() {
        var cache = PaletteCandidateCache()
        var buildCount = 0
        func build() -> [HistoryEntry] { buildCount += 1; return [entry("/x")] }
        // Simulate 5 keystrokes at the same open-generation.
        for _ in 0..<5 {
            _ = cache.candidates(generation: 1, build: build)
        }
        XCTAssertEqual(buildCount, 1, "query-independent list built ONCE per generation")
    }

    func test_cache_rebuildsWhenGenerationChanges() {
        var cache = PaletteCandidateCache()
        var buildCount = 0
        let r1 = cache.candidates(generation: 1) { buildCount += 1; return [entry("/a")] }
        let r2 = cache.candidates(generation: 2) { buildCount += 1; return [entry("/b")] }
        XCTAssertEqual(buildCount, 2, "a new generation (open / inputs changed) rebuilds")
        XCTAssertEqual(r1.map(\.url.path), ["/a"])
        XCTAssertEqual(r2.map(\.url.path), ["/b"])
    }

    func test_cache_invalidateForcesRebuild() {
        var cache = PaletteCandidateCache()
        var buildCount = 0
        _ = cache.candidates(generation: 1) { buildCount += 1; return [] }
        cache.invalidate()
        _ = cache.candidates(generation: 1) { buildCount += 1; return [] }  // same gen, but invalidated
        XCTAssertEqual(buildCount, 2, "invalidate() forces a rebuild at the same generation")
    }
}
