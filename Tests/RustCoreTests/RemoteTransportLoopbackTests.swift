import XCTest
@testable import RustCore

/// THE TSK-652 acceptance: the engine surface, byte-equal over a LOOPBACK
/// `mdv-serve` (unix socket) vs the in-process FFI — remote is a carrier
/// swap. Spawns the real server binary (env `MDV_SERVE_BIN`, falling back
/// to the workspace target dir); self-skips when the binary isn't built so
/// hosts without a Rust toolchain (the VM) stay green.
final class RemoteTransportLoopbackTests: XCTestCase {

    // Class-setUp populated, read-only afterwards; XCTest serializes the
    // class lifecycle so the unprotected statics are race-free in practice.
    nonisolated(unsafe) private static var server: Process?
    nonisolated(unsafe) private static var socketPath = ""
    nonisolated(unsafe) private static var remote: RemoteTransport?
    /// Set when the binary EXISTS but dial/hello failed — that's a FAILURE,
    /// never a skip (a broken transport must not silently skip the suite).
    nonisolated(unsafe) private static var handshakeFailure: String?

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
        socketPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-serve-\(UUID().uuidString.prefix(8)).sock").path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["--socket", socketPath]
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return }
        server = p
        // Wait for the socket to appear (bind is fast; cap at 5 s).
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
        CoreTransportRegistry.resetToInProcess()
        server?.terminate()
        try? FileManager.default.removeItem(atPath: socketPath)
        super.tearDown()
    }

    override func tearDown() {
        CoreTransportRegistry.resetToInProcess()
        super.tearDown()
    }

    private func requireRemote() throws -> RemoteTransport {
        if let failure = Self.handshakeFailure {
            XCTFail("mdv-serve handshake failed (binary exists — this is a transport bug, not an environment gap): \(failure)")
            throw XCTSkip("handshake failed — see the failure above")
        }
        guard let r = Self.remote else {
            throw XCTSkip("mdv-serve binary not built (cargo build -p mdvcore-serve)")
        }
        return r
    }

    func test_hello_advertisesEngineMaskPlusServerOnlyFamilies() throws {
        let remote = try requireRemote()
        let engineMask = CoreABI.capabilities.rawValue
        XCTAssertEqual(remote.capabilities & engineMask, engineMask,
                       "the server must advertise every engine family the staticlib has")
        // This spawn has no --root: the only server-only bit is
        // transcript.list (fs/git need a served root).
        XCTAssertEqual(remote.capabilities & ~engineMask,
                       CoreCapabilities.transcriptList.rawValue,
                       "unexpected server-only bits for a root-less spawn")
        // indent_detect now rides the wire (TSK-651) — its bit is part of the
        // engine mask, so the server must advertise it.
        XCTAssertNotEqual(remote.capabilities & CoreCapabilities.indent.rawValue, 0,
                          "indent_detect must be advertised once served over the wire")
    }

    /// Every stateless wrapper, byte-equal local vs remote — the carrier-swap
    /// proof. Each wrapper runs against the in-process default, then against
    /// the loopback server, and the decoded results must match exactly.
    func test_engineSurface_byteEqual_localVsRemote() throws {
        let remote = try requireRemote()

        func both<T: Equatable>(_ label: String, _ call: () throws -> T) throws {
            CoreTransportRegistry.resetToInProcess()
            let local = try call()
            CoreTransportRegistry.current = remote
            let remoteResult = try call()
            CoreTransportRegistry.resetToInProcess()
            XCTAssertEqual(local, remoteResult, "\(label) diverged local vs remote")
        }

        try both("fuzzy_rank") {
            try mdvCoreFuzzyRank(query: "fz", candidates: ["fuzzy", "fz-a", "nope"])
                .map { "\($0.index):\($0.score):\($0.matchedIndices)" }
        }
        try both("find_search") {
            try mdvCoreFindSearch(text: "a hello\r\nb hello", pattern: "hello",
                                  kind: "literal", caseSensitive: false, wholeWord: false)
        }
        try both("transcript_parse") {
            try mdvCoreTranscriptParse(
                text: #"{"uuid":"u1","timestamp":"2026-06-12T03:14:15.926Z","message":{"role":"user","content":"hi"}}"# + "\n",
                redacting: true)
        }
        try both("markdown_render") {
            try mdvCoreMarkdownRender(text: "# T\n\n```mermaid\nA-->B\n```\n\na <b>b</b>")
        }
        try both("diff_hunk_marks") {
            try mdvCoreDiffHunkMarks(text: "diff --git a/f b/f\n@@ -1 +1 @@\n-a\n+b\n")
        }
        try both("cm_apply") {
            try mdvCoreApplyCMEdits(base: "hello", edits: [(from: 5, to: 5, insert: " world")])
        }
        try both("diff_parse") {
            try mdvCoreParseDiff(text: "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1 +1 @@\n-a\n+b\n")
        }
        try both("highlight_runs") {
            try mdvCoreHighlightRuns(text: "fn main() { let x = 7; } // é😀", lang: "rust")
        }
        // TSK-651: the first AUX-bearing method on the wire. The source text
        // rides the envelope `a` (aux) key; {sample_lines} rides `b`. If the
        // server dropped aux, detect would see empty text → "—" ≠ "Spaces (4)",
        // so the byte-equality below has teeth on the aux carrier.
        try both("indent_detect:spaces") {
            try mdvCoreIndentDetect(text: "    a\n    b\n      c\n")
        }
        try both("indent_detect:tabs") {
            try mdvCoreIndentDetect(text: "\tx\n\ty\n")
        }
        try both("indent_detect:none") {
            try mdvCoreIndentDetect(text: "no indentation here\nstill none\n")
        }
        try both("highlight_runs:unsupported") {
            // The in-band supported:false (nil) signal must survive the wire.
            // "plain" is the forever-unsupported host rawValue (stage 3
            // closed the real language gaps).
            try mdvCoreHighlightRuns(text: "anything", lang: "plain") == nil
        }
    }

    func test_remoteTypedErrors_mapToCoreError() throws {
        let remote = try requireRemote()
        CoreTransportRegistry.current = remote
        defer { CoreTransportRegistry.resetToInProcess() }
        // invalid_pattern must survive the wire as the TYPED error (the
        // adapters' ICU-fallback channel depends on it).
        XCTAssertThrowsError(
            try mdvCoreFindSearch(text: "x", pattern: "(unclosed", kind: "regex",
                                  caseSensitive: false, wholeWord: false)
        ) { error in
            guard case CoreError.invalidPattern = error else {
                return XCTFail("expected .invalidPattern over the wire, got \(error)")
            }
        }
    }

    func test_wireBoundary_redactionForced_evenWhenClientAsksOff() throws {
        // TSK-658: nothing unredacted leaves the server. A redacting:false
        // request over the WIRE must still come back scrubbed (the same call
        // in-process honors the flag — the trust boundary is the socket).
        let remote = try requireRemote()
        let log = #"{"uuid":"a","message":{"role":"assistant","content":[{"type":"tool_use","id":"t","name":"X","input":{"signature":"SECRET-BLOB"}}]}}"# + "\n"
        CoreTransportRegistry.current = remote
        defer { CoreTransportRegistry.resetToInProcess() }
        let events = try mdvCoreTranscriptParse(text: log, redacting: false)
        guard case let .toolUse(_, _, input)? = events.first?.kind else {
            return XCTFail("expected a tool_use event")
        }
        XCTAssertEqual(input["signature"], "[REDACTED]",
                       "the wire must force redaction regardless of the flag")
        // Sanity: the SAME request in-process honors the caller's choice.
        CoreTransportRegistry.resetToInProcess()
        let local = try mdvCoreTranscriptParse(text: log, redacting: false)
        guard case let .toolUse(_, _, localInput)? = local.first?.kind else {
            return XCTFail("expected a tool_use event locally")
        }
        XCTAssertEqual(localInput["signature"], "SECRET-BLOB")
    }

    func test_unknownMethod_surfacesAsTypedDecodeFault() throws {
        let remote = try requireRemote()
        XCTAssertThrowsError(try remote.call("no.such.method", requestBody: [0x80])) { error in
            guard case CoreError.decode(let msg)? = error as? CoreError else {
                return XCTFail("expected decode fault, got \(error)")
            }
            XCTAssertTrue(msg.contains("unknown_method"))
        }
    }
}
