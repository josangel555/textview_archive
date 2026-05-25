import Foundation

/// Minimal sourcekit-lsp client for the PoC. Owns one subprocess,
/// frames JSON-RPC over its stdio, and exposes hover + definition.
///
/// Scope intentionally narrow per `docs/LSP_DESIGN.md` Phase 1:
///   - one client → one server process → one workspace root
///   - no pool, no reaper, no restart-on-crash, no cancellation token
///   - no `$/cancelRequest`; pending requests just time out
///   - only methods exercised by the PoC UI hook
///
/// All public methods are `async` and run on the actor; stdout-reader
/// dispatches back to the actor via `Task` hops. Cancellation safety
/// is *not* guaranteed at PoC scope — caller-side cancellation will
/// leak the pending continuation until the per-request timeout fires.
public actor LSPClient {

    // MARK: Configuration

    public struct Config: Sendable {
        public let executable: URL
        public let arguments: [String]
        public let workspaceRoot: URL
        /// Optional environment overlay for the child process. When nil
        /// (the production default) the child inherits the parent env;
        /// when non-nil, the *full* env is set from this dictionary
        /// (Foundation's `Process.environment` is set-or-inherit, not
        /// overlay). Tests use this to dial in fake-server scenarios
        /// without polluting the test process's own env.
        public let environment: [String: String]?
        public init(
            executable: URL, arguments: [String] = [],
            workspaceRoot: URL, environment: [String: String]? = nil
        ) {
            self.executable = executable
            self.arguments = arguments
            self.workspaceRoot = workspaceRoot
            self.environment = environment
        }
    }

    // MARK: State

    private let config: Config
    private let process: Process
    private let stdinPipe: Pipe
    private let stdoutPipe: Pipe
    private let stderrPipe: Pipe

    private var nextID: Int64 = 1
    private var pending: [Int64: CheckedContinuation<Data, Error>] = [:]
    /// Method names of currently pending requests, so we can produce a
    /// useful error when the server crashes / closes the transport.
    private var pendingMethods: [Int64: String] = [:]
    private var initialized = false
    /// Dedicated OS thread that drives the stdout read loop. We use
    /// a separate `Thread` (not `Task.detached`) so blocking POSIX
    /// reads don't starve the cooperative pool. See `startReader()`
    /// doc-comment for the full rationale.
    private var readerThread: Thread?

    /// Write a fully-framed JSON-RPC payload to the child's stdin.
    /// Uses POSIX `write(2)` on the raw fd instead of
    /// `FileHandle.write(contentsOf:)`. On macOS 26, the FileHandle
    /// write end of a `Pipe` and the read end held by a separate
    /// thread can race: the second write returns success but the
    /// bytes never reach the child. POSIX write hits the kernel pipe
    /// buffer directly and behaves correctly.
    ///
    /// Returns true on full write, false on partial / failed write.
    /// Callers translate failure into `LSPError.transportClosed`.
    @discardableResult
    private func writeFramedToChild(_ framed: Data) -> Bool {
        let fd = stdinPipe.fileHandleForWriting.fileDescriptor
        var written = 0
        let total = framed.count
        while written < total {
            // Slice into a fresh contiguous buffer each iteration so
            // `withUnsafeBytes` is always pointing at the right
            // memory. (Data subscripting on a slice carries an
            // internal base offset that the `count`/pointer pair
            // does not surface; constructing a new `Data` re-bases.)
            let chunk = Data(framed[written..<total])
            let chunkCount = chunk.count
            let n = chunk.withUnsafeBytes { ptr -> Int in
                return write(fd, ptr.baseAddress, chunkCount)
            }
            if n <= 0 {
                // EINTR is rare for pipes; we don't retry it here.
                // EPIPE is suppressed via F_SETNOSIGPIPE so write
                // returns -1 with errno=EPIPE instead of SIGPIPE.
                return false
            }
            written += n
        }
        return true
    }

    /// Position encoding negotiated with the server in `initialize`.
    /// The spec default is `.utf16`. If the server replies with
    /// `positionEncoding: "utf-8"` or `"utf-32"`, we honor it here and
    /// the `LSPPositionConverter` translates accordingly.
    public private(set) var positionEncoding: LSPPositionEncoding = .utf16

    /// Crash callback invoked when stdout EOFs / framing fails after
    /// `initialize`. Used by `LSPPool` to demote the entry. Optional;
    /// stand-alone callers don't need it.
    private var onCrash: (@Sendable (Error) -> Void)?
    public func setOnCrash(_ handler: @escaping @Sendable (Error) -> Void) {
        self.onCrash = handler
    }

    /// Callback for server-pushed `textDocument/publishDiagnostics`.
    /// Wired by `LSPPool` to forward into the @MainActor
    /// `LSPDiagnosticsStore`. Optional; standalone clients drop pushes.
    private var onDiagnostics: (@Sendable (URL, [LSPDiagnostic]) -> Void)?
    public func setOnDiagnostics(
        _ handler: @escaping @Sendable (URL, [LSPDiagnostic]) -> Void
    ) {
        self.onDiagnostics = handler
    }

    // MARK: Init / spawn

    /// Spawns the subprocess. Throws if the binary is missing or the
    /// process can't be launched. Caller must then `await initialize()`
    /// before issuing any other requests.
    public init(config: Config) throws {
        self.config = config
        guard FileManager.default.fileExists(atPath: config.executable.path) else {
            throw LSPError.serverBinaryNotFound(config.executable.path)
        }

        let p = Process()
        p.executableURL = config.executable
        p.arguments = config.arguments
        p.currentDirectoryURL = config.workspaceRoot
        if let env = config.environment {
            p.environment = env
        }

        let sIn = Pipe(), sOut = Pipe(), sErr = Pipe()
        p.standardInput = sIn
        p.standardOutput = sOut
        p.standardError = sErr
        self.process = p
        self.stdinPipe = sIn
        self.stdoutPipe = sOut
        self.stderrPipe = sErr

        do {
            try p.run()
        } catch {
            throw LSPError.spawnFailed("\(error)")
        }

        // Suppress SIGPIPE on the stdin write fd: if the LSP server
        // exits between requests (`shutdown` → `exit` → child gone),
        // the next `notify` would otherwise raise SIGPIPE and kill
        // the parent process. `F_SETNOSIGPIPE` makes write(2) return
        // EPIPE as an errno instead, which Foundation surfaces as a
        // throwing call we already handle. macOS-specific; Linux
        // would use `MSG_NOSIGNAL` / `SO_NOSIGPIPE`.
        _ = fcntl(sIn.fileHandleForWriting.fileDescriptor,
                  F_SETNOSIGPIPE, 1)

        // stderr drain — without this the child blocks at ~64 KB
        // (kernel pipe buffer). We intentionally discard; a real
        // implementation would surface in a diagnostics panel.
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
    }

    /// Kick off the background stdout reader. Must run on the actor;
    /// caller invokes from `initialize()`.
    ///
    /// Uses POSIX `read(2)` on the raw fd on a dedicated `Thread` for
    /// two reasons:
    ///
    /// 1. **FileHandle hazard.** On macOS 26, concurrent
    ///    `FileHandle.read(upToCount:)` on the read end of a pipe AND
    ///    `FileHandle.write(contentsOf:)` on the write end of the
    ///    same `Pipe` can wedge the write — the writer's bytes never
    ///    reach the child even though `write` returns successfully.
    ///    The raw POSIX dance bypasses Foundation's per-FileHandle
    ///    serial queue and works reliably.
    /// 2. **Cooperative pool starvation.** A blocking `read(2)` on
    ///    `Task.detached` parks one of the cooperative pool threads
    ///    indefinitely. With a small pool (typical on a 4-core test
    ///    host), other actor requests starve and the test framework
    ///    surfaces this as `CancellationError`. A dedicated `Thread`
    ///    keeps the cooperative pool free for actor hops.
    ///
    /// Inbound frames are hopped back onto the actor via a one-shot
    /// `Task { await self.dispatchInbound(...) }`. The reader exits
    /// when `read` returns 0 (EOF after `process.terminate()`).
    private func startReader() {
        let fd = stdoutPipe.fileHandleForReading.fileDescriptor
        let weakBox = WeakLSPClientBox(client: self)
        let thread = Thread {
            var buffer = Data()
            let bufSize = 8 * 1024
            var scratch = [UInt8](repeating: 0, count: bufSize)
            while true {
                let n = scratch.withUnsafeMutableBufferPointer { ptr -> Int in
                    return read(fd, ptr.baseAddress, bufSize)
                }
                if n <= 0 {
                    // 0 = EOF, <0 = error. Either way the transport
                    // is gone.
                    if let client = weakBox.client {
                        Task { await client.failAllPending(LSPError.transportClosed) }
                    }
                    return
                }
                buffer.append(scratch, count: n)
                while true {
                    let step: LSPFraming.DecodeStep
                    do {
                        step = try LSPFraming.decode(buffer)
                    } catch {
                        if let client = weakBox.client {
                            Task { await client.failAllPending(error) }
                        }
                        return
                    }
                    switch step {
                    case .needMore:
                        break
                    case .message(let body, let consumed):
                        buffer.removeFirst(consumed)
                        if let client = weakBox.client {
                            Task { await client.dispatchInbound(body) }
                        }
                        continue
                    }
                    break
                }
            }
        }
        thread.name = "LSPClient.readerThread"
        thread.qualityOfService = .utility
        readerThread = thread
        thread.start()
    }

    private func failAllPending(_ error: Error) {
        for (_, cont) in pending {
            cont.resume(throwing: error)
        }
        pending.removeAll()
        pendingMethods.removeAll()
        // Notify the pool (if any) that the transport died after we'd
        // initialized — that's a crash, not a clean shutdown.
        if initialized, let cb = onCrash {
            cb(error)
        }
        initialized = false
    }

    // MARK: Inbound dispatch

    /// Top-level dispatch for any framed message coming off stdout.
    /// JSON-RPC distinguishes by presence of `id` + `method`:
    ///   - response: has `id`, no `method`
    ///   - request from server: has `id` AND `method`  (we ignore in PoC)
    ///   - notification from server: no `id`, has `method` (also ignored)
    private func dispatchInbound(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        // Response path: has `id`, no `method` (per JSON-RPC 2.0 spec).
        if obj["method"] == nil, let rawID = obj["id"] {
            guard let id = idAsInt64(rawID) else { return }
            guard let cont = pending.removeValue(forKey: id) else { return }
            pendingMethods.removeValue(forKey: id)
            if let err = obj["error"] as? [String: Any] {
                let code = (err["code"] as? Int) ?? -1
                let msg = (err["message"] as? String) ?? "(no message)"
                cont.resume(throwing: LSPError.serverError(code: code, message: msg))
                return
            }
            // Re-encode the `result` field as Data so callers can decode
            // with their own Codable types or raw JSONSerialization.
            let result = obj["result"] ?? NSNull()
            let resultData: Data
            do {
                resultData = try JSONSerialization.data(
                    withJSONObject: result, options: [.fragmentsAllowed])
            } catch {
                cont.resume(throwing: LSPError.decodeError(
                    method: "(unknown)", message: "\(error)"))
                return
            }
            cont.resume(returning: resultData)
            return
        }
        // Server-originated request or notification path.
        // We handle the notifications we care about (publishDiagnostics)
        // and drop the rest (window/logMessage, telemetry/event, etc.).
        if let method = obj["method"] as? String {
            if obj["id"] == nil {
                // Notification.
                if method == "textDocument/publishDiagnostics" {
                    if let params = obj["params"] as? [String: Any],
                       let uriString = params["uri"] as? String,
                       let url = URL(string: uriString),
                       let diagsArr = params["diagnostics"] as? [[String: Any]] {
                        let diagnostics = diagsArr.compactMap(Self.parseDiagnostic)
                        if let cb = onDiagnostics {
                            cb(url, diagnostics)
                        }
                    }
                }
                // Other notifications: drop silently.
            } else if let id = obj["id"] {
                // S2-I: server-originated REQUEST (id + method). Per LSP
                // spec these MUST be responded to or the server logs
                // timeouts and eventually degrades. sourcekit-lsp
                // tolerates dropping; clangd / rust-analyzer / pyright
                // / typescript-language-server do not. Reply with
                // MethodNotFound (-32601) for everything until we
                // explicitly handle a request (e.g. workspace/configuration).
                replyMethodNotFound(id: id, method: method)
            }
        }
    }

    /// Reply to an inbound server request with JSON-RPC error
    /// `MethodNotFound` (-32601). Best-effort: write errors are
    /// swallowed (transport may already be dead). See S2-I in the
    /// 2026-05-25 correctness review.
    private func replyMethodNotFound(id: Any, method: String) {
        let env: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "error": [
                "code": -32601,
                "message": "Method not found: \(method)"
            ] as [String: Any]
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: env, options: []) else {
            return
        }
        let framed = LSPFraming.frame(body)
        _ = writeFramedToChild(framed)
    }

    private func idAsInt64(_ raw: Any) -> Int64? {
        if let n = raw as? Int64 { return n }
        if let n = raw as? Int   { return Int64(n) }
        if let n = raw as? NSNumber { return n.int64Value }
        if let s = raw as? String, let n = Int64(s) { return n }
        return nil
    }

    // MARK: Outbound — request/response with timeout

    /// Send a JSON-RPC request and await the raw `result` JSON bytes.
    /// Per-method timeout per the design doc; default 8s.
    ///
    /// If `token` is non-nil, the token is bound to the request's id so
    /// `cancel(token:)` from another task can send `$/cancelRequest` to
    /// the server and resume the continuation with `CancellationError`.
    private func request(
        method: String, params: Any, timeout: Duration,
        token: LSPCancellationToken? = nil
    ) async throws -> Data {
        let id = nextID
        nextID &+= 1
        if let token = token {
            token.bind(id: id, owner: self)
        }
        let envelope: [String: Any] = [
            "jsonrpc": "2.0", "id": id, "method": method, "params": params
        ]
        let body = try JSONSerialization.data(withJSONObject: envelope, options: [])
        let framed = LSPFraming.frame(body)

        // Register the continuation FIRST, then arm the timeout. The
        // earlier ordering (timeout before continuation) opened a tiny
        // race: a sub-millisecond `Task.sleep` could fire before the
        // continuation hop, find `pending[id]` empty, and silently
        // drop the wakeup — leaving the continuation forever
        // unresumed (debug warning + indefinite hang in release).
        // We assign the task to the holder inside the continuation
        // block so the `defer { holder.task?.cancel() }` below still
        // cancels on success.
        final class TaskHolder: @unchecked Sendable {
            var task: Task<Void, Never>?
        }
        let holder = TaskHolder()
        defer { holder.task?.cancel() }

        return try await withCheckedThrowingContinuation { cont in
            self.pending[id] = cont
            self.pendingMethods[id] = method
            if !self.writeFramedToChild(framed) {
                self.pending.removeValue(forKey: id)
                self.pendingMethods.removeValue(forKey: id)
                cont.resume(throwing: LSPError.transportClosed)
                return
            }
            // Now that the pending entry exists, arm the timeout. If
            // the deadline fires before a response, `timeoutFire`
            // finds the entry and resumes with `.timeout`.
            holder.task = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.timeoutFire(id: id, method: method)
            }
        }
    }

    /// Invoked from the timeout `Task` once the deadline elapses. If
    /// the continuation is still pending, resume it with a timeout
    /// error and forget the entry.
    private func timeoutFire(id: Int64, method: String) {
        guard let cont = pending.removeValue(forKey: id) else { return }
        pendingMethods.removeValue(forKey: id)
        cont.resume(throwing: LSPError.timeout(method: method))
    }

    /// Cancel a pending request by its JSON-RPC id. Sends `$/cancelRequest`
    /// to the server (best-effort notification — fire-and-forget) and
    /// resumes the local continuation with `CancellationError` if it's
    /// still pending. Late responses from the server are silently
    /// discarded by `dispatchInbound`.
    /// Cancel by id from another file (token bridge). Public so the
    /// LSPCancellationToken — which lives in LSPProtocol.swift — can
    /// reach into the actor without exposing pending state.
    public func cancelRequestPublic(id: Int64) {
        cancelRequest(id: id)
    }

    private func cancelRequest(id: Int64) {
        // Notify server first so it can stop work. Errors swallowed —
        // if the transport is dead the local resume below still happens.
        let env: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "$/cancelRequest",
            "params": ["id": id]
        ]
        if let body = try? JSONSerialization.data(withJSONObject: env, options: []) {
            let framed = LSPFraming.frame(body)
            _ = writeFramedToChild(framed)
        }
        // Resume the local awaiter.
        if let cont = pending.removeValue(forKey: id) {
            pendingMethods.removeValue(forKey: id)
            cont.resume(throwing: CancellationError())
        }
    }

    /// Fire-and-forget notification (no `id`, no response expected).
    private func notify(method: String, params: Any) throws {
        let envelope: [String: Any] = [
            "jsonrpc": "2.0", "method": method, "params": params
        ]
        let body = try JSONSerialization.data(withJSONObject: envelope, options: [])
        let framed = LSPFraming.frame(body)
        if !writeFramedToChild(framed) {
            throw LSPError.transportClosed
        }
    }

    // MARK: Public capability methods

    /// Send `initialize` + `initialized`. Must complete before any
    /// other call. Throws `LSPError.timeout(method: "initialize")` if
    /// the server doesn't respond within 30s (sourcekit-lsp is
    /// typically <1s on a small package; longer on Cargo/RA-class).
    public func initialize() async throws {
        startReader()
        let pid = ProcessInfo.processInfo.processIdentifier
        let rootURI = config.workspaceRoot.absoluteString
        let params: [String: Any] = [
            "processId": pid,
            "clientInfo": ["name": "TextView-PoC", "version": "0.1"],
            "rootUri": rootURI,
            "workspaceFolders": [
                ["uri": rootURI, "name": config.workspaceRoot.lastPathComponent]
            ],
            // Minimal capability advert. Design doc §3.7 explicitly
            // does NOT advertise completion / signatureHelp / codeAction
            // / formatting / rename / linkedEditingRange / codeLens /
            // workspace.applyEdit — viewer can't accept edits.
            "capabilities": [
                "textDocument": [
                    "synchronization": [
                        "dynamicRegistration": false,
                        "willSave": false, "willSaveWaitUntil": false, "didSave": false
                    ],
                    "hover": [
                        "dynamicRegistration": false,
                        "contentFormat": ["markdown", "plaintext"]
                    ],
                    "definition": [
                        "dynamicRegistration": false, "linkSupport": true
                    ]
                ],
                "workspace": [
                    "workspaceFolders": true
                ],
                "general": [
                    // Accept all three; server picks. We translate at the
                    // boundary via `LSPPositionConverter`.
                    "positionEncodings": ["utf-16", "utf-8", "utf-32"]
                ]
            ],
            "trace": "off"
        ]
        let raw = try await request(method: "initialize", params: params, timeout: .seconds(30))
        // Parse server's `capabilities.positionEncoding`. Optional;
        // absent → utf-16 default (spec).
        if let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
           let caps = obj["capabilities"] as? [String: Any],
           let pe = caps["positionEncoding"] as? String {
            positionEncoding = LSPPositionEncoding(rawValue: pe) ?? .utf16
        }
        try notify(method: "initialized", params: [String: Any]())
        initialized = true
    }

    /// Send `textDocument/didOpen` with file contents from disk.
    /// Idempotent: calling twice on the same URI is allowed by the
    /// PoC (server may complain via `window/logMessage`; we discard).
    public func didOpen(url: URL, languageId: String, text: String, version: Int = 1) throws {
        guard initialized else { throw LSPError.notInitialized }
        let params: [String: Any] = [
            "textDocument": [
                "uri": url.absoluteString,
                "languageId": languageId,
                "version": version,
                "text": text
            ]
        ]
        try notify(method: "textDocument/didOpen", params: params)
    }

    /// Send `textDocument/didChange` with the full new file contents.
    /// We always use Full sync (single change with the entire new
    /// text) — the viewer is read-only so file mutations only come
    /// from the file watcher catching on-disk diffs, which is fine
    /// for full-text replace. The caller must monotonically bump
    /// `version`; sourcekit-lsp drops out-of-order changes.
    public func didChange(url: URL, text: String, version: Int) throws {
        guard initialized else { throw LSPError.notInitialized }
        let params: [String: Any] = [
            "textDocument": [
                "uri": url.absoluteString,
                "version": version
            ],
            "contentChanges": [
                ["text": text]
            ]
        ]
        try notify(method: "textDocument/didChange", params: params)
    }

    public func hover(
        url: URL, line: Int, character: Int,
        token: LSPCancellationToken? = nil
    ) async throws -> LSPHover? {
        guard initialized else { throw LSPError.notInitialized }
        let params: [String: Any] = [
            "textDocument": ["uri": url.absoluteString],
            "position": ["line": line, "character": character]
        ]
        let raw = try await request(
            method: "textDocument/hover", params: params,
            timeout: .seconds(3), token: token)
        return Self.decodeHover(raw)
    }

    public func definition(
        url: URL, line: Int, character: Int,
        token: LSPCancellationToken? = nil
    ) async throws -> [LSPLocation] {
        guard initialized else { throw LSPError.notInitialized }
        let params: [String: Any] = [
            "textDocument": ["uri": url.absoluteString],
            "position": ["line": line, "character": character]
        ]
        let raw = try await request(
            method: "textDocument/definition", params: params,
            timeout: .seconds(5), token: token)
        return Self.decodeDefinition(raw)
    }

    /// `textDocument/references` — returns all locations where the
    /// symbol under the cursor is used. The `includeDeclaration` flag
    /// controls whether the declaration site itself appears in the
    /// results (typically true — users want to see the home base too).
    /// Same polymorphic response shape as `definition`.
    public func references(
        url: URL, line: Int, character: Int,
        includeDeclaration: Bool = true,
        token: LSPCancellationToken? = nil
    ) async throws -> [LSPLocation] {
        guard initialized else { throw LSPError.notInitialized }
        let params: [String: Any] = [
            "textDocument": ["uri": url.absoluteString],
            "position": ["line": line, "character": character],
            "context": ["includeDeclaration": includeDeclaration],
        ]
        let raw = try await request(
            method: "textDocument/references", params: params,
            timeout: .seconds(10), token: token)
        return Self.decodeDefinition(raw)
    }

    /// `textDocument/declaration` — same shape as definition. Useful in
    /// languages that distinguish forward declaration from definition
    /// (C/C++ headers, Swift protocol requirements).
    public func declaration(
        url: URL, line: Int, character: Int,
        token: LSPCancellationToken? = nil
    ) async throws -> [LSPLocation] {
        guard initialized else { throw LSPError.notInitialized }
        let params: [String: Any] = [
            "textDocument": ["uri": url.absoluteString],
            "position": ["line": line, "character": character],
        ]
        let raw = try await request(
            method: "textDocument/declaration", params: params,
            timeout: .seconds(5), token: token)
        return Self.decodeDefinition(raw)
    }

    /// `textDocument/typeDefinition` — jumps to the type of the symbol
    /// under the cursor (vs `definition` which jumps to the symbol
    /// itself). On a variable `let x: Foo`, definition lands on `x`,
    /// typeDefinition lands on `Foo`.
    public func typeDefinition(
        url: URL, line: Int, character: Int,
        token: LSPCancellationToken? = nil
    ) async throws -> [LSPLocation] {
        guard initialized else { throw LSPError.notInitialized }
        let params: [String: Any] = [
            "textDocument": ["uri": url.absoluteString],
            "position": ["line": line, "character": character],
        ]
        let raw = try await request(
            method: "textDocument/typeDefinition", params: params,
            timeout: .seconds(5), token: token)
        return Self.decodeDefinition(raw)
    }

    /// `textDocument/implementation` — for a protocol / interface
    /// method, returns conforming implementations. Multi-result is
    /// the norm (one per conformer).
    public func implementation(
        url: URL, line: Int, character: Int,
        token: LSPCancellationToken? = nil
    ) async throws -> [LSPLocation] {
        guard initialized else { throw LSPError.notInitialized }
        let params: [String: Any] = [
            "textDocument": ["uri": url.absoluteString],
            "position": ["line": line, "character": character],
        ]
        let raw = try await request(
            method: "textDocument/implementation", params: params,
            timeout: .seconds(8), token: token)
        return Self.decodeDefinition(raw)
    }

    /// `workspace/symbol` — server-side fuzzy symbol search across the
    /// entire workspace. Empty query returns the server's notion of
    /// "all symbols" (most servers cap at a few hundred). UI callers
    /// debounce on the input.
    public func workspaceSymbol(
        query: String, token: LSPCancellationToken? = nil
    ) async throws -> [LSPWorkspaceSymbol] {
        guard initialized else { throw LSPError.notInitialized }
        let params: [String: Any] = ["query": query]
        let raw = try await request(
            method: "workspace/symbol", params: params,
            timeout: .seconds(8), token: token)
        return Self.decodeWorkspaceSymbol(raw)
    }

    /// `textDocument/foldingRange` — returns the foldable regions in
    /// `url` as the server understands them (per LSP 3.17 §16.18).
    /// Used by CM6's fold gutter via a `foldService.of(...)` extension
    /// driven through the editor bridge. Servers that don't implement
    /// it return `null`; we normalize to an empty array.
    public func foldingRange(
        url: URL, token: LSPCancellationToken? = nil
    ) async throws -> [LSPFoldingRange] {
        guard initialized else { throw LSPError.notInitialized }
        let params: [String: Any] = [
            "textDocument": ["uri": url.absoluteString]
        ]
        let raw = try await request(
            method: "textDocument/foldingRange", params: params,
            timeout: .seconds(5), token: token)
        return Self.decodeFoldingRange(raw)
    }

    /// `textDocument/documentSymbol` — returns a flat list of document
    /// symbols (hierarchy preserved via `children`). Used by the outline
    /// sidebar. Server may return either `SymbolInformation[]` (legacy)
    /// or `DocumentSymbol[]`; we normalize to the latter.
    public func documentSymbol(
        url: URL, token: LSPCancellationToken? = nil
    ) async throws -> [LSPDocumentSymbol] {
        guard initialized else { throw LSPError.notInitialized }
        let params: [String: Any] = [
            "textDocument": ["uri": url.absoluteString]
        ]
        let raw = try await request(
            method: "textDocument/documentSymbol", params: params,
            timeout: .seconds(5), token: token)
        return Self.decodeDocumentSymbol(raw)
    }

    /// Best-effort graceful shutdown. Caller is responsible for not
    /// using the client afterwards. PoC: send `shutdown`+`exit`, wait
    /// briefly, then SIGTERM if still alive.
    public func shutdown() async {
        if initialized {
            _ = try? await request(method: "shutdown", params: NSNull(), timeout: .seconds(2))
            try? notify(method: "exit", params: NSNull())
        }
        // Reader thread exits when the child's stdout closes (EOF
        // after `process.terminate()` below). We don't need to cancel
        // it explicitly — POSIX `read` doesn't honor Task
        // cancellation and the thread cleans itself up on EOF.
        // Give the child a moment to exit voluntarily.
        try? await Task.sleep(for: .milliseconds(200))
        if process.isRunning {
            process.terminate()
        }
        try? stdinPipe.fileHandleForWriting.close()
    }
}

