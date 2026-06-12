import XCTest
import Foundation
@testable import RustCore

/// TSK-664 — the subscription client half against a REAL `mdv-serve`
/// spawned WITH `--root` and `--claude-dir`: pushed events arrive through
/// the reader-thread demux while ordinary calls interleave; unsubscribe
/// silences; the transcript.follow wire-redaction guarantee is observed
/// CLIENT-side; a dying server fails pending calls instead of wedging.
///
/// Self-skips when the binary isn't built; binary-present + handshake
/// failure is a FAILURE (the false-green rule from the loopback suite).
final class RemoteSubscriptionTests: XCTestCase {

    nonisolated(unsafe) private static var server: Process?
    nonisolated(unsafe) private static var socketPath: String = ""
    nonisolated(unsafe) private static var rootDir: URL!
    nonisolated(unsafe) private static var claudeDir: URL!
    nonisolated(unsafe) private static var handshakeFailure: String?
    nonisolated(unsafe) private static var remote: RemoteTransport?

    private static func serveBinary() -> String? {
        if let env = ProcessInfo.processInfo.environment["MDV_SERVE_BIN"],
           FileManager.default.isExecutableFile(atPath: env) {
            return env
        }
        let fallback = "/private/tmp/mdv-rust-target/debug/mdv-serve"
        return FileManager.default.isExecutableFile(atPath: fallback) ? fallback : nil
    }

