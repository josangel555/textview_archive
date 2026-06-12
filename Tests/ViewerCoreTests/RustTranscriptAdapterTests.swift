import XCTest
@testable import ViewerCore
import RustCore

/// RustTranscriptAdapter routing (TSK-647): gate OFF → Swift parser
/// untouched, gate ON → Rust core with ClaudeEvent-equal results
/// (ids, timestamps, kinds, redaction), the maxEvents cap riding the
/// wire, and non-UTF-8 input falling back to Swift. Gate state injected
/// via `environment`.
final class RustTranscriptAdapterTests: XCTestCase {

    private let gateOn = ["MDV_RUST_TRANSCRIPT": "1"]

    /// uuid-bearing fixture (the documented missing-id divergence is out of
    /// corpus by design): plain messages, blocks, a tool pair, a secret to
    /// redact, garbage + torn tail lines for the tolerant framing.
    private let log = """
        {"uuid":"u1","type":"user","timestamp":"2026-06-12T03:14:15.926Z","message":{"role":"user","content":"hello"}}
        {"uuid":"a1","type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"hi"},{"type":"thinking","thinking":"hmm","signature":"SECRET-BLOB"},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls","signature":"SECRET-BLOB"}}]}}
        not json
        {"uuid":"r1","type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"done"}]}}
        {"uuid":"torn","message":{"role":"user","con
        """

    private var data: Data { Data(log.utf8) }

    func test_gateOff_runsSwift() {
        let out = RustTranscriptAdapter.outcome(data, redacting: true, environment: [:])
        XCTAssertEqual(out.source, .swiftBecauseGateOff)
        XCTAssertEqual(out.value, ClaudeLogParser().parseRedacted(data))
    }

    func test_gateOn_runsRust_eventsEqualSwift_redactedAndNot() {
        for redacting in [true, false] {
            let out = RustTranscriptAdapter.outcome(
                data, redacting: redacting, environment: gateOn)
            XCTAssertEqual(out.source, .rust, "gate ON must route rust")
            let swift = redacting
                ? ClaudeLogParser().parseRedacted(data)
                : ClaudeLogParser().parse(data)
            XCTAssertEqual(out.value, swift, "redacting=\(redacting)")
            XCTAssertFalse(out.value.isEmpty)
        }
    }

    func test_gateOn_redactionBarrierHolds() {
        let out = RustTranscriptAdapter.outcome(data, redacting: true, environment: gateOn)
        XCTAssertEqual(out.source, .rust)
        // The secret must not survive anywhere in any projected event: the
        // `signature` key is scrubbed wherever it nests — incl. inside a
        // tool_use input, where the projection DOES surface the value.
        var sawScrubbedInput = false
        for event in out.value {
            if case .toolUse(_, _, let input) = event.kind {
                XCTAssertEqual(input["signature"], "[REDACTED]")
                sawScrubbedInput = true
            }
            XCTAssertFalse(event.summary.contains("SECRET-BLOB"))
        }
        XCTAssertTrue(sawScrubbedInput, "fixture must exercise the input scrub")
    }

    func test_gateOn_maxEventsCapAppliesAndMatchesSwift() {
        let rust = RustTranscriptAdapter.outcome(
            data, redacting: true, maxEvents: 2, environment: gateOn)
        XCTAssertEqual(rust.source, .rust)
        XCTAssertEqual(rust.value, ClaudeLogParser(maxEvents: 2).parseRedacted(data))
        XCTAssertEqual(rust.value.count, 2)
    }

    func test_nonUTF8_fallsBackToSwift() {
        var bad = Data(log.utf8)
        bad.append(contentsOf: [0xFF, 0xFE])  // invalid UTF-8 tail
        let out = RustTranscriptAdapter.outcome(bad, redacting: true, environment: gateOn)
        XCTAssertEqual(out.source, .swiftFallback)
        XCTAssertEqual(out.value, ClaudeLogParser().parseRedacted(bad))
    }

    func test_redactedEventsFromURL_fileErrorContract() {
        XCTAssertThrowsError(
            try RustTranscriptAdapter.redactedEvents(
                from: URL(fileURLWithPath: "/nonexistent/transcript.jsonl"))
        ) { error in
            XCTAssertEqual(error as? ClaudeLogError, .fileNotFound)
        }
        // And the happy path round-trips through a real temp file.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-transcript-adapter-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("s.jsonl")
        try? data.write(to: file)
        let events = (try? RustTranscriptAdapter.redactedEvents(from: file)) ?? []
        XCTAssertEqual(events, ClaudeLogParser().parseRedacted(data))
    }
}