/// Sendable holder for a weak reference to the actor. The reader
/// `Thread` needs to call back into the actor; capturing the actor
/// directly would extend its lifetime. Holding a weak property on a
/// final class is the canonical way to get a Sendable weak-ref box
/// in Swift 6 strict-concurrency.
final class WeakLSPClientBox: @unchecked Sendable {
    weak var client: LSPClient?
    init(client: LSPClient) { self.client = client }
}

extension LSPClient {

    // MARK: - Decoders (defensive; LSP unions are messy)

    /// `hover.contents` polymorphic decode — see LSPHover doc-comment.
    static func decodeHover(_ data: Data) -> LSPHover? {
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
                as? [String: Any] else {
            return nil
        }
        let rangeDict = obj["range"] as? [String: Any]
        let range = rangeDict.flatMap(parseRange(_:))

        guard let contents = obj["contents"] else { return nil }
        let (text, isMd) = flattenHoverContents(contents)
        if text.isEmpty { return nil }
        return LSPHover(contents: text, isMarkdown: isMd, range: range)
    }

    private static func flattenHoverContents(_ raw: Any) -> (String, Bool) {
        // Case 1: plain string (legacy MarkedString).
        if let s = raw as? String { return (s, false) }
        // Case 2: MarkedString {language, value} — check FIRST because
        // it also has a `value` field that would otherwise fall through
        // to the MarkupContent branch below.
        if let d = raw as? [String: Any],
           let value = d["value"] as? String,
           let lang = d["language"] as? String {
            return ("```\(lang)\n\(value)\n```", true)
        }
        // Case 3: MarkupContent {kind, value}.
        if let d = raw as? [String: Any],
           let value = d["value"] as? String {
            let isMd = (d["kind"] as? String) == "markdown"
            return (value, isMd)
        }
        // Case 4: array of MarkedString | string.
        if let arr = raw as? [Any] {
            let parts = arr.map { flattenHoverContents($0).0 }
            return (parts.joined(separator: "\n\n"), true)
        }
        return ("", false)
    }

