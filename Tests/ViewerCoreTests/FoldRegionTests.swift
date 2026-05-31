import XCTest
import ViewerKit
@testable import ViewerCore

/// Detection tests: per-language we feed a small golden fixture into
/// `computeFoldsSync` and assert that the regions that fall out match
/// what the design doc lists for that language. Substring-based asserts
/// (verify the *first source line* of the matching region contains the
/// expected anchor) so a 1-character whitespace edit upstream doesn't
/// nuke the test.
final class FoldRegionTests: XCTestCase {

    private func regions(_ src: String, _ lang: HighlightLanguage)
        -> [FoldRegion]
    {
        TreeSitterEngine.shared._testOnly_clearFoldCaches()
        return TreeSitterEngine.shared.computeFoldsSync(
            text: src, language: lang
        )
    }

    private func assertHasFold(
        _ regions: [FoldRegion],
        kind: FoldRegion.Kind,
        startLine: Int,
        endLine: Int? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let hit = regions.contains { r in
            guard r.kind == kind, r.startLine == startLine else { return false }
            if let endLine { return r.endLine == endLine }
            return true
        }
        XCTAssertTrue(
            hit,
            "expected \(kind) starting line \(startLine)\(endLine.map { " ending \($0)" } ?? ""); got \(regions)",
            file: file, line: line
        )
    }

    // MARK: JSON

    func testJSONObjectAndArrayFolds() {
        let src = """
        {
          "name": "x",
          "items": [
            1,
            2,
            3
          ]
        }
        """
        let r = regions(src, .json)
        // Outer object starts on line 1; array starts on line 3. Exact
        // end-line semantics depend on whether upstream's `document`
        // node includes the trailing EOF position, so we don't pin it.
        assertHasFold(r, kind: .object, startLine: 1)
        assertHasFold(r, kind: .array, startLine: 3)
        // Sanity: the array's range is strictly *inside* the object's.
        let obj = r.first { $0.kind == .object && $0.startLine == 1 }!
        let arr = r.first { $0.kind == .array && $0.startLine == 3 }!
        XCTAssertGreaterThan(obj.endLine, arr.endLine)
    }

