import XCTest
@testable import ViewerCore

/// Regression coverage for the two audit findings fixed in
/// `Sources/ViewerCore/ClaudeSessionIndex.swift`:
///   * S3/perf — title candidates (first user prompt, custom/ai title) are
///     capped at capture so an oversized title doesn't ride into the summary
///     / on-disk index.
///   * S4/perf — `eventCount` is computed without redacting the record or
///     materializing the throwaway event array; the count must stay identical
///     to `ClaudeLogParser.parseRecord(...).count`.
///
/// T1 headless. All fixtures are synthetic `.jsonl` under the per-user temp
/// dir; these never touch the real `~/.claude` or `~/Documents` etc.
final class ClaudeSessionIndexTitleCapAndEventCountAuditTests: XCTestCase {

    private let index = ClaudeSessionIndex()
    private var scratchDirs: [URL] = []

    override func tearDown() {
        for dir in scratchDirs { try? FileManager.default.removeItem(at: dir) }
        scratchDirs.removeAll()
        super.tearDown()
    }

    // MARK: Fixture scaffolding (self-contained; shared file untouched)

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CSIAuditTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        scratchDirs.append(root)
        return root
    }

    private func makeProjectDir(_ root: URL, _ name: String) throws -> URL {
        let dir = root
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    private func writeTranscript(_ dir: URL, stem: String, lines: [String]) throws -> URL {
        let url = dir.appendingPathComponent("\(stem).jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: Title cap (S3)

    func test_firstUserPrompt_cappedAtMaxTitleChars() throws {
        let root = try makeRoot()
        let dir = try makeProjectDir(root, "-p")
        // A 5000-char prompt; JSON-safe (no quotes/backslashes/newlines).
        let huge = String(repeating: "a", count: 5000)
        let url = try writeTranscript(dir, stem: "s", lines: [
            #"{"type":"user","uuid":"u1","message":{"role":"user","content":"\#(huge)"}}"#,
        ])
        let title = try XCTUnwrap(index.summary(for: url).title)
        XCTAssertEqual(title.count, ClaudeSessionIndex.maxTitleChars,
                       "oversized first prompt must be truncated to the cap")
        XCTAssertTrue(title.allSatisfy { $0 == "a" })
    }

    func test_customTitle_cappedAtMaxTitleChars() throws {
        let root = try makeRoot()
        let dir = try makeProjectDir(root, "-p")
        let huge = String(repeating: "b", count: 5000)
        let url = try writeTranscript(dir, stem: "s", lines: [
            #"{"type":"custom-title","sessionId":"s","customTitle":"\#(huge)"}"#,
        ])
        let title = try XCTUnwrap(index.summary(for: url).title)
        XCTAssertEqual(title.count, ClaudeSessionIndex.maxTitleChars)
    }

    func test_aiTitle_cappedAtMaxTitleChars() throws {
        let root = try makeRoot()
        let dir = try makeProjectDir(root, "-p")
        let huge = String(repeating: "c", count: 5000)
        let url = try writeTranscript(dir, stem: "s", lines: [
            #"{"type":"ai-title","sessionId":"s","aiTitle":"\#(huge)"}"#,
        ])
        let title = try XCTUnwrap(index.summary(for: url).title)
        XCTAssertEqual(title.count, ClaudeSessionIndex.maxTitleChars)
    }

    func test_shortTitle_preservedExactly() throws {
        let root = try makeRoot()
        let dir = try makeProjectDir(root, "-p")
        let url = try writeTranscript(dir, stem: "s", lines: [
            #"{"type":"user","uuid":"u1","message":{"role":"user","content":"short prompt"}}"#,
        ])
        XCTAssertEqual(try index.summary(for: url).title, "short prompt")
    }

    // MARK: eventCount parity with parseRecord (S4)

    func test_eventCount_matchesParseRecord_acrossBlockKinds() throws {
        let root = try makeRoot()
        let dir = try makeProjectDir(root, "-p")
        let lines = [
            // string content, user -> 1 event
            #"{"type":"user","uuid":"u1","message":{"role":"user","content":"hi"}}"#,
            // assistant with text + thinking + tool_use blocks -> 3 events
            #"{"type":"assistant","uuid":"a1","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hmm"},{"type":"text","text":"answer"},{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/x"}}]}}"#,
            // user block-array carrying a tool_result -> 1 event
            #"{"type":"user","uuid":"r1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":[{"type":"text","text":"body"}]}]}}"#,
            // an unknown block kind contributes 0; mixed with one text -> 1
            #"{"type":"assistant","uuid":"a2","message":{"role":"assistant","content":[{"type":"image","source":"x"},{"type":"text","text":"caption"}]}}"#,
            // a system/title sidecar with no message envelope -> 0 events
            #"{"type":"custom-title","sessionId":"s","customTitle":"T"}"#,
        ]
        let url = try writeTranscript(dir, stem: "s", lines: lines)

        // Expected: independently parse every line through parseRecord and sum
        // the emitted-event counts — exactly the semantics eventCount mirrors.
        var expected = 0
        for line in lines {
            let data = Data(line.utf8)
            let obj = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            expected += ClaudeLogParser.parseRecord(obj).count
            // Redaction must not change the count (no block added/removed).
            XCTAssertEqual(
                ClaudeLogParser.parseRecord(ClaudeLogParser.redact(obj)).count,
                ClaudeLogParser.parseRecord(obj).count
            )
        }
        XCTAssertEqual(expected, 1 + 3 + 1 + 1 + 0)

        let summary = try index.summary(for: url)
        XCTAssertEqual(summary.eventCount, expected,
                       "streaming eventCount must match summed parseRecord counts")
    }
}
