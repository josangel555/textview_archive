import XCTest
@testable import ViewerCore
import ViewerKit

/// TSK-718 (hot exit) — pure-data persistence coverage for the unsaved
/// editor-buffer text `TabSnapshot.unsavedText`. Host-safe (pure Codable, no
/// UI, no FS). Mirrors the additive-optional / downgrade-safe contract pinned
/// for `scrollTopLine` / `categoryOverride`:
///
///   - concrete unsaved text survives a `TabSnapshot` round-trip;
///   - `nil` unsaved text OMITS the JSON key (clean wire — an older reader
///     never sees an unknown field) — NOT a literal `null`;
///   - a legacy on-disk tab (no `unsavedText` key) decodes to nil = no restore
///     (forward-compat downgrade guard);
///   - an explicit JSON `null` also decodes to nil (defensive);
///   - unsaved text survives a FULL `SessionSnapshot` round-trip and a
///     differing unsaved buffer is detected by `hasSamePersistedContent` (so
///     the autosave equality guard writes when an unsaved edit changes).
final class TabSnapshotUnsavedTextPersistenceTests: XCTestCase {

    // MARK: - TabSnapshot round-trip

    func test_unsavedText_roundTrips() throws {
        let snap = TabSnapshot(path: "/tmp/a.swift", viewMode: "editor",
                               unsavedText: "let x = 1  // in-flight edit")
        let data = try JSONEncoder().encode(snap)
        let back = try JSONDecoder().decode(TabSnapshot.self, from: data)
        XCTAssertEqual(back, snap)
        XCTAssertEqual(back.unsavedText, "let x = 1  // in-flight edit")
    }

    func test_unsavedText_coexistsWithScrollAndOverride() throws {
        // All three additive-optional fields present at once round-trip
        // independently.
        let snap = TabSnapshot(path: "/tmp/a.db", viewMode: "source",
                               categoryOverride: FileCategory.sqlite.rawValue,
                               scrollTopLine: 7,
                               unsavedText: "edited")
        let data = try JSONEncoder().encode(snap)
        let back = try JSONDecoder().decode(TabSnapshot.self, from: data)
        XCTAssertEqual(back.categoryOverride, "sqlite")
        XCTAssertEqual(back.scrollTopLine, 7)
        XCTAssertEqual(back.unsavedText, "edited")
    }

    // MARK: - nil → key omitted (not `null`)

    func test_nilUnsaved_omitsKeyOnWire() throws {
        let snap = TabSnapshot(path: "/tmp/a.md", viewMode: "rendered")
        let json = String(decoding: try JSONEncoder().encode(snap), as: UTF8.self)
        XCTAssertFalse(json.contains("unsavedText"),
                       "nil unsavedText must omit the key, got: \(json)")
    }

    func test_explicitNullJSON_decodesToNil() throws {
        let withNull = #"{"path":"/tmp/a.md","viewMode":"source","unsavedText":null}"#
        let snap = try JSONDecoder().decode(TabSnapshot.self, from: Data(withNull.utf8))
        XCTAssertNil(snap.unsavedText)
    }

    // MARK: - Legacy decode (downgrade guard)

    func test_legacyJSON_withoutUnsavedKey_decodesToNil() throws {
        // A pre-TSK-718 tab has no `unsavedText` key — must decode fine with
        // the synthesized optional defaulting to nil (no restore).
        let legacy = #"{"path":"/tmp/x.swift","viewMode":"editor","scrollTopLine":3}"#
        let snap = try JSONDecoder().decode(TabSnapshot.self, from: Data(legacy.utf8))
        XCTAssertEqual(snap.path, "/tmp/x.swift")
        XCTAssertEqual(snap.scrollTopLine, 3)
        XCTAssertNil(snap.unsavedText)
    }

    // MARK: - Full SessionSnapshot round-trip + equality guard

    func test_sessionSnapshot_carriesUnsaved_andComparesEqual() throws {
        let tabs = [
            TabSnapshot(path: "/tmp/a.swift", viewMode: "editor",
                        unsavedText: "dirty A"),
            TabSnapshot(path: "/tmp/b.md", viewMode: "rendered"),  // clean
        ]
        let session = SessionSnapshot(
            id: UUID(), displayName: "S", createdAt: Date(),
            lastActiveAt: Date(), sidebarRootPath: "/tmp",
            openTabs: tabs, selectedTabIndex: 0)
        let data = try JSONEncoder().encode(session)
        let back = try JSONDecoder().decode(SessionSnapshot.self, from: data)
        XCTAssertEqual(back.openTabs.count, 2)
        XCTAssertEqual(back.openTabs[0].unsavedText, "dirty A")
        XCTAssertNil(back.openTabs[1].unsavedText)
        XCTAssertTrue(back.hasSamePersistedContent(as: session))
    }

    func test_sessionSnapshot_differingUnsaved_isNotEqualContent() {
        // Same identity + timestamps, only the unsaved buffer differs → must be
        // detected as a real content change so the autosave fires (otherwise an
        // edit-then-quit would silently fail to persist for hot exit).
        let pinned = Date(timeIntervalSince1970: 0)
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let s1 = SessionSnapshot(
            id: id, displayName: "S", createdAt: pinned, lastActiveAt: pinned,
            sidebarRootPath: nil,
            openTabs: [TabSnapshot(path: "/tmp/a.swift", viewMode: "editor",
                                   unsavedText: "v1")],
            selectedTabIndex: 0)
        let s2 = SessionSnapshot(
            id: id, displayName: "S", createdAt: pinned, lastActiveAt: pinned,
            sidebarRootPath: nil,
            openTabs: [TabSnapshot(path: "/tmp/a.swift", viewMode: "editor",
                                   unsavedText: "v2")],
            selectedTabIndex: 0)
        XCTAssertFalse(s1.hasSamePersistedContent(as: s2),
                       "an unsaved-buffer change is a persisted-content change")
    }

    // The clean→dirty transition (nil → text) is likewise a content change —
    // pins that the FIRST unsaved edit after a clean snapshot triggers a write.
    func test_sessionSnapshot_nilToText_isNotEqualContent() {
        let pinned = Date(timeIntervalSince1970: 0)
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        func snap(_ unsaved: String?) -> SessionSnapshot {
            SessionSnapshot(
                id: id, displayName: "S", createdAt: pinned, lastActiveAt: pinned,
                sidebarRootPath: nil,
                openTabs: [TabSnapshot(path: "/tmp/a.swift", viewMode: "editor",
                                       unsavedText: unsaved)],
                selectedTabIndex: 0)
        }
        XCTAssertFalse(snap(nil).hasSamePersistedContent(as: snap("typed")),
                       "clean→dirty must be a persisted-content change")
    }
}
