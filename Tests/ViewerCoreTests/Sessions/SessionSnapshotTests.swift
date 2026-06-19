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

    // MARK: displayNameIsUserSet (TSK-1016) --------------------------

    func testDisplayNameIsUserSet_roundtripTrue() throws {
        let pinned = Date(timeIntervalSince1970: 1_700_000_000)
        let snap = SessionSnapshot(
            savedAt: pinned, id: UUID(), displayName: "My Work",
            createdAt: pinned, lastActiveAt: pinned,
            sidebarRootPath: "/tmp/proj",
            displayNameIsUserSet: true
        )
        let data = try JSONFileStore.encoder.encode(snap)
        let back = try JSONFileStore.decoder.decode(SessionSnapshot.self, from: data)
        XCTAssertEqual(back, snap)
        XCTAssertEqual(back.displayNameIsUserSet, true)
    }

    func testDisplayNameIsUserSet_missingKeyDecodesNil() throws {
        // A pre-TSK-1016 file has no `displayNameIsUserSet` key; it must
        // decode to nil (== not user-set ⇒ auto-relabel allowed).
        let json = """
        {
          "schemaVersion": 2,
          "savedAt": "2026-01-01T00:00:00Z",
          "id": "22222222-2222-2222-2222-222222222222",
          "displayName": "Foo",
          "createdAt": "2026-01-01T00:00:00Z",
          "lastActiveAt": "2026-01-01T00:00:00Z",
          "sidebarRootPath": "/p",
          "openTabs": [],
          "selectedTabIndex": null
        }
        """.data(using: .utf8)!
        let decoded = try JSONFileStore.decoder.decode(SessionSnapshot.self, from: json)
        XCTAssertNil(decoded.displayNameIsUserSet)
    }

    func testWith_displayNameIsUserSet_precedence() {
        let pinned = Date(timeIntervalSince1970: 1_700_000_000)
        let base = SessionSnapshot(
            savedAt: pinned, id: UUID(), displayName: "proj",
            createdAt: pinned, lastActiveAt: pinned, sidebarRootPath: "/tmp/proj"
        )
        XCTAssertNil(base.displayNameIsUserSet)
        // Omitting the arg leaves the field unchanged…
        XCTAssertNil(base.with(displayName: "x").displayNameIsUserSet,
            "omitting displayNameIsUserSet must leave it unchanged")
        // …passing .some(true) flips it (the rename path)…
        let renamed = base.with(displayName: "My Work", displayNameIsUserSet: .some(true))
        XCTAssertEqual(renamed.displayName, "My Work")
        XCTAssertEqual(renamed.displayNameIsUserSet, true)
        // …and .some(nil) clears it back to folder-derived.
        XCTAssertNil(renamed.with(displayNameIsUserSet: .some(nil)).displayNameIsUserSet)
    }

    func testEqualityGuard_userSetFlagChange_isDifferent() {
        let pinned = Date(timeIntervalSince1970: 1_700_000_000)
        let folderDerived = SessionSnapshot(
            savedAt: pinned, id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            displayName: "proj", createdAt: pinned, lastActiveAt: pinned,
            sidebarRootPath: "/tmp/proj", displayNameIsUserSet: nil
        )
        let userSet = folderDerived.with(displayNameIsUserSet: .some(true))
        XCTAssertFalse(folderDerived.hasSamePersistedContent(as: userSet),
            "flipping displayNameIsUserSet is a real persisted change — autosave must fire")
        // nil and explicit-false must be treated as the same (both = not user-set).
        let explicitFalse = folderDerived.with(displayNameIsUserSet: .some(false))
        XCTAssertTrue(folderDerived.hasSamePersistedContent(as: explicitFalse),
            "nil and false both mean not-user-set — must not spam writes")
    }

    func testSessionIndexDecodeToleratesMissingVersion() throws {
        // TSK-1028: a legacy/hand-edited index.json with no `version` must
        // decode (defaulting to the v1 schema), NOT throw → be classified
        // corrupt → discard lastActiveID + ordering.
        let uuid = UUID()
        let json = Data("""
        {"sessions":[{"id":"\(uuid.uuidString)","rootPath":"/tmp/x","displayName":"X","lastActiveAt":"2020-01-01T00:00:00Z"}],"lastActiveID":"\(uuid.uuidString)"}
        """.utf8)
        let idx = try JSONFileStore.decoder.decode(SessionIndex.self, from: json)
        XCTAssertEqual(idx.version, SessionIndex.currentSchema)
        XCTAssertEqual(idx.sessions.count, 1)
        XCTAssertEqual(idx.lastActiveID, uuid, "lastActiveID preserved, not discarded")
    }
}
