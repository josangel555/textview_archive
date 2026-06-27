import XCTest
import ViewerKit
@testable import ViewerCore

/// Regression coverage for the audit finding at
/// `Sources/ViewerCore/Automation/MCPServer.swift:346`:
///
/// A failed stdout write (e.g. EPIPE after the client closes the read end
/// of our stdout while keeping our stdin open) used to be logged and
/// swallowed. The read loop only winds down on stdin EOF or a framing
/// error, so the server kept reading/dispatching requests it could never
/// answer — the orphaned-headless-server hang the `onExit` wiring exists
/// to prevent, but outside its trigger conditions.
///
/// The fix: a write error in `send()` is treated as a dead transport —
/// `stop()` is called, which closes stdin → EOF → `fireExit()`.
@MainActor
private final class StubHost: AutomationHost {
    var stateResult = AutomationState(
        tabs: [], selectedTabIndex: nil, viewMode: "rendered",
        zoom: 1.0, sidebarRoot: nil, isPalettePresented: false
    )
    func automationOpenPath(_ url: URL, newTab: Bool) -> UUID { UUID() }
    func automationSelectTab(byIndex index: Int?, byId id: UUID?) -> Bool { true }
    func automationSetViewMode(_ mode: ViewMode) {}
    func automationSetZoom(_ zoom: Double) {}
    func automationGotoLine(_ line: Int, column: Int?) {}
    func automationFind(_ query: FindQuery) -> [FindMatch] { [] }
    func automationVisibleText() -> String { "" }
    func automationCurrentState() -> AutomationState { stateResult }
    func automationToggleBookmark(line: Int?) {}
    func automationListBookmarks() -> [BookmarkEntry] { [] }
    func automationSnapshotPNG() throws -> Data { Data() }
    func automationRunVerb(_ verbLine: String) -> Bool { false }
}

@MainActor
final class Audit_Sources_ViewerCore_Automation_MCPServer_swift_DeadTransportTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // A broken-pipe write would deliver SIGPIPE, whose default
        // disposition kills the test process. Production wires this off
        // via `NSApplication.run`; the bare XCTest host does not, so we
        // ignore it here and rely on `write(2)` returning EPIPE instead.
        signal(SIGPIPE, SIG_IGN)
    }

    /// Half-close the transport: the client closes the read end of the
    /// server's stdout but leaves the server's stdin open. The very next
    /// response write fails (EPIPE). The server must observe the write
    /// failure as a dead transport and fire `onExit` exactly once, rather
    /// than spinning on a stdin that will never close.
    func test_writeFailure_firesOnExit() throws {
        let inPipe = Pipe()
        let outPipe = Pipe()
        let host = StubHost()

        let exitExpectation = XCTestExpectation(description: "onExit fires after dead-transport write")
        let exitCount = ExitCounter()
        let server = MCPServer(
            host: host,
            input: inPipe.fileHandleForReading,
            output: outPipe.fileHandleForWriting,
            logger: nil,
            onExit: {
                exitCount.increment()
                exitExpectation.fulfill()
            }
        )
        server.start()
        defer { server.stop() }

        // Close the read end of the server's stdout BEFORE it answers.
        // The server's first response write will hit EPIPE.
        try outPipe.fileHandleForReading.close()

        // Deliver one well-formed request. The server dispatches it,
        // produces a response, and fails to write it.
        let req = Data(#"""
        {"jsonrpc":"2.0","id":1,"method":"ping","params":{}}
        """#.utf8)
        let framed = MCPFraming.encode(body: req)
        try inPipe.fileHandleForWriting.write(contentsOf: framed)

        // `onExit` must fire — without the fix the loop keeps reading on
        // the still-open stdin and never terminates, so this times out.
        wait(for: [exitExpectation], timeout: 5.0)
        XCTAssertEqual(exitCount.value, 1, "onExit must fire exactly once")
    }

    /// Thread-safe counter so the read-loop thread's `onExit` callback can
    /// be asserted on from the main thread. The expectation fence orders
    /// the read; the lock guards against the (unexpected) double-fire.
    private final class ExitCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
        func increment() { lock.lock(); _value += 1; lock.unlock() }
    }
}
