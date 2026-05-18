import XCTest
@testable import ViewerCore
import ViewerKit

/// End-to-end test for the Phase-1 migration story: a user with the
/// previous build has only `Workspaces/_last.json` on disk; on first
/// launch of the sessions build, the bootstrap path must lift that
/// snapshot into a "Default" session and write the new
/// `Sessions/index.json` + `<uuid>.json` pair without losing user
/// state.
///
/// We exercise the migration at the `SessionStore` + `WorkspaceStore`
/// boundary so the test runs on host (no `SessionsAppCoordinator`,
/// no `DocumentModel`, no NSApplication). The exact migration
/// sequence we model:
///
///   1. Plant a legacy `_last.json` in a fake Workspaces/ directory.
///   2. Run the same steps `SessionsAppCoordinator.bootstrap()` does
///      when no v2 index exists:
///         - `WorkspaceStore.loadAutoSlot()` reads legacy
///         - `SessionSnapshot.fromLegacy(...)` lifts it
///         - `SessionStore.saveSync(...)` persists the snapshot
///         - `SessionStore.saveIndexSync(...)` persists the index
///   3. Re-construct a `SessionsCoordinator` against the v2 store and
///      call `restore()`. Verify the resulting in-memory state matches
///      the original legacy snapshot's user-visible fields.
///   4. Verify the compat-bridge write back to `_last.json` (Phase-1
///      "keep writing legacy for one release" rule) round-trips.
final class SessionsMigrationTests: XCTestCase {

    private var tmp: URL!
    private var workspaceDir: URL!
    private var sessionsDir: URL!
    private var workspace: WorkspaceStore!
    private var store: SessionStore!

