import XCTest
@testable import ViewerCore
import ViewerKit

/// WAVE 2b item 6 — deeper persistence coverage for the per-tab
/// "Open As…" `TabSnapshot.categoryOverride`. Host-safe (pure Codable,
/// no UI, no FS). Complements `OpenAsCategoryOverrideTests`, which pins
/// the single-value round-trip + one legacy case; this file pins the
/// full additive-optional / downgrade-safe contract:
///
///   - every `FileCategory` rawValue survives a round-trip;
///   - a `nil` override OMITS the JSON key entirely (clean wire shape,
///     not a literal `null`) so an older reader never sees an unknown
///     field;
///   - a legacy on-disk tab (no `categoryOverride` key) decodes to nil
///     = auto-detect (forward-compat downgrade guard);
///   - an explicit JSON `null` also decodes to nil (defensive: some
///     encoders emit `null` for optionals);
///   - an UNKNOWN raw string (a future category this build can't model)
///     stays as a String in `TabSnapshot` but hydrates to nil via
///     `FileCategory(rawValue:)` — the documented "future category →
///     auto-detect" mapping that keeps an old build from crashing on a
///     newer session file;
///   - the override survives a FULL `SessionSnapshot` round-trip and is
///     compared by `hasSamePersistedContent` (autosave equality guard).
final class TabSnapshotCategoryOverrideTests: XCTestCase {

    // MARK: - Per-category round-trip

    func test_everyCategory_rawValue_roundTrips() throws {
        for cat in FileCategory.allCases {
            let snap = TabSnapshot(path: "/tmp/f", viewMode: "source",
                                   categoryOverride: cat.rawValue)
            let data = try JSONEncoder().encode(snap)
            let back = try JSONDecoder().decode(TabSnapshot.self, from: data)
            XCTAssertEqual(back, snap, "round-trip failed for \(cat)")
            XCTAssertEqual(back.categoryOverride, cat.rawValue)
            // And the stored string must re-hydrate to the same category.
            XCTAssertEqual(FileCategory(rawValue: back.categoryOverride!), cat)
        }
    }

    // MARK: - nil → key omitted (not `null`)

    func test_nilOverride_omitsKeyOnWire() throws {
        // The synthesized Codable for an Optional with no value encodes
        // the key as absent (JSONEncoder default), which is what keeps
        // the wire shape identical to a pre-WAVE-2b file. Assert on the
        // literal bytes so a future `encodeIfPresent` regression (or a
        // switch to emitting `null`) is caught.
        let snap = TabSnapshot(path: "/tmp/a.md", viewMode: "rendered")
        let json = String(decoding: try JSONEncoder().encode(snap), as: UTF8.self)
        XCTAssertFalse(json.contains("categoryOverride"),
                       "nil override must omit the key, got: \(json)")
    }

    func test_explicitNullJSON_decodesToNil() throws {
        // Defensive: if some encoder writes `"categoryOverride":null`,
        // it must still decode to nil, not throw.
        let withNull = #"{"path":"/tmp/a.md","viewMode":"source","categoryOverride":null}"#
        let snap = try JSONDecoder().decode(TabSnapshot.self, from: Data(withNull.utf8))
        XCTAssertNil(snap.categoryOverride)
    }

    // MARK: - Legacy decode (downgrade guard)

    func test_legacyJSON_extraUnknownKeys_stillDecodes() throws {
        // A future-schema tab carrying keys this build doesn't model must
        // still decode (Codable ignores unknown keys) and surface a nil
        // override when the key is absent.
        let future = #"""
        {"path":"/tmp/x.swift","viewMode":"editor","futureFlag":true,"pinned":1}
        """#
        let snap = try JSONDecoder().decode(TabSnapshot.self, from: Data(future.utf8))
        XCTAssertEqual(snap.path, "/tmp/x.swift")
        XCTAssertEqual(snap.viewMode, "editor")
        XCTAssertNil(snap.categoryOverride)
    }

    // MARK: - Unknown raw string → nil on hydrate

    func test_unknownRawString_storesButHydratesToNil() throws {
        // A newer build might persist a category this (older) build can't
        // model. The raw string round-trips verbatim in TabSnapshot (no
        // data loss on a re-save), but the hydrate-side mapping through
        // `FileCategory(rawValue:)` yields nil = auto-detect, matching
        // `SessionState.hydrate`'s documented downgrade behavior.
        let snap = TabSnapshot(path: "/tmp/f.future", viewMode: "source",
                               categoryOverride: "holographic")
        let data = try JSONEncoder().encode(snap)
        let back = try JSONDecoder().decode(TabSnapshot.self, from: data)
        XCTAssertEqual(back.categoryOverride, "holographic",
                       "raw string must survive re-save without loss")
        XCTAssertNil(FileCategory(rawValue: back.categoryOverride!),
                     "unknown category → nil on hydrate (auto-detect)")
    }

    func test_emptyStringOverride_hydratesToNil() {
        // Edge: an empty override string is not a valid category.
        XCTAssertNil(FileCategory(rawValue: ""))
    }

    // MARK: - Full SessionSnapshot round-trip

    func test_sessionSnapshot_carriesOverride_andComparesEqual() throws {
        let tabs = [
            TabSnapshot(path: "/tmp/a.db", viewMode: "source",
                        categoryOverride: FileCategory.sqlite.rawValue),
            TabSnapshot(path: "/tmp/b.md", viewMode: "rendered"),  // nil override
        ]
        let session = SessionSnapshot(
            id: UUID(), displayName: "S", createdAt: Date(),
            lastActiveAt: Date(), sidebarRootPath: "/tmp",
            openTabs: tabs, selectedTabIndex: 0)
        let data = try JSONEncoder().encode(session)
        let back = try JSONDecoder().decode(SessionSnapshot.self, from: data)
        XCTAssertEqual(back.openTabs.count, 2)
        XCTAssertEqual(back.openTabs[0].categoryOverride, "sqlite")
        XCTAssertNil(back.openTabs[1].categoryOverride)
        // The autosave equality guard must treat the round-tripped value
        // as identical persisted content (override is part of openTabs,
        // which `hasSamePersistedContent` compares).
        XCTAssertTrue(back.hasSamePersistedContent(as: session))
    }

    func test_sessionSnapshot_differingOverride_isNotEqualContent() {
        let base = TabSnapshot(path: "/tmp/a.db", viewMode: "source",
                               categoryOverride: nil)
        let forced = TabSnapshot(path: "/tmp/a.db", viewMode: "source",
                                 categoryOverride: FileCategory.sqlite.rawValue)
        let s1 = SessionSnapshot(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            displayName: "S", createdAt: Date(timeIntervalSince1970: 0),
            lastActiveAt: Date(timeIntervalSince1970: 0),
            sidebarRootPath: nil, openTabs: [base], selectedTabIndex: 0)
        let s2 = SessionSnapshot(
            id: s1.id, displayName: "S",
            createdAt: Date(timeIntervalSince1970: 0),
            lastActiveAt: Date(timeIntervalSince1970: 0),
            sidebarRootPath: nil, openTabs: [forced], selectedTabIndex: 0)
        // Same identity + timestamps, only the override differs → must be
        // detected as a real content change (so autosave fires).
        XCTAssertFalse(s1.hasSamePersistedContent(as: s2),
                       "an override change is a persisted-content change")
    }
}
