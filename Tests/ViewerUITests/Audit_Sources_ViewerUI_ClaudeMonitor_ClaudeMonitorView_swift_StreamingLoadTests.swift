import XCTest
import ViewerCore
@testable import ViewerUI

/// Regression coverage for the [S2/perf] audit fix on
/// `Sources/ViewerUI/ClaudeMonitor/ClaudeMonitorView.swift:150`:
/// `ClaudeMonitorModel.loadRedactedEvents` was rewritten from an offset-table
/// reader that re-opened the file once PER physical line into a single
/// streaming pass over one held read-only `FileHandle`.
///
/// The existing `ClaudeMonitorModelTests` already cover the small-input happy
/// path, the event cap, and the missing-file case. These tests pin the
/// behaviours that the chunked single-pass rewrite makes newly load-bearing
/// and which the small fixtures cannot exercise:
///   1. A line LONGER than the 256 KB read chunk reassembles across chunk
///      boundaries (the riskiest part of the rewrite).
///   2. The redaction barrier still sits in front of the parser on the
///      streaming path (inline image blobs / signature blobs never surface).
///   3. A trailing line with no final newline is still parsed.
///   4. Interleaved blank lines are skipped without desyncing the stream.
///
/// Host-safe (mirrors `ClaudeMonitorModelTests`): only the model's `nonisolated
/// static` loader and a `/var/folders` temp fixture — no window is created.
final class Audit_Sources_ViewerUI_ClaudeMonitor_ClaudeMonitorView_swift_StreamingLoadTests: XCTestCase {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CMMStreamTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeRawJSONL(_ text: String, to dir: URL, stem: String) throws -> URL {
        let url = dir.appendingPathComponent("\(stem).jsonl")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: 1. Cross-chunk-boundary reassembly

    /// A single JSONL line whose serialized size far exceeds the 256 KB read
    /// chunk must reassemble correctly across multiple `read(upToCount:)`
    /// chunks and decode to one event. The old per-line offset reader sidestepped
    /// this entirely; the streaming rewrite owns the reassembly, so guard it.
    func test_loadRedactedEvents_lineLongerThanReadChunk_reassembles() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // ~600 KB of message text => the record line is > 2 read chunks.
        let bigText = String(repeating: "A", count: 600_000)
        let line1 = #"{"type":"user","uuid":"u1","message":{"role":"user","content":"before"}}"#
        let line2 = "{\"type\":\"assistant\",\"uuid\":\"a1\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"\(bigText)\"}]}}"
        let line3 = #"{"type":"user","uuid":"u2","message":{"role":"user","content":"after"}}"#
        let url = try writeRawJSONL([line1, line2, line3].joined(separator: "\n"), to: dir, stem: "huge")

        let (events, truncated) = ClaudeMonitorModel.loadRedactedEvents(url: url, cap: 20_000)
        XCTAssertFalse(truncated)
        XCTAssertEqual(events.count, 3, "all three lines should parse including the >chunk one")

        guard case .userMessage(let t0) = events[0].kind else {
            return XCTFail("expected userMessage, got \(events[0].kind)")
        }
        XCTAssertEqual(t0, "before")
        guard case .assistantMessage(let t1) = events[1].kind else {
            return XCTFail("expected assistantMessage, got \(events[1].kind)")
        }
        XCTAssertEqual(t1.count, 600_000, "the cross-chunk line must reassemble byte-for-byte")
        guard case .userMessage(let t2) = events[2].kind else {
            return XCTFail("expected userMessage, got \(events[2].kind)")
        }
        XCTAssertEqual(t2, "after", "stream must stay in sync after the oversized line")
    }

    // MARK: 2. Redaction barrier on the streaming path

