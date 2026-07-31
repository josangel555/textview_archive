import XCTest
@testable import ViewerUI
import ViewerCore

/// TSK-315 — tab context menu "Open in New Session" / "Move to New
/// Session". Pins the model/session outcomes headlessly (the menu wires
/// straight to `SessionsAppCoordinator.openFileInNewSession`):
///   - a NEW session is created, rooted at the file's parent folder,
///     with the file open in it;
///   - "open" leaves the source session's tab set untouched;
///   - "move" removes the tab from the source session — verified by
///     switching BACK (detach-persist → rehydrate round-trip).
@MainActor
final class TabToNewSessionTests: XCTestCase {

    private var tmpRoot: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-tab-newsession-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmpRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpRoot)
        try await super.tearDown()
    }

    private func makeCoordinator(initialRoot: URL)
        -> SessionsAppCoordinator {
        let sessionsDir = tmpRoot
            .appendingPathComponent("stores-\(UUID().uuidString)/Sessions")
        try? FileManager.default.createDirectory(
            at: sessionsDir, withIntermediateDirectories: true)
        let coord = SessionsAppCoordinator(
            model: DocumentModel(), store: SessionStore(directory: sessionsDir),
            initialRoot: initialRoot)
        coord.bootstrap()
        return coord
    }

    /// Shared fixture: session A rooted at `rootA` with `file` (living in
    /// a SEPARATE folder B) open as a tab.
    private func makeFixture() throws
        -> (coord: SessionsAppCoordinator, file: URL, folderB: URL, sessionA: UUID) {
        let rootA = tmpRoot.appendingPathComponent("rootA")
        let folderB = tmpRoot.appendingPathComponent("folderB")
        try FileManager.default.createDirectory(at: rootA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folderB, withIntermediateDirectories: true)
        let file = folderB.appendingPathComponent("note.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)

        let coord = makeCoordinator(initialRoot: rootA)
        let sessionA = try XCTUnwrap(coord.core.activeID, "bootstrap must seed a session")
        coord.model.openPath(file)
        XCTAssertTrue(coord.model.tabs.tabs.contains { $0.url == file },
            "fixture: the file must be open in session A")
        return (coord, file, folderB, sessionA)
    }

    func test_openInNewSession_createsSessionAtParent_andOpensFile() throws {
        let (coord, file, folderB, sessionA) = try makeFixture()

        coord.openFileInNewSession(file)

        XCTAssertEqual(coord.core.sessions.count, 2, "a NEW session must be created")
        let active = try XCTUnwrap(coord.core.sessions.first {
            $0.id == coord.core.activeID
        })
        XCTAssertNotEqual(active.id, sessionA, "the new session must be active")
        XCTAssertEqual(
            active.sidebarRootPath,
            folderB.standardizedFileURL.resolvingSymlinksInPath().path,
            "the new session must be rooted at the file's parent folder")
        XCTAssertTrue(coord.model.tabs.tabs.contains { $0.url == file },
            "the file must be open in the new session")

        // "Open" is copy-like: switching back, session A still has the tab.
        coord.activate(id: sessionA)
        XCTAssertTrue(coord.model.tabs.tabs.contains { $0.url == file },
            "OPEN must leave the source session's tab in place")
    }

    /// TSK-274 — drag a tab onto an EXISTING session pill. Same fixture;
    /// the drop delegate calls exactly this coordinator method.
    func test_moveTab_toExistingSession_movesFileAndActivatesTarget() throws {
        let (coord, file, _, sessionA) = try makeFixture()
        // A second, pre-existing session to drop onto.
        let rootC = tmpRoot.appendingPathComponent("rootC")
        try FileManager.default.createDirectory(at: rootC, withIntermediateDirectories: true)
        let sessionC = coord.core.openFolder(rootC, forceNew: true).id
        coord.activate(id: sessionA)
        let tabID = try XCTUnwrap(
            coord.model.tabs.tabs.first { $0.url == file }?.id)

        coord.moveTab(withID: tabID, toSessionID: sessionC)

        XCTAssertEqual(coord.core.activeID, sessionC, "target session must activate")
        XCTAssertTrue(coord.model.tabs.tabs.contains { $0.url == file },
            "the file must be open in the target session")
        // Owner's contract for the drag-onto-pill flow (2026-07-31): after
        // the move you are IN the target session ON the moved tab — not
        // watching it land somewhere in the background.
        XCTAssertEqual(coord.model.tabs.selected?.url, file,
            "the moved tab must be the SELECTED tab in the target session")
        coord.activate(id: sessionA)
        XCTAssertFalse(coord.model.tabs.tabs.contains { $0.url == file },
            "the source session must lose the moved tab")
    }

    /// Same-session drops and stale ids are clean no-ops — the tab stays.
    func test_moveTab_sameSessionOrUnknownTarget_isNoOp() throws {
        let (coord, file, _, sessionA) = try makeFixture()
        let tabID = try XCTUnwrap(
            coord.model.tabs.tabs.first { $0.url == file }?.id)
        let tabCount = coord.model.tabs.tabs.count

        coord.moveTab(withID: tabID, toSessionID: sessionA)       // same session
        coord.moveTab(withID: tabID, toSessionID: UUID())         // unknown session
        coord.moveTab(withID: UUID(), toSessionID: sessionA)      // stale tab id

        XCTAssertEqual(coord.core.activeID, sessionA, "no-ops must not switch sessions")
        XCTAssertEqual(coord.model.tabs.tabs.count, tabCount,
            "no-ops must not close or open tabs")
        XCTAssertTrue(coord.model.tabs.tabs.contains { $0.url == file })
    }

    func test_moveToNewSession_removesTabFromSourceSession() throws {
        let (coord, file, _, sessionA) = try makeFixture()

        coord.openFileInNewSession(file, removingFromCurrent: true)

        XCTAssertEqual(coord.core.sessions.count, 2)
        XCTAssertTrue(coord.model.tabs.tabs.contains { $0.url == file },
            "the file must be open in the new session")

        // The detach-persist → rehydrate round-trip is the contract: the
        // source session must come back WITHOUT the moved tab.
        coord.activate(id: sessionA)
        XCTAssertFalse(coord.model.tabs.tabs.contains { $0.url == file },
            "MOVE must remove the tab from the source session")
    }
}
