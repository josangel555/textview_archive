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
