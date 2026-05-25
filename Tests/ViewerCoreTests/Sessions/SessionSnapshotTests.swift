import XCTest
@testable import ViewerCore
import ViewerKit

/// Pure-data tests for `SessionSnapshot` / `SessionIndex`. Focus is on
/// the contract that future schema versions can't silently corrupt
/// older readers — codable round-trip + the "additive optional fields
/// tolerate missing keys" property. The legacy `WorkspaceSnapshot`
/// migration was retired in decision G (2026-05-25).
///
/// No UI, no FS state (we round-trip through `Data`, not files). Safe
/// to run on the host Mac per CLAUDE.md.
final class SessionSnapshotTests: XCTestCase {

    // MARK: Codable round-trip ---------------------------------------

    func testRoundtripFullyPopulated() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snap = SessionSnapshot(
            schemaVersion: SessionSnapshot.currentSchema,
            savedAt: now,
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000ABCD")!,
            displayName: "Project Foo",
            createdAt: now.addingTimeInterval(-3600),
            lastActiveAt: now,
            sidebarRootPath: "/tmp/proj",
            openTabs: [
                TabSnapshot(path: "/tmp/a.md", viewMode: "rendered"),
                TabSnapshot(path: "/tmp/b.swift", viewMode: "source"),
            ],
            selectedTabIndex: 1,
            sidebarExpandedPaths: ["/tmp/proj/src", "/tmp/proj/Tests"],
            sidebarIncludeHidden: true,
            splitURL: "/tmp/proj/README.md",
            zoom: 1.25,
            wordWrap: true,
            themeOverride: "xcodeDark"
        )
        let data = try JSONFileStore.encoder.encode(snap)
        let back = try JSONFileStore.decoder.decode(SessionSnapshot.self, from: data)
        XCTAssertEqual(back, snap)
    }

    func testRoundtripMinimalNilFields() throws {
        // The "fresh-session" shape — every optional left at nil. This
        // is what `SessionsCoordinator.openFolder` writes on first
        // creation, so it had better round-trip.
        //
        // Fixed timestamps with no subsecond fraction: JSONFileStore's
        // ISO-8601 encoder strategy truncates to whole seconds, so a
        // `Date()` round-trip would fail Equatable on the µs drift.
        let pinned = Date(timeIntervalSince1970: 1_700_000_000)
        let snap = SessionSnapshot(
            schemaVersion: SessionSnapshot.currentSchema,
            savedAt: pinned,
            id: UUID(),
            displayName: "Untitled",
            createdAt: pinned,
            lastActiveAt: pinned,
            sidebarRootPath: nil,
            openTabs: [],
            selectedTabIndex: nil,
            sidebarExpandedPaths: nil,
            sidebarIncludeHidden: nil,
            splitURL: nil,
            zoom: nil,
            wordWrap: nil,
            themeOverride: nil
        )
        let data = try JSONFileStore.encoder.encode(snap)
        let back = try JSONFileStore.decoder.decode(SessionSnapshot.self, from: data)
        XCTAssertEqual(back, snap)
    }

    func testCurrentSchemaIsTwo() {
        // Pin the constant: any bump needs to be explicit + paired
        // with a migration step.
        XCTAssertEqual(SessionSnapshot.currentSchema, 2)
    }

    // MARK: Forward-compat decode tolerance --------------------------

    func testDecodeToleratesMissingAdditiveFields() throws {
        // A future v3 might omit `splitURL` if nil. Decode must succeed
        // with the field set to nil — this mirrors the
        // "additive, optional, default-filled" rule from the design doc.
        let json = """
        {
          "schemaVersion": 2,
          "savedAt": "2026-01-01T00:00:00Z",
          "id": "11111111-1111-1111-1111-111111111111",
          "displayName": "Foo",
          "createdAt": "2026-01-01T00:00:00Z",
          "lastActiveAt": "2026-01-01T00:00:00Z",
          "sidebarRootPath": "/p",
          "openTabs": [],
          "selectedTabIndex": null
        }
        """.data(using: .utf8)!
        let decoded = try JSONFileStore.decoder.decode(SessionSnapshot.self, from: json)
        XCTAssertEqual(decoded.displayName, "Foo")
        XCTAssertNil(decoded.splitURL)
        XCTAssertNil(decoded.sidebarExpandedPaths)
        XCTAssertNil(decoded.zoom)
    }

    func testDecodeRejectsMissingRequiredField() {
        // `id` is required (v2 baseline). A malformed file lacking it
        // must fail to decode — we'd rather skip-and-log than synthesize
        // a random UUID that would orphan the session against its
        // on-disk filename.
        let json = """
        {
          "schemaVersion": 2,
          "savedAt": "2026-01-01T00:00:00Z",
          "displayName": "Foo",
          "createdAt": "2026-01-01T00:00:00Z",
          "lastActiveAt": "2026-01-01T00:00:00Z",
          "sidebarRootPath": "/p",
          "openTabs": [],
          "selectedTabIndex": null
        }
        """.data(using: .utf8)!
        XCTAssertNil(
            try? JSONFileStore.decoder.decode(SessionSnapshot.self, from: json)
        )
    }

    // MARK: SessionIndex ---------------------------------------------

    func testSessionIndexRoundtrip() throws {
        let id1 = UUID(), id2 = UUID()
        let idx = SessionIndex(
            version: SessionIndex.currentSchema,
            sessions: [
                .init(id: id1, rootPath: "/a", displayName: "A",
                      lastActiveAt: Date(timeIntervalSince1970: 100)),
                .init(id: id2, rootPath: "/b", displayName: "B",
                      lastActiveAt: Date(timeIntervalSince1970: 200)),
            ],
            lastActiveID: id2
        )
        let data = try JSONFileStore.encoder.encode(idx)
        let back = try JSONFileStore.decoder.decode(SessionIndex.self, from: data)
        XCTAssertEqual(back, idx)
        XCTAssertEqual(back.lastActiveID, id2)
        XCTAssertEqual(back.sessions.count, 2)
    }

    func testSessionIndexDefaultIsEmpty() {
        let idx = SessionIndex()
        XCTAssertEqual(idx.version, SessionIndex.currentSchema)
        XCTAssertTrue(idx.sessions.isEmpty)
        XCTAssertNil(idx.lastActiveID)
    }
}