    /// `textDocument/definition` polymorphic decode: Location |
    /// Location[] | LocationLink[] | null.
    static func decodeDefinition(_ data: Data) -> [LSPLocation] {
        // `null` → no definition. JSONSerialization gives NSNull.
        guard let any = try? JSONSerialization.jsonObject(
                with: data, options: [.fragmentsAllowed]) else {
            return []
        }
        if any is NSNull { return [] }
        if let dict = any as? [String: Any] {
            return parseLocation(dict).map { [$0] } ?? parseLocationLink(dict).map { [$0] } ?? []
        }
        if let arr = any as? [[String: Any]] {
            return arr.compactMap { parseLocation($0) ?? parseLocationLink($0) }
        }
        return []
    }

    private static func parseLocation(_ d: [String: Any]) -> LSPLocation? {
        guard let uri = d["uri"] as? String,
              let r = d["range"] as? [String: Any],
              let range = parseRange(r) else { return nil }
        return LSPLocation(uri: uri, range: range)
    }

    private static func parseLocationLink(_ d: [String: Any]) -> LSPLocation? {
        guard let uri = d["targetUri"] as? String,
              let r = d["targetSelectionRange"] as? [String: Any]
                      ?? d["targetRange"] as? [String: Any],
              let range = parseRange(r) else { return nil }
        return LSPLocation(uri: uri, range: range)
    }

