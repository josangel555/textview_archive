import Foundation
import ViewerKit

/// MCP server over stdio. Reads framed JSON-RPC requests on stdin,
/// dispatches them to `AutomationHost` on the main actor, and writes
/// framed responses to stdout.
///
/// Lifecycle:
///   - `start()` spawns a background thread parked in
///     `MCPFraming.decode(...)`. The thread hops onto MainActor per
///     request to drive the host, then writes the response back from
///     the same background thread.
///   - The loop terminates on stdin EOF or after `stop()` is called.
///
/// We deliberately do NOT use Foundation's URLSession / DispatchIO —
/// stdio is a single bidirectional channel that's already serial; the
/// extra machinery adds nothing and pulls in async surfaces that don't
/// play with Swift 6 strict concurrency cleanly.
public final class MCPServer: @unchecked Sendable {

    private let host: AutomationHost
    private let input: FileHandle
    private let output: FileHandle
    /// The output descriptor, captured ONCE at init while `output` is open
    /// (TSK-1559). `send` writes via a raw `write(2)` on this cached fd rather
    /// than `output.write(contentsOf:)`, because `FileHandle.write` raises an
    /// UNCATCHABLE (from Swift) ObjC `NSFileHandleOperationException` when the
    /// handle is closed concurrently (teardown / app-quit / a peer close) —
    /// the same landmine the reader's fd-cache fixed. `write(2)` returns
    /// -1/EPIPE/EBADF instead, which `send` handles as a dead transport. This
    /// makes closing the output end safe, so a blocked response reader can be
    /// released with a clean EOF instead of leaking.
    private let outputFD: Int32
    private let logger: ((String) -> Void)?

    /// Upper bound on how long the reader thread will park waiting for a
    /// single request to complete on the main actor. If the main actor
    /// wedges (or a handler runs unboundedly), the reader recovers after
    /// this deadline and returns a JSON-RPC internal error to the client
    /// instead of parking forever — the liveness gap `stop()` can't close
    /// once the thread is already past the read and blocked mid-request.
    ///
    /// Generous by design: long enough not to false-trip a slow-but-live
    /// main actor (a model walk over thousands of tabs, a synchronous
    /// snapshot), short enough that a true wedge is recoverable within a
    /// reasonable window. Overridable via `init` so tests can inject a
    /// short deadline without a multi-second hang.
    private let mainActorDeadline: DispatchTimeInterval

    /// Invoked exactly once when the read loop ends — clean stdin EOF,
    /// a framing error, or an external `stop()` (which closes stdin and
    /// thus unblocks the read into EOF). Wired by the headless
    /// `--mcp-stdio` launcher to terminate the process; without it the
    /// loop returns but `NSApplication.run` keeps the process alive
    /// forever (orphaned MCP server). Defaults to `nil` for tests, which
    /// drive the server in-process and don't want a host-process exit.
    nonisolated(unsafe) private var onExit: (@Sendable () -> Void)?
    /// Guards `onExit` against a double-fire if both a framing/EOF return
    /// and a concurrent `stop()` race to wind the loop down.
    private let exitLock = NSLock()
    nonisolated(unsafe) private var didExit = false

    /// Atomically-flipped flag the read loop checks between requests
    /// so an external `stop()` (or fatal error elsewhere) can wind it
    /// down without waiting on the next stdin byte. `nonisolated(unsafe)`
    /// because Swift 6 can't see the OSAtomic guarantees.
    nonisolated(unsafe) private var stopFlag: Bool = false
    private let stopLock = NSLock()

    private var thread: Thread?

    /// One writer lock — `write(2)` is atomic up to PIPE_BUF (4096
    /// bytes on macOS), but framed responses can exceed that. Without
    /// this lock a concurrent notification publish would interleave
    /// bytes with a response and corrupt the stream.
    private let writeLock = NSLock()

