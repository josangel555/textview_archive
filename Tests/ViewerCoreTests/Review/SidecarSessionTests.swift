import XCTest
@testable import ViewerCore

/// Stage 1 (§7): the `.textview/` sidecar files that are NOT review JSON —
/// `session.json` (review cursor) and `config.json` (tracked-vs-ignored),
/// plus the git-tracking files the app emits. Asserts round-trip, the
/// tracked-by-default invariant, the `.gitignore` body for each mode, and
/// schema-too-new refusal.
final class SidecarSessionTests: XCTestCase {

    private var repoRoot: URL!

    override func setUpWithError() throws {
        repoRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-sidecar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repoRoot)
    }

    private func makeStore() -> SidecarStore {
        SidecarStore.projectLocal(repoRoot: repoRoot, environment: [:])
    }

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - session.json

    func test_session_roundTrip() {
        let store = makeStore()
        let s = SidecarSession(
            activeReviewId: "01HF7QABCDEFGHJKMNPQRSTVWX",
            draftInstructions: "Be terse.",
            lastExport: .init(
                reviewId: "01HF7QABCDEFGHJKMNPQRSTVWX",
                at: t0,
                target: .clipboard
            )
        )
        XCTAssertTrue(store.saveSession(s))
        XCTAssertEqual(store.loadSession(), s)
    }

    func test_session_landsAtSidecarRoot_notInReviewsTenant() {
        let store = makeStore()
        XCTAssertTrue(store.saveSession(SidecarSession(activeReviewId: "x")))
        let expected = repoRoot.appendingPathComponent(".textview/session.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path))
        // Must NOT live inside reviews/ (where ReviewStore would scan it).
        let wrong = repoRoot.appendingPathComponent(".textview/reviews/session.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: wrong.path))
    }

    func test_session_missingFile_loadsAsNil() {
        XCTAssertNil(makeStore().loadSession())
    }

    func test_session_schemaTooNew_isRefused() throws {
        let store = makeStore()
        let url = repoRoot.appendingPathComponent(".textview/session.json")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(#"{"schemaVersion": 999, "activeReviewId": "x"}"#.utf8).write(to: url)
        XCTAssertNil(store.loadSession(), "a newer-schema session must be refused")
    }

    // MARK: - config.json

    func test_config_defaultsToIgnored_noAudit_whenMissing() {
        let cfg = makeStore().loadConfig()
        XCTAssertFalse(cfg.tracked, "reviews are git-ignored by default (§1.3; owner decision 2026-06-01)")
        XCTAssertFalse(cfg.auditTrail, "audit sidecar is off by default (§2.4)")
    }

    func test_config_roundTrip() {
        let store = makeStore()
        let cfg = SidecarConfig(tracked: false, auditTrail: true)
        XCTAssertTrue(store.saveConfig(cfg))
        XCTAssertEqual(store.loadConfig(), cfg)
    }

    func test_config_schemaTooNew_fallsBackToDefault() throws {
        let store = makeStore()
        let url = repoRoot.appendingPathComponent(".textview/config.json")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(#"{"schemaVersion": 999, "tracked": true}"#.utf8).write(to: url)
        // Refused → safe default (git-ignored) rather than honoring a future shape.
        XCTAssertFalse(store.loadConfig().tracked)
    }

    // MARK: - git-tracking files (§1.3)

    func test_trackedConfig_writesNarrowGitignore_andGitattributes() {
        let store = makeStore()
        XCTAssertTrue(store.writeGitTrackingFiles(for: SidecarConfig(tracked: true)))

        let ignore = try? String(
            contentsOf: repoRoot.appendingPathComponent(".textview/.gitignore"), encoding: .utf8
        )
        XCTAssertNotNil(ignore)
        // Tracked → reviews/*.json are NOT ignored, but audit + session are.
        XCTAssertTrue(ignore!.contains("reviews/audit/"))
        XCTAssertTrue(ignore!.contains("session.json"))
        XCTAssertFalse(ignore!.contains("\n*\n"), "tracked mode must not ignore everything")

        let attrs = try? String(
            contentsOf: repoRoot.appendingPathComponent(".textview/.gitattributes"), encoding: .utf8
        )
        XCTAssertNotNil(attrs)
        XCTAssertTrue(attrs!.contains("reviews/*.json text eol=lf"))
    }

    func test_ignoredConfig_writesIgnoreEverythingGitignore_noGitattributes() {
        let store = makeStore()
        XCTAssertTrue(store.writeGitTrackingFiles(for: SidecarConfig(tracked: false)))

        let ignore = try? String(
            contentsOf: repoRoot.appendingPathComponent(".textview/.gitignore"), encoding: .utf8
        )
        XCTAssertNotNil(ignore)
        XCTAssertTrue(ignore!.contains("*"))
        XCTAssertTrue(ignore!.contains("!.gitignore"), "the ignore rule itself stays visible")

        // No .gitattributes when nothing is tracked.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: repoRoot.appendingPathComponent(".textview/.gitattributes").path
        ))
    }

    func test_gitTrackingFiles_areIdempotent() {
        let store = makeStore()
        XCTAssertTrue(store.writeGitTrackingFiles(for: SidecarConfig(tracked: true)))
        let url = repoRoot.appendingPathComponent(".textview/.gitignore")
        let first = try? Data(contentsOf: url)
        XCTAssertTrue(store.writeGitTrackingFiles(for: SidecarConfig(tracked: true)))
        let second = try? Data(contentsOf: url)
        XCTAssertEqual(first, second)
    }
}