    private static func parseRange(_ d: [String: Any]) -> LSPRange? {
        guard let s = d["start"] as? [String: Any],
              let e = d["end"] as? [String: Any],
              let sl = s["line"] as? Int, let sc = s["character"] as? Int,
              let el = e["line"] as? Int, let ec = e["character"] as? Int
        else { return nil }
        return LSPRange(
            start: LSPPosition(line: sl, character: sc),
            end:   LSPPosition(line: el, character: ec))
    }

    /// `textDocument/documentSymbol` polymorphic decode:
    ///   - `DocumentSymbol[]` (preferred): has `name`, `kind`, `range`,
    ///     `selectionRange`, optional `children`, optional `detail`.
    ///   - `SymbolInformation[]` (legacy fallback): has `name`, `kind`,
    ///     `location: {uri, range}`, optional `containerName`. We flatten
    ///     these into a single-level list (no `containerName` hierarchy
    ///     rebuild — too lossy and rarely useful for outline display).
    ///   - `null` / `[]`: empty.
    static func decodeDocumentSymbol(_ data: Data) -> [LSPDocumentSymbol] {
        guard let any = try? JSONSerialization.jsonObject(
                with: data, options: [.fragmentsAllowed]) else { return [] }
        if any is NSNull { return [] }
        guard let arr = any as? [[String: Any]] else { return [] }
        // Discriminate by presence of `location` (SymbolInformation) vs
        // `range` (DocumentSymbol).
        return arr.compactMap { parseDocumentSymbol($0) }
    }

