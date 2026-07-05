import XCTest
@testable import ViewerCore

/// TSK-1544 — MCP into the running app: the socket listener + stdio bridge.
/// Host-testable end-to-end over a real unix socket with the same
/// FakeAutomationHost the stdio-server tests use; no app, no VM.
///
/// Concurrency shape: the class is @MainActor (the host + listener are
/// constructed here), but ALL blocking socket I/O runs on background
/// threads behind expectations — `wait(for:)` pumps the main run loop, so
/// the server's per-request MainActor hop can execute while the test waits.
/// Blocking a read on the main thread instead would starve that hop into
/// its 20 s deadline (the exact wedge `MCPServer.runOnMainActor` documents).
@MainActor
final class MCPSocketListenerTests: XCTestCase {

    private var listener: MCPSocketListener!
    private var path: String!

    override func setUp() {
        super.setUp()
        // Short name — sun_path is capped at 104 bytes and the per-user
        // temp dir is already long-ish.
        path = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-\(UInt32.random(in: 0..<UInt32.max)).sock").path
    }

    override func tearDown() {
        listener?.stop()
        listener = nil
        super.tearDown()
    }

    private func startListener() throws {
        listener = MCPSocketListener(host: FakeAutomationHost(), path: path)
        try listener.start()
    }

    func test_initialize_and_toolsList_roundTrip_overTheSocket() throws {
        try startListener()
        let sockPath = path!
        let done = expectation(description: "client round-trip")
        // Single-writer cell: written once on the client thread before
        // fulfill(), read once after wait() — ordered by the expectation.
        nonisolated(unsafe) var results: [String] = []

        Thread.detachNewThread {
            guard let conn = MCPSocketBridge.connect(path: sockPath) else {
                results = ["CONNECT-FAILED"]; done.fulfill(); return
            }
            func send(_ json: String) {
                try? conn.write(contentsOf: MCPFraming.encode(body: Data(json.utf8)))
            }
            func readBody() -> String {
                var reader = MCPFraming.FileHandleReader(conn)
                guard let body = try? MCPFraming.decode(from: &reader)
                else { return "READ-FAILED" }
                return String(decoding: body, as: UTF8.self)
            }
            send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}"#)
            let initReply = readBody()
            send(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
            let toolsReply = readBody()
            results = [initReply, toolsReply]
            try? conn.close()
            done.fulfill()
        }

        wait(for: [done], timeout: 15)
        XCTAssertEqual(results.count, 2, "client thread failed: \(results)")
        XCTAssertTrue(results[0].contains("\"TextView\""),
                      "initialize must answer with serverInfo over the socket; got \(results[0].prefix(200))")
        XCTAssertTrue(results[1].contains("canvas_apply"),
                      "tools/list on the SAME connection must expose the full catalog")
    }

    func test_socketNode_isOwnerOnly_0600() throws {
        try startListener()
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        XCTAssertEqual(perms & 0o777, 0o600,
                       "the MCP socket must be same-user only")
    }

    func test_staleSocketNode_isReplacedOnStart() throws {
        // A leftover node from a crashed predecessor must not block startup.
        FileManager.default.createFile(atPath: path, contents: Data())
        try startListener()
        let conn = MCPSocketBridge.connect(path: path)
        XCTAssertNotNil(conn, "listener must bind over a stale node")
        try? conn?.close()
    }

    func test_stop_unlinksTheNode_andRefusesNewConnections() throws {
        try startListener()
        listener.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path),
                       "stop() must unlink the socket node")
        XCTAssertNil(MCPSocketBridge.connect(path: path))
    }

    func test_bridgeConnect_returnsNil_whenNothingListens() {
        XCTAssertNil(MCPSocketBridge.connect(path: path))
    }

    // MARK: - The bridge pump

    /// The pump through the REAL path: listener up, `connect()` dials it,
    /// `pump()` bridges a pair of local pipes (standing in for the bridge
    /// process's stdio) to the socket — a framed `initialize` written into
    /// the "stdin" side must come back framed on the "stdout" side, served
    /// by the real MCPServer on the other end. Closing "stdin" winds the
    /// pump down (the exact `--mcp-connect` lifecycle).
    func test_bridgePump_endToEnd_throughTheListener() throws {
        try startListener()
        let sockPath = path!

        let stdinPipe = Pipe()    // test → bridge "stdin"
        let stdoutPipe = Pipe()   // bridge "stdout" → test

        let pumpDone = expectation(description: "pump returned")
        Thread.detachNewThread {
            guard let remote = MCPSocketBridge.connect(path: sockPath) else {
                pumpDone.fulfill(); return
            }
            MCPSocketBridge.pump(localIn: stdinPipe.fileHandleForReading,
                                 localOut: stdoutPipe.fileHandleForWriting,
                                 remote: remote)
            pumpDone.fulfill()
        }

        let replyDone = expectation(description: "framed reply arrived")
        nonisolated(unsafe) var reply = ""
        Thread.detachNewThread {
            try? stdinPipe.fileHandleForWriting.write(contentsOf: MCPFraming.encode(
                body: Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}"#.utf8)))
            var reader = MCPFraming.FileHandleReader(stdoutPipe.fileHandleForReading)
            if let body = try? MCPFraming.decode(from: &reader) {
                reply = String(decoding: body, as: UTF8.self)
            }
            // stdin EOF ⇒ the pump winds down end-to-end.
            try? stdinPipe.fileHandleForWriting.close()
            replyDone.fulfill()
        }

        wait(for: [replyDone, pumpDone], timeout: 15)
        XCTAssertTrue(reply.contains("\"TextView\""),
                      "initialize must round-trip stdio→pump→socket→server; got \(reply.prefix(200))")
    }
}