    override class func setUp() {
        super.setUp()
        guard let bin = serveBinary() else { return }
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-subs-\(UUID().uuidString.prefix(8))", isDirectory: true)
        rootDir = base.appendingPathComponent("root", isDirectory: true)
        claudeDir = base.appendingPathComponent("claude", isDirectory: true)
        let proj = claudeDir.appendingPathComponent("projects/proj-a", isDirectory: true)
        try? FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        try? Data().write(to: proj.appendingPathComponent("s.jsonl"))

        socketPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-subs-\(UUID().uuidString.prefix(8)).sock").path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = [
            "--socket", socketPath,
            "--root", rootDir.path,
            "--claude-dir", claudeDir.path,
        ]
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return }
        server = p
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: socketPath) { break }
            usleep(50_000)
        }
        do {
            remote = try RemoteTransport(socketPath: socketPath)
        } catch {
            handshakeFailure = "\(error)"
        }
    }

    override class func tearDown() {
        remote = nil
        server?.terminate()
        try? FileManager.default.removeItem(atPath: socketPath)
        if let rootDir {
            try? FileManager.default.removeItem(at: rootDir.deletingLastPathComponent())
        }
        super.tearDown()
    }

    private func requireRemote() throws -> RemoteTransport {
        if let failure = Self.handshakeFailure {
            XCTFail("mdv-serve handshake failed (binary exists): \(failure)")
            throw XCTSkip("handshake failed")
        }
        guard let r = Self.remote else {
            throw XCTSkip("mdv-serve binary not built (cargo build -p mdvcore-serve)")
        }
        return r
    }

    /// Thread-safe event collector (handlers run on the reader thread).
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [RemoteEvent] = []
        func append(_ e: RemoteEvent) {
            lock.lock()
            events.append(e)
            lock.unlock()
        }
        func snapshot() -> [RemoteEvent] {
            lock.lock()
            defer { lock.unlock() }
            return events
        }
        func waitFor(
            _ timeout: TimeInterval = 5, _ predicate: ([RemoteEvent]) -> Bool
        ) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if predicate(snapshot()) { return true }
                usleep(20_000)
            }
            return predicate(snapshot())
        }
    }

    private func watchBody(paths: [String], debounceMs: UInt64) -> [UInt8] {
        MsgPackValue.map([
            (.string("paths"), .array(paths.map { .string($0) })),
            (.string("recursive"), .bool(false)),
            (.string("debounce_ms"), .uint(debounceMs)),
        ]).encode()
    }

    func test_fsWatch_eventsArrive_thenUnsubscribeSilences() throws {
        let remote = try requireRemote()
        let sink = Sink()
        let sub = try remote.subscribe(
            "fs.watch", requestBody: watchBody(paths: ["."], debounceMs: 30)
        ) { sink.append($0) }

        let file = Self.rootDir.appendingPathComponent("hello.txt")
        try Data("x".utf8).write(to: file)
        XCTAssertTrue(sink.waitFor { events in
            events.contains { $0.kind == "created" && $0.seq == 1 && $0.sub == sub }
        }, "the created event must be PUSHED to the handler: \(sink.snapshot())")

        try remote.unsubscribe(sub)
        let countAfterUnsub = sink.snapshot().count
        try Data("y".utf8).write(to: Self.rootDir.appendingPathComponent("post.txt"))
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(sink.snapshot().count, countAfterUnsub,
                       "no events may arrive after unsubscribe")
    }

    func test_calls_interleave_with_events_underChurn() throws {
        let remote = try requireRemote()
        let sink = Sink()
        let sub = try remote.subscribe(
            "fs.watch", requestBody: watchBody(paths: ["."], debounceMs: 30)
        ) { sink.append($0) }
        defer { try? remote.unsubscribe(sub) }

        // Interleave: file churn (events) while issuing real calls whose
        // responses must demux correctly past the event frames.
        for i in 0..<10 {
            try Data("v\(i)".utf8).write(
                to: Self.rootDir.appendingPathComponent("churn-\(i).txt"))
            let ranked = try mdvCoreFuzzyRank(query: "fz", candidates: ["fuzzy", "nope"])
            XCTAssertEqual(ranked.first?.index, 0,
                           "call \(i) must return ITS response, not an event frame")
        }
        XCTAssertTrue(sink.waitFor { $0.count >= 1 },
                      "events must flow alongside the calls")
        // Seq is strictly monotonic across everything this sub received.
        let seqs = sink.snapshot().map(\.seq)
        XCTAssertEqual(seqs, seqs.sorted(), "event seq must be monotonic: \(seqs)")
    }

    func test_transcriptFollow_pushedBodies_areRedacted() throws {
        let remote = try requireRemote()
        let sink = Sink()
        let body = MsgPackValue.map([
            (.string("dir"), .string("proj-a")),
            (.string("name"), .string("s.jsonl")),
            (.string("debounce_ms"), .uint(30)),
        ]).encode()
        let sub = try remote.subscribe("transcript.follow", requestBody: body) {
            sink.append($0)
        }
        defer { try? remote.unsubscribe(sub, method: "transcript.unfollow") }

        let line = #"{"uuid":"t1","message":{"role":"assistant","content":[{"type":"tool_use","id":"t","name":"X","input":{"signature":"SECRET-BLOB"}}]}}"# + "\n"
        let file = Self.claudeDir.appendingPathComponent("projects/proj-a/s.jsonl")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line.utf8))
        try handle.close()

        XCTAssertTrue(sink.waitFor { events in events.contains { $0.kind == "events" } },
                      "the parsed batch must arrive: \(sink.snapshot())")
        // MessagePack bodies are binary; string fields embed as UTF-8 runs,
        // so a byte-subsequence scan is the right oracle.
        func contains(_ haystack: [UInt8], _ needle: String) -> Bool {
            let n = Array(needle.utf8)
            guard !n.isEmpty, haystack.count >= n.count else { return false }
            return (0...(haystack.count - n.count)).contains { i in
                Array(haystack[i..<i + n.count]) == n
            }
        }
        // XCTUnwrap, NEVER force-unwrap: under a regression this must FAIL,
        // not crash the runner (a crashed xctest leaves swift-test wedged on
        // a zombie child — observed live during the teeth run).
        let batch = try XCTUnwrap(sink.snapshot().first { $0.kind == "events" })
        XCTAssertTrue(contains(batch.body, "[REDACTED]"),
                      "the redaction marker must be present in the pushed body")
        XCTAssertFalse(contains(batch.body, "SECRET-BLOB"),
                       "the planted secret must NEVER cross the wire")
    }

    // zz-prefixed: kills the SHARED server, so it must sort last in the class.
    func test_zz_serverDeath_failsPendingAndFutureCalls_andFiresOnClose() throws {
        // A dedicated connection so killing the server doesn't break the
        // class-level transport the other tests share.
        _ = try requireRemote()
        let mine = try RemoteTransport(socketPath: Self.socketPath)
        let closed = expectation(description: "onClose fires")
        mine.onClose = { _ in closed.fulfill() }

        // Kill the server, then call: either the write or the slot-wait
        // must fail with a transport error — never a wedge.
        Self.server?.terminate()
        Self.server?.waitUntilExit()
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertThrowsError(try mine.call("ping", requestBody: [0x80])) { error in
            XCTAssertTrue(error is RemoteTransport.RemoteError,
                          "expected a transport error, got \(error)")
        }
        wait(for: [closed], timeout: 5)
    }
}
