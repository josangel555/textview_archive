import XCTest
@testable import RustCore
import ViewerCore

/// A/B parity (TSK-632): the Rust core's `mdvcore_transcript_parse` (via
/// `mdvCoreTranscriptParse`) vs the SHIPPING Swift `ClaudeLogParser`, over a
/// corpus exercising every projected kind, the tolerant-framing hazards
/// (blank/garbage/torn-tail lines, non-object documents, poisoned block
/// arrays), timestamp forms (fractional/plain/offset/numeric/invalid), input
/// stringification (string/int/bool/double/null/nested), and the TSK-245
/// redaction barrier where it is observable in projected events.
///
/// Out of corpus by design (documented divergences): records with neither
/// `uuid` nor `id` (Swift mints a random UUID; Rust a deterministic
/// `line-<n>`), and multi-key NESTED objects inside `tool_use.input` (the
/// compact JSON repr's key order is Swift-dictionary-nondeterministic).
final class TranscriptABTests: XCTestCase {

    private let parser = ClaudeLogParser()

    private func assertParity(
        _ log: String, redacting: Bool = false,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let swift = redacting
            ? parser.parseRedacted(Data(log.utf8))
            : parser.parse(log)
        let rust = try mdvCoreTranscriptParse(text: log, redacting: redacting)
        XCTAssertEqual(rust.count, swift.count,
                       "event count diverged for log: \(log.prefix(200))",
                       file: file, line: line)
        for (r, s) in zip(rust, swift) {
            XCTAssertEqual(r.id, s.id, file: file, line: line)
            let swiftMs = s.timestamp.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) }
            XCTAssertEqual(r.timestampMs, swiftMs,
                           "timestamp diverged for event \(s.id)", file: file, line: line)
            switch (r.kind, s.kind) {
            case let (.userMessage(rt), .userMessage(st)),
                 let (.assistantMessage(rt), .assistantMessage(st)),
                 let (.thinking(rt), .thinking(st)):
                XCTAssertEqual(rt, st, file: file, line: line)
            case let (.toolUse(rid, rname, rinput), .toolUse(sid, sname, sinput)):
                XCTAssertEqual(rid, sid, file: file, line: line)
                XCTAssertEqual(rname, sname, file: file, line: line)
                XCTAssertEqual(rinput, sinput,
                               "tool_use input diverged for \(s.id)", file: file, line: line)
            case let (.toolResult(rtid, rsum), .toolResult(stid, ssum)):
                XCTAssertEqual(rtid, stid, file: file, line: line)
                XCTAssertEqual(rsum, ssum, file: file, line: line)
            default:
                XCTFail("kind diverged for \(s.id): rust \(r.kind) vs swift \(s.kind)",
                        file: file, line: line)
            }
        }
    }

    func test_string_content_and_timestamps() throws {
        try assertParity("""
            {"uuid":"u1","type":"user","timestamp":"2026-06-12T03:14:15.926Z","message":{"role":"user","content":"hello"}}
            {"uuid":"a1","type":"assistant","timestamp":"2026-06-12T03:14:16Z","message":{"role":"assistant","content":"hi"}}
            {"uuid":"o1","type":"user","timestamp":"2026-06-12T05:14:15+02:00","message":{"role":"user","content":"offset"}}
            {"uuid":"n1","type":"user","timestamp":1718150400,"message":{"role":"user","content":"numeric"}}
            {"uuid":"f1","type":"user","timestamp":1718150400.5,"message":{"role":"user","content":"fractional"}}
            {"uuid":"b1","type":"user","timestamp":"not a date","message":{"role":"user","content":"bad ts"}}
            {"uuid":"m1","type":"user","timestamp":"2026-06-12T03:14:15","message":{"role":"user","content":"no offset"}}

            """)
    }

    func test_block_array_all_kinds() throws {
        try assertParity("""
            {"uuid":"e1","type":"assistant","timestamp":"2026-06-12T10:00:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"answer"},{"type":"thinking","thinking":"hmm"},{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls -la","description":"list"}},{"type":"server_tool_use"}]}}
            {"uuid":"e2","type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":[{"type":"text","text":"file1"},{"type":"text","text":"file2"}]},{"type":"text","text":"user follow-up"}]}}
            {"uuid":"e3","type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","text":"via text field"}]}}
            {"uuid":"e4","type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_2","content":"plain string result"}]}}

            """)
    }

    func test_tolerant_framing_and_yieldless_shapes() throws {
        try assertParity("""
            {"uuid":"s1","type":"summary","summary":"a summary record"}

            not json at all
            [1,2,3]
            {"uuid":"v1","type":"user","message":{"role":"user","content":"valid between garbage"}}
            {"uuid":"x1","type":"system","message":{"role":"system","content":"system role drops"}}
            {"uuid":"p1","message":{"role":"assistant","content":[{"type":"text","text":"ok"},"poison"]}}
            {"uuid":"torn","type":"user","message":{"role":"user","con
            """)
    }

    func test_input_stringification_scalars_and_nested() throws {
        // Single-key nested object only (multi-key nested order is
        // Swift-nondeterministic — documented divergence).
        try assertParity("""
            {"uuid":"i1","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"X","input":{"s":"str","i":42,"neg":-7,"b":true,"bf":false,"d":1.5,"whole":2000.0,"nul":null,"arr":["a","b",3],"nested":{"k":"v/slash"}}}]}}

            """)
    }

    func test_redaction_observable_in_projected_input() throws {
        // A `signature`/`headers` key inside tool_use input IS projected —
        // the barrier must scrub it identically on both sides.
        let log = """
            {"uuid":"r1","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"X","input":{"signature":"SECRET-BLOB","headers":{"set-cookie":"_cfuvid=secret"},"ok":"kept"}}]}}
            {"uuid":"r2","message":{"role":"assistant","content":[{"type":"thinking","thinking":"reasoning","signature":"SIG"}]}}

            """
        try assertParity(log, redacting: true)
        // And pin the scrub itself (not just parity): the projected input
        // must carry the token, never the secret.
        let rust = try mdvCoreTranscriptParse(text: log, redacting: true)
        guard case let .toolUse(_, _, input) = rust[0].kind else {
            return XCTFail("expected tool_use")
        }
        XCTAssertEqual(input["signature"], "[REDACTED]")
        XCTAssertEqual(input["headers"], "[REDACTED]")
        XCTAssertEqual(input["ok"], "kept")
    }

    func test_event_cap_parity() throws {
        let line = #"{"uuid":"c","type":"user","message":{"role":"user","content":"x"}}"#
        let log = Array(repeating: line, count: 50).joined(separator: "\n") + "\n"
        let swift = ClaudeLogParser(maxEvents: 10).parse(log)
        XCTAssertEqual(swift.count, 10)
        // The Rust wire uses the default caps; cap semantics are pinned in
        // the Rust unit tests (caps_bound_events_and_line_bytes). Here just
        // prove the uncapped counts agree.
        let rust = try mdvCoreTranscriptParse(text: log, redacting: false)
        XCTAssertEqual(rust.count, parser.parse(log).count)
    }

    func test_capability_bit_advertised() {
        XCTAssertTrue(CoreABI.capabilities.contains(.transcript))
    }

    /// Sweep a REAL transcript from this machine's `~/.claude/projects`, if
    /// one exists (self-skips otherwise) — the corpus that catches shape
    /// drift fixtures can't anticipate. Reads at most 256 KB.
    func test_real_transcript_sweep_if_available() throws {
        let projects = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
        let jsonls = (FileManager.default.enumerator(
            at: projects, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "jsonl" }) ?? []
        guard let sample = jsonls.first,
              let data = try? Data(contentsOf: sample) else {
            throw XCTSkip("no local Claude transcripts to sweep")
        }
        // Whole lines only, capped: cut at the last newline within 256 KB.
        let window = data.prefix(256 * 1024)
        let cut = window.lastIndex(of: 0x0A).map { window.prefix(through: $0) } ?? window
        guard let text = String(data: Data(cut), encoding: .utf8) else {
            throw XCTSkip("transcript window not valid UTF-8")
        }
        try assertParity(text, redacting: true)
    }
}
