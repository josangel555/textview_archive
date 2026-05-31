import XCTest
import ViewerKit
@testable import ViewerCore

/// Regression coverage for the launch-memory blow-up (2026-05-31).
///
/// A heavily-used active session had grown to **1951 persisted tabs of only
/// ~35 unique files** (each path duplicated ~64×). Workspace restore appended
/// every persisted entry unconditionally and `makeSnapshot()` re-persisted the
/// live list, forming a one-way ratchet: each launch read N, materialized the
/// focused tab, and re-wrote N — and any path re-opened during the session
/// pushed N higher. Even though non-focused tabs stay lazy (`.empty`), 1951
/// `Tab` structs + 1951 SwiftUI tab-strip cells + per-tab work pushed launch
/// `phys_footprint` from ~40 MB (empty) to ~1 GB.
///
/// The fix is `TabsState.dedupedRestoreTabs` (collapse by normalized path,
/// first-occurrence-wins, then clamp to `maxRestoredTabs`), applied on the
/// restore read side, plus an idempotent `appendLazyTab` and a dedup on the
/// snapshot write side. These tests pin the pure Core helper that all three
/// rely on.
final class TabRestoreDedupTests: XCTestCase {

    private func pairs(_ paths: [String],
                       _ mode: String = "rendered")
        -> [(path: String, viewMode: String)] {
        paths.map { (path: $0, viewMode: mode) }
    }

    // MARK: dedupedRestoreTabs

    func test_dedup_collapsesExactDuplicates_firstWins() {
        let input = pairs([
            "/a/one.md", "/a/two.md", "/a/one.md", "/a/two.md", "/a/one.md",
        ])
        let out = TabsState.dedupedRestoreTabs(input)
        XCTAssertEqual(out.map(\.path), ["/a/one.md", "/a/two.md"])
    }

    func test_dedup_preservesOnDiskOrder() {
        let input = pairs(["/z.md", "/y.md", "/x.md", "/z.md", "/y.md"])
        let out = TabsState.dedupedRestoreTabs(input)
        XCTAssertEqual(out.map(\.path), ["/z.md", "/y.md", "/x.md"])
    }

    func test_dedup_firstOccurrenceKeepsItsViewMode() {
        // First occurrence of /a.md is "source"; a later dup is "rendered".
        let input: [(path: String, viewMode: String)] = [
            (path: "/a.md", viewMode: "source"),
            (path: "/b.md", viewMode: "rendered"),
            (path: "/a.md", viewMode: "rendered"),
        ]
        let out = TabsState.dedupedRestoreTabs(input)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out.first(where: { $0.path == "/a.md" })?.viewMode, "source")
    }

    /// The exact shape that bit the owner: ~35 unique paths each repeated 64×.
    func test_dedup_reproducesOwnerRatchet_collapsesToUnique() {
        let unique = (0..<35).map { "/repo/doc\($0).md" }
        var bloated: [(path: String, viewMode: String)] = []
        for _ in 0..<64 { bloated.append(contentsOf: pairs(unique)) }
        XCTAssertEqual(bloated.count, 35 * 64)   // 2240, like the real 1951

        let out = TabsState.dedupedRestoreTabs(bloated)
        XCTAssertEqual(out.count, 35)
        XCTAssertEqual(Set(out.map(\.path)).count, 35)
    }

    // MARK: cap

    func test_cap_clampsToMaxRestoredTabs_keepingTail() {
        let n = TabsState.maxRestoredTabs + 50
        let input = pairs((0..<n).map { "/f/\($0).md" })   // all unique
        let out = TabsState.dedupedRestoreTabs(input)
        XCTAssertEqual(out.count, TabsState.maxRestoredTabs)
        // Tail kept: the LAST persisted entry (nearest last focus) survives,
        // the very first is dropped.
        XCTAssertEqual(out.last?.path, "/f/\(n - 1).md")
        XCTAssertEqual(out.first?.path, "/f/\(n - TabsState.maxRestoredTabs).md")
    }

    func test_cap_appliesAfterDedup_notBeforeIt() {
        // 300 unique files, but each present twice → 600 entries. Dedup first
        // (→300), THEN cap (→maxRestoredTabs). If cap ran first on the raw 600
        // we'd lose uniques we should have kept.
        let unique = (0..<300).map { "/u/\($0).md" }
        let input = pairs(unique + unique)
        let out = TabsState.dedupedRestoreTabs(input)
        XCTAssertEqual(out.count, TabsState.maxRestoredTabs)
        XCTAssertEqual(Set(out.map(\.path)).count, TabsState.maxRestoredTabs)
    }

    func test_dedup_emptyInput_isEmpty() {
        XCTAssertTrue(TabsState.dedupedRestoreTabs([]).isEmpty)
    }

    func test_dedup_underCap_passesThroughUntouched() {
        let input = pairs(["/a.md", "/b.md", "/c.md"])
        let out = TabsState.dedupedRestoreTabs(input)
        XCTAssertEqual(out.map(\.path), ["/a.md", "/b.md", "/c.md"])
    }
}
