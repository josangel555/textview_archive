import XCTest
import ViewerCore
import ViewerKit
@testable import ViewerUI

/// WAVE-1 foundations backfill for the WRITE side of the launch-memory
/// ratchet fix (TRACE #188): `SessionState.dedupedSnapshotTabs(from:selectedIndex:)`.
///
/// `makeSnapshot()` runs the live tab list through this before persisting so a
/// snapshot that ALREADY accumulated duplicate entries (on a pre-fix build)
/// heals to its unique set on the next write instead of being re-persisted at
/// full bloat — and the live `selectedTabIndex` is remapped onto the compacted
/// `openTabs` so the persisted index stays coherent with the persisted list.
/// The restore READ side (`TabsState.dedupedRestoreTabs`) is pinned in
/// `ViewerCoreTests`; this is the only direct coverage of the write-side
/// compaction + the `liveIndex → outIndex` selection remap (a real gap — the
/// helper was previously untested).
///
/// `dedupedSnapshotTabs` is `nonisolated static` pure value logic; these tests
/// construct `Tab` values directly and never launch the app. Host-safe.
/// Filter: `swift test --filter ViewerUITests.SnapshotDedupRemapTests`
final class SnapshotDedupRemapTests: XCTestCase {

    private func lazyTab(_ path: String, _ mode: ViewMode = .source) -> Tab {
        Tab(url: URL(fileURLWithPath: path), state: .empty, viewMode: mode)
    }

    // MARK: dedup + order

    /// Duplicate paths collapse, first occurrence wins, on-disk order kept —
    /// the write-side mirror of the restore-side dedup.
    func test_dedup_collapsesDuplicates_firstWins_orderPreserved() {
        let tabs = [
            lazyTab("/a/one.md", .source),
            lazyTab("/a/two.md", .rendered),
            lazyTab("/a/one.md", .rendered),   // dup of #0
            lazyTab("/a/three.md", .source),
            lazyTab("/a/two.md", .source),     // dup of #1
        ]
        let (out, _) = SessionState.dedupedSnapshotTabs(from: tabs, selectedIndex: nil)
        XCTAssertEqual(out.map(\.path), ["/a/one.md", "/a/two.md", "/a/three.md"])
        XCTAssertEqual(out.first(where: { $0.path == "/a/one.md" })?.viewMode, "source",
            "first occurrence's viewMode is the one persisted")
    }

    /// Tabs with no URL (blank / hosted-view tabs) can't be persisted and are
    /// dropped from the snapshot.
    func test_urlessTabs_areDropped() {
        let tabs = [
            Tab(state: .empty),                       // blank, no url
            lazyTab("/a/keep.md"),
            Tab(state: .hostedView(id: UUID(), title: "Git Log")),  // no url
        ]
        let (out, _) = SessionState.dedupedSnapshotTabs(from: tabs, selectedIndex: nil)
        XCTAssertEqual(out.map(\.path), ["/a/keep.md"])
    }

    // MARK: selectedTabIndex remap (the core of this suite)

    /// Selection on a SURVIVOR remaps to that survivor's slot in the compacted
    /// list. Here the live selected index (3 → /a/three.md) lands at output
    /// slot 2 because an earlier dup collapsed away.
    func test_remap_selectionOnSurvivor_movesToCompactedSlot() {
        let tabs = [
            lazyTab("/a/one.md"),    // live 0 → out 0
            lazyTab("/a/two.md"),    // live 1 → out 1
            lazyTab("/a/one.md"),    // live 2 → dup → out 0
            lazyTab("/a/three.md"),  // live 3 → out 2  ← selected
        ]
        let (out, sel) = SessionState.dedupedSnapshotTabs(from: tabs, selectedIndex: 3)
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(sel, 2, "live index 3 must remap to compacted slot 2")
        XCTAssertEqual(out[sel!].path, "/a/three.md")
    }

    /// Selection ON a tab that itself dedups away (a later dup of an earlier
    /// survivor) remaps to the SURVIVOR's slot — selection is never lost or
    /// pointed past the compacted end.
    func test_remap_selectionOnDuplicate_pointsAtSurvivor() {
        let tabs = [
            lazyTab("/a/one.md"),    // live 0 → out 0 (survivor)
            lazyTab("/a/two.md"),    // live 1 → out 1
            lazyTab("/a/one.md"),    // live 2 → dup of 0 ← selected
        ]
        let (out, sel) = SessionState.dedupedSnapshotTabs(from: tabs, selectedIndex: 2)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(sel, 0,
            "selecting a duplicate remaps to its surviving first occurrence (slot 0)")
        XCTAssertEqual(out[sel!].path, "/a/one.md")
    }

    /// A nil live selection stays nil (no spurious "select tab 0").
    func test_remap_nilSelection_staysNil() {
        let (_, sel) = SessionState.dedupedSnapshotTabs(
            from: [lazyTab("/a/x.md")], selectedIndex: nil)
        XCTAssertNil(sel)
    }

    /// Selection pointing at a URL-less tab (which is dropped) remaps to nil
    /// rather than to an unrelated survivor.
    func test_remap_selectionOnDroppedUrllessTab_isNil() {
        let tabs = [
            lazyTab("/a/x.md"),       // live 0 → out 0
            Tab(state: .empty),       // live 1 → dropped (no url) ← selected
        ]
        let (out, sel) = SessionState.dedupedSnapshotTabs(from: tabs, selectedIndex: 1)
        XCTAssertEqual(out.count, 1)
        XCTAssertNil(sel, "selection on a dropped url-less tab maps to nil, not a wrong survivor")
    }

    /// The bloat-heal shape: 35 unique paths each repeated, with selection on
    /// a late occurrence. The output is the 35 unique entries and the
    /// selection lands on the right file's compacted slot.
    func test_remap_bloatedSnapshot_healsAndKeepsSelectionFile() {
        let unique = (0..<35).map { "/repo/doc\($0).md" }
        var tabs: [Tab] = []
        for _ in 0..<8 { tabs.append(contentsOf: unique.map { lazyTab($0) }) }
        XCTAssertEqual(tabs.count, 35 * 8)
        // Select a late occurrence of doc17 (in the final repeat block).
        let selectedLive = tabs.lastIndex { $0.url?.lastPathComponent == "doc17.md" }!

        let (out, sel) = SessionState.dedupedSnapshotTabs(
            from: tabs, selectedIndex: selectedLive)
        XCTAssertEqual(out.count, 35, "heals to the unique set")
        XCTAssertEqual(out[sel!].path, "/repo/doc17.md",
            "selection resolves to the surviving doc17 entry regardless of which dup was live-selected")
    }
}
