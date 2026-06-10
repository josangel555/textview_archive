import XCTest
import ViewerCore
@testable import ViewerUI

/// TSK-313 — double-clicking the empty session-tab-strip area opens a
/// new session rooted at ~. The strip gesture and the `session-open-home`
/// script verb both call exactly `SessionsAppCoordinator.openHomeSession()`
/// (exact-closure rule), so pinning that action pins the feature's
/// behavior; the gesture's hit-area is the VM lane.
@MainActor
final class SessionOpenHomeTests: XCTestCase {

    private var tmp: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionOpenHome-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
        try await super.tearDown()
    }

    private func makeCoordinator() -> SessionsAppCoordinator {
        let storeDir = tmp.appendingPathComponent("store-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        let coord = SessionsAppCoordinator(
            model: DocumentModel(),
            store: SessionStore(directory: storeDir),
            initialRoot: nil,
            autosaveDebounce: 0)
        coord.bootstrap()
        return coord
    }

    private var homePath: String {
        FileManager.default.homeDirectoryForCurrentUser.path
    }

    func test_opensNewSessionRootedAtHome_andActivatesIt() throws {
        let coord = makeCoordinator()
        let existing = tmp.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        coord.openFolder(existing)
        let before = coord.core.sessions.count

        coord.openHomeSession()

        XCTAssertEqual(coord.core.sessions.count, before + 1,
                       "a NEW session, not a re-root of the current one")
        let active = coord.core.sessions.first { $0.id == coord.core.activeID }
        XCTAssertEqual(active?.sidebarRootPath.map { URL(fileURLWithPath: $0).standardizedFileURL.path },
                       URL(fileURLWithPath: homePath).standardizedFileURL.path,
                       "the new session is rooted at ~ and active")
        // The prior session is untouched.
        XCTAssertTrue(coord.core.sessions.contains {
            $0.sidebarRootPath.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
                == existing.standardizedFileURL.path
        })
    }

    func test_forceNew_evenWhenHomeSessionAlreadyExists() {
        let coord = makeCoordinator()
        coord.openHomeSession()
        let after1 = coord.core.sessions.count

        coord.openHomeSession()

        XCTAssertEqual(coord.core.sessions.count, after1 + 1,
                       "double-click always spawns a fresh tab (browser idiom), never refocuses")
    }

    func test_doesNotArmGoToPrompt() {
        let coord = makeCoordinator()
        coord.openHomeSession()
        XCTAssertFalse(coord.consumeFirstPaintGoTo(),
                       "unlike the + button, the strip double-click opens ~ DIRECTLY — no prompt")
    }
}