    /// Wire mode of the CURRENT session, captured from each decoded
    /// request so responses go back in kind (TSK-1545: real MCP clients
    /// speak newline-delimited JSON; our own tooling speaks
    /// Content-Length — both are served). Written by the reader thread
    /// before dispatch, read under `writeLock` when sending — the
    /// request/response pairing on the serial channel orders the two.
    nonisolated(unsafe) private var wireMode: MCPFraming.Mode = .contentLength

    public init(
        host: AutomationHost,
        input: FileHandle = .standardInput,
        output: FileHandle = .standardOutput,
        logger: ((String) -> Void)? = nil,
        onExit: (@Sendable () -> Void)? = nil,
        mainActorDeadline: DispatchTimeInterval = .seconds(20)
    ) {
        self.host = host
        self.input = input
        self.output = output
        self.outputFD = output.fileDescriptor   // safe: output is open here
        self.logger = logger
        self.onExit = onExit
        self.mainActorDeadline = mainActorDeadline
    }

    // MARK: - Public lifecycle

    public func start() {
        let t = Thread { [weak self] in
            self?.runLoop()
        }
        t.name = "MCPServer.stdio"
        t.qualityOfService = .userInitiated
        thread = t
        t.start()
    }

    public func stop() {
        stopLock.lock(); stopFlag = true; stopLock.unlock()
        // Closing stdin causes any blocking read on the loop thread
        // to return EOF, releasing the loop.
        try? input.close()
    }

    private var shouldStop: Bool {
        stopLock.lock(); defer { stopLock.unlock() }
        return stopFlag
    }

    // MARK: - Loop

    private func runLoop() {
        // Whichever way the loop ends — clean EOF, framing error, or an
        // external `stop()` that closed stdin — fire `onExit` exactly
        // once. The headless launcher wires this to `NSApp.terminate`;
        // without it the loop returns but the process never exits.
        defer { fireExit() }
        var reader = MCPFraming.FileHandleReader(input)
        while !shouldStop {
            let message: (body: Data, mode: MCPFraming.Mode)?
            do {
                message = try MCPFraming.decodeDetecting(from: &reader)
            } catch {
                log("framing error: \(error). Closing.")
                return
            }
            guard let message else {
                // Clean EOF.
                log("stdin EOF; server exiting")
                return
            }
            writeLock.lock(); wireMode = message.mode; writeLock.unlock()
            handle(requestBody: message.body)
        }
    }

    /// Fire the exit callback at most once. Idempotent so a `stop()`
    /// path and the loop's own `defer` can't double-terminate.
    private func fireExit() {
        exitLock.lock()
        if didExit { exitLock.unlock(); return }
        didExit = true
        let cb = onExit
        // Drop the reference so the closure (and anything it captures)
        // can't be retained past its single use.
        onExit = nil
        exitLock.unlock()
        cb?()
    }

