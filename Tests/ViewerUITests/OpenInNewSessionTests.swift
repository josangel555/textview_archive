import XCTest
@testable import ViewerUI

/// Coverage for the `openFolderInNewSession` integration. The earlier
/// shape of this file asserted four Swift-closure tautologies
/// ("a `var closure: ((URL) -> Void)?` defaults to nil; assigning it
/// then calling it calls it") — every assertion would pass on any
/// stored optional closure of any type, anywhere. Zero signal.
///
/// The replacement tests pin the real wiring: `commitGoToPath(...,
/// newSession: true)` is the headless entry point both the Go-To-Path
/// prompt and the right-click menu route through. It must:
///   - call `openFolderInNewSession` for an existing directory when
///     the callback is set,
///   - fall back to `openPath` when the callback is nil OR when the
///     resolved URL is a file (not a directory),
///   - never call `openFolderInNewSession` for a non-existent path.
///
/// The rendering of the menu item itself — that the SwiftUI `if let
/// openInNewSession = model.openFolderInNewSession` reveals/hides the
/// button — is still a VM live-app concern; we don't fake it here.
@MainActor
final class OpenInNewSessionTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenInNewSession-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func test_commitGoToPath_newSession_directory_routesToOpenFolderInNewSession() {
        let sub = tmpDir.appendingPathComponent("sub")
        try? FileManager.default.createDirectory(
            at: sub, withIntermediateDirectories: true)
        let model = DocumentModel()
        var newSessionCalls: [URL] = []
        model.openFolderInNewSession = { newSessionCalls.append($0) }

        model.commitGoToPath(sub.path, newSession: true)

        XCTAssertEqual(newSessionCalls.count, 1,
            "newSession=true on a directory must invoke openFolderInNewSession exactly once")
        XCTAssertEqual(newSessionCalls.first?.path, sub.path)
        // It also clears any prior go-to error + dismisses the prompt.
        XCTAssertEqual(model.lastGoToError, "")
        XCTAssertFalse(model.isGoToPathPresented)
    }

    func test_commitGoToPath_newSession_file_fallsBackToOpenPath() throws {
        // A *file* path with newSession=true must NOT call the
        // openFolderInNewSession callback — sessions are folder-scoped.
        let file = tmpDir.appendingPathComponent("doc.md")
        try "# hi\n".write(to: file, atomically: true, encoding: .utf8)
        let model = DocumentModel()
        var newSessionCalls: [URL] = []
        model.openFolderInNewSession = { newSessionCalls.append($0) }

        model.commitGoToPath(file.path, newSession: true)

        XCTAssertTrue(newSessionCalls.isEmpty,
            "files must never route through openFolderInNewSession")
        // openPath should have produced a tab.
        XCTAssertEqual(model.tabs.tabs.count, 1,
            "openPath should have created a tab for the file")
    }

    func test_commitGoToPath_newSession_callbackNil_fallsBackToOpenPath() throws {
        // If the UI host hasn't installed the callback (e.g. a test
        // process running without a Sessions coordinator), the
        // newSession=true request must degrade to a regular openPath.
        let sub = tmpDir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(
            at: sub, withIntermediateDirectories: true)
        let model = DocumentModel()
        XCTAssertNil(model.openFolderInNewSession,
            "default must be nil so the SwiftUI `if let` hides the menu item")

        model.commitGoToPath(sub.path, newSession: true)

        // openPath on a directory sets the sidebar root (rather than
        // opening a tab).
        XCTAssertNotNil(model.sidebar.rootURL,
            "callback-nil + directory should still route through openPath → setRoot")
        XCTAssertEqual(model.sidebar.rootURL?.path, sub.path)
    }

    // MARK: - New-session intent (TSK-600)

    /// The `+`-button entry point shows the prompt with
    /// `newSessionIntent: true`. Confirming a folder via the DEFAULT
    /// Open path (newSession: false — plain Return) must then still
    /// spawn a new session instead of re-rooting the current one.
    func test_commitGoToPath_underNewSessionIntent_defaultOpen_routesToNewSession() throws {
        let sub = tmpDir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(
            at: sub, withIntermediateDirectories: true)
        let model = DocumentModel()
        var newSessionCalls: [URL] = []
        model.openFolderInNewSession = { newSessionCalls.append($0) }

        model.showGoToPath(newSessionIntent: true)
        model.commitGoToPath(sub.path, newSession: false)

        XCTAssertEqual(newSessionCalls.count, 1,
            "default Open under new-session intent must spawn a session (TSK-600)")
        XCTAssertNil(model.sidebar.rootURL,
            "the current session must NOT be re-rooted (the reported 'flash')")
        XCTAssertFalse(model.goToPathNewSessionIntent,
            "the intent is one-shot — cleared on dismiss")
    }

    /// The plain ⇧⌘G invocation keeps today's behavior: default Open on
    /// a folder mutates the ACTIVE session, no new-session call.
    func test_commitGoToPath_withoutIntent_defaultOpen_staysInCurrentSession() throws {
        let sub = tmpDir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(
            at: sub, withIntermediateDirectories: true)
        let model = DocumentModel()
        var newSessionCalls: [URL] = []
        model.openFolderInNewSession = { newSessionCalls.append($0) }

        model.showGoToPath()
        model.commitGoToPath(sub.path, newSession: false)

        XCTAssertTrue(newSessionCalls.isEmpty,
            "plain Go-to-path must not hijack the open into a new session")
        XCTAssertEqual(model.sidebar.rootURL?.path, sub.path,
            "default Open on a folder re-roots the active session")
    }

    /// Cancelling the prompt consumes the intent: a later plain
    /// invocation must not inherit it.
    func test_dismissGoToPath_clearsNewSessionIntent() throws {
        let sub = tmpDir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(
            at: sub, withIntermediateDirectories: true)
        let model = DocumentModel()
        var newSessionCalls: [URL] = []
        model.openFolderInNewSession = { newSessionCalls.append($0) }

        model.showGoToPath(newSessionIntent: true)
        model.dismissGoToPath()   // user hits Escape
        model.showGoToPath()      // later: plain ⇧⌘G
        model.commitGoToPath(sub.path, newSession: false)

        XCTAssertTrue(newSessionCalls.isEmpty,
            "a cancelled + intent must not leak into the next plain invocation")
    }

    func test_commitGoToPath_newSession_missingPath_setsErrorAndDoesNotInvoke() {
        let missing = tmpDir.appendingPathComponent("does-not-exist")
        let model = DocumentModel()
        var newSessionCalls: [URL] = []
        model.openFolderInNewSession = { newSessionCalls.append($0) }

        model.commitGoToPath(missing.path, newSession: true)

        XCTAssertTrue(newSessionCalls.isEmpty,
            "a path that doesn't resolve must not reach the callback")
        XCTAssertFalse(model.lastGoToError.isEmpty,
            "the user-facing error must be surfaced")
    }
}
