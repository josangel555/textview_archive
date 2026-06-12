import Foundation

// MDVFakeLSPServer — a tiny deterministic LSP server used by host-side
// tests of `LSPClient` and `LSPPool`. Speaks JSON-RPC over stdio using
// LSP's `Content-Length` framing. No sourcekit-lsp dependency: behavior
// is driven by env vars + the file URI so tests can dial in:
//
//   MDV_FAKE_LSP_SCENARIO    Selects the behavior bundle. One of:
//     "normal"     (default)  Standard, fast canned responses.
//     "slow_init"             Sleeps before responding to `initialize`.
//     "crash_after_init"      Exits 1 right after `initialized`.
//     "garbled_after_init"    Writes garbage bytes after `initialized`
//                             so the framing decoder errors out.
//     "fail_initialize"       Returns a JSON-RPC error to `initialize`.
//     "encoding_utf8"         Negotiates `utf-8` instead of `utf-16`.
//
//   MDV_FAKE_LSP_HOVER_DELAY_MS    Per-hover artificial delay.
//   MDV_FAKE_LSP_PUBLISH_DIAGNOSTICS=1   Push a publishDiagnostics with
//                                        one .error diagnostic on `initialized`.
//   MDV_FAKE_LSP_SHUTDOWN_DELAY_MS Artificial delay (ms) *inside* the
//                                  `shutdown` request handler, before the
//                                  response is written. Used to make the
//                                  pool's concurrent-vs-sequential teardown
//                                  observable (LSPPool.closeAll test).
//   MDV_FAKE_LSP_SHUTDOWN_LOG      Path to a shared file each server appends
//                                  "START"/"END" markers to (bracketing the
//                                  shutdown delay) via a single atomic
//                                  O_APPEND write — so a test can prove the
//                                  shutdowns overlapped by line ORDER, not
//                                  wall-clock.
//
// Canned response shapes are kept in lockstep with `LSPClient`'s
// decoders (`decodeHover`, `decodeDefinition`, `decodeDocumentSymbol`,
// `decodeFoldingRange`, `decodeWorkspaceSymbol`, `parseDiagnostic`).
// We don't try to fake "interesting" coordinates — tests prove the
// wire path closes and the structured value reaches the caller; the
// decoders themselves are exhaustively tested by LSPProtocolDecodeTests
// etc. with literal JSON inputs.

// Single-threaded by construction: `run()` is called once from
// top-level main and never spawns work. We mark @unchecked Sendable
// only so it satisfies actor-isolation requirements when accessed via
// the global runner closure below.
final class FakeServer: @unchecked Sendable {

    let scenario: String
    let hoverDelayMs: Int
    let pushDiags: Bool
    let shutdownDelayMs: Int
    let shutdownLogPath: String?
    var buffer = Data()
    var shouldExit = false

    init() {
        let env = ProcessInfo.processInfo.environment
        self.scenario = env["MDV_FAKE_LSP_SCENARIO"] ?? "normal"
        self.hoverDelayMs = Int(env["MDV_FAKE_LSP_HOVER_DELAY_MS"] ?? "0") ?? 0
        self.pushDiags = env["MDV_FAKE_LSP_PUBLISH_DIAGNOSTICS"] == "1"
        self.shutdownDelayMs = Int(env["MDV_FAKE_LSP_SHUTDOWN_DELAY_MS"] ?? "0") ?? 0
        self.shutdownLogPath = env["MDV_FAKE_LSP_SHUTDOWN_LOG"]
    }

    /// Append a short marker line to the shared shutdown log (if one is
    /// configured) with a single `O_APPEND` `write(2)`. POSIX guarantees
    /// append-mode writes below `PIPE_BUF` are atomic across processes, so
    /// concurrent fake-server children interleave whole lines rather than
    /// shredding each other's bytes. Best-effort: any failure is silently
    /// dropped (the marker log is a test-only diagnostic).
    func appendShutdownMarker(_ token: String) {
        guard let path = shutdownLogPath else { return }
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        if fd < 0 { return }
        let bytes = Array("\(token)\n".utf8)
        _ = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
        close(fd)
    }

    // MARK: - Framing

