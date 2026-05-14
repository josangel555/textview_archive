import XCTest
@testable import ViewerCore

final class ClaudeLogParserTests: XCTestCase {
    private let parser = ClaudeLogParser()

    // MARK: Plain user / assistant messages

    func test_userMessage_stringContent() {
        let line = #"""
        {"type":"user","uuid":"u1","timestamp":"2026-05-14T10:00:00Z","message":{"role":"user","content":"refactor auth"}}
        """#
        let events = parser.parse(line)
        XCTAssertEqual(events.count, 1)
        guard case .userMessage(let text) = events[0].kind else {
            return XCTFail("expected .userMessage")
        }
        XCTAssertEqual(text, "refactor auth")
        XCTAssertEqual(events[0].id, "u1")
        XCTAssertNotNil(events[0].timestamp)
    }

    func test_assistantMessage_arrayWithTextBlock() {
        let line = #"""
        {"type":"assistant","uuid":"a1","message":{"role":"assistant","content":[{"type":"text","text":"Sure, here goes."}]}}
        """#
        let events = parser.parse(line)
        XCTAssertEqual(events.count, 1)
        guard case .assistantMessage(let text) = events[0].kind else {
            return XCTFail("expected .assistantMessage")
        }
        XCTAssertEqual(text, "Sure, here goes.")
    }

    // MARK: Tool use

    func test_toolUse_extractsNameAndInput() {
        let line = #"""
        {"type":"assistant","uuid":"a2","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu1","name":"Edit","input":{"file_path":"/x/y.swift"}}]}}
        """#
        let events = parser.parse(line)
        XCTAssertEqual(events.count, 1)
        guard case .toolUse(let id, let name, let input) = events[0].kind else {
            return XCTFail("expected .toolUse")
        }
        XCTAssertEqual(id, "tu1")
        XCTAssertEqual(name, "Edit")
        XCTAssertEqual(input["file_path"], "/x/y.swift")
    }

    func test_toolUse_bashCommandInput() {
        let line = #"""
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu2","name":"Bash","input":{"command":"swift test"}}]}}
        """#
        let events = parser.parse(line)
        guard case .toolUse(_, let name, let input) = events[0].kind else {
            return XCTFail("expected .toolUse")
        }
        XCTAssertEqual(name, "Bash")
        XCTAssertEqual(input["command"], "swift test")
    }

    func test_summary_toolUseShowsFilePath() {
        let line = #"""
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu3","name":"Read","input":{"file_path":"/foo/bar.md"}}]}}
        """#
        let events = parser.parse(line)
        XCTAssertTrue(events[0].summary.contains("Read"))
        XCTAssertTrue(events[0].summary.contains("/foo/bar.md"))
    }

    // MARK: Tool result

    func test_toolResult_arrayContent() {
        let line = #"""
        {"type":"user","uuid":"r1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu1","content":[{"type":"text","text":"OK"}]}]}}
        """#
        let events = parser.parse(line)
        XCTAssertEqual(events.count, 1)
        guard case .toolResult(let id, let summary) = events[0].kind else {
            return XCTFail("expected .toolResult")
        }
        XCTAssertEqual(id, "tu1")
        XCTAssertEqual(summary, "OK")
    }

    func test_toolResult_stringContent() {
        let line = #"""
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu1","content":"done"}]}}
        """#
        let events = parser.parse(line)
        guard case .toolResult(_, let summary) = events[0].kind else {
            return XCTFail("expected .toolResult")
        }
        XCTAssertEqual(summary, "done")
    }

    // MARK: Multi-line

    func test_multipleEvents_inOrder() {
        let lines = [
            #"{"type":"user","uuid":"u1","message":{"role":"user","content":"do thing"}}"#,
            #"{"type":"assistant","uuid":"a1","message":{"role":"assistant","content":[{"type":"text","text":"OK"}]}}"#,
        ].joined(separator: "\n")
        let events = parser.parse(lines)
        XCTAssertEqual(events.count, 2)
        guard case .userMessage = events[0].kind else { return XCTFail() }
        guard case .assistantMessage = events[1].kind else { return XCTFail() }
    }

    func test_malformedJSON_isSkipped() {
        let lines = """
        not json
        {"broken
        {"type":"user","uuid":"u1","message":{"role":"user","content":"x"}}
        """
        let events = parser.parse(lines)
        XCTAssertEqual(events.count, 1)
    }

    func test_unknownRecord_isSkipped() {
        let line = #"{"type":"system","message":{"role":"system","content":"hi"}}"#
        let events = parser.parse(line)
        XCTAssertEqual(events.count, 0, "unknown roles are not surfaced")
    }

    // CRIT-7: real Claude Code transcripts include top-level records with no
    // `message` key (system, permission-mode, last-prompt, file-history-snapshot,
    // ai-title). These are silently ignored — pin the contract.
    func test_topLevelSystemRecord_withoutMessage_isSkipped() {
        let line = #"{"type":"system","uuid":"s1","content":"loaded plugin","cwd":"/x"}"#
        XCTAssertEqual(parser.parse(line).count, 0)
    }

    func test_fileHistorySnapshotRecord_isSkipped() {
        let line = #"{"type":"file-history-snapshot","uuid":"f1","files":[]}"#
        XCTAssertEqual(parser.parse(line).count, 0)
    }

    // MARK: CRIT-7 — thinking blocks (~6% of real transcripts) used to be dropped

    func test_thinkingBlock_isEmitted() {
        let line = #"""
        {"type":"assistant","uuid":"a1","message":{"role":"assistant","content":[{"type":"thinking","thinking":"weighing options"}]}}
        """#
        let events = parser.parse(line)
        XCTAssertEqual(events.count, 1)
        guard case .thinking(let text) = events[0].kind else {
            return XCTFail("expected .thinking, got \(events[0].kind)")
        }
        XCTAssertEqual(text, "weighing options")
    }

    func test_thinkingBlock_acceptsTextField_too() {
        // Some emitters use `text` instead of `thinking` for the payload.
        let line = #"""
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","text":"alt shape"}]}}
        """#
        guard case .thinking(let text) = parser.parse(line)[0].kind else {
            return XCTFail("expected .thinking")
        }
        XCTAssertEqual(text, "alt shape")
    }

    func test_thinkingBlock_summary_isPrefixedWithLabel() {
        let line = #"""
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hmm"}]}}
        """#
        XCTAssertEqual(parser.parse(line)[0].summary, "thinking: hmm")
    }

    // MARK: Nested input — should not surface Swift's debug repr

    func test_toolUse_nestedArrayInput_isJSONified() {
        let line = #"""
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu","name":"MultiEdit","input":{"edits":[{"old":"a","new":"b"}]}}]}}
        """#
        let events = parser.parse(line)
        guard case .toolUse(_, _, let input) = events[0].kind else {
            return XCTFail("expected .toolUse")
        }
        let edits = input["edits"] ?? ""
        XCTAssertFalse(edits.contains("Swift.AnyHashable"), "should not be Swift's debug repr")
        // The value should be valid JSON (round-trippable), not Swift debug-style.
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(edits.utf8)),
                        "input value should be valid JSON; got: \(edits)")
    }

    // MARK: S6/S7 — resource caps

    func test_oversizedLine_isSkipped() {
        let bigText = String(repeating: "x", count: 100)
        let bigLine = "{\"type\":\"user\",\"uuid\":\"u\",\"message\":{\"role\":\"user\",\"content\":\"\(bigText)\"}}"
        let strictParser = ClaudeLogParser(maxLineBytes: 50)
        XCTAssertEqual(strictParser.parse(bigLine).count, 0,
                       "line longer than maxLineBytes should be skipped")
    }

    func test_eventCap_isEnforced() {
        let line = #"{"type":"user","uuid":"u","message":{"role":"user","content":"hi"}}"#
        let many = Array(repeating: line, count: 100).joined(separator: "\n")
        let cappedParser = ClaudeLogParser(maxEvents: 10)
        XCTAssertEqual(cappedParser.parse(many).count, 10)
    }

    // MARK: Real-transcript shape (uses heterogeneous JSONL fixture inline)

    func test_realisticTranscript_yieldsExpectedKindMix() {
        let lines = [
            // user prompt
            #"{"type":"user","uuid":"u1","message":{"role":"user","content":"do x"}}"#,
            // assistant thinking + text + tool_use
            #"{"type":"assistant","uuid":"a1","message":{"role":"assistant","content":[{"type":"thinking","thinking":"plan"},{"type":"text","text":"sure"},{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/x"}}]}}"#,
            // tool result
            #"{"type":"user","uuid":"r1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":[{"type":"text","text":"contents"}]}]}}"#,
            // top-level system records (must be skipped)
            #"{"type":"system","uuid":"s1","cwd":"/x"}"#,
            #"{"type":"permission-mode","uuid":"p1","mode":"acceptEdits"}"#,
        ].joined(separator: "\n")
        let events = parser.parse(lines)
        XCTAssertEqual(events.count, 5,
                       "1 user + 1 thinking + 1 assistant text + 1 tool_use + 1 tool_result; system + permission-mode are top-level no-message records and are dropped")

        // Count by kind
        var nUser = 0, nAssistant = 0, nThinking = 0, nToolUse = 0, nToolResult = 0
        for e in events {
            switch e.kind {
            case .userMessage: nUser += 1
            case .assistantMessage: nAssistant += 1
            case .thinking: nThinking += 1
            case .toolUse: nToolUse += 1
            case .toolResult: nToolResult += 1
            }
        }
        XCTAssertEqual(nUser, 1)
        XCTAssertEqual(nAssistant, 1)
        XCTAssertEqual(nThinking, 1)
        XCTAssertEqual(nToolUse, 1)
        XCTAssertEqual(nToolResult, 1)
    }

    // MARK: File loading

    func test_eventsFromURL_throwsOnMissingFile() {
        let url = URL(fileURLWithPath: "/tmp/__nope_\(UUID().uuidString).jsonl")
        XCTAssertThrowsError(try parser.events(from: url)) { error in
            XCTAssertEqual(error as? ClaudeLogError, .fileNotFound)
        }
    }

    func test_eventsFromURL_readsFromDisk() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLPTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("t.jsonl")
        let line = #"{"type":"user","uuid":"u","message":{"role":"user","content":"hi"}}"#
        try line.write(to: url, atomically: true, encoding: .utf8)
        let events = try parser.events(from: url)
        XCTAssertEqual(events.count, 1)
    }

    // MARK: Path encoding

    func test_transcriptDirectory_encodesPathWithHyphens() {
        let proj = URL(fileURLWithPath: "/Users/me/work/repo")
        let dir = ClaudeLogParser.transcriptDirectory(for: proj)
        XCTAssertTrue(dir.path.hasSuffix("/.claude/projects/-Users-me-work-repo"),
                      "got \(dir.path)")
    }
}
