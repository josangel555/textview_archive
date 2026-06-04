import XCTest
@testable import ViewerCore
import ViewerKit

/// UX-K (#231) — pure-data persistence coverage for the per-file scroll
/// position `TabSnapshot.scrollTopLine`. Host-safe (pure Codable, no UI,
/// no FS — round-trips through `Data`, not files). Mirrors the
/// additive-optional / downgrade-safe contract already pinned for
/// `categoryOverride` in `TabSnapshotCategoryOverrideTests`:
///
///   - a concrete scroll line survives a `TabSnapshot` round-trip;
///   - a `nil` scroll OMITS the JSON key entirely (clean wire shape, so an
///     older reader never sees an unknown field) — NOT a literal `null`;
///   - a legacy on-disk tab (no `scrollTopLine` key) decodes to nil = no
///     restore (forward-compat downgrade guard);
///   - an explicit JSON `null` also decodes to nil (defensive);
///   - the scroll line survives a FULL `SessionSnapshot` round-trip and a
///     differing scroll is detected by `hasSamePersistedContent` (so the
///     autosave equality guard schedules a write when scroll moves).
final class TabSnapshotScrollPersistenceTests: XCTestCase {

    // MARK: - TabSnapshot round-trip

    func test_scrollTopLine_roundTrips() throws {
        let snap = TabSnapshot(path: "/tmp/a.swift", viewMode: "source",
                               scrollTopLine: 412)
        let data = try JSONEncoder().encode(snap)
        let back = try JSONDecoder().decode(TabSnapshot.self, from: data)
        XCTAssertEqual(back, snap)
        XCTAssertEqual(back.scrollTopLine, 412)
    }

    func test_scrollAndOverride_coexist() throws {
        // Both additive-optional fields present at once must round-trip
        // independently.
        let snap = TabSnapshot(path: "/tmp/a.db", viewMode: "source",
                               categoryOverride: FileCategory.sqlite.rawValue,
                               scrollTopLine: 7)
        let data = try JSONEncoder().encode(snap)
        let back = try JSONDecoder().decode(TabSnapshot.self, from: data)
        XCTAssertEqual(back.categoryOverride, "sqlite")
        XCTAssertEqual(back.scrollTopLine, 7)
    }

    // MARK: - nil → key omitted (not `null`)

    func test_nilScroll_omitsKeyOnWire() throws {
        let snap = TabSnapshot(path: "/tmp/a.md", viewMode: "rendered")
        let json = String(decoding: try JSONEncoder().encode(snap), as: UTF8.self)
        XCTAssertFalse(json.contains("scrollTopLine"),
                       "nil scroll must omit the key, got: \(json)")
    }

    func test_explicitNullJSON_decodesToNil() throws {
        let withNull = #"{"path":"/tmp/a.md","viewMode":"source","scrollTopLine":null}"#
        let snap = try JSONDecoder().decode(TabSnapshot.self, from: Data(withNull.utf8))
        XCTAssertNil(snap.scrollTopLine)
    }

    // MARK: - Legacy decode (downgrade guard)

    func test_legacyJSON_withoutScrollKey_decodesToNil() throws {
        // A pre-UX-K tab has no `scrollTopLine` key — must decode fine with
        // the synthesized optional defaulting to nil (no restore).
        let legacy = #"{"path":"/tmp/x.swift","viewMode":"editor"}"#
        let snap = try JSONDecoder().decode(TabSnapshot.self, from: Data(legacy.utf8))
        XCTAssertEqual(snap.path, "/tmp/x.swift")
        XCTAssertEqual(snap.viewMode, "editor")
        XCTAssertNil(snap.scrollTopLine)
    }

    // MARK: - Full SessionSnapshot round-trip + equality guard

    func test_sessionSnapshot_carriesScroll_andComparesEqual() throws {
        let tabs = [
            TabSnapshot(path: "/tmp/a.swift", viewMode: "source", scrollTopLine: 120),
            TabSnapshot(path: "/tmp/b.md", viewMode: "rendered"),  // nil scroll
        ]
        let session = SessionSnapshot(
            id: UUID(), displayName: "S", createdAt: Date(),
            lastActiveAt: Date(), sidebarRootPath: "/tmp",
            openTabs: tabs, selectedTabIndex: 0)
        let data = try JSONEncoder().encode(session)
        let back = try JSONDecoder().decode(SessionSnapshot.self, from: data)
        XCTAssertEqual(back.openTabs.count, 2)
        XCTAssertEqual(back.openTabs[0].scrollTopLine, 120)
        XCTAssertNil(back.openTabs[1].scrollTopLine)
        // Scroll is part of `openTabs`, which `hasSamePersistedContent`
        // compares — a clean round-trip is identical content.
        XCTAssertTrue(back.hasSamePersistedContent(as: session))
    }

    func test_sessionSnapshot_differingScroll_isNotEqualContent() {
        // Same identity + timestamps, only the scroll line differs → must be
        // detected as a real content change so the autosave fires.
        let pinned = Date(timeIntervalSince1970: 0)
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let s1 = SessionSnapshot(
            id: id, displayName: "S", createdAt: pinned, lastActiveAt: pinned,
            sidebarRootPath: nil,
            openTabs: [TabSnapshot(path: "/tmp/a.swift", viewMode: "source",
                                   scrollTopLine: 10)],
            selectedTabIndex: 0)
        let s2 = SessionSnapshot(
            id: id, displayName: "S", createdAt: pinned, lastActiveAt: pinned,
            sidebarRootPath: nil,
            openTabs: [TabSnapshot(path: "/tmp/a.swift", viewMode: "source",
                                   scrollTopLine: 99)],
            selectedTabIndex: 0)
        XCTAssertFalse(s1.hasSamePersistedContent(as: s2),
                       "a scroll-position change is a persisted-content change")
    }
}