    private func handle(requestBody: Data) {
        // Parse the envelope. A malformed envelope is a JSON-RPC
        // parseError; we still respond if we recovered an id, otherwise
        // we send a null-id error (per JSON-RPC 2.0).
        let decoder = JSONDecoder()
        let request: MCP.Request
        do {
            request = try decoder.decode(MCP.Request.self, from: requestBody)
        } catch {
            sendError(id: .null, code: MCP.ErrorCode.parseError, message: "parse error: \(error)")
            return
        }
        guard request.jsonrpc == "2.0" else {
            sendError(id: request.id ?? .null,
                      code: MCP.ErrorCode.invalidRequest,
                      message: "jsonrpc must be \"2.0\"")
            return
        }

        // Notifications (no id) are accepted but we don't have any
        // notification verbs to honour in v1 — just drop them.
        guard let id = request.id else {
            log("dropping notification \(request.method)")
            return
        }

        // TSK-1192: ASYNC tools (LSP-backed code nav) bypass the main-actor
        // bridge — an LSP round-trip can take seconds, and parking main for
        // it would freeze the UI. They run on THIS reader thread behind
        // their own semaphore; the handler hops actors internally only
        // where it must (the LSP pool).
        if request.method == "tools/call",
           case .object(let o)? = request.params,
           case .string(let toolName)? = o["name"],
           MCPToolCatalog.isAsyncTool(toolName) {
            send(response: runAsyncToolCall(id: id, name: toolName, params: request.params))
            return
        }

        // Dispatch on the main actor — every handler touches
        // DocumentModel. We previously used `DispatchQueue.main.sync`
        // which wedges if any main-actor handler (or anything it
        // awaits) needs to bounce through the main queue while we're
        // parked there: main is blocked-on-itself.
        //
        // Continuation bridge instead: spawn a `Task { @MainActor in
        // ... }` that runs the handler and signals a kernel
        // semaphore. The reader thread blocks on that semaphore —
        // **not** on main — so main is free to service the handler's
        // own awaits, NSEvent reentries, run-loop hops, etc.
        //
        // Sequencing: stdio is a single channel, clients send requests
        // serially and expect ordered responses. We block the reader
        // thread per-request so responses still emit in request order.
        let captured: (MCP.ID, String, MCP.Value?) = (id, request.method, request.params)
        let outcome = runOnMainActor { [self] in
            // `self` is captured strongly: the read-loop thread holds
            // us alive while it's parked on the semaphore, and the
            // captured reference is touched only inside the
            // main-actor Task.
            self.dispatch(id: captured.0, method: captured.1, params: captured.2)
        }
        let response: MCP.Response
        switch outcome {
        case .success(let r):
            response = r
        case .failure(.timedOut):
            // The main actor did not service this request within
            // `mainActorDeadline`. Rather than park the reader thread
            // forever (the liveness gap), surface a JSON-RPC internal
            // error so the client gets a definite answer and the loop
            // moves on to the next request. The wedged Task may still
            // complete later and signal a now-orphaned semaphore — that
            // is harmless (the semaphore is local to that call).
            log("main-actor timeout for \(captured.1) (id \(id)); returning -32603")
            response = MCP.Response(id: id, error: .init(
                code: MCP.ErrorCode.internalError,
                message: "main-actor timeout: handler for '\(captured.1)' did not complete within deadline"))
        }
        send(response: response)
    }

