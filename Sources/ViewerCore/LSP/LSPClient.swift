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
        public init(executable: URL, arguments: [String] = [], workspaceRoot: URL) {
            self.executable = executable
            self.arguments = arguments
            self.workspaceRoot = workspaceRoot
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
    private var initialized = false
    private var readerTask: Task<Void, Never>?

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

        // stderr drain — without this the child blocks at ~64 KB
        // (kernel pipe buffer). We intentionally discard; a real
        // implementation would surface in a diagnostics panel.
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
    }

    /// Kick off the background stdout reader. Must run on the actor;
    /// caller invokes from `initialize()`.
    private func startReader() {
        let handle = stdoutPipe.fileHandleForReading
        // Capture only what's needed by the detached reader. We cannot
        // reach back into actor state from the read closure directly;
        // we hop back via `Task { await self.dispatch(...) }`.
        readerTask = Task.detached { [weak self] in
            var buffer = Data()
            while !Task.isCancelled {
                let chunk: Data
                do {
                    chunk = try handle.read(upToCount: 8 * 1024) ?? Data()
                } catch {
                    await self?.failAllPending(LSPError.transportClosed)
                    return
                }
                if chunk.isEmpty {
                    // EOF — server exited
                    await self?.failAllPending(LSPError.transportClosed)
                    return
                }
                buffer.append(chunk)
                // Drain as many complete frames as we can.
                while true {
                    let step: LSPFraming.DecodeStep
                    do {
                        step = try LSPFraming.decode(buffer)
                    } catch {
                        await self?.failAllPending(error)
                        return
                    }
                    switch step {
                    case .needMore:
                        break
                    case .message(let body, let consumed):
                        buffer.removeFirst(consumed)
                        await self?.dispatchInbound(body)
                        continue
                    }
                    break
                }
            }
        }
    }

    private func failAllPending(_ error: Error) {
        for (_, cont) in pending {
            cont.resume(throwing: error)
        }
        pending.removeAll()
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
        // Server-originated request or notification. PoC: log-and-drop.
        // sourcekit-lsp does send `window/logMessage` and similar; we
        // discard them. A real impl would route to a diagnostics sink.
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
    private func request(
        method: String, params: Any, timeout: Duration
    ) async throws -> Data {
        let id = nextID
        nextID &+= 1
        let envelope: [String: Any] = [
            "jsonrpc": "2.0", "id": id, "method": method, "params": params
        ]
        let body = try JSONSerialization.data(withJSONObject: envelope, options: [])
        let framed = LSPFraming.frame(body)

        // Arm the timeout, then await the continuation. The timeout
        // task pokes back into the actor via `timeoutFire(id:method:)`,
        // which resumes the pending continuation with an error if it's
        // still alive. Late responses are silently discarded because the
        // pending entry is gone by then.
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.timeoutFire(id: id, method: method)
        }
        defer { timeoutTask.cancel() }

        return try await withCheckedThrowingContinuation { cont in
            self.pending[id] = cont
            do {
                try self.stdinPipe.fileHandleForWriting.write(contentsOf: framed)
            } catch {
                self.pending.removeValue(forKey: id)
                cont.resume(throwing: LSPError.transportClosed)
            }
        }
    }

    /// Invoked from the timeout `Task` once the deadline elapses. If
    /// the continuation is still pending, resume it with a timeout
    /// error and forget the entry.
    private func timeoutFire(id: Int64, method: String) {
        guard let cont = pending.removeValue(forKey: id) else { return }
        cont.resume(throwing: LSPError.timeout(method: method))
    }

    /// Fire-and-forget notification (no `id`, no response expected).
    private func notify(method: String, params: Any) throws {
        let envelope: [String: Any] = [
            "jsonrpc": "2.0", "method": method, "params": params
        ]
        let body = try JSONSerialization.data(withJSONObject: envelope, options: [])
        let framed = LSPFraming.frame(body)
        try stdinPipe.fileHandleForWriting.write(contentsOf: framed)
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
                    "positionEncodings": ["utf-16"]
                ]
            ],
            "trace": "off"
        ]
        _ = try await request(method: "initialize", params: params, timeout: .seconds(30))
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

    public func hover(url: URL, line: Int, character: Int) async throws -> LSPHover? {
        guard initialized else { throw LSPError.notInitialized }
        let params: [String: Any] = [
            "textDocument": ["uri": url.absoluteString],
            "position": ["line": line, "character": character]
        ]
        let raw = try await request(
            method: "textDocument/hover", params: params, timeout: .seconds(3))
        return Self.decodeHover(raw)
    }

    public func definition(url: URL, line: Int, character: Int) async throws -> [LSPLocation] {
        guard initialized else { throw LSPError.notInitialized }
        let params: [String: Any] = [
            "textDocument": ["uri": url.absoluteString],
            "position": ["line": line, "character": character]
        ]
        let raw = try await request(
            method: "textDocument/definition", params: params, timeout: .seconds(5))
        return Self.decodeDefinition(raw)
    }

    /// Best-effort graceful shutdown. Caller is responsible for not
    /// using the client afterwards. PoC: send `shutdown`+`exit`, wait
    /// briefly, then SIGTERM if still alive.
    public func shutdown() async {
        if initialized {
            _ = try? await request(method: "shutdown", params: NSNull(), timeout: .seconds(2))
            try? notify(method: "exit", params: NSNull())
        }
        readerTask?.cancel()
        // Give the child a moment to exit voluntarily.
        try? await Task.sleep(for: .milliseconds(200))
        if process.isRunning {
            process.terminate()
        }
        try? stdinPipe.fileHandleForWriting.close()
    }

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
}
