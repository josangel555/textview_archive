import XCTest
@testable import ViewerCore

/// Sanity check: the fake server binary actually launches under the
/// same conditions LSPClient uses (env overlay, current-dir tmpdir,
/// pipes for stdio) and responds to one initialize frame within 5s.
/// If this passes but the full `LSPClientFakeServerTests` time out,
/// the bug is in `LSPClient` framing or transport, not the fake.
final class FakeLSPServerLaunchTest: XCTestCase {

    func test_directLaunch_andInitialize_returnsFrameWithin5s() throws {
        let (cfg, root) = try FakeLSPServerHelper.makeConfig()
        defer { FakeLSPServerHelper.cleanup(root) }

        let p = Process()
        p.executableURL = cfg.executable
        p.arguments = cfg.arguments
        p.currentDirectoryURL = cfg.workspaceRoot
        if let env = cfg.environment { p.environment = env }

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = stderr
        try p.run()
        defer { p.terminate() }

        // Capture stderr + stdout asynchronously via readabilityHandlers.
        // Don't use the blocking `read(upToCount:)` on the test thread —
        // that call waits for arbitrary additional bytes even after the
        // response has been delivered (FileHandle doesn't surface
        // "available now" in a non-blocking way without a handler).
        let errCollector = StderrCollector()
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let d = handle.availableData
            if !d.isEmpty { errCollector.append(d) }
        }
        let outCollector = StderrCollector()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let d = handle.availableData
            if !d.isEmpty { outCollector.append(d) }
        }

        // Write framed initialize.
        let body = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#
            .data(using: .utf8)!
        var frame = "Content-Length: \(body.count)\r\n\r\n"
            .data(using: .ascii)!
        frame.append(body)
        try stdin.fileHandleForWriting.write(contentsOf: frame)

        // Poll the collector for the response header (deterministic
        // signal — the response is well-formed when the trailing
        // "\r\n\r\n" of the LSP header arrives).
        let deadline = Date().addingTimeInterval(5)
        var found = false
        while Date() < deadline {
            let snapshot = outCollector.snapshot()
            if snapshot.contains("\r\n\r\n") {
                found = true; break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        // Detach handlers BEFORE we tear down the process — otherwise
        // the test process can race with the readability callback's
        // queue and leak file descriptors.
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil

        let stderrText = errCollector.snapshot()
        let stdoutText = outCollector.snapshot()
        XCTAssertTrue(found,
            "fake server produced no header in 5s. stdout: \(stdoutText) stderr: \(stderrText)")
        XCTAssertTrue(stdoutText.hasPrefix("Content-Length:"),
            "expected Content-Length frame, got \(stdoutText.prefix(40)). stderr: \(stderrText)")
    }
}

/// Thread-safe stderr accumulator. The Pipe `readabilityHandler` fires
/// on a private serial queue (not our test thread) so we lock.
final class StderrCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ d: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(d)
    }
    func snapshot() -> String {
        lock.lock(); defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? "<binary \(data.count) bytes>"
    }
}