    /// `textDocument/foldingRange` decode. Spec says either
    /// `FoldingRange[]` or `null`. Unparseable entries drop silently;
    /// a totally missing / non-array result returns `[]`.
    static func decodeFoldingRange(_ data: Data) -> [LSPFoldingRange] {
        guard let any = try? JSONSerialization.jsonObject(
                with: data, options: [.fragmentsAllowed]) else { return [] }
        if any is NSNull { return [] }
        guard let arr = any as? [[String: Any]] else { return [] }
        var out: [LSPFoldingRange] = []
        out.reserveCapacity(arr.count)
        for d in arr {
            // `startLine` + `endLine` are required per the spec; reject
            // entries that lack them rather than silently substituting
            // zero (would collapse the file's top into a fold).
            guard let s = d["startLine"] as? Int,
                  let e = d["endLine"] as? Int,
                  s >= 0, e >= s else { continue }
            out.append(LSPFoldingRange(
                startLine: s, endLine: e,
                startCharacter: d["startCharacter"] as? Int,
                endCharacter: d["endCharacter"] as? Int,
                kind: d["kind"] as? String
            ))
        }
        return out
    }

    /// `workspace/symbol` decode. Accepts either
    /// `SymbolInformation[]` (legacy) or `WorkspaceSymbol[]` (modern,
    /// with full Location — URI-only stub form is skipped per v1
    /// design note). Returns empty on null / non-array.
    static func decodeWorkspaceSymbol(_ data: Data) -> [LSPWorkspaceSymbol] {
        guard let any = try? JSONSerialization.jsonObject(
                with: data, options: [.fragmentsAllowed]) else { return [] }
        if any is NSNull { return [] }
        guard let arr = any as? [[String: Any]] else { return [] }
        return arr.compactMap { parseWorkspaceSymbol($0) }
    }