    /// Synchronously bridge a `@MainActor` closure call from a
    /// background thread without ever calling `DispatchQueue.main.sync`.
    ///
    /// # Why not `DispatchQueue.main.sync`
    ///
    /// `main.sync` from a background thread parks the calling thread
    /// in libdispatch's queue-drain wait. Two classes of wedge follow:
    ///
    /// 1. **Main-on-main invocation.** If a refactor ever causes the
    ///    bridge to be called from the main thread itself,
    ///    `main.sync` is an immediate libdispatch deadlock (filing
    ///    work behind ourselves on the queue we're already running).
    ///    The cost surfaces as a hang rather than a crash, which is
    ///    much harder to diagnose.
    /// 2. **QoS inversion under strict concurrency.** Swift 6's
    ///    runtime warns about `main.sync` from a non-main Task; the
    ///    Task is forced to wait on libdispatch instead of the actor
    ///    executor, defeating priority inheritance.
    ///
    /// # The new bridge
    ///
    /// 1. Spawn a `Task { @MainActor in ... }` for the work.
    /// 2. Park the caller thread on a `DispatchSemaphore`.
    /// 3. Main-actor executor runs the work, signals the semaphore.
    /// 4. Caller wakes, returns the boxed result.
    ///
    /// The reader thread parks on a kernel semaphore — not on
    /// `DispatchQueue.main` — so libdispatch's "queue waiting for
    /// itself" trap is impossible. The `precondition` below catches
    /// the main-on-main misuse loudly instead of letting it become a
    /// silent hang.
    ///
    /// # Deadline / liveness
    ///
    /// The wait is **bounded** by `mainActorDeadline`. The original
    /// `semaphore.wait()` had no deadline: if the main actor wedged
    /// (deadlock, an unbounded handler, a non-pumping kernel wait), the
    /// reader thread parked here indefinitely. `stop()` only closes
    /// stdin — it can release a thread blocked in `MCPFraming.decode`,
    /// but it cannot release one already past the read and parked
    /// mid-request. The bounded wait closes that gap: on `.timedOut` the
    /// caller gets a `.failure(.timedOut)` and emits a JSON-RPC internal
    /// error to the client instead of hanging.
    ///
    /// # Visibility
    ///
    /// `internal` (not `private`) so the wedge regression tests in
    /// `MCPServerWedgeTests` can `@testable` import and exercise the
    /// bridge directly. The implementation is otherwise an
    /// implementation detail of `handle(requestBody:)`.
    nonisolated internal func runOnMainActor<T: Sendable>(
        _ work: @escaping @Sendable @MainActor () -> T
    ) -> Result<T, MainActorBridgeError> {
        precondition(!Thread.isMainThread,
                     "MCPServer.runOnMainActor must not be called from the main thread")
        let semaphore = DispatchSemaphore(value: 0)
        // `nonisolated(unsafe)` is the canonical pattern for a
        // single-writer / single-reader cell ordered by a semaphore
        // signal/wait pair (happens-before is established by the
        // semaphore on macOS / libdispatch). Carrying the value through
        // a typed `Result` rather than a bare `T?` removes the old
        // `return box!` force-unwrap: a timeout is now a typed `.failure`
        // value, never a `nil` we'd crash on.
        nonisolated(unsafe) var box: T?
        Task { @MainActor in
            box = work()
            semaphore.signal()
        }
        switch semaphore.wait(timeout: .now() + mainActorDeadline) {
        case .success:
            // `box` is guaranteed assigned: `signal()` happens-after the
            // assignment on the same Task, and `.success` means we
            // observed that signal — so the write is visible here. The
            // `?? .timedOut` is a belt-and-braces fallback that can't
            // trigger but keeps the path total (no force-unwrap).
            if let value = box { return .success(value) }
            return .failure(.timedOut)
        case .timedOut:
            // The MainActor Task is still outstanding. It may complete
            // later and signal a semaphore no one is waiting on — that's
            // benign: the semaphore is local to this call and is simply
            // deallocated once the Task's `signal()` returns.
            return .failure(.timedOut)
        }
    }

    /// Failure modes of the synchronous main-actor bridge. Today the only
    /// case is a deadline expiry; modelled as an enum so adding bridge
    /// failure modes later stays source-compatible at the call site.
    internal enum MainActorBridgeError: Error, Equatable {
        /// The main-actor handler did not signal within `mainActorDeadline`.
        case timedOut
    }

    @MainActor
    private func dispatch(id: MCP.ID, method: String, params: MCP.Value?) -> MCP.Response {
        do {
            switch method {
            case "initialize":
                return MCP.Response(id: id, result: try initializeResult())
            case "initialized", "notifications/initialized":
                // Spec-compliant clients send `initialized` as a
                // notification after `initialize` returns — we already
                // filtered notifications above, but some buggy clients
                // send it with an id. Reply empty success.
                return MCP.Response(id: id, result: .object([:]))
            case "tools/list":
                return MCP.Response(id: id, result: try toolsListResult())
            case "tools/call":
                return try toolsCall(id: id, params: params)
            case "ping":
                return MCP.Response(id: id, result: .object([:]))
            case "shutdown":
                // Returning success then stopping the loop matches LSP
                // semantics. The client typically sends `exit` after.
                defer { self.stop() }
                return MCP.Response(id: id, result: .null)
            default:
                return MCP.Response(id: id, error: .init(
                    code: MCP.ErrorCode.methodNotFound,
                    message: "unknown method: \(method)"))
            }
        } catch let e as MCPError {
            return MCP.Response(id: id, error: .init(code: e.code, message: e.message))
        } catch {
            return MCP.Response(id: id, error: .init(
                code: MCP.ErrorCode.internalError,
                message: "\(error)"))
        }
    }

    // MARK: - Method handlers

