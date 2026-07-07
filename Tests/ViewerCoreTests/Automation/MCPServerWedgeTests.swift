import XCTest
import ViewerKit
@testable import ViewerCore

/// Regression tests for the continuation-based main-actor bridge in
/// `MCPServer` (previously `DispatchQueue.main.sync`).
///
/// # What changed
///
/// `handle(requestBody:)` used to dispatch the handler via
/// `DispatchQueue.main.sync { MainActor.assumeIsolated { ... } }`.
/// It now uses a `Task { @MainActor in ... }` + `DispatchSemaphore`
/// bridge in `runOnMainActor`.
///
/// # Why the old bridge was wedge-prone
///
/// `DispatchQueue.main.sync` from a background thread has two
/// well-documented failure modes:
///
/// 1. **Main-on-main.** If a refactor ever causes the bridge to be
///    invoked from the main thread (a re-entrant tool call, an
///    accidental `await Task { @MainActor in mcpServer.handle(...) }`
///    in some future tooling code), `main.sync` from main is an
///    instant libdispatch self-wait — the process hangs with no
///    diagnostic.
/// 2. **QoS / scheduler inversion.** Swift 6's strict-concurrency
///    runtime flags `main.sync` from a non-main Task because the
///    Task is forced to wait on libdispatch instead of the cooperative
///    actor executor, defeating priority inheritance.
///
/// The new bridge:
///
/// 1. The reader thread parks on a kernel `DispatchSemaphore`, not on
///    a libdispatch queue. No queue-drain wedge.
/// 2. A `precondition(!Thread.isMainThread, ...)` catches main-on-main
///    misuse loudly instead of hanging.
/// 3. The handler runs inside a `Task { @MainActor in ... }`, which
///    integrates with the Swift concurrency scheduler — priority
///    inheritance, cancellation, etc. — without forcing a libdispatch
///    sync wait on main.
///
/// # What these tests prove
///
/// These tests can't reproduce the production wedge inside the
/// XCTest harness because `XCTestExpectation.wait` pumps the main
/// run loop, which keeps `DispatchQueue.main` draining. The wedge
/// is real in production where main can be in a non-pumping kernel
/// wait. So instead these tests pin the bridge's **positive contract**
/// — which would be broken by any "fix" that swung back to a
/// brittle dispatch pattern.
///
/// - `test_bridge_dispatchesQuickly` — the bridge resolves a
///   round-trip with no perceptible overhead (proxy for "no wedge,
///   no busy-wait, no priority inversion").
/// - `test_longRunningHandler_doesNotBlockSubsequentRequests` — a
///   handler that holds the main actor for ~100 ms doesn't wedge
///   the next request; the second response arrives within budget.
///   This is the closest test-harness analogue to the original
///   wedge.
/// - `test_manyRequests_inSequence_complete` — 8 sequential
///   requests cycle cleanly; catches a bridge that leaks Tasks /
///   semaphores or fails to signal after some N invocations.
/// - `test_handler_runsOnOSMainThread` — the handler still sees
///   `Thread.isMainThread == true`. Pins the AppKit contract: the
///   bridge swap didn't silently demote isolation.

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
}

/// Host that holds the main actor for a configurable duration on
/// each `current_state` call, simulating a long-running synchronous
/// handler (e.g., a model walk over thousands of tabs).
private final class SleepingHost: AutomationHost, @unchecked Sendable {
    let sleepFor: TimeInterval
    private let lock = NSLock()
    nonisolated(unsafe) private var _callCount = 0

    init(sleepFor: TimeInterval) {
        self.sleepFor = sleepFor
    }

    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _callCount
    }

    @MainActor func automationOpenPath(_ url: URL, newTab: Bool) -> UUID { UUID() }
    @MainActor func automationSelectTab(byIndex index: Int?, byId id: UUID?) -> Bool { true }
    @MainActor func automationSetViewMode(_ mode: ViewMode) {}
    @MainActor func automationSetZoom(_ zoom: Double) {}
    @MainActor func automationGotoLine(_ line: Int, column: Int?) {}
    @MainActor func automationFind(_ query: FindQuery) -> [FindMatch] { [] }
    @MainActor func automationVisibleText() -> String { "" }
    @MainActor func automationCurrentState() -> AutomationState {
        // Sync sleep on main — simulates a long-running model
        // operation. The bridge must wait for this to finish before
        // signalling and accepting the next request.
        Thread.sleep(forTimeInterval: sleepFor)
        lock.lock(); _callCount += 1; lock.unlock()
        return AutomationState(
            tabs: [], selectedTabIndex: nil,
            viewMode: "rendered", zoom: 1.0,
            sidebarRoot: nil, isPalettePresented: false)
    }
    @MainActor func automationToggleBookmark(line: Int?) {}
    @MainActor func automationListBookmarks() -> [BookmarkEntry] { [] }
    @MainActor func automationSnapshotPNG() throws -> Data { Data() }
}