    /// A `signature` key nested inside a `tool_use` block's `input` must be
    /// scrubbed before the surfaced tool-call event materializes its args —
    /// proving `redact` (key-name driven, recursive) still runs in front of
    /// `parse` on the rewritten single-pass loader. This is a NON-vacuous
    /// surfacing path: `stringifyInput` would otherwise emit the value verbatim.
    func test_loadRedactedEvents_redactsNestedSignatureInToolInput() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let secret = "sk-tool-input-signature-secret"
        let line = "{\"type\":\"assistant\",\"uuid\":\"a1\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"Bash\",\"input\":{\"command\":\"ls\",\"signature\":\"\(secret)\"}}]}}"
        let url = try writeRawJSONL(line, to: dir, stem: "toolsig")

        let (events, _) = ClaudeMonitorModel.loadRedactedEvents(url: url, cap: 100)
        XCTAssertEqual(events.count, 1)
        guard case .toolUse(_, let name, let input) = events[0].kind else {
            return XCTFail("expected toolUse, got \(events[0].kind)")
        }
        XCTAssertEqual(name, "Bash")
        XCTAssertEqual(input["command"], "ls", "non-secret args must pass through")
        XCTAssertEqual(input["signature"], "[REDACTED]", "nested signature must be scrubbed")
        XCTAssertNotEqual(input["signature"], secret, "raw signature must never surface")
    }

    /// A `signature` blob (extended-thinking signature) must be scrubbed by the
    /// redaction barrier before the thinking event surfaces.
    func test_loadRedactedEvents_redactsSignatureOnStreamingPath() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let secret = "sk-supersecret-signature-value"
        let line = "{\"type\":\"assistant\",\"uuid\":\"a1\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"pondering\",\"signature\":\"\(secret)\"}]}}"
        let url = try writeRawJSONL(line, to: dir, stem: "sig")

        let (events, _) = ClaudeMonitorModel.loadRedactedEvents(url: url, cap: 100)
        XCTAssertEqual(events.count, 1)
        guard case .thinking(let text) = events[0].kind else {
            return XCTFail("expected thinking, got \(events[0].kind)")
        }
        XCTAssertEqual(text, "pondering")
        XCTAssertFalse(text.contains(secret), "signature blob must never surface")
    }

    // MARK: 3. Trailing line without a final newline

    func test_loadRedactedEvents_trailingLineNoFinalNewline_isParsed() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // No trailing "\n" on the last line.
        let text = [
            #"{"type":"user","uuid":"u1","message":{"role":"user","content":"first"}}"#,
            #"{"type":"user","uuid":"u2","message":{"role":"user","content":"last"}}"#,
        ].joined(separator: "\n")
        let url = try writeRawJSONL(text, to: dir, stem: "nonl")

        let (events, _) = ClaudeMonitorModel.loadRedactedEvents(url: url, cap: 100)
        XCTAssertEqual(events.count, 2, "the unterminated trailing line must still parse")
        guard case .userMessage(let t1) = events[1].kind else {
            return XCTFail("expected userMessage, got \(events[1].kind)")
        }
        XCTAssertEqual(t1, "last")
    }

    // MARK: 4. Blank / undecodable lines are skipped without desyncing

    func test_loadRedactedEvents_blankAndJunkLinesAreSkipped() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Leading blank line, a junk (non-JSON) line, an empty line between
        // two valid records, and a trailing blank line.
        let text = [
            "",
            #"{"type":"user","uuid":"u1","message":{"role":"user","content":"one"}}"#,
            "not json at all",
            "",
            #"{"type":"user","uuid":"u2","message":{"role":"user","content":"two"}}"#,
            "",
        ].joined(separator: "\n")
        let url = try writeRawJSONL(text, to: dir, stem: "mixed")

        let (events, _) = ClaudeMonitorModel.loadRedactedEvents(url: url, cap: 100)
        XCTAssertEqual(events.count, 2, "only the two valid records should surface")
        guard case .userMessage(let t0) = events[0].kind,
              case .userMessage(let t1) = events[1].kind else {
            return XCTFail("expected two userMessages, got \(events.map(\.kind))")
        }
        XCTAssertEqual([t0, t1], ["one", "two"])
    }
}
