import XCTest
@testable import ViewerCore
import RustCore

/// RustTranscriptAdapter behavior pins (STAGE-B, TSK-649: the Swift
/// projection twin is deleted — rust is the only engine, no gate). The
/// expectations below are the CONTRACT the deleted A/B suite proved
/// event-equal before deletion: kinds/order/ids, the redaction barrier,
/// the maxEvents cap, tolerant framing (garbage + torn lines skipped),
/// lossy non-UTF-8 decode, and the file-error contract.
final class RustTranscriptAdapterTests: XCTestCase {

    /// uuid-bearing fixture: plain messages, blocks, a tool pair, a secret
    /// to redact, garbage + torn tail lines for the tolerant framing.
    private let log = """
        {"uuid":"u1","type":"user","timestamp":"2026-06-12T03:14:15.926Z","message":{"role":"user","content":"hello"}}
        {"uuid":"a1","type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"hi"},{"type":"thinking","thinking":"hmm","signature":"SECRET-BLOB"},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls","signature":"SECRET-BLOB"}}]}}
        not json
        {"uuid":"r1","type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"done"}]}}
        {"uuid":"torn","message":{"role":"user","con
        """

    private var data: Data { Data(log.utf8) }

    func test_rustIsTheOnlyEngine_projectionContractHolds() {
        let out = RustTranscriptAdapter.outcome(data, redacting: true)
        XCTAssertEqual(out.source, .rust, "twin deleted — rust must serve the projection")
        // The fixture's well-formed records project in order; garbage +
        // torn lines are skipped, never fatal.
        let kinds = out.value.map(\.kind)
        XCTAssertEqual(out.value.first?.id, "u1")
        guard case .userMessage(let hello)? = kinds.first else {
            return XCTFail("first event must be the user message, got \(kinds)")
        }
        XCTAssertEqual(hello, "hello")
        XCTAssertTrue(kinds.contains { if case .toolResult(let id, _) = $0 { return id == "t1" }; return false },
                      "the tool pair round-trips")
        XCTAssertTrue(kinds.contains { if case .thinking = $0 { return true }; return false })
        // Timestamp parses on the stamped record.
        XCTAssertNotNil(out.value.first?.timestamp)
    }

    func test_redactionBarrierHolds() {
        let out = RustTranscriptAdapter.outcome(data, redacting: true)
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
        // Unredacted mode keeps the raw value (the redaction is the barrier,
        // not the parser) — surfacing consumers must pass redacting: true.
        let raw = RustTranscriptAdapter.parse(data, redacting: false)
        XCTAssertTrue(raw.contains { event in
            if case .toolUse(_, _, let input) = event.kind {
                return input["signature"] == "SECRET-BLOB"
            }
            return false
        })
    }

    func test_maxEventsCapApplies() {
        let out = RustTranscriptAdapter.outcome(data, redacting: true, maxEvents: 2)
        XCTAssertEqual(out.source, .rust)
        XCTAssertEqual(out.value.count, 2, "the cap rides the wire")
    }

    func test_nonUTF8_decodesLossilyAndStillProjects() {
        // Stage-B: invalid bytes decode lossily (replacement chars) instead
        // of falling back to the deleted Swift parser; well-formed lines
        // still project.
        var bad = Data(log.utf8)
        bad.append(contentsOf: [0xFF, 0xFE])  // invalid UTF-8 tail
        let out = RustTranscriptAdapter.outcome(bad, redacting: true)
        XCTAssertEqual(out.source, .rust)
        XCTAssertEqual(out.value.map(\.id),
                       RustTranscriptAdapter.parse(data, redacting: true).map(\.id),
                       "a corrupt tail must not cost the well-formed events")
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
        XCTAssertEqual(events, RustTranscriptAdapter.parse(data, redacting: true))
        XCTAssertFalse(events.isEmpty)
    }
}
