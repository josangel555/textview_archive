import XCTest
@testable import ViewerCore

/// T1 headless tests for `ClaudeSessionIndex`. All fixtures are synthetic
/// `.jsonl` written under `FileManager.default.temporaryDirectory` — these
/// tests NEVER read the user's real `~/.claude`, and never touch
/// `~/Documents` / `~/Desktop` / `~/Downloads`.
final class ClaudeSessionIndexTests: XCTestCase {

    private let index = ClaudeSessionIndex()

    // MARK: Fixture scaffolding

    /// Unique scratch root per test; auto-removed in `tearDown`-style defer.
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CSITest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        scratchDirs.append(root)
        return root
    }

    /// Create `<root>/projects/<projectDir>/` and return it.
    private func makeProjectDir(_ root: URL, _ name: String) throws -> URL {
        let dir = root
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Write JSONL lines to `<dir>/<stem>.jsonl`.
    @discardableResult
    private func writeTranscript(_ dir: URL, stem: String, lines: [String]) throws -> URL {
        let url = dir.appendingPathComponent("\(stem).jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private var scratchDirs: [URL] = []

    override func tearDown() {
        for dir in scratchDirs { try? FileManager.default.removeItem(at: dir) }
        scratchDirs.removeAll()
        super.tearDown()
    }

    // MARK: Title resolution

    func test_title_customTitleWinsOverLaterPositionedAITitle() throws {
        // ai-title appears, then a LATER custom-title ⇒ custom-title wins.
        let root = try makeRoot()
        let dir = try makeProjectDir(root, "-Users-me-x")
        let url = try writeTranscript(dir, stem: "sess1", lines: [
            #"{"type":"user","uuid":"u1","timestamp":"2026-06-01T10:00:00Z","cwd":"/Users/me/x","sessionId":"sess1","message":{"role":"user","content":"do the thing"}}"#,
            #"{"type":"ai-title","sessionId":"sess1","aiTitle":"Auto Generated Title"}"#,
            #"{"type":"custom-title","sessionId":"sess1","customTitle":"My Custom Title"}"#,
        ])
        let summary = try index.summary(for: url)
        XCTAssertEqual(summary.title, "My Custom Title")
    }

    func test_title_lastCustomTitleWins_acrossMultiple() throws {
        let root = try makeRoot()
        let dir = try makeProjectDir(root, "-p")
        let url = try writeTranscript(dir, stem: "s", lines: [
            #"{"type":"custom-title","sessionId":"s","customTitle":"First"}"#,
            #"{"type":"ai-title","sessionId":"s","aiTitle":"AI"}"#,
            #"{"type":"custom-title","sessionId":"s","customTitle":"Second"}"#,
        ])
        XCTAssertEqual(try index.summary(for: url).title, "Second")
    }

    func test_title_aiTitleWhenNoCustom() throws {
        let root = try makeRoot()
        let dir = try makeProjectDir(root, "-p")
        let url = try writeTranscript(dir, stem: "s", lines: [
            #"{"type":"user","uuid":"u1","message":{"role":"user","content":"prompt text"}}"#,
            #"{"type":"ai-title","sessionId":"s","aiTitle":"AI Title Only"}"#,
        ])
        XCTAssertEqual(try index.summary(for: url).title, "AI Title Only")
    }

    func test_title_fallsBackToFirstUserPrompt_whenNoTitleRecords() throws {
        let root = try makeRoot()
        let dir = try makeProjectDir(root, "-p")
        let url = try writeTranscript(dir, stem: "s", lines: [
            #"{"type":"assistant","uuid":"a0","message":{"role":"assistant","content":[{"type":"text","text":"hi"}]}}"#,
            #"{"type":"user","uuid":"u1","message":{"role":"user","content":"the first real prompt"}}"#,
            #"{"type":"user","uuid":"u2","message":{"role":"user","content":"a later prompt"}}"#,
        ])
        XCTAssertEqual(try index.summary(for: url).title, "the first real prompt")
    }

    func test_title_firstUserPrompt_ignoresToolResultUserRecords() throws {
        // A user record carrying tool_result blocks is NOT a prompt; the
        // fallback should latch the first real text prompt instead.
        let root = try makeRoot()
        let dir = try makeProjectDir(root, "-p")
        let url = try writeTranscript(dir, stem: "s", lines: [
            #"{"type":"user","uuid":"r1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"output"}]}}"#,
            #"{"type":"user","uuid":"u1","message":{"role":"user","content":"actual prompt"}}"#,
        ])
        XCTAssertEqual(try index.summary(for: url).title, "actual prompt")
    }

    // MARK: Session-key divergence

    func test_sessionKey_isFilenameStem_notInRecordSessionId() throws {
        // File `aaaa.jsonl` whose records carry sessionId "bbbb" ⇒ key == "aaaa".
        let root = try makeRoot()
        let dir = try makeProjectDir(root, "-p")
        let url = try writeTranscript(dir, stem: "aaaa", lines: [
            #"{"type":"user","uuid":"u1","sessionId":"bbbb","cwd":"/real/cwd","message":{"role":"user","content":"x"}}"#,
        ])
        let summary = try index.summary(for: url)
        XCTAssertEqual(summary.key, "aaaa")
        XCTAssertEqual(summary.recordSessionId, "bbbb")
        // Real cwd comes from the record, not the lossy project-dir name.
        XCTAssertEqual(summary.cwd, "/real/cwd")
    }

    // MARK: Sidecar / subagent exclusion

    func test_enumeration_excludesSidecarSubagentDirs() throws {
        let root = try makeRoot()
        let dir = try makeProjectDir(root, "-Users-me-proj")
        // One top-level transcript.
        try writeTranscript(dir, stem: "80ad52ff", lines: [
            #"{"type":"user","uuid":"u1","cwd":"/Users/me/proj","message":{"role":"user","content":"top level"}}"#,
        ])
        // Sibling sidecar dir with same UUID stem, containing subagents/.
        let subagents = dir
            .appendingPathComponent("80ad52ff", isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        try writeTranscript(subagents, stem: "agent-a3dc1da55ef66b6bf", lines: [
            #"{"type":"user","uuid":"sa1","isSidechain":true,"agentId":"a3","message":{"role":"user","content":"subagent"}}"#,
        ])

        let urls = index.transcriptURLs(root: root)
        XCTAssertEqual(urls.count, 1, "only the top-level transcript should be listed")
        XCTAssertEqual(urls.first?.lastPathComponent, "80ad52ff.jsonl")

        let summaries = index.summaries(root: root)
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries.first?.key, "80ad52ff")
    }

    func test_enumeration_acrossMultipleProjectDirs() throws {
        let root = try makeRoot()
        let d1 = try makeProjectDir(root, "-a")
        let d2 = try makeProjectDir(root, "-b")
        try writeTranscript(d1, stem: "s1", lines: [
            #"{"type":"user","uuid":"u","message":{"role":"user","content":"x"}}"#,
        ])
        try writeTranscript(d2, stem: "s2", lines: [
            #"{"type":"user","uuid":"u","message":{"role":"user","content":"y"}}"#,
        ])
        XCTAssertEqual(Set(index.summaries(root: root).map(\.key)), ["s1", "s2"])
    }

    func test_enumeration_missingProjectsDir_returnsEmpty() throws {
        let root = try makeRoot() // no projects/ created
        XCTAssertTrue(index.transcriptURLs(root: root).isEmpty)
        XCTAssertTrue(index.summaries(root: root).isEmpty)
    }

    // MARK: Streaming bound — pathologically long line

    func test_streaming_oversizedLine_isSkipped_noThrow() throws {
        let root = try makeRoot()
        let dir = try makeProjectDir(root, "-p")
        // A single line longer than the (tiny) cap, plus a normal line.
        let huge = String(repeating: "x", count: 5_000)
        let bigLine = #"{"type":"user","uuid":"big","message":{"role":"user","content":"\#(huge)"}}"#
        let normal = #"{"type":"user","uuid":"u","message":{"role":"user","content":"ok"}}"#
        let url = try writeTranscript(dir, stem: "s", lines: [bigLine, normal])

        // Cap well below the big line but above the normal one.
        let tightIndex = ClaudeSessionIndex(maxLineBytes: 500, readChunkBytes: 128)
        let summary = try tightIndex.summary(for: url)
        // The oversized line is not decoded; only the normal record counts.
        XCTAssertEqual(summary.recordCount, 1)
        XCTAssertEqual(summary.messageCount, 1)
        // But the offset table still has an entry per physical line.
        let offsets = try tightIndex.lineOffsets(for: url)
        XCTAssertEqual(offsets.count, 2)
    }

    func test_streaming_chunkBoundary_splitsLinesCorrectly() throws {
        // Force many tiny reads so newlines land mid-buffer and across chunks.
        let root = try makeRoot()
        let dir = try makeProjectDir(root, "-p")
        var lines: [String] = []
        for i in 0..<50 {
            lines.append(#"{"type":"user","uuid":"u\#(i)","message":{"role":"user","content":"msg \#(i)"}}"#)
        }
        let url = try writeTranscript(dir, stem: "s", lines: lines)
        let tinyChunk = ClaudeSessionIndex(readChunkBytes: 7)
        let summary = try tinyChunk.summary(for: url)
        XCTAssertEqual(summary.recordCount, 50)
        XCTAssertEqual(summary.messageCount, 50)
        XCTAssertEqual(try tinyChunk.lineOffsets(for: url).count, 50)
    }

    // MARK: Redaction (security gate)

    func test_redaction_stripsThinkingSignatureAndApiErrorHeaders() throws {
        let root = try makeRoot()
        let dir = try makeProjectDir(root, "-p")
        let secretSignature = "SIG-SECRET-abc123-do-not-leak"
        let secretCookie = "_cfuvid=COOKIE-SECRET-xyz789; path=/"
        let assistantLine =
            #"{"type":"assistant","uuid":"a1","message":{"role":"assistant","content":[{"type":"thinking","thinking":"reasoning","signature":"\#(secretSignature)"}]}}"#
        let apiErrorLine =
            #"{"type":"system","subtype":"api_error","uuid":"s1","error":{"status":529,"headers":{"set-cookie":"\#(secretCookie)"},"error":{"type":"overloaded"}}}"#
        let url = try writeTranscript(dir, stem: "s", lines: [assistantLine, apiErrorLine])

        // 1. The summary itself must carry neither secret.
        let summary = try index.summary(for: url)
        let encoded = try JSONEncoder().encode(summary)
        let summaryJSON = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(summaryJSON.contains(secretSignature), "summary leaked signature")
        XCTAssertFalse(summaryJSON.contains("COOKIE-SECRET"), "summary leaked set-cookie")

        // 2. Directly exercise the redaction transform on each record and
        //    assert the secrets are gone from the re-serialized object.
        for line in [assistantLine, apiErrorLine] {
            let obj = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            )
            let redacted = ClaudeLogParser.redact(obj)
            let data = try JSONSerialization.data(withJSONObject: redacted)
            let json = String(decoding: data, as: UTF8.self)
            XCTAssertFalse(json.contains(secretSignature), "redact leaked signature")
            XCTAssertFalse(json.contains("COOKIE-SECRET"), "redact leaked set-cookie")
        }
    }

    func test_redaction_dropsLargeImageSourceBlob() throws {
        let bigBase64 = String(repeating: "A", count: 10_000)
        let line =
            #"{"type":"assistant","uuid":"a1","message":{"role":"assistant","content":[{"type":"image","source":"\#(bigBase64)"}]}}"#
        let obj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )
        let redacted = ClaudeLogParser.redact(obj)
        let json = String(decoding: try JSONSerialization.data(withJSONObject: redacted), as: UTF8.self)
        XCTAssertFalse(json.contains(bigBase64), "large image source must not be surfaced")
        XCTAssertTrue(json.contains("image source omitted"), "should leave a placeholder")
    }

    func test_redaction_keepsThinkingTextAndErrorStatus() throws {
        // Redaction must be surgical: scrub secrets, keep useful fields.
        let line =
            #"{"type":"assistant","uuid":"a1","message":{"role":"assistant","content":[{"type":"thinking","thinking":"useful reasoning","signature":"SECRET"}]}}"#
        let obj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )
        let redacted = ClaudeLogParser.redact(obj)
        let json = String(decoding: try JSONSerialization.data(withJSONObject: redacted), as: UTF8.self)
        XCTAssertTrue(json.contains("useful reasoning"), "thinking text must be preserved")
        XCTAssertFalse(json.contains("SECRET"))
    }

    // MARK: Polymorphic content

    func test_polymorphicContent_stringAndBlockArray_bothParse() throws {
        let root = try makeRoot()
        let dir = try makeProjectDir(root, "-p")
        let url = try writeTranscript(dir, stem: "s", lines: [
            // user content as a plain string
            #"{"type":"user","uuid":"u1","message":{"role":"user","content":"plain string prompt"}}"#,
            // user content as a block array carrying a tool_result
            #"{"type":"user","uuid":"r1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":[{"type":"text","text":"result body"}]}]}}"#,
        ])
        let summary = try index.summary(for: url)
        // Both are `user` records ⇒ messageCount 2.
        XCTAssertEqual(summary.messageCount, 2)
        // Events: 1 userMessage + 1 toolResult = 2.
        XCTAssertEqual(summary.eventCount, 2)
        // Title falls back to the first real prompt (string content).
        XCTAssertEqual(summary.title, "plain string prompt")
    }

    // MARK: Timestamps

    func test_timestamps_firstAndLast_inFileOrder() throws {
        let root = try makeRoot()
        let dir = try makeProjectDir(root, "-p")
        let url = try writeTranscript(dir, stem: "s", lines: [
            #"{"type":"user","uuid":"u1","timestamp":"2026-06-01T10:00:00.000Z","message":{"role":"user","content":"a"}}"#,
            #"{"type":"assistant","uuid":"a1","timestamp":"2026-06-01T10:05:30.500Z","message":{"role":"assistant","content":[{"type":"text","text":"b"}]}}"#,
            // a sidecar record with no timestamp must not disturb first/last
            #"{"type":"custom-title","sessionId":"s","customTitle":"T"}"#,
        ])
        let summary = try index.summary(for: url)
        XCTAssertNotNil(summary.firstTimestamp)
        XCTAssertNotNil(summary.lastTimestamp)
        XCTAssertLessThan(summary.firstTimestamp!, summary.lastTimestamp!)
        XCTAssertEqual(summary.recordCount, 3)
        XCTAssertEqual(summary.messageCount, 2)
    }

    // MARK: Line offset random-access

    func test_lineOffsets_enableRandomAccessLineRead() throws {
        let root = try makeRoot()
        let dir = try makeProjectDir(root, "-p")
        let l0 = #"{"type":"user","uuid":"u0","message":{"role":"user","content":"first"}}"#
        let l1 = #"{"type":"user","uuid":"u1","message":{"role":"user","content":"second"}}"#
        let l2 = #"{"type":"user","uuid":"u2","message":{"role":"user","content":"third"}}"#
        let url = try writeTranscript(dir, stem: "s", lines: [l0, l1, l2])

        let offsets = try index.lineOffsets(for: url)
        XCTAssertEqual(offsets.count, 3)
        XCTAssertEqual(offsets[0], 0)

        // Read line 1 directly via the offset table and confirm bytes match.
        let line1 = try XCTUnwrap(try index.line(at: 1, offsets: offsets, in: url))
        XCTAssertEqual(String(decoding: line1, as: UTF8.self), l1)

        // Last line (uses EOF as the upper bound).
        let line2 = try XCTUnwrap(try index.line(at: 2, offsets: offsets, in: url))
        XCTAssertEqual(String(decoding: line2, as: UTF8.self), l2)

        // Out of range ⇒ nil.
        XCTAssertNil(try index.line(at: 99, offsets: offsets, in: url))
    }

    // MARK: Missing file

    func test_summary_throwsOnMissingFile() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("__nope_\(UUID().uuidString).jsonl")
        XCTAssertThrowsError(try index.summary(for: url)) { error in
            XCTAssertEqual(error as? ClaudeLogError, .fileNotFound)
        }
    }

    // MARK: Trailing-newline handling

    func test_trailingNewline_doesNotProduceSpuriousEmptyLine() throws {
        let root = try makeRoot()
        let dir = try makeProjectDir(root, "-p")
        let url = dir.appendingPathComponent("s.jsonl")
        // Two records, file ENDS with a newline.
        let body = [
            #"{"type":"user","uuid":"u0","message":{"role":"user","content":"a"}}"#,
            #"{"type":"user","uuid":"u1","message":{"role":"user","content":"b"}}"#,
        ].joined(separator: "\n") + "\n"
        try body.write(to: url, atomically: true, encoding: .utf8)
        let summary = try index.summary(for: url)
        XCTAssertEqual(summary.recordCount, 2)
        // Offsets: one per real line (trailing empty line is not finalized).
        XCTAssertEqual(try index.lineOffsets(for: url).count, 2)
    }
}