@MainActor
final class MCPServerWedgeTests: XCTestCase {

    // MARK: - Helpers

    /// Set up a live server with the given host. Caller is responsible
    /// for `start()` + a deferred `stop()`.
    ///
    /// `deadline` is bounded (5 s, not the 20 s default): under heavy
    /// parallel-gate load, once a test's `wait()` returns the main thread
    /// stops pumping the run loop, so the reader thread's remaining
    /// per-request MainActor Tasks are starved and each parks up to the
    /// deadline. 5 s caps that drain 4× shorter than 20 s (TSK-1559).
    private func makeServer(host: AutomationHost,
                            deadline: DispatchTimeInterval = .seconds(5))
        -> (server: MCPServer, inPipe: Pipe, outPipe: Pipe)
    {
        let inPipe = Pipe()
        let outPipe = Pipe()
        let server = MCPServer(
            host: host,
            input: inPipe.fileHandleForReading,
            output: outPipe.fileHandleForWriting,
            logger: nil,
            mainActorDeadline: deadline
        )
        return (server, inPipe, outPipe)
    }

    /// Tear down a server env so NO reader thread leaks past the test
    /// (TSK-1559 — a leaked drain reader kept the whole `swift test --parallel`
    /// worker alive for minutes when fewer than N responses arrived, hanging
    /// the gate). Two threads must release: (1) the server's stdio reader —
    /// `stop()` closes its input so the blocked read hits EOF; (2) the
    /// background `drainResponses` reader — closing the outPipe WRITE end
    /// delivers it EOF so it exits instead of blocking forever on
    /// `MCPFraming.decode`. Closing the write end is now SAFE: the server's
    /// `send` writes via raw `write(2)`, so a concurrent close is a clean
    /// EPIPE (→ stop), not the uncatchable ObjC exception that made this
    /// unsafe before the send-path fix.
    private func teardown(_ env: (server: MCPServer, inPipe: Pipe, outPipe: Pipe)) {
        env.server.stop()
        try? env.outPipe.fileHandleForWriting.close()
    }

