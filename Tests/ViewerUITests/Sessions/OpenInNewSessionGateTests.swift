import XCTest
@testable import ViewerCore
@testable import ViewerUI

/// Coordinator-level regression for bug2: "Open in New Session" popped the
/// Go-to-path dialog on top of the just-opened session.
///
/// `SessionsAppCoordinator.openFolder(forceNew:)` used to arm the first-paint
/// GoTo gate and bump `firstPaintGoToToken` on `forceNew == true`. But every
/// real `forceNew: true` caller already supplies a concrete folder URL — only
/// the dedicated `requestNewSessionViaGoTo()` (the SessionTabBar `+` button)
/// wants the prompt, and it does not route through `openFolder`. The stray arm
/// produced a spurious prompt.
///
/// These tests construct the coordinator + a temp-dir `SessionStore` directly —
/// no NSApplication / window, so they are host-safe (run with a class filter,
/// not the unfiltered live-app sweep). The pre-existing `OpenInNewSessionTests`
/// stubbed the `openFolderInNewSession` closure and never ran the real
/// coordinator, which is exactly why this gate regression slipped through.
@MainActor
final class OpenInNewSessionGateTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenInNewSessionGate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func makeCoordinator() -> SessionsAppCoordinator {
        let storeDir = tmp.appendingPathComponent("store", isDirectory: true)
        try? FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        let coord = SessionsAppCoordinator(model: DocumentModel(),
                                           store: SessionStore(directory: storeDir),
                                           initialRoot: nil)
        coord.bootstrap()
        return coord
    }

    private func makeFolder(_ name: String) throws -> URL {
        let dir = tmp.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // The bug: opening a known folder in a new session must NOT arm the GoTo
    // prompt — the folder is already in hand.
    func test_openFolderForceNew_doesNotBumpGoToToken() throws {
        let coord = makeCoordinator()
        XCTAssertNil(coord.firstPaintGoToToken, "no gate armed at boot")

        let folder = try makeFolder("Project")
        coord.openFolder(folder, forceNew: true)

        XCTAssertNil(coord.firstPaintGoToToken,
            "openFolder(forceNew:) must NOT arm the first-paint GoTo prompt (bug2)")
        // The session was actually created and rooted at the folder.
        XCTAssertEqual(coord.active?.rootURL.standardizedFileURL.resolvingSymlinksInPath(),
                       folder.standardizedFileURL.resolvingSymlinksInPath(),
                       "the right-clicked folder must become the new session's root")
    }

    // The intended prompt path is untouched: the `+`-button entry point still
    // arms the gate.
    func test_requestNewSessionViaGoTo_bumpsGoToToken() throws {
        let coord = makeCoordinator()
        XCTAssertNil(coord.firstPaintGoToToken)

        coord.requestNewSessionViaGoTo()

        XCTAssertNotNil(coord.firstPaintGoToToken,
            "the dedicated empty-session entry point must still arm the GoTo prompt")
        XCTAssertTrue(coord.consumeFirstPaintGoTo(),
            "the armed gate must be takeable exactly once")
        XCTAssertFalse(coord.consumeFirstPaintGoTo(),
            "a consumed gate must not re-fire")
    }

    // Opening a plain (non-forceNew) folder must also never prompt.
    func test_openFolder_noForceNew_doesNotBumpGoToToken() throws {
        let coord = makeCoordinator()
        let folder = try makeFolder("Plain")
        coord.openFolder(folder, forceNew: false)
        XCTAssertNil(coord.firstPaintGoToToken)
    }
}
