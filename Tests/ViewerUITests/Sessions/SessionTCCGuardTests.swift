import XCTest
import ViewerCore
import ViewerKit
@testable import ViewerUI

/// T1m guard for the sessions TCC policy, as revised for TSK-599:
///
/// - **Explicit user gestures open ANY folder** — including roots under the
///   TCC-protected set (`~/Documents`, `~/Desktop`, `~/Downloads`,
///   `~/Pictures`, iCloud Drive). The sidebar/bookmark context menu, the
///   open panel, script verbs and Go-to-path all route through
///   `SessionsAppCoordinator.openFolder`, and an explicit gesture is the
///   user's opt-in: a session is created, activated and persisted.
///   (Regression TSK-599: the 2026-06-03 blanket guard silently no-op'd
///   every open under `~/Documents` — the owner's entire workspace — so
///   "Open in New Session" did nothing, with no feedback.)
/// - **Implicit launch-time touches stay guarded** — the `bootstrap()`
///   prefs-root seed (and `DocumentModel.restorePreviousFolderIfAvailable`)
///   must never touch a TCC root the user didn't just point at, because a
///   permission prompt with no gesture behind it is hostile.
///
/// Pure-logic; no NSApplication / NSWindow, and the lifecycle bridge is
/// deliberately NOT wired, so no TCC-protected folder is ever enumerated —
/// only path math + persistence into an injected temp-dir store.
/// Filter: `swift test --filter ViewerUITests.SessionTCCGuard`
@MainActor
final class SessionTCCGuardTests: XCTestCase {

    private lazy var tmpRoot: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionTCCGuardTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        return url
    }()

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpRoot)
    }

    private func makeCoordinator(initialRoot: URL? = nil)
        -> (SessionsAppCoordinator, SessionStore) {
        let storesDir = tmpRoot.appendingPathComponent("stores-\(UUID().uuidString)")
        let sessionsDir = storesDir.appendingPathComponent("Sessions")
        try? FileManager.default.createDirectory(
            at: sessionsDir, withIntermediateDirectories: true)
        let store = SessionStore(directory: sessionsDir)
        let coord = SessionsAppCoordinator(
            model: DocumentModel(), store: store, initialRoot: initialRoot)
        coord.bootstrap()
        return (coord, store)
    }

    /// TSK-599: the explicit-gesture path must create + activate + persist
    /// a session even when the folder lives under a TCC-protected root.
    /// Uses a non-existent nested path so nothing real is enumerated —
    /// `core.openFolder` is pure path math when the lifecycle is unwired.
    func test_openFolder_explicitGesture_underTCCRoot_createsAndPersists() {
        let home = NSHomeDirectory()
        let url = URL(fileURLWithPath:
            "\(home)/Documents/mdv-tsk599-fixture/ProjectX")

        let (coord, store) = makeCoordinator()
        coord.openFolder(url)

        XCTAssertEqual(coord.core.sessions.count, 1,
            "an explicit open under ~/Documents must create a session (TSK-599)")
        XCTAssertNotNil(coord.active,
            "the new session must mount as active")
        XCTAssertEqual(coord.active?.rootURL.lastPathComponent, "ProjectX",
            "the session must be rooted at the right-clicked folder")

        // forceNew (the "Open in New Session" context-menu path) creates a
        // SECOND distinct session for the same physical folder.
        coord.openFolder(url, forceNew: true)
        XCTAssertEqual(coord.core.sessions.count, 2,
            "forceNew under ~/Documents must create a distinct session")

        coord.core.flushPersistenceSync()
        store.flushSync()
        XCTAssertNotNil(store.loadIndex(),
            "explicitly created TCC-root sessions persist like any other")
    }

    /// The IMPLICIT launch-time seed keeps the guard: a prefs initialRoot
    /// under a TCC root must never become a session without a gesture.
    /// `~/Documents` itself is used because the seed requires an existing
    /// directory — only its metadata is stat'd, never its contents.
    func test_bootstrap_initialRootUnderTCCRoot_stillRefused() {
        let documents = URL(fileURLWithPath: NSHomeDirectory() + "/Documents")
        let (coord, store) = makeCoordinator(initialRoot: documents)

        XCTAssertTrue(coord.core.sessions.isEmpty,
            "bootstrap must not seed a session from a TCC-protected prefs root")
        XCTAssertNil(coord.active,
            "no SessionState should mount from an implicit TCC-root seed")

        coord.core.flushPersistenceSync()
        store.flushSync()
        XCTAssertNil(store.loadIndex(),
            "nothing should be persisted for a refused implicit seed")
    }

    /// Control: a non-protected temp folder still opens + persists, so the
    /// explicit path isn't special-casing TCC roots in either direction.
    func test_openFolder_underTempRoot_stillOpensAndPersists() {
        let (coord, store) = makeCoordinator()
        let folder = tmpRoot.appendingPathComponent("ProjectA", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true)

        coord.openFolder(folder)

        XCTAssertEqual(coord.core.sessions.count, 1,
            "a non-TCC folder should create exactly one session")
        coord.core.flushPersistenceSync()
        store.flushSync()
        XCTAssertNotNil(store.loadIndex(),
            "a non-TCC session should be persisted")
    }
}