    /// Hand-frozen fixture: the on-disk shape `WorkspaceStore` wrote
    /// in the pre-sessions build, captured here so we don't depend on
    /// the current encoder's output (which might evolve). The shape
    /// matches `WorkspaceSnapshot v1` field-for-field — schema 1,
    /// six payload keys.
    ///
    /// Sourced from a real run on the previous build (Mar 2026 commit
    /// `036a911`, walkthrough branch merge). Keep this fixture stable
    /// — if the schema changes intentionally, add a NEW fixture and
    /// leave this one in place so we keep regression coverage on the
    /// historical layout.
    private static let lastJsonFixture: String = """
    {
      "openTabs" : [
        {
          "path" : "/tmp/proj/README.md",
          "viewMode" : "rendered"
        },
        {
          "path" : "/tmp/proj/src/main.swift",
          "viewMode" : "source"
        }
      ],
      "savedAt" : "2026-03-15T12:34:56Z",
      "schemaVersion" : 1,
      "selectedTabIndex" : 0,
      "sidebarRootPath" : "/tmp/proj",
      "themeOverride" : "xcodeDark",
      "wordWrap" : true,
      "zoom" : 1.25
    }
    """

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mdv-migration-tests-\(UUID().uuidString)")
        workspaceDir = tmp.appendingPathComponent("Workspaces")
        sessionsDir = tmp.appendingPathComponent("Sessions")
        try FileManager.default.createDirectory(
            at: workspaceDir, withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: sessionsDir, withIntermediateDirectories: true
        )
        workspace = WorkspaceStore(directory: workspaceDir)
        store = SessionStore(directory: sessionsDir)
    }

    override func tearDownWithError() throws {
        store.flushSync()
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: end-to-end migration -------------------------------------

    @MainActor
    func testLegacyFixtureLiftsIntoSessionStore() throws {
        // 1. Plant the legacy fixture.
        try Self.lastJsonFixture.data(using: .utf8)!.write(
            to: workspaceDir.appendingPathComponent("_last.json")
        )

        // 2. Replay the bootstrap migration steps.
        guard let legacy = workspace.loadAutoSlot() else {
            XCTFail("WorkspaceStore failed to read fixture _last.json")
            return
        }
        XCTAssertEqual(legacy.openTabs.count, 2)
        XCTAssertEqual(legacy.sidebarRootPath, "/tmp/proj")
        XCTAssertEqual(legacy.zoom, 1.25)
        XCTAssertEqual(legacy.themeOverride, "xcodeDark")

        let migrated = SessionSnapshot.fromLegacy(legacy)
        XCTAssertTrue(store.saveSync(migrated))
        XCTAssertTrue(store.saveIndexSync(SessionIndex(
            sessions: [.init(
                id: migrated.id,
                rootPath: migrated.sidebarRootPath ?? "",
                displayName: migrated.displayName,
                lastActiveAt: migrated.lastActiveAt
            )],
            lastActiveID: migrated.id
        )))

        // 3. Fresh coordinator against the v2 store reads it back.
        let coord = SessionsCoordinator(store: store)
        coord.restore()
        XCTAssertEqual(coord.sessions.count, 1)
        guard let active = coord.active else {
            XCTFail("Migrated session not active after restore")
            return
        }
        XCTAssertEqual(active.displayName, "proj")
        XCTAssertEqual(active.sidebarRootPath, "/tmp/proj")
        XCTAssertEqual(active.openTabs.count, 2)
        XCTAssertEqual(active.openTabs.first?.path, "/tmp/proj/README.md")
        XCTAssertEqual(active.selectedTabIndex, 0)
        XCTAssertEqual(active.zoom, 1.25)
        XCTAssertEqual(active.wordWrap, true)
        XCTAssertEqual(active.themeOverride, "xcodeDark")
        XCTAssertEqual(active.schemaVersion, SessionSnapshot.currentSchema)
    }

    // MARK: compat-bridge --------------------------------------------

    func testCompatBridgeWriteRoundtripsThroughLegacyReader() throws {
        // The Phase-1 plan keeps writing `Workspaces/_last.json` for
        // one release so a downgrade-to-pre-sessions binary doesn't
        // lose the user's tabs. Verify the projection back through
        // `toLegacyWorkspaceSnapshot()` survives a WorkspaceStore
        // read.
        let v2 = SessionSnapshot(
            id: UUID(),
            displayName: "myproj",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastActiveAt: Date(timeIntervalSince1970: 1_700_000_000),
            sidebarRootPath: "/tmp/myproj",
            openTabs: [TabSnapshot(path: "/tmp/myproj/a.md", viewMode: "rendered")],
            selectedTabIndex: 0,
            sidebarExpandedPaths: ["/tmp/myproj/src"],  // dropped by v1 reader
            sidebarIncludeHidden: true,                  // dropped by v1 reader
            splitURL: "/tmp/myproj/b.md",                // dropped by v1 reader
            zoom: 1.0,
            wordWrap: false,
            themeOverride: nil
        )
        let bridged = v2.toLegacyWorkspaceSnapshot()
        workspace.saveAutoSlot(bridged)
        guard let reread = workspace.loadAutoSlot() else {
            XCTFail("WorkspaceStore could not re-read the compat-bridge write")
            return
        }
        XCTAssertEqual(reread.sidebarRootPath, "/tmp/myproj")
        XCTAssertEqual(reread.openTabs.count, 1)
        XCTAssertEqual(reread.selectedTabIndex, 0)
        XCTAssertEqual(reread.zoom, 1.0)
        XCTAssertEqual(reread.wordWrap, false)
    }

    // MARK: degenerate inputs ----------------------------------------

    @MainActor
    func testMigrationOfEmptyLegacyProducesDefaultSession() {
        // A user who quit with no folder open: `_last.json` has every
        // optional null. Migration must still produce a valid session
        // named "Default" rather than crashing or skipping.
        let empty = WorkspaceSnapshot(
            sidebarRootPath: nil,
            openTabs: [],
            selectedTabIndex: nil,
            zoom: nil, wordWrap: nil, themeOverride: nil
        )
        let migrated = SessionSnapshot.fromLegacy(empty)
        XCTAssertEqual(migrated.displayName, "Default")
        XCTAssertTrue(store.saveSync(migrated))
        // Restore through the coordinator to verify end-to-end.
        XCTAssertTrue(store.saveIndexSync(SessionIndex(
            sessions: [.init(
                id: migrated.id,
                rootPath: "",
                displayName: migrated.displayName,
                lastActiveAt: migrated.lastActiveAt
            )],
            lastActiveID: migrated.id
        )))
        let coord = SessionsCoordinator(store: store)
        coord.restore()
        XCTAssertEqual(coord.active?.displayName, "Default")
        XCTAssertTrue(coord.active?.openTabs.isEmpty ?? false)
    }

    func testMigrationDoesNotRunWhenSessionsIndexExists() {
        // Sanity check for the bootstrap's branch logic: if a v2
        // `index.json` is present, `loadIndex()` returns non-nil and
        // the caller skips the legacy lift. We model the precondition
        // directly here — bootstrap's branch is in ViewerUI but the
        // primitive it pivots on is `store.loadIndex()`.
        let pre = SessionIndex(sessions: [], lastActiveID: nil)
        store.saveIndexSync(pre)
        XCTAssertNotNil(store.loadIndex(), "v2 index should be visible to bootstrap")
    }
}
