import XCTest
@testable import ViewerCore

/// WAVE-1 foundations backfill extending `SessionSnapshotContentEqualityTests`:
/// the equality guard's behavior on persisted-content edges that the existing
/// suite doesn't pin — tab REORDER (same set, different order) and the WAVE-2b
/// per-tab `categoryOverride` field (which rides into the guard via
/// `openTabs ==` on `TabSnapshot`). The autosave (`fireAutosave`) only writes
/// when `hasSamePersistedContent(as:)` is false, so a missed dimension here is
/// a silently-dropped autosave (data loss on crash) or a write storm.
///
/// Pure value logic, host-safe (no UI, no FS). Filter:
///   `swift test --filter ViewerCoreTests.SessionSnapshotGuardExtraTests`
final class SessionSnapshotGuardExtraTests: XCTestCase {

    private let id = UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!
    private let created = Date(timeIntervalSince1970: 1_700_000_000)

    private func snap(
        openTabs: [TabSnapshot],
        selectedTabIndex: Int? = 0
    ) -> SessionSnapshot {
        SessionSnapshot(
            savedAt: Date(),
            id: id,
            displayName: "Proj",
            createdAt: created,
            lastActiveAt: Date(),
            sidebarRootPath: "/tmp/p",
            openTabs: openTabs,
            selectedTabIndex: selectedTabIndex)
    }

    private let a = TabSnapshot(path: "/tmp/p/a.md", viewMode: "rendered")
    private let b = TabSnapshot(path: "/tmp/p/b.md", viewMode: "source")

    /// Reordering the SAME tabs is a real persisted-content change — the
    /// guard must let the autosave through so the new order survives a crash.
    func test_tabReorder_sameSet_isDifferent() {
        let original = snap(openTabs: [a, b])
        let reordered = snap(openTabs: [b, a])
        XCTAssertFalse(original.hasSamePersistedContent(as: reordered),
            "a tab reorder changes openTabs order and must count as a content change")
    }

    /// Identical order compares equal (the no-op the reorder test contrasts
    /// with) — a re-snapshot of an unchanged list must not write.
    func test_tabList_identicalOrder_isSame() {
        XCTAssertTrue(snap(openTabs: [a, b]).hasSamePersistedContent(as: snap(openTabs: [a, b])))
    }

    /// A change to ONLY a tab's `categoryOverride` (WAVE-2b "Open As…") is a
    /// persisted-content change — the chosen viewer must survive a restart, so
    /// the autosave guard must not collapse it.
    func test_categoryOverrideChange_isDifferent() {
        let plain = TabSnapshot(path: "/tmp/p/x.db", viewMode: "source", categoryOverride: nil)
        let asCSV = TabSnapshot(path: "/tmp/p/x.db", viewMode: "source", categoryOverride: "csv")
        XCTAssertFalse(snap(openTabs: [plain]).hasSamePersistedContent(as: snap(openTabs: [asCSV])),
            "a per-tab categoryOverride change is real persisted content")
    }

    /// Same categoryOverride on both sides → equal (no spurious write when the
    /// override is unchanged).
    func test_sameCategoryOverride_isSame() {
        let t1 = TabSnapshot(path: "/tmp/p/x.db", viewMode: "source", categoryOverride: "csv")
        let t2 = TabSnapshot(path: "/tmp/p/x.db", viewMode: "source", categoryOverride: "csv")
        XCTAssertTrue(snap(openTabs: [t1]).hasSamePersistedContent(as: snap(openTabs: [t2])))
    }

    /// Reducing the tab count (a close) is a content change even when the
    /// surviving tab is byte-identical to one of the originals.
    func test_tabClose_isDifferent() {
        XCTAssertFalse(snap(openTabs: [a, b]).hasSamePersistedContent(as: snap(openTabs: [a])))
    }
}