    @MainActor
    private func initializeResult() throws -> MCP.Value {
        let result = MCP.InitializeResult(
            // Pin a recent stable MCP protocol version. Clients
            // negotiate via this string — bumping it is intentional.
            protocolVersion: "2024-11-05",
            capabilities: .init(tools: .init(listChanged: false)),
            serverInfo: .init(name: "TextView", version: "1.0.0")
        )
        return try Self.encodeValue(result)
    }

    @MainActor
    private func toolsListResult() throws -> MCP.Value {
        let tools = MCPToolCatalog.all
        let payload: MCP.Value = .object([
            "tools": .array(try tools.map { try Self.encodeValue($0) })
        ])
        return payload
    }

    /// TSK-1192 — run an ASYNC tool on the calling (reader) thread: spawn
    /// the async handler as a detached Task, park on a semaphore with a
    /// deadline sized for an LSP round-trip (the pool's per-request timeout
    /// is 8 s; two hops + slack = 20 s). Same ToolCallResult wrapping as
    /// the sync lane; a deadline trip answers a definite tool error.
    private nonisolated func runAsyncToolCall(id: MCP.ID, name: String, params: MCP.Value?) -> MCP.Response {
        let args: MCP.Value = {
            if case .object(let o)? = params, let a = o["arguments"] { return a }
            return .object([:])
        }()
        let sem = DispatchSemaphore(value: 0)
        // Single-producer box: written once by the Task, read after wait().
        let box = ResultBox()
        let host = MCPToolCatalog.AsyncHostBox(self.host)
        Task.detached {
            do {
                box.value = .success(try await MCPToolCatalog.dispatchAsync(
                    name: name, args: args, host: host))
            } catch let e as MCPError {
                box.value = .failure(e)
            } catch {
                box.value = .failure(MCPError.toolFailed("\(error)"))
            }
            sem.signal()
        }
        guard sem.wait(timeout: .now() + 20) == .success else {
            log("async tool '\(name)' deadline (20s); returning tool error")
            let r = MCP.ToolCallResult(
                text: "'\(name)' timed out — the language server may be starting or wedged",
                isError: true)
            return MCP.Response(id: id, result: (try? Self.encodeValue(r)) ?? .object([:]))
        }
        switch box.value {
        case .success(let v):
            let json = (try? Self.jsonString(v)) ?? "{}"
            let r = MCP.ToolCallResult(text: json, isError: false)
            return MCP.Response(id: id, result: (try? Self.encodeValue(r)) ?? .object([:]))
        case .failure(let e):
            let r = MCP.ToolCallResult(text: e.message, isError: true)
            return MCP.Response(id: id, result: (try? Self.encodeValue(r)) ?? .object([:]))
        case nil:
            let r = MCP.ToolCallResult(text: "internal: async tool returned no result", isError: true)
            return MCP.Response(id: id, result: (try? Self.encodeValue(r)) ?? .object([:]))
        }
    }

    /// The write-once cell `runAsyncToolCall` hands its Task (class, so the
    /// concurrently-executing Task can mutate it; the semaphore orders the
    /// read after the write).
    private final class ResultBox: @unchecked Sendable {
        var value: Result<MCP.Value, MCPError>?
    }

    @MainActor
    private func toolsCall(id: MCP.ID, params: MCP.Value?) throws -> MCP.Response {
        guard let params else {
            throw MCPError.invalidParams("missing params")
        }
        let name = try params.string("name")
        // Tool args default to {} if omitted — many tools take none.
        let args: MCP.Value = {
            if case .object(let o) = params, let a = o["arguments"] { return a }
            return .object([:])
        }()

        do {
            let resultValue = try MCPToolCatalog.dispatch(
                name: name, args: args, host: host
            )
            // Per MCP spec, tools/call returns a `ToolCallResult` —
            // content array, not the raw return value. We serialise
            // the structured value to a single text block so clients
            // can re-parse it (most do).
            let json = try Self.jsonString(resultValue)
            let toolResult = MCP.ToolCallResult(text: json, isError: false)
            return MCP.Response(id: id, result: try Self.encodeValue(toolResult))
        } catch let e as MCPError {
            // Surface tool-level failures as `tools/call` result with
            // `isError: true` rather than a JSON-RPC error, per MCP
            // convention: the call succeeded, the tool reported an
            // application-level error.
            let toolResult = MCP.ToolCallResult(text: e.message, isError: true)
            return MCP.Response(id: id, result: try Self.encodeValue(toolResult))
        }
    }

