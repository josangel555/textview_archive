import XCTest
@testable import ViewerUI
import ViewerCore

/// Named session save points, coordinator + UI wiring (2026-07-31, owner
/// ask "Save and retrieve session"). The contract:
///   - SAVE freezes what's ON SCREEN (live state flushed first), under a
///     fresh identity, without disturbing the live session;
///   - RESTORE materializes a NEW session from the point (the point
///     survives — restore again anytime) and switches to it;
///   - the menus actually mount both verbs (dead-channel pin).
@MainActor
final class SavedSessionsTests: XCTestCase {

    private var tmpRoot: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-saved-sessions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmpRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpRoot)
        try await super.tearDown()
    }

    private func makeFixture() throws
        -> (coord: SessionsAppCoordinator, file: URL, sessionA: UUID) {
        let rootA = tmpRoot.appendingPathComponent("rootA")
        try FileManager.default.createDirectory(at: rootA, withIntermediateDirectories: true)
        let file = rootA.appendingPathComponent("note.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)
        let sessionsDir = tmpRoot.appendingPathComponent("Sessions")
        try FileManager.default.createDirectory(
            at: sessionsDir, withIntermediateDirectories: true)
        let coord = SessionsAppCoordinator(
            model: DocumentModel(), store: SessionStore(directory: sessionsDir),
            initialRoot: rootA)
        coord.bootstrap()
        let sessionA = try XCTUnwrap(coord.core.activeID)
        coord.model.openPath(file)
        return (coord, file, sessionA)
    }

    // MARK: reopen closed sessions (trash recovery, owner ask 2026-08-26)

    /// Close → the session sits in the 30-day trash with its final state →
    /// "Recently Closed" reopens it under its OWN identity, consuming the
    /// trash entry, and switches to it.
    func test_closeThenReopen_restoresTheSessionWithItsTabs() throws {
        let (coord, file, sessionA) = try makeFixture()
        // A second session so closing A doesn't leave an empty coordinator.
        let rootB = tmpRoot.appendingPathComponent("rootB")
        try FileManager.default.createDirectory(at: rootB, withIntermediateDirectories: true)
        coord.openFolder(rootB, forceNew: true)

        coord.close(id: sessionA)
        XCTAssertFalse(coord.core.sessions.contains { $0.id == sessionA },
            "closed session leaves the live list")

        let closed = coord.trashedSessions()
        XCTAssertTrue(closed.contains { $0.id == sessionA },
            "the closed session must be recoverable from the trash listing")
        let entry = try XCTUnwrap(closed.first { $0.id == sessionA })
        XCTAssertTrue(entry.openTabs.contains { $0.path == file.path },
            "the trashed snapshot carries the session's final tab set")

        let reopened = try XCTUnwrap(coord.reopenClosedSession(id: sessionA))
        XCTAssertEqual(reopened.id, sessionA,
            "reopen resumes the SAME session, not a copy")
        XCTAssertEqual(coord.core.activeID, sessionA, "reopen activates it")
        XCTAssertTrue(coord.model.tabs.tabs.contains { $0.url == file },
            "the reopened session mounts with its tabs")
        XCTAssertFalse(coord.trashedSessions().contains { $0.id == sessionA },
            "a reopened session no longer lingers in the trash listing")
    }

    func test_reopenUnknownTrashedID_isANoOp() throws {
        let (coord, _, sessionA) = try makeFixture()
        XCTAssertNil(coord.reopenClosedSession(id: UUID()))
        XCTAssertEqual(coord.core.activeID, sessionA, "active session untouched")
    }

    func test_saveActiveSession_freezesTheLiveTabs() throws {
        let (coord, file, sessionA) = try makeFixture()

        let point = try XCTUnwrap(coord.saveSession(id: sessionA, named: "checkpoint"))

        XCTAssertEqual(point.displayName, "checkpoint")
        XCTAssertNotEqual(point.id, sessionA,
            "a save point has its OWN identity — it is a copy, not an alias")
        XCTAssertTrue(point.openTabs.contains { $0.path == file.path },
            "the point must carry the LIVE tab set (flushed, not last autosave)")
        // The live session is untouched.
        XCTAssertEqual(coord.core.activeID, sessionA)
        XCTAssertTrue(coord.model.tabs.tabs.contains { $0.url == file })
    }

    func test_restore_materializesANewSession_andSwitchesToIt() throws {
        let (coord, file, sessionA) = try makeFixture()
        let point = try XCTUnwrap(coord.saveSession(id: sessionA, named: "cp"))

        let restored = try XCTUnwrap(coord.restoreSavedSession(id: point.id))

        XCTAssertNotEqual(restored.id, point.id,
            "restore must mint a fresh session id — the point stays retrievable")
        XCTAssertEqual(coord.core.activeID, restored.id, "restore switches to the copy")
        XCTAssertTrue(coord.model.tabs.tabs.contains { $0.url == file },
            "the restored session opens the point's tabs")
        XCTAssertEqual(coord.savedSessions().map(\.id), [point.id],
            "the save point survives its restore")
    }

    func test_restoreTwice_yieldsTwoIndependentSessions() throws {
        let (coord, _, sessionA) = try makeFixture()
        let point = try XCTUnwrap(coord.saveSession(id: sessionA, named: "cp"))

        let first = try XCTUnwrap(coord.restoreSavedSession(id: point.id))
        let second = try XCTUnwrap(coord.restoreSavedSession(id: point.id))

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(coord.core.sessions.count, 3, "original + two restores")
    }

    func test_deleteSavedSession_removesThePoint() throws {
        let (coord, _, sessionA) = try makeFixture()
        let point = try XCTUnwrap(coord.saveSession(id: sessionA, named: "cp"))
        coord.deleteSavedSession(id: point.id)
        XCTAssertTrue(coord.savedSessions().isEmpty)
        XCTAssertNil(coord.restoreSavedSession(id: point.id),
                     "restoring a deleted point is a clean no-op")
    }

    func test_emptyOrBlankName_isRefused() throws {
        let (coord, _, sessionA) = try makeFixture()
        XCTAssertNil(coord.saveSession(id: sessionA, named: "   "))
        XCTAssertTrue(coord.savedSessions().isEmpty, "no file for a refused save")
    }

    func test_promptDefaultName_carriesSessionAndDate() {
        let jul31 = Date(timeIntervalSince1970: 1_785_400_000) // 2026-07-30-ish
        let name = SaveSessionPrompt.defaultName(for: "markdown_viewer", now: jul31)
        XCTAssertTrue(name.hasPrefix("markdown_viewer \u{2014} "),
                      "default carries the session name: \(name)")
        XCTAssertGreaterThan(name.count, "markdown_viewer \u{2014} ".count,
                             "and a date suffix: \(name)")
    }

    /// Dead-channel pin (the TSK-561 idiom): the model layer above is
    /// inert unless the menus actually mount it.
    func test_menus_mountSaveAndRestore() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let bar = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/ViewerUI/Sessions/SessionTabBar.swift"),
            encoding: .utf8)
        XCTAssertTrue(bar.contains("Save Session As"),
                      "the context menu must offer the save verb")
        XCTAssertTrue(bar.contains("saveSession(id: snapshot.id, named: name)"),
                      "…and route it through the coordinator")
        XCTAssertEqual(
            bar.components(separatedBy: "SavedSessionsMenuSection(sessionsApp:").count - 1, 2,
            "retrieval mounts in BOTH the context menu and the + menu")
        XCTAssertTrue(bar.contains("restoreSavedSession(id: point.id)"),
                      "the section must route restore through the coordinator")
    }

    /// Same dead-channel pin for the trash-recovery surface (2026-08-26).
    func test_menus_mountReopenClosed() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let bar = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/ViewerUI/Sessions/SessionTabBar.swift"),
            encoding: .utf8)
        XCTAssertEqual(
            bar.components(separatedBy: "RecentlyClosedSessionsMenuSection(sessionsApp:").count - 1, 2,
            "trash recovery mounts in BOTH the context menu and the + menu")
        XCTAssertTrue(bar.contains("reopenClosedSession(id: snap.id)"),
                      "the section must route reopen through the coordinator")
    }
}