    private static func parseWorkspaceSymbol(_ d: [String: Any]) -> LSPWorkspaceSymbol? {
        guard let name = d["name"] as? String else { return nil }
        let kind = (d["kind"] as? Int).flatMap(LSPSymbolKind.init(rawValue:)) ?? .other
        let containerName = d["containerName"] as? String
        // Full Location shape (both SymbolInformation and modern
        // WorkspaceSymbol when the server inlines the location).
        if let loc = d["location"] as? [String: Any],
           let location = parseLocation(loc) {
            return LSPWorkspaceSymbol(
                name: name, kind: kind,
                containerName: containerName, location: location)
        }
        // WorkspaceSymbol with URI-only `location: {uri: ...}` (no
        // range). v1 skips these — they require workspaceSymbol/resolve
        // to fetch the range, which we don't implement yet.
        return nil
    }

    /// `textDocument/publishDiagnostics` diagnostic-list decode.
    /// Caller passes the per-diagnostic dict; we return nil on parse
    /// failure (drop unparseable entries individually rather than
    /// failing the whole notification).
    static func parseDiagnostic(_ d: [String: Any]) -> LSPDiagnostic? {
        guard let rangeDict = d["range"] as? [String: Any],
              let range = parseRange(rangeDict),
              let message = d["message"] as? String else { return nil }
        // Severity defaults to .error per LSP spec when absent.
        let severity: LSPDiagnostic.Severity = {
            if let s = d["severity"] as? Int,
               let parsed = LSPDiagnostic.Severity(rawValue: s) {
                return parsed
            }
            return .error
        }()
        let code: String? = {
            if let s = d["code"] as? String { return s }
            if let n = d["code"] as? Int    { return String(n) }
            return nil
        }()
        let source = d["source"] as? String
        return LSPDiagnostic(
            range: range, severity: severity,
            code: code, source: source, message: message)
    }