    // MARK: - IO

    private func send(response: MCP.Response) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body: Data
        do {
            body = try encoder.encode(response)
        } catch {
            // A non-Encodable `MCP.Response` is unreachable here; log + return
            // (an encoding failure is not a transport failure — don't tear down).
            log("send encode error: \(error)")
            return
        }
        let framed = MCPFraming.encode(body: body, mode: wireMode)
        writeLock.lock()
        let err = Self.writeAll(fd: outputFD, framed)
        writeLock.unlock()
        guard err != 0 else { return }
        // A failed write means the response never reached the client. A
        // transport failure means stdout is gone: in the half-closed case the
        // client closed the read end of our stdout while keeping our stdin
        // open, so every subsequent response would silently fail and the read
        // loop would keep dispatching requests it can never answer — the
        // orphaned headless-server hang the `onExit` wiring exists to prevent.
        // `stop()` closes stdin → the read loop hits EOF → `fireExit()` →
        // terminate. Raw `write(2)` yields an errno (never an ObjC exception),
        // so a concurrent output close (teardown) is a clean EPIPE/EBADF here.
        log("send error (\(Self.isDeadTransport(errno: err) ? "dead transport" : "errno \(err)")); stopping")
        stop()
    }

    /// Write every byte of `data` to `fd` via raw `write(2)` (retrying EINTR),
    /// returning `0` on success or the failing `errno`. Used instead of
    /// `FileHandle.write` so a closed descriptor surfaces as EPIPE/EBADF —
    /// inspectable — rather than an uncatchable ObjC exception (TSK-1559).
    private static func writeAll(fd: Int32, _ data: Data) -> Int32 {
        if data.isEmpty { return 0 }
        return data.withUnsafeBytes { raw -> Int32 in
            guard let base = raw.baseAddress else { return 0 }
            var off = 0
            let total = raw.count
            while off < total {
                let n = Darwin.write(fd, base + off, total - off)
                if n < 0 {
                    if errno == EINTR { continue }
                    return errno
                }
                if n == 0 { return EIO }  // unexpected on a pipe/socket
                off += n
            }
            return 0
        }
    }

    /// Whether a `write(2)` `errno` means the channel is dead (no retry can
    /// succeed): peer closed the read end, fd closed under us, or reset.
    private static func isDeadTransport(errno err: Int32) -> Bool {
        switch err {
        case EPIPE, EBADF, ENOTCONN, ECONNRESET:
            return true
        default:
            return false
        }
    }

    private func sendError(id: MCP.ID, code: Int, message: String) {
        send(response: MCP.Response(
            id: id,
            error: .init(code: code, message: message)))
    }

    private func log(_ s: String) {
        // Route to the unified observability sink (subsystem "mcp"). The
        // sink ring-buffers in memory; per the security model the MCP
        // host must NEVER read that buffer back out (no audit/consent),
        // but emitting the server's OWN diagnostics into it is fine.
        Obs.shared.emit(.info, "mcp", s)

        // Logger optional — production callers route to stderr or
        // ~/Library/Logs; tests pass nil. Stdout must stay clean for
        // protocol bytes only. Preserved verbatim.
        logger?(s)
    }

    // MARK: - JSON helpers

    /// Encode a Codable value into `MCP.Value`. Round-tripping through
    /// JSON data isn't free, but tool results are small and this keeps
    /// the encoder centralised — handlers don't manually build
    /// `.object([...])` trees.
    static func encodeValue<T: Encodable>(_ value: T) throws -> MCP.Value {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(MCP.Value.self, from: data)
    }

    /// JSON-encode a `MCP.Value` to a compact string.
    static func jsonString(_ value: MCP.Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8) ?? "null"
    }
}