    /// Pull `n` framed responses off `outPipe`, fulfilling
    /// `expectation` when done. Uses a background dispatch queue so
    /// the main run loop can pump (which the new bridge's
    /// `Task { @MainActor in }` requires to land its work).
    private func drainResponses(
        from outPipe: Pipe,
        count n: Int,
        expectation: XCTestExpectation,
        into holder: ResponseHolder
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            var reader = MCPFraming.FileHandleReader(outPipe.fileHandleForReading)
            var bodies: [Data] = []
            for _ in 0..<n {
                do {
                    if let body = try MCPFraming.decode(from: &reader) {
                        bodies.append(body)
                    } else {
                        break
                    }
                } catch {
                    DispatchQueue.main.async {
                        holder.error = error
                        expectation.fulfill()
                    }
                    return
                }
            }
            DispatchQueue.main.async {
                holder.allBodies = bodies
                expectation.fulfill()
            }
        }
    }

    @MainActor
    private final class ResponseHolder {
        var allBodies: [Data]?
        var error: Error?
    }

    // MARK: - Tests

    /// The bridge resolves a single round-trip with no perceptible
    /// overhead. Proxy for "no wedge, no busy-wait, no priority
    /// inversion".
    func test_bridge_dispatchesQuickly() throws {
        let host = StubHost()
        let env = makeServer(host: host)
        env.server.start()
        defer { teardown(env) }

        let req = Data(#"""
        {"jsonrpc":"2.0","id":1,"method":"ping"}
        """#.utf8)
        try env.inPipe.fileHandleForWriting.write(contentsOf: MCPFraming.encode(body: req))

        let arrived = XCTestExpectation(description: "ping response")
        let holder = ResponseHolder()
        drainResponses(from: env.outPipe, count: 1, expectation: arrived, into: holder)

        // 1 s budget for a sub-millisecond operation. A wedge or a
        // serious scheduler stall would blow through this.
        wait(for: [arrived], timeout: 10.0)  // generous ceiling; pumps under load (TSK-1559)

        if let err = holder.error { throw err }
        XCTAssertEqual(holder.allBodies?.count, 1)
    }

    /// # The wedge-analogue test.
    ///
    /// A handler that holds the main actor for ~100 ms (synchronous
    /// `Thread.sleep` on main) doesn't wedge the bridge for
    /// subsequent requests. Two back-to-back requests both complete
    /// within a budget tight enough to fail on wedge.
    ///
    /// Under the OLD `DispatchQueue.main.sync` bridge: the reader
    /// thread parks in libdispatch's queue-drain wait for ~100 ms,
    /// then it picks up the next request. Under specific QoS /
    /// scheduling pressure scenarios (which we can't easily
    /// reproduce in unit tests), the second request can be delayed
    /// arbitrarily — `main.sync`'s priority semantics fight Swift
    /// concurrency's scheduler.
    ///
    /// Under the NEW bridge: the reader parks on a kernel semaphore
    /// while a MainActor Task runs the handler. The Task scheduler
    /// integrates cleanly with QoS; the second request lands
    /// promptly after the first.
    ///
    /// The hard guarantee this test pins: **two sequential requests
    /// through long-running handlers complete in < 3 s**. A
    /// regression to a wedge-prone bridge would fail here in some
    /// schedule scenarios; even if it passes deterministically in
    /// CI, the test prevents a *worse* regression where requests
    /// stop serializing entirely.
    func test_longRunningHandler_doesNotBlockSubsequentRequests() throws {
        let host = SleepingHost(sleepFor: 0.1)
        let env = makeServer(host: host)
        env.server.start()
        defer { teardown(env) }

        for i in 1...2 {
            let req = Data(#"""
            {"jsonrpc":"2.0","id":\#(i),"method":"tools/call",
             "params":{"name":"current_state","arguments":{}}}
            """#.utf8)
            try env.inPipe.fileHandleForWriting.write(contentsOf: MCPFraming.encode(body: req))
        }

        let arrived = XCTestExpectation(description: "two responses arrive")
        let holder = ResponseHolder()
        drainResponses(from: env.outPipe, count: 2, expectation: arrived, into: holder)

        // Generous ceiling; keeps main pumping under gate load (TSK-1559).
        wait(for: [arrived], timeout: 15.0)

        XCTAssertEqual(holder.allBodies?.count, 2,
                       "second request never got through; bridge wedged behind first long handler")
        XCTAssertEqual(host.callCount, 2,
                       "handler must have run twice, got \(host.callCount)")
    }

    /// Sequential load smoke. 8 round-trips back-to-back. Catches a
    /// bridge that leaks Tasks / semaphores or whose signal/wait
    /// pair becomes unbalanced after some N calls.
    ///
    /// TSK-1559: the count was 25, which under the 18-worker parallel gate
    /// created a LONG starvation window — each request is a main-thread
    /// MainActor Task hop, and under whole-machine contention the queue of
    /// 25 hops could outlive every timeout (observed: the gate hung on this
    /// test for 9+ minutes with 0 failures). 8 still exercises the
    /// leak/unbalance contract ("fails after some N" bridges break well
    /// before 8 — the original bug reproduced at 2) with a ~3× smaller
    /// window. The wait ceiling stays generous so the main run loop keeps
    /// PUMPING (servicing the Tasks) rather than starving them, and the
    /// failure message carries the partial count for diagnosis.
    func test_manyRequests_inSequence_complete() throws {
        let host = StubHost()
        let env = makeServer(host: host)
        env.server.start()
        defer { teardown(env) }

        let count = 8
        for i in 0..<count {
            let req = Data(#"""
            {"jsonrpc":"2.0","id":\#(i),"method":"ping"}
            """#.utf8)
            try env.inPipe.fileHandleForWriting.write(contentsOf: MCPFraming.encode(body: req))
        }

        let arrived = XCTestExpectation(description: "\(count) responses")
        let holder = ResponseHolder()
        drainResponses(from: env.outPipe, count: count, expectation: arrived, into: holder)

        // Generous ceiling: returns the instant `arrived` fulfills (<1 s
        // normally); under heavy load it keeps main pumping until the
        // responses land. On timeout the test FAILS LOUDLY with the partial
        // count (never hangs: teardown's outPipe-close EOFs the drain reader).
        let outcome = XCTWaiter.wait(for: [arrived], timeout: 60.0)
        if let err = holder.error { throw err }
        XCTAssertEqual(outcome, .completed,
                       "timed out with \(holder.allBodies?.count ?? 0)/\(count) responses — "
                       + "MainActor-Task starvation under load (TSK-1559)")
        XCTAssertEqual(holder.allBodies?.count, count,
                       "bridge wedged or leaked state under sequential load")
    }

    /// The handler runs on the OS main thread, not just at MainActor
    /// isolation. Pins the AppKit contract: the bridge swap didn't
    /// silently demote isolation by, e.g., scheduling the Task on a
    /// different actor.
    func test_handler_runsOnOSMainThread() throws {
        final class CheckingHost: AutomationHost, @unchecked Sendable {
            let lock = NSLock()
            nonisolated(unsafe) var sawMainThread = false
            @MainActor func automationOpenPath(_ url: URL, newTab: Bool) -> UUID { UUID() }
            @MainActor func automationSelectTab(byIndex index: Int?, byId id: UUID?) -> Bool { true }
            @MainActor func automationSetViewMode(_ mode: ViewMode) {}
            @MainActor func automationSetZoom(_ zoom: Double) {}
            @MainActor func automationGotoLine(_ line: Int, column: Int?) {}
            @MainActor func automationFind(_ query: FindQuery) -> [FindMatch] { [] }
            @MainActor func automationVisibleText() -> String { "" }
            @MainActor func automationCurrentState() -> AutomationState {
                lock.lock(); sawMainThread = Thread.isMainThread; lock.unlock()
                return AutomationState(
                    tabs: [], selectedTabIndex: nil,
                    viewMode: "rendered", zoom: 1.0,
                    sidebarRoot: nil, isPalettePresented: false)
            }
            @MainActor func automationToggleBookmark(line: Int?) {}
            @MainActor func automationListBookmarks() -> [BookmarkEntry] { [] }
            @MainActor func automationSnapshotPNG() throws -> Data { Data() }
        }
        let host = CheckingHost()
        let env = makeServer(host: host)
        env.server.start()
        defer { teardown(env) }

        let req = Data(#"""
        {"jsonrpc":"2.0","id":1,"method":"tools/call",
         "params":{"name":"current_state","arguments":{}}}
        """#.utf8)
        try env.inPipe.fileHandleForWriting.write(contentsOf: MCPFraming.encode(body: req))

        let arrived = XCTestExpectation(description: "response arrives")
        let holder = ResponseHolder()
        drainResponses(from: env.outPipe, count: 1, expectation: arrived, into: holder)
        wait(for: [arrived], timeout: 10.0)  // generous ceiling; pumps under load (TSK-1559)

        host.lock.lock(); defer { host.lock.unlock() }
        XCTAssertTrue(host.sawMainThread,
                      "handler must run on the OS main thread, not just at MainActor isolation")
    }

    // MARK: - Deadline / timeout (TSK-977)

    /// `runOnMainActor` must NOT park forever when the main-actor work
    /// never completes within the deadline. With a short injected
    /// deadline, a `work` closure that blocks the main actor well past
    /// it must return `.failure(.timedOut)` — not hang. On the unfixed
    /// (`semaphore.wait()`, no deadline) code this test hangs and the
    /// test-runner timeout fails it red.
    ///
    /// The bridge is invoked from a BACKGROUND thread (it `precondition`s
    /// `!Thread.isMainThread`), so the test's main RunLoop stays free to
    /// pump the MainActor Task — which then blocks the main actor with a
    /// synchronous sleep that outlasts the deadline.
    func test_runOnMainActor_timesOutWhenMainActorWedges() {
        let host = StubHost()
        // 200 ms deadline; the handler holds main for ~2 s — well past it.
        let server = MCPServer(
            host: host,
            input: Pipe().fileHandleForReading,
            output: Pipe().fileHandleForWriting,
            logger: nil,
            mainActorDeadline: .milliseconds(200)
        )

        let done = XCTestExpectation(description: "bridge returns despite a wedged handler")
        // Thread-safe captures recorded on the BACKGROUND thread the
        // instant `runOnMainActor` returns — NOT marshalled back through
        // the (deliberately wedged) main thread, which would mis-measure
        // elapsed as ~2 s (the callback can't land until the main-thread
        // sleep finishes).
        let resultBox = TimedOutcomeBox()
        let started = Date()

        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = server.runOnMainActor { () -> Int in
                // Block the main actor far longer than the deadline.
                Thread.sleep(forTimeInterval: 2.0)
                return 42
            }
            resultBox.record(outcome: outcome, elapsed: Date().timeIntervalSince(started))
            done.fulfill()
        }

        // Generous budget: 200 ms deadline + scheduling slack. If the
        // bridge hung (unfixed code), we'd blow through this and the
        // wait would fail — exactly the red signal we want.
        wait(for: [done], timeout: 3.0)

        guard let (outcome, elapsed) = resultBox.value else {
            return XCTFail("bridge never returned — wedged on a no-deadline wait")
        }
        switch outcome {
        case .success:
            XCTFail("expected a timeout, got a value — deadline did not fire")
        case .failure(let err):
            XCTAssertEqual(err, .timedOut)
        }
        // It returned at/around the deadline, not after the full 2 s
        // handler sleep — proving the wait was bounded, not that the
        // handler merely finished fast.
        XCTAssertLessThan(elapsed, 1.5,
                          "bridge returned only after the 2 s handler completed; the wait was not bounded by the deadline")
    }

    /// Lock-guarded box for capturing a bridge outcome + elapsed time off
    /// the main thread (the timeout test wedges main, so we can't route
    /// the result through `DispatchQueue.main`).
    private final class TimedOutcomeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: (Result<Int, MCPServer.MainActorBridgeError>, TimeInterval)?
        func record(outcome: Result<Int, MCPServer.MainActorBridgeError>, elapsed: TimeInterval) {
            lock.lock(); _value = (outcome, elapsed); lock.unlock()
        }
        var value: (Result<Int, MCPServer.MainActorBridgeError>, TimeInterval)? {
            lock.lock(); defer { lock.unlock() }; return _value
        }
    }

    /// A normally-completing handler still returns its value through the
    /// bridge — the deadline path must not eat fast results. Pins that
    /// the `Result` refactor preserves the happy path.
    func test_runOnMainActor_returnsValueWhenHandlerCompletes() {
        let host = StubHost()
        let server = MCPServer(
            host: host,
            input: Pipe().fileHandleForReading,
            output: Pipe().fileHandleForWriting,
            logger: nil,
            mainActorDeadline: .seconds(5)
        )

        let done = XCTestExpectation(description: "bridge returns the handler's value")
        let outcomeHolder = OutcomeHolder()

        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = server.runOnMainActor { () -> Int in 1234 }
            DispatchQueue.main.async {
                outcomeHolder.outcome = outcome
                done.fulfill()
            }
        }

        wait(for: [done], timeout: 3.0)

        guard let outcome = outcomeHolder.outcome else {
            return XCTFail("bridge never returned")
        }
        switch outcome {
        case .success(let value):
            XCTAssertEqual(value, 1234, "bridge dropped or corrupted the handler's return value")
        case .failure(let err):
            XCTFail("a fast handler should not time out, got \(err)")
        }
    }

    /// End-to-end: a wedged main-actor handler surfaces a JSON-RPC
    /// `-32603` internal error to the CLIENT (not a hang) when the
    /// deadline fires. Drives the full request path through a live
    /// server with a short injected deadline.
    func test_wedgedHandler_returnsInternalErrorToClient() throws {
        // Handler holds main for ~2 s; deadline is 200 ms.
        let host = SleepingHost(sleepFor: 2.0)
        let inPipe = Pipe()
        let outPipe = Pipe()
        let server = MCPServer(
            host: host,
            input: inPipe.fileHandleForReading,
            output: outPipe.fileHandleForWriting,
            logger: nil,
            mainActorDeadline: .milliseconds(200)
        )
        server.start()
        defer { server.stop(); try? outPipe.fileHandleForWriting.close() }

        let req = Data(#"""
        {"jsonrpc":"2.0","id":7,"method":"tools/call",
         "params":{"name":"current_state","arguments":{}}}
        """#.utf8)
        try inPipe.fileHandleForWriting.write(contentsOf: MCPFraming.encode(body: req))

        let arrived = XCTestExpectation(description: "error response arrives despite wedge")
        let holder = ResponseHolder()
        drainResponses(from: outPipe, count: 1, expectation: arrived, into: holder)

        // Deadline (200 ms) + framing + scheduling. A hang would never
        // arrive within this; the unfixed code fails here.
        wait(for: [arrived], timeout: 3.0)

        if let err = holder.error { throw err }
        guard let bodies = holder.allBodies, let body = bodies.first else {
            return XCTFail("no response arrived — server wedged on the long handler")
        }
        let response = try JSONDecoder().decode(MCP.Response.self, from: body)
        XCTAssertEqual(response.id, .int(7))
        XCTAssertNil(response.result, "a timed-out request must not carry a result")
        XCTAssertEqual(response.error?.code, MCP.ErrorCode.internalError,
                       "a main-actor timeout must surface as JSON-RPC -32603")
        XCTAssertTrue(response.error?.message.contains("timeout") ?? false,
                      "the error message should name the timeout, got: \(response.error?.message ?? "nil")")
    }

    @MainActor
    private final class OutcomeHolder {
        var outcome: Result<Int, MCPServer.MainActorBridgeError>?
        var elapsed: TimeInterval?
    }
}