    private static func parseDocumentSymbol(_ d: [String: Any]) -> LSPDocumentSymbol? {
        guard let name = d["name"] as? String else { return nil }
        let kind = (d["kind"] as? Int).flatMap(LSPSymbolKind.init(rawValue:)) ?? .other
        let detail = d["detail"] as? String
        // DocumentSymbol shape.
        if let rangeDict = d["range"] as? [String: Any],
           let range = parseRange(rangeDict) {
            let selectionRange = (d["selectionRange"] as? [String: Any])
                .flatMap(parseRange) ?? range
            let children: [LSPDocumentSymbol] = {
                guard let kids = d["children"] as? [[String: Any]] else { return [] }
                return kids.compactMap(parseDocumentSymbol)
            }()
            return LSPDocumentSymbol(
                name: name, detail: detail, kind: kind,
                range: range, selectionRange: selectionRange,
                children: children, uri: nil)
        }
        // SymbolInformation legacy shape.
        if let loc = d["location"] as? [String: Any],
           let uri = loc["uri"] as? String,
           let rangeDict = loc["range"] as? [String: Any],
           let range = parseRange(rangeDict) {
            return LSPDocumentSymbol(
                name: name, detail: detail, kind: kind,
                range: range, selectionRange: range,
                children: [], uri: uri)
        }
        return nil
    }
}
