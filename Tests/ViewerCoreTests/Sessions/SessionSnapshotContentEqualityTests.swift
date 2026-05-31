import XCTest
@testable import ViewerCore

/// Tests for `SessionSnapshot.hasSamePersistedContent(as:)` — the equality
/// guard backing the debounced autosave (item7). Must ignore the bookkeeping
/// timestamps (`savedAt`, `lastActiveAt`) so an idle re-snapshot is a no-op,
/// while still treating any real persisted-field change as different.
///
/// Pure value logic, host-safe (no UI, no FS).
final class SessionSnapshotContentEqualityTests: XCTestCase {

    private let id = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
    private let created = Date(timeIntervalSince1970: 1_700_000_000)

    private func snap(
        savedAt: Date = Date(),
        lastActiveAt: Date = Date(),
        displayName: String = "Proj",
        sidebarRootPath: String? = "/tmp/p",
        openTabs: [TabSnapshot] = [TabSnapshot(path: "/tmp/p/a.md", viewMode: "rendered")],
        selectedTabIndex: Int? = 0,
        zoom: Double? = 1.0,
        wordWrap: Bool? = false,
        themeOverride: String? = nil
    ) -> SessionSnapshot {
        SessionSnapshot(
            savedAt: savedAt,
            id: id,
            displayName: displayName,
            createdAt: created,
            lastActiveAt: lastActiveAt,
            sidebarRootPath: sidebarRootPath,
            openTabs: openTabs,
            selectedTabIndex: selectedTabIndex,
            zoom: zoom,
            wordWrap: wordWrap,
            themeOverride: themeOverride
        )
    }

    func test_ignoresSavedAtAndLastActiveAt() {
        let a = snap(savedAt: Date(timeIntervalSince1970: 1), lastActiveAt: Date(timeIntervalSince1970: 2))
        let b = snap(savedAt: Date(timeIntervalSince1970: 100), lastActiveAt: Date(timeIntervalSince1970: 200))
        XCTAssertTrue(a.hasSamePersistedContent(as: b),
            "snapshots differing only in savedAt/lastActiveAt must compare equal — else autosave spams writes")
    }

    func test_tabListChange_isDifferent() {
        let a = snap()
        let b = snap(openTabs: [
            TabSnapshot(path: "/tmp/p/a.md", viewMode: "rendered"),
            TabSnapshot(path: "/tmp/p/b.md", viewMode: "source"),
        ])
        XCTAssertFalse(a.hasSamePersistedContent(as: b), "an added tab is a real content change")
    }

    func test_selectedIndexChange_isDifferent() {
        XCTAssertFalse(snap(selectedTabIndex: 0).hasSamePersistedContent(as: snap(selectedTabIndex: 1)))
    }

    func test_rootChange_isDifferent() {
        XCTAssertFalse(snap(sidebarRootPath: "/a").hasSamePersistedContent(as: snap(sidebarRootPath: "/b")))
    }

    func test_zoomWrapTheme_changes_areDifferent() {
        let base = snap()
        XCTAssertFalse(base.hasSamePersistedContent(as: snap(zoom: 1.5)))
        XCTAssertFalse(base.hasSamePersistedContent(as: snap(wordWrap: true)))
        XCTAssertFalse(base.hasSamePersistedContent(as: snap(themeOverride: "xcodeDark")))
    }

    func test_renameIsContentChange() {
        XCTAssertFalse(snap(displayName: "Old").hasSamePersistedContent(as: snap(displayName: "New")),
            "a rename must count as a content change")
    }

    func test_viewModeChange_isDifferent() {
        let a = snap(openTabs: [TabSnapshot(path: "/tmp/p/a.md", viewMode: "rendered")])
        let b = snap(openTabs: [TabSnapshot(path: "/tmp/p/a.md", viewMode: "source")])
        XCTAssertFalse(a.hasSamePersistedContent(as: b))
    }
}