    func writeFramed(_ body: Data) {
        let header = "Content-Length: \(body.count)\r\n\r\n"
        var out = Data(header.utf8)
        out.append(body)
        FileHandle.standardOutput.write(out)
    }

    func writeJSON(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: obj, options: [.fragmentsAllowed]) else { return }
        writeFramed(data)
    }

    // MARK: - Response builders

    func canonicalRange() -> [String: Any] {
        return [
            "start": ["line": 0, "character": 0] as [String: Any],
            "end":   ["line": 0, "character": 1] as [String: Any]
        ]
    }

    func locationDict(uri: String) -> [String: Any] {
        return ["uri": uri, "range": canonicalRange()] as [String: Any]
    }

    func hoverResult(line: Int, character: Int) -> [String: Any] {
        return [
            "contents": [
                "kind": "markdown",
                "value": "**fake**\nhover at \(line):\(character)"
            ] as [String: Any],
            "range": canonicalRange()
        ] as [String: Any]
    }

    func documentSymbolResult() -> [Any] {
        let child: [String: Any] = [
            "name": "Child", "kind": 13,
            "range": canonicalRange(),
            "selectionRange": canonicalRange()
        ]
        let root: [String: Any] = [
            "name": "RootSym", "kind": 5, "detail": "struct",
            "range": canonicalRange(),
            "selectionRange": canonicalRange(),
            "children": [child]
        ]
        return [root]
    }

    func foldingRangeResult() -> [Any] {
        return [
            ["startLine": 1, "endLine": 3, "kind": "region"] as [String: Any]
        ]
    }

    func workspaceSymbolResult(query: String, fileURI: String) -> [Any] {
        return [
            [
                "name": query.isEmpty ? "FakeSym" : query,
                "kind": 12,
                "containerName": "FakeModule",
                "location": locationDict(uri: fileURI)
            ] as [String: Any]
        ]
    }

    func paramFileURI(_ params: Any) -> String {
        if let d = params as? [String: Any],
           let td = d["textDocument"] as? [String: Any],
           let uri = td["uri"] as? String {
            return uri
        }
        return "file:///fake"
    }

    func responseEnvelope(id: Any, result: Any) -> [String: Any] {
        return ["jsonrpc": "2.0", "id": id, "result": result]
    }

    func errorEnvelope(id: Any, code: Int, message: String) -> [String: Any] {
        return [
            "jsonrpc": "2.0", "id": id,
            "error": ["code": code, "message": message] as [String: Any]
        ]
    }

    // MARK: - Dispatch

    func handle(message obj: [String: Any]) {
        let method = obj["method"] as? String
        let id = obj["id"]
        let params = obj["params"] ?? [:]

        // Notification: no id.
        if id == nil, let method = method {
            switch method {
            case "initialized":
                if scenario == "crash_after_init" {
                    exit(1)
                }
                if scenario == "garbled_after_init" {
                    FileHandle.standardOutput.write(Data("not-a-valid-lsp-frame\n".utf8))
                    FileHandle.standardOutput.write(Data("XXX".utf8))
                    exit(0)
                }
                if pushDiags {
                    let uri = "file:///fake/published.swift"
                    let diag: [String: Any] = [
                        "range": canonicalRange(),
                        "severity": 1, "code": "FAKE001",
                        "source": "mdv-fake", "message": "fake diagnostic"
                    ]
                    writeJSON([
                        "jsonrpc": "2.0",
                        "method": "textDocument/publishDiagnostics",
                        "params": [
                            "uri": uri, "diagnostics": [diag]
                        ] as [String: Any]
                    ])
                }
            case "textDocument/didSave":
                // notify_on_save: echo receipt as a publishDiagnostics so a
                // host test can prove the (response-less) didSave notification
                // was sent + its params parsed. The diagnostic carries the
                // saved file's URI, so the test asserts the round-trip.
                if scenario == "notify_on_save",
                   let p = params as? [String: Any],
                   let td = p["textDocument"] as? [String: Any],
                   let uri = td["uri"] as? String {
                    let diag: [String: Any] = [
                        "range": canonicalRange(),
                        "severity": 1, "code": "SAVED001",
                        "source": "mdv-fake", "message": "didSave received"
                    ]
                    writeJSON([
                        "jsonrpc": "2.0",
                        "method": "textDocument/publishDiagnostics",
                        "params": ["uri": uri, "diagnostics": [diag]] as [String: Any]
                    ])
                }
            case "exit":
                shouldExit = true
            default:
                // didOpen/didChange/didClose/$/cancelRequest — drop silently.
                break
            }
            return
        }

        guard let id = id, let method = method else { return }

        // Requests.
        switch method {
        case "initialize":
            if scenario == "fail_initialize" {
                writeJSON(errorEnvelope(id: id, code: -32603,
                                        message: "fake init failure"))
                return
            }
            if scenario == "slow_init" {
                Thread.sleep(forTimeInterval: 0.5)
            }
            let posEncoding: String = (scenario == "encoding_utf8") ? "utf-8" : "utf-16"
            let caps: [String: Any] = [
                "positionEncoding": posEncoding,
                "textDocumentSync": 1,
                "hoverProvider": true,
                "definitionProvider": true,
                "referencesProvider": true,
                "declarationProvider": true,
                "typeDefinitionProvider": true,
                "implementationProvider": true,
                "documentSymbolProvider": true,
                "renameProvider": true,
                "foldingRangeProvider": true,
                "workspaceSymbolProvider": true
            ]
            writeJSON(responseEnvelope(
                id: id,
                result: [
                    "capabilities": caps,
                    "serverInfo": ["name": "MDVFakeLSPServer", "version": "0.1"]
                        as [String: Any]
                ] as [String: Any]))

        case "shutdown":
            // Optional artificial delay, bracketed by START/END markers,
            // so a test can prove `LSPPool.closeAll()` shut servers down
            // concurrently (all STARTs precede the first END) vs
            // sequentially (START/END interleave). `LSPClient.shutdown()`
            // awaits this response, so the delay lands on the awaited path.
            if shutdownDelayMs > 0 {
                appendShutdownMarker("START")
                Thread.sleep(forTimeInterval: Double(shutdownDelayMs) / 1000.0)
                appendShutdownMarker("END")
            }
            writeJSON(responseEnvelope(id: id, result: NSNull()))

        case "textDocument/hover":
            if hoverDelayMs > 0 {
                Thread.sleep(forTimeInterval: Double(hoverDelayMs) / 1000.0)
            }
            let p = params as? [String: Any] ?? [:]
            let pos = p["position"] as? [String: Any] ?? [:]
            let line = pos["line"] as? Int ?? 0
            let character = pos["character"] as? Int ?? 0
            writeJSON(responseEnvelope(
                id: id, result: hoverResult(line: line, character: character)))

        case "textDocument/definition":
            writeJSON(responseEnvelope(
                id: id, result: locationDict(uri: paramFileURI(params))))

        case "textDocument/references":
            let uri = paramFileURI(params)
            writeJSON(responseEnvelope(
                id: id, result: [locationDict(uri: uri), locationDict(uri: uri)]))

        case "textDocument/declaration":
            writeJSON(responseEnvelope(
                id: id, result: locationDict(uri: paramFileURI(params))))

        case "textDocument/typeDefinition":
            writeJSON(responseEnvelope(
                id: id, result: locationDict(uri: paramFileURI(params))))

        case "textDocument/implementation":
            let uri = paramFileURI(params)
            writeJSON(responseEnvelope(
                id: id, result: [locationDict(uri: uri), locationDict(uri: uri)]))

        case "textDocument/formatting":
            // Canned, deterministic edit set (TSK-627): replace the first
            // three UTF-16 units of line 0 with "FMT" and insert a header
            // line at the very top. Two edits so the client's reverse-order
            // application is exercised, not just a single replace.
            writeJSON(responseEnvelope(id: id, result: [
                [
                    "range": [
                        "start": ["line": 0, "character": 0],
                        "end": ["line": 0, "character": 3],
                    ],
                    "newText": "FMT",
                ],
                [
                    "range": [
                        "start": ["line": 0, "character": 0],
                        "end": ["line": 0, "character": 0],
                    ],
                    "newText": "// formatted\n",
                ],
            ]))

        case "textDocument/documentSymbol":
            writeJSON(responseEnvelope(id: id, result: documentSymbolResult()))

        case "textDocument/foldingRange":
            writeJSON(responseEnvelope(id: id, result: foldingRangeResult()))

        case "textDocument/rename":
            // Deterministic fixture: rename the 3-char symbol at the given
            // position in the SAME file, twice (lines 0 and 2), exercising
            // the multi-edit + reverse-application path client-side.
            let p = params as? [String: Any] ?? [:]
            let td = p["textDocument"] as? [String: Any] ?? [:]
            let uri = td["uri"] as? String ?? "file:///fake.swift"
            let newName = p["newName"] as? String ?? "renamed"
            writeJSON(responseEnvelope(id: id, result: [
                "changes": [
                    uri: [
                        ["range": ["start": ["line": 0, "character": 4],
                                   "end": ["line": 0, "character": 7]],
                         "newText": newName],
                        ["range": ["start": ["line": 2, "character": 8],
                                   "end": ["line": 2, "character": 11]],
                         "newText": newName],
                    ],
                ],
            ]))

        case "workspace/symbol":
            let p = params as? [String: Any] ?? [:]
            let q = p["query"] as? String ?? ""
            writeJSON(responseEnvelope(
                id: id, result: workspaceSymbolResult(
                    query: q, fileURI: "file:///fake/sym.swift")))

        default:
            writeJSON(errorEnvelope(id: id, code: -32601,
                                    message: "no \(method)"))
        }
    }

    // MARK: - Reader

    func tryDecodeOne() -> Data? {
        // Re-base the buffer to a fresh `Data` value so all index
        // arithmetic below works from 0 regardless of internal
        // slice offsets (the previous `removeFirst` may leave the
        // buffer's startIndex >0 internally).
        let buf = Data(buffer)
        guard buf.count >= 4 else { return nil }
        let bytes = [UInt8](buf)
        var hdrEnd: Int = -1
        let limit = bytes.count - 4
        var i = 0
        while i <= limit {
            if bytes[i] == 0x0D, bytes[i+1] == 0x0A,
               bytes[i+2] == 0x0D, bytes[i+3] == 0x0A {
                hdrEnd = i
                break
            }
            i += 1
        }
        if hdrEnd < 0 { return nil }
        let headerEnd = hdrEnd
        let headerBytes = Array(bytes.prefix(headerEnd))
        guard let hdrStr = String(bytes: headerBytes, encoding: .ascii)
        else { return nil }
        var contentLength: Int?
        for line in hdrStr.components(separatedBy: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                let v = line.dropFirst("content-length:".count)
                    .trimmingCharacters(in: .whitespaces)
                contentLength = Int(v)
            }
        }
        guard let n = contentLength else { return nil }
        let bodyStart = headerEnd + 4
        let needed = bodyStart + n
        if bytes.count < needed { return nil }
        let body = Data(bytes[bodyStart..<needed])
        // Remove the consumed bytes by rebuilding from `bytes`.
        buffer = Data(bytes.suffix(from: needed))
        return body
    }

    func run() {
        // Use blocking POSIX read on fd 0. `FileHandle.availableData`
        // can return empty data on signals or non-blocking pipes;
        // POSIX `read()` blocks until either data arrives or true EOF
        // (return value 0). This is what we want — a tight, deterministic
        // server loop driven entirely by the parent over stdin.
        let fd: Int32 = 0
        let bufSize = 8 * 1024
        var scratch = [UInt8](repeating: 0, count: bufSize)
        FileHandle.standardError.write(Data("FakeServer ready scenario=\(scenario)\n".utf8))
        while !shouldExit {
            let n = scratch.withUnsafeMutableBufferPointer { ptr -> Int in
                return read(fd, ptr.baseAddress, bufSize)
            }
            if n <= 0 {
                // 0 = EOF; <0 = error. Either way we exit.
                break
            }
            buffer.append(scratch, count: n)
            while let body = tryDecodeOne() {
                guard let obj = try? JSONSerialization.jsonObject(
                        with: body, options: [.fragmentsAllowed]) as? [String: Any]
                else { continue }
                handle(message: obj)
                if shouldExit { break }
            }
        }
    }
}

FakeServer().run()
