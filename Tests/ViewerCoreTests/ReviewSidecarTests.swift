import XCTest
@testable import ViewerCore

/// Pure-logic coverage for the `.textview/` sidecar persistence
/// (`ReviewSidecar.swift`) — session.json / config.json round-trips,
/// forward-compat schema refusal, the missing-file defaults, the git-
/// tracking-file bodies, and `projectLocal` path resolution. It shipped
/// with zero tests. All IO is confined to a per-test temp dir.
final class ReviewSidecarTests: XCTestCase {

    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReviewSidecarTests-\(UUID().uuidString)")
        // SidecarStore / JSONFileStore create intermediate dirs, but make the
        // root explicitly so path assertions are unambiguous.
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func store() -> SidecarStore { SidecarStore(sidecarRoot: root) }

    // MARK: - session.json

    func test_loadSession_missing_returnsNil() {
        XCTAssertNil(store().loadSession())
    }

    func test_session_roundTrips_withLastExport() {
        let s = store()
        let exp = SidecarSession.LastExport(
            reviewId: "rev-7",
            at: Date(timeIntervalSince1970: 1_700_000_000),
            target: ReviewExportRecord.Target.allCases.first!)
        let session = SidecarSession(
            activeReviewId: "rev-7",
            draftInstructions: "be terse",
            lastExport: exp)
        XCTAssertTrue(s.saveSession(session))
        XCTAssertEqual(s.loadSession(), session)
    }

    func test_loadSession_schemaTooNew_refused() {
        let s = store()
        XCTAssertTrue(s.saveSession(SidecarSession(schemaVersion: 99, activeReviewId: "x")))
        XCTAssertNil(s.loadSession(), "a newer schema must be refused (forward-compat)")
    }

    func test_loadSession_corruptJSON_returnsNil() throws {
        try Data("not json {".utf8).write(to: root.appendingPathComponent("session.json"))
        XCTAssertNil(store().loadSession())
    }

    // MARK: - config.json

    func test_loadConfig_missing_returnsRecommendedDefault() {
        let c = store().loadConfig()
        XCTAssertEqual(c, SidecarConfig())
        XCTAssertFalse(c.tracked)
        XCTAssertFalse(c.auditTrail)
        XCTAssertEqual(c.schemaVersion, SidecarConfig.currentSchema)
    }

    func test_config_roundTrips() {
        let s = store()
        let cfg = SidecarConfig(tracked: true, auditTrail: true)
        XCTAssertTrue(s.saveConfig(cfg))
        XCTAssertEqual(s.loadConfig(), cfg)
    }

    func test_loadConfig_schemaTooNew_fallsBackToDefault() {
        let s = store()
        XCTAssertTrue(s.saveConfig(SidecarConfig(schemaVersion: 99, tracked: true)))
        XCTAssertEqual(s.loadConfig(), SidecarConfig(),
                       "schema-too-new config must fall back to the default, not the tracked value")
    }

    // MARK: - git-tracking files

    func test_writeGitTrackingFiles_ignored_writesGitignoreOnly() {
        let s = store()
        XCTAssertTrue(s.writeGitTrackingFiles(for: SidecarConfig(tracked: false)))
        let gi = root.appendingPathComponent(".gitignore")
        let ga = root.appendingPathComponent(".gitattributes")
        XCTAssertEqual(try? String(contentsOf: gi, encoding: .utf8),
                       SidecarStore.ignoredGitignore + "\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ga.path),
                       ".gitattributes is only written when tracked")
    }

    func test_writeGitTrackingFiles_tracked_writesBothBodies() {
        let s = store()
        XCTAssertTrue(s.writeGitTrackingFiles(for: SidecarConfig(tracked: true)))
        XCTAssertEqual(
            try? String(contentsOf: root.appendingPathComponent(".gitignore"), encoding: .utf8),
            SidecarStore.trackedGitignore + "\n")
        XCTAssertEqual(
            try? String(contentsOf: root.appendingPathComponent(".gitattributes"), encoding: .utf8),
            SidecarStore.trackedGitattributes + "\n")
    }

    func test_writeGitTrackingFiles_createsRootDirWhenMissing() {
        let fresh = root.appendingPathComponent("nested/deeper")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.path))
        let s = SidecarStore(sidecarRoot: fresh)
        XCTAssertTrue(s.writeGitTrackingFiles(for: SidecarConfig(tracked: false)))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fresh.appendingPathComponent(".gitignore").path))
    }

    // MARK: - projectLocal resolution

    func test_projectLocal_defaultsToDotTextviewUnderRepo() {
        let store = SidecarStore.projectLocal(repoRoot: root, environment: [:])
        XCTAssertEqual(store.sidecarRoot.lastPathComponent, ".textview")
        XCTAssertEqual(store.sidecarRoot.deletingLastPathComponent().standardizedFileURL,
                       root.standardizedFileURL)
    }

    func test_projectLocal_honorsEnvOverride() {
        let custom = root.appendingPathComponent("custom-sidecar")
        let store = SidecarStore.projectLocal(
            repoRoot: root, environment: ["MDV_TEXTVIEW_DIR": custom.path])
        // Compare `.path` (the override resolves with isDirectory: true → a
        // trailing slash, which standardizedFileURL preserves but .path drops).
        XCTAssertEqual(store.sidecarRoot.path, custom.path)
    }
}
