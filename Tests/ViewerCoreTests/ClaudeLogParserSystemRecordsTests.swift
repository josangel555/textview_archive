import XCTest
@testable import ViewerCore

/// Coverage for the `ClaudeLogParser` system-record accessors
/// (`recordType` / `recordCwd` / `recordSessionId` / `titleRecord` /
/// `userPromptText`). These pure `[String: Any]` parsers back the Claude
/// monitor's title/cwd/session derivation and were untested (the sibling
/// `redact` security path is covered separately in ClaudeTranscriptSearch
/// + ClaudeLogParser tests).
final class ClaudeLogParserSystemRecordsTests: XCTestCase {

    // MARK: - recordType / recordCwd / recordSessionId

    func test_recordType_returnsTypeOrEmpty() {
        XCTAssertEqual(ClaudeLogParser.recordType(["type": "assistant"]), "assistant")
        XCTAssertEqual(ClaudeLogParser.recordType([:]), "")
        XCTAssertEqual(ClaudeLogParser.recordType(["type": 42]), "", "non-string type → empty")
    }

    func test_recordCwd_presentEmptyMissing() {
        XCTAssertEqual(ClaudeLogParser.recordCwd(["cwd": "/Users/x/proj"]), "/Users/x/proj")
        XCTAssertNil(ClaudeLogParser.recordCwd(["cwd": ""]), "empty cwd → nil")
        XCTAssertNil(ClaudeLogParser.recordCwd([:]))
    }

    func test_recordSessionId() {
        XCTAssertEqual(ClaudeLogParser.recordSessionId(["sessionId": "abc-123"]), "abc-123")
        XCTAssertNil(ClaudeLogParser.recordSessionId([:]))
    }

    // MARK: - titleRecord (custom > ai precedence carried by isCustom)

    func test_titleRecord_customTitle() {
        let r = ClaudeLogParser.titleRecord(["type": "custom-title", "customTitle": "My Title"])
        XCTAssertEqual(r?.isCustom, true)
        XCTAssertEqual(r?.title, "My Title")
    }

    func test_titleRecord_aiTitle() {
        let r = ClaudeLogParser.titleRecord(["type": "ai-title", "aiTitle": "Generated"])
        XCTAssertEqual(r?.isCustom, false)
        XCTAssertEqual(r?.title, "Generated")
    }

    func test_titleRecord_emptyTitle_isNil() {
        XCTAssertNil(ClaudeLogParser.titleRecord(["type": "custom-title", "customTitle": ""]))
        XCTAssertNil(ClaudeLogParser.titleRecord(["type": "ai-title", "aiTitle": ""]))
    }

    func test_titleRecord_nonTitleType_isNil() {
        XCTAssertNil(ClaudeLogParser.titleRecord(["type": "assistant", "customTitle": "x"]))
        XCTAssertNil(ClaudeLogParser.titleRecord([:]))
    }

    func test_titleRecord_mismatchedKeyForType_isNil() {
        // A custom-title record carrying only aiTitle (and vice versa) yields nil.
        XCTAssertNil(ClaudeLogParser.titleRecord(["type": "custom-title", "aiTitle": "x"]))
        XCTAssertNil(ClaudeLogParser.titleRecord(["type": "ai-title", "customTitle": "x"]))
    }

    // MARK: - userPromptText

    func test_userPromptText_plainStringContent() {
        let rec: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": "hello there"],
        ]
        XCTAssertEqual(ClaudeLogParser.userPromptText(rec), "hello there")
    }

    func test_userPromptText_defaultsRoleToUserWhenMissing() {
        // role is read with a "user" default, so a content-bearing message
        // without an explicit role still counts.
        let rec: [String: Any] = ["type": "user", "message": ["content": "hi"]]
        XCTAssertEqual(ClaudeLogParser.userPromptText(rec), "hi")
    }

    func test_userPromptText_blockArrayTakesFirstTextBlock() {
        let rec: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": [
                ["type": "image"],
                ["type": "text", "text": "the prompt"],
                ["type": "text", "text": "second"],
            ]],
        ]
        XCTAssertEqual(ClaudeLogParser.userPromptText(rec), "the prompt")
    }

    func test_userPromptText_toolResultBlocks_returnNil() {
        // tool_result-bearing user records have no text block → nil, so the
        // title fallback never latches onto them.
        let rec: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": [
                ["type": "tool_result", "content": "output"],
            ]],
        ]
        XCTAssertNil(ClaudeLogParser.userPromptText(rec))
    }

    func test_userPromptText_nonUserType_returnsNil() {
        let rec: [String: Any] = [
            "type": "assistant",
            "message": ["role": "user", "content": "x"],
        ]
        XCTAssertNil(ClaudeLogParser.userPromptText(rec))
    }

    func test_userPromptText_emptyContent_returnsNil() {
        let rec: [String: Any] = ["type": "user", "message": ["role": "user", "content": ""]]
        XCTAssertNil(ClaudeLogParser.userPromptText(rec))
    }
}
