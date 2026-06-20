import XCTest
import ViewerCore
import ViewerKit
@testable import ViewerUI

/// T1m tests for SESSION TYPES (#184 scope item 3): a `SessionKind` with
/// a per-kind default panel layout, SEEDED ONCE on creation — a template,
/// NOT a live override.
///
/// The seed-once contract is the load-bearing nuance: opening a folder
/// with a kind installs that kind's default layout the first time; the
/// user's later edits win, and re-mounting / relaunching never re-imposes
/// the kind default. `.project` (or no kind) seeds nothing.
///
/// Pure-logic; no NSApplication / NSWindow. Safe on host.
/// Filter: `swift test --filter ViewerUITests.SessionTypeSeed`
@MainActor
final class SessionTypeSeedTests: XCTestCase {

    private lazy var tmpRoot: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionTypeSeedTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpRoot)
    }

    private func makeWorkspace(named: String) -> URL {
        let folder = tmpRoot.appendingPathComponent(named, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func makeCoordinator() -> SessionsAppCoordinator {
        let sessionsDir = tmpRoot
            .appendingPathComponent("stores-\(UUID().uuidString)")
            .appendingPathComponent("Sessions")
        try? FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        return {
            let c = SessionsAppCoordinator(
                model: DocumentModel(),
                store: SessionStore(directory: sessionsDir),
                initialRoot: nil)
            c.bootstrap()
            return c
        }()
    }

    // MARK: Pure-kind layout (no UI) -----------------------------------

    /// Asserts the given store is in the files-only state (owner request
    /// 2026-06-20): Files shown, every other panel forced hidden.
    private func assertFilesOnly(_ store: PanelLayoutStore,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(store.override(for: .files), .shown,
                       "Files must be shown", file: file, line: line)
        for k in SidebarPanelRegistry.defaultOrder where k != .files {
            XCTAssertEqual(store.override(for: k), .hidden,
                           "\(k) must start hidden in a fresh session", file: file, line: line)
        }
    }

    func test_projectKind_defaultLayoutIsFilesOnly() {
        // Owner request 2026-06-20: a plain new session opens with ONLY Files.
        XCTAssertEqual(SessionKind.project.defaultPanelLayout, .filesOnly,
            ".project default opens files-only (was: identity / data-presence heuristic)")
        XCTAssertFalse(SessionKind.project.defaultPanelLayout.isDefault)
    }

    func test_nonProjectKinds_haveNonDefaultLayouts() {
        for kind in [SessionKind.codeReview, .cicd, .metrics] {
            XCTAssertFalse(kind.defaultPanelLayout.isDefault,
                "\(kind.rawValue) must seed a non-default layout")
        }
    }

    func test_codeReview_layoutShowsGitAndProblems() {
        let layout = SessionKind.codeReview.defaultPanelLayout
        let overrides = PanelVisibilityOverrides.decoded(layout.overrides)
        XCTAssertEqual(overrides.state(.git), .shown)
        XCTAssertEqual(overrides.state(.lspProblems), .shown)
    }

    // MARK: Seed-once on creation --------------------------------------

    func test_openFolderWithKind_seedsThePanelLayout() {
        let coord = makeCoordinator()
        coord.openFolder(makeWorkspace(named: "review"), forceNew: true, kind: .codeReview)
        // The live model's panel layout reflects the codeReview seed.
        XCTAssertEqual(coord.model.panelLayout.override(for: .git), .shown,
            "creating a codeReview session must seed git=shown")
        XCTAssertEqual(coord.model.panelLayout.override(for: .lspProblems), .shown)
        // And it was persisted (so it survives relaunch + closes the seed gate).
        XCTAssertNotNil(coord.core.active?.panelLayout,
            "the seeded layout must be persisted into the snapshot")
        XCTAssertEqual(coord.core.active?.sessionType, SessionKind.codeReview.rawValue)
    }

    // MARK: New ▸ Session ▸ Kind menu wiring (TSK-373) -----------------

    func test_openNewSessionWithKind_seedsAndStampsTheKind() {
        // The exact action the New Session ▸ Kind menu row invokes.
        let coord = makeCoordinator()
        let root = makeWorkspace(named: "agent-root")
        coord.openNewSession(kind: .agent, root: root)
        XCTAssertEqual(coord.core.active?.sessionType, SessionKind.agent.rawValue,
            "the menu's kind must be stamped onto the new session")
        XCTAssertEqual(coord.model.panelLayout.override(for: .claudeTimeline), .shown,
            "the agent kind must seed claudeTimeline=shown")
        XCTAssertEqual(coord.model.panelLayout.override(for: .git), .shown)
        XCTAssertEqual(coord.core.active?.sidebarRootPath,
                       root.standardizedFileURL.resolvingSymlinksInPath().path,
            "openNewSession(kind:root:) roots the session at the given folder")
    }

    func test_openNewSessionCodeReview_seedsCodeReviewLayout() {
        let coord = makeCoordinator()
        coord.openNewSession(kind: .codeReview, root: makeWorkspace(named: "cr"))
        XCTAssertEqual(coord.core.active?.sessionType, SessionKind.codeReview.rawValue)
        XCTAssertEqual(coord.model.panelLayout.override(for: .git), .shown)
        XCTAssertEqual(coord.model.panelLayout.override(for: .lspProblems), .shown)
    }

    func test_openNewSessionProject_opensFilesOnly() {
        let coord = makeCoordinator()
        coord.openNewSession(kind: .project, root: makeWorkspace(named: "plainmenu"))
        assertFilesOnly(coord.model.panelLayout)   // owner: fresh session = Files only
        XCTAssertNil(coord.core.active?.sessionType,
            "the Project menu row stays the implicit default — sessionType nil")
    }

    func test_openFolderProjectKind_opensFilesOnly_andDoesNotStampType() {
        let coord = makeCoordinator()
        coord.openFolder(makeWorkspace(named: "plain"), forceNew: true, kind: .project)
        assertFilesOnly(coord.model.panelLayout)
        XCTAssertNil(coord.core.active?.sessionType,
            ".project is the implicit default — sessionType stays nil (minimal snapshot)")
    }

    func test_openFolderNoKind_opensFilesOnly() {
        let coord = makeCoordinator()
        coord.openFolder(makeWorkspace(named: "plain"), forceNew: true)
        assertFilesOnly(coord.model.panelLayout)
        XCTAssertNil(coord.core.active?.sessionType)
    }

    // MARK: Seed is NOT a live override --------------------------------

    func test_seed_doesNotOverrideUserEditsOnReactivate() {
        let coord = makeCoordinator()
        let review = makeWorkspace(named: "review")
        coord.openFolder(review, forceNew: true, kind: .cicd)
        let cID = coord.core.activeID!
        // cicd seeds git=shown. User then HIDES git — their edit must win.
        XCTAssertEqual(coord.model.panelLayout.override(for: .git), .shown)
        coord.model.panelLayout.setOverride(.git, .hidden)

        // Open another session, then come back. The cicd seed must NOT
        // re-fire and clobber the user's git=hidden.
        coord.openFolder(makeWorkspace(named: "other"), forceNew: true)
        coord.activate(id: cID)
        XCTAssertEqual(coord.model.panelLayout.override(for: .git), .hidden,
            "seed-once must not re-impose the kind default — the user's later edit wins")
    }

    // MARK: Round-trip / downgrade-safety ------------------------------

    func test_unknownSessionType_decodesToNil() {
        // A future kind this build doesn't know maps back to nil (==
        // .project), so an old reader doesn't crash on a new-kind file.
        XCTAssertNil(SessionKind(rawValue: "quantumDebugger"))
    }

    func test_panelLayoutSnapshot_roundTripsThroughSessionSnapshot() throws {
        let layout = SessionKind.metrics.defaultPanelLayout
        let snap = SessionSnapshot(
            id: UUID(), displayName: "M",
            createdAt: Date(timeIntervalSince1970: 1), lastActiveAt: Date(timeIntervalSince1970: 1),
            sidebarRootPath: "/tmp/m",
            sessionType: SessionKind.metrics.rawValue,
            panelLayout: layout)
        let data = try JSONFileStore.encoder.encode(snap)
        let back = try JSONFileStore.decoder.decode(SessionSnapshot.self, from: data)
        XCTAssertEqual(back.sessionType, SessionKind.metrics.rawValue)
        XCTAssertEqual(back.panelLayout, layout)
    }
}