    func testJSONSingleLineObject_TreatedAsTwoLineDueToTSDocumentNode() {
        // The TS JSON grammar reports `document.byteRange` ending at the
        // (synthetic) position past EOF, so a one-line file shows up as
        // a 2-line span via our byte→line mapper. That's acceptable —
        // the source view layer suppresses folds whose ellipsis would
        // overlap their own start. We just verify the engine emits at
        // most one trivial fold here (no garbage).
        let r = regions(#"{"a":1,"b":2}"#, .json)
        XCTAssertLessThanOrEqual(r.count, 1)
    }

    // MARK: Markdown — fenced code blocks + heading folds

    func testMarkdownFencedCodeBlock() {
        let src = """
        # heading

        ```swift
        let x = 1
        let y = 2
        ```

        text
        """
        let r = regions(src, .markdown)
        // Heading fold spans entire doc (line 1..8).
        assertHasFold(r, kind: .heading, startLine: 1)
        // Fenced code block: line 3..6 (inclusive of fences).
        assertHasFold(r, kind: .codeFence, startLine: 3, endLine: 6)
    }

    func testMarkdownHeadingFolds_NestedLevels() {
        let src = """
        # A
        a body
        ## A.1
        a1 body
        ## A.2
        a2 body
        # B
        b body
        """
        let r = regions(src, .markdown)
        // `# A` should fold to the line before `# B` (line 6).
        assertHasFold(r, kind: .heading, startLine: 1, endLine: 6)
        // `## A.1` should fold to the line before `## A.2` (line 4).
        assertHasFold(r, kind: .heading, startLine: 3, endLine: 4)
        // `## A.2` ends at line 6 (before `# B` at line 7).
        assertHasFold(r, kind: .heading, startLine: 5, endLine: 6)
        // `# B` to EOF (line 8).
        assertHasFold(r, kind: .heading, startLine: 7, endLine: 8)
    }

    // MARK: Cache behavior

    func testComputeFolds_CachesByContentHash() async {
        let src = """
        {
          "a": [
            1,
            2
          ]
        }
        """
        TreeSitterEngine.shared._testOnly_clearFoldCaches()
        let r1 = await TreeSitterEngine.shared.computeFolds(
            text: src, language: .json
        )
        let r2 = await TreeSitterEngine.shared.computeFolds(
            text: src, language: .json
        )
        XCTAssertEqual(r1, r2)
        XCTAssertFalse(r1.isEmpty)
    }

    func testComputeFolds_InvalidatesOnContentChange() async {
        let a = """
        {
          "a": 1
        }
        """
        let b = """
        {
          "a": 1,
          "b": 2
        }
        """
        let ra = await TreeSitterEngine.shared.computeFolds(
            text: a, language: .json
        )
        let rb = await TreeSitterEngine.shared.computeFolds(
            text: b, language: .json
        )
        // Different end line: a has endLine=3, b has endLine=4.
        XCTAssertNotEqual(ra, rb)
    }

    func testPlainTextReturnsNoFolds() async {
        let r = await TreeSitterEngine.shared.computeFolds(
            text: "no syntax here\njust prose\n",
            language: .plainText
        )
        XCTAssertTrue(r.isEmpty)
    }

    // MARK: RWC-4 — fold cache keys on (language, contentHash) with LRU

    /// Two distinct same-language documents must BOTH stay cached — the
    /// old single-slot-per-language design evicted one when the other was
    /// computed, so two open JSON tabs re-parsed on every switch.
    func testFoldCache_TwoSameLanguageDocs_BothCached() async {
        let a = """
        {
          "a": [1, 2]
        }
        """
        let b = """
        {
          "b": {
            "c": 3
          }
        }
        """
        TreeSitterEngine.shared._testOnly_clearFoldCaches()
        _ = await TreeSitterEngine.shared.computeFolds(text: a, language: .json)
        _ = await TreeSitterEngine.shared.computeFolds(text: b, language: .json)
        // Both content hashes occupy their own slot — no thrash.
        XCTAssertEqual(
            TreeSitterEngine.shared._testOnly_foldCacheSlotCount(for: .json),
            2,
            "both same-language docs must coexist in the cache"
        )
    }

    /// The per-language LRU is bounded: feeding more distinct documents
    /// than `FoldCacheEntry.maxEntries` must not grow the slot count
    /// without limit, and the most recently computed doc must survive.
    func testFoldCache_BoundedLRU_EvictsOldest() async {
        TreeSitterEngine.shared._testOnly_clearFoldCaches()
        let cap = 8   // mirrors FoldCacheEntry.maxEntries
        // Generate cap+4 distinct JSON docs (distinct content → distinct hash).
        var docs: [String] = []
        for i in 0..<(cap + 4) {
            docs.append("""
            {
              "k\(i)": [
                \(i)
              ]
            }
            """)
        }
        for d in docs {
            _ = await TreeSitterEngine.shared.computeFolds(text: d, language: .json)
        }
        let count = TreeSitterEngine.shared._testOnly_foldCacheSlotCount(for: .json)
        XCTAssertLessThanOrEqual(count, cap, "LRU must cap slots at maxEntries")
        XCTAssertEqual(count, cap, "after overflowing, the cache should sit at the cap")

        // The most-recently computed doc must be a hit (no recompute).
        // Re-running it should not change the slot count (already present).
        _ = await TreeSitterEngine.shared.computeFolds(text: docs.last!, language: .json)
        XCTAssertEqual(
            TreeSitterEngine.shared._testOnly_foldCacheSlotCount(for: .json),
            cap,
            "recomputing the most-recent doc must be a cache hit, not a new slot"
        )
    }

    /// Different languages keep independent slot budgets — caching a JSON
    /// doc must not evict an XML doc and vice versa.
    func testFoldCache_DistinctLanguages_IndependentSlots() async {
        TreeSitterEngine.shared._testOnly_clearFoldCaches()
        let json = """
        {
          "a": [1]
        }
        """
        _ = await TreeSitterEngine.shared.computeFolds(text: json, language: .json)
        XCTAssertEqual(
            TreeSitterEngine.shared._testOnly_foldCacheSlotCount(for: .json), 1
        )
        XCTAssertEqual(
            TreeSitterEngine.shared._testOnly_foldCacheSlotCount(for: .xml), 0,
            "a JSON store must not populate the XML language bucket"
        )
    }

    // MARK: Region sorting + dedup

    func testRegions_AreSortedAndDeduped() {
        // Nested objects — outer should appear before inner in the
        // sorted output (start ASC; ties broken by end DESC).
        let src = """
        {
          "outer": {
            "inner": [
              1,
              2
            ]
          }
        }
        """
        let r = regions(src, .json)
        XCTAssertGreaterThanOrEqual(r.count, 3, "expected 3 folds; got \(r)")
        // First fold is the outermost (starts on the earliest line and,
        // among same-start regions, has the largest end). Subsequent
        // folds are non-decreasing on startLine.
        for i in 1..<r.count {
            XCTAssertGreaterThanOrEqual(r[i].startLine, r[i - 1].startLine)
        }
        XCTAssertEqual(r.first?.startLine, 1)
        // Dedup: a unique set of (start, end, kind).
        XCTAssertEqual(Set(r).count, r.count)
    }
}
