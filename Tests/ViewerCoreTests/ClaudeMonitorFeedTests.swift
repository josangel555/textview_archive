import XCTest
@testable import ViewerCore

/// Coverage for the TSK-336 slice (a) surfacing logic in `ClaudeMonitorLog`:
/// the per-project hook feed (`projectEvents`), the `cwd`-containment filter,
/// and `ClaudeMonitorEvent.summary` / `.isFailure` / `formatBytes`. These are
/// the pure pieces the new "Hooks" sidebar segment renders, so a regression
/// here (wrong attribution, leaked raw payload, mis-ordered feed) fails the
/// host gate even though the SwiftUI render is VM-only.
final class ClaudeMonitorFeedTests: XCTestCase {

    private var dir: URL!
    private let reader = ClaudeMonitorLog()

    override func setUp() {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MonitorFeed-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    @discardableResult
    private func write(_ name: String, _ lines: [String]) -> URL {
        let url = dir.appendingPathComponent(name)
        try? (lines.joined(separator: "\n") + "\n").data(using: .utf8)!.write(to: url)
        return url
    }

    private func ev(_ event: String, tool: String? = nil, cwd: String? = nil,
                    ts: String? = nil, succeeded: Bool? = nil, error: String? = nil,
                    bytes: Int? = nil, seq: Int = 0) -> ClaudeMonitorEvent {
        let date = ts.flatMap { ISO8601DateFormatter().date(from: $0) }
        return ClaudeMonitorEvent(
            sequence: seq, timestamp: date, host: nil, pid: nil, event: event,
            tool: tool, cwd: cwd, sessionId: nil, errorMessage: error,
            toolInputBytes: bytes, toolSucceeded: succeeded)
    }

    // MARK: - summary

    func test_summary_toolWithSize() {
        XCTAssertEqual(ev("PostToolUse", tool: "Edit", bytes: 81).summary, "Edit · 81 B")
    }

    func test_summary_toolWithoutSize_isJustTheTool() {
        XCTAssertEqual(ev("PostToolUse", tool: "Read").summary, "Read")
        // bytes: 0 is treated as "no size" — no trailing " · 0 B".
        XCTAssertEqual(ev("PostToolUse", tool: "Read", bytes: 0).summary, "Read")
    }

    func test_summary_failedTool_showsFailedNotSize() {
        let e = ev("PostToolUse", tool: "Bash", succeeded: false, bytes: 12)
        XCTAssertTrue(e.isFailure)
        XCTAssertEqual(e.summary, "Bash · failed")
    }

    func test_summary_eventWithoutTool_isEventName() {
        XCTAssertEqual(ev("UserPromptSubmit").summary, "UserPromptSubmit")
        XCTAssertEqual(ev("Stop").summary, "Stop")
    }

    func test_summary_failureWithoutTool_appendsErrorMessage() {
        XCTAssertEqual(ev("Notification", error: "blocked").summary, "Notification · blocked")
    }

    func test_summary_neverLeaksRawPrompt() {
        // The prompt field exists on the model but must NEVER appear in the row
        // summary (privacy contract for the surfaced feed — TSK-336/TSK-178).
        let e = ClaudeMonitorEvent(
            sequence: 0, timestamp: nil, host: nil, pid: nil, event: "UserPromptSubmit",
            tool: nil, cwd: nil, sessionId: nil, prompt: "my secret token sk-12345")
        XCTAssertFalse(e.summary.contains("sk-12345"))
        XCTAssertFalse(e.summary.contains("secret"))
        XCTAssertEqual(e.summary, "UserPromptSubmit")
    }

    // MARK: - isFailure

    func test_isFailure_allThreeSignals() {
        XCTAssertTrue(ev("PostToolUseFailure", tool: "Bash").isFailure)
        XCTAssertTrue(ev("PostToolUse", tool: "Edit", succeeded: false).isFailure)
        XCTAssertTrue(ev("Notification", error: "blocked").isFailure)
        XCTAssertFalse(ev("PostToolUse", tool: "Read", succeeded: true).isFailure)
        XCTAssertFalse(ev("Stop").isFailure)
    }

    // MARK: - formatBytes

    func test_formatBytes_units() {
        XCTAssertEqual(ClaudeMonitorEvent.formatBytes(0), "0 B")
        XCTAssertEqual(ClaudeMonitorEvent.formatBytes(1023), "1023 B")
        XCTAssertEqual(ClaudeMonitorEvent.formatBytes(1024), "1.0 KB")
        XCTAssertEqual(ClaudeMonitorEvent.formatBytes(2048), "2.0 KB")
        XCTAssertEqual(ClaudeMonitorEvent.formatBytes(1024 * 1024), "1.0 MB")
    }

    // MARK: - cwd containment

    func test_cwd_exactMatch() {
        XCTAssertTrue(ClaudeMonitorLog.cwd("/repo", isUnder: "/repo"))
    }

    func test_cwd_descendantMatches() {
        XCTAssertTrue(ClaudeMonitorLog.cwd("/repo/src/lib", isUnder: "/repo"))
    }

    func test_cwd_siblingPrefixDoesNotMatch() {
        // The classic hasPrefix bug: "/repo-other" must NOT match "/repo".
        XCTAssertFalse(ClaudeMonitorLog.cwd("/repo-other", isUnder: "/repo"))
        XCTAssertFalse(ClaudeMonitorLog.cwd("/repository", isUnder: "/repo"))
    }

    func test_cwd_outsideDoesNotMatch() {
        XCTAssertFalse(ClaudeMonitorLog.cwd("/elsewhere", isUnder: "/repo"))
    }

    func test_cwd_nilOrEmpty_isFalse() {
        XCTAssertFalse(ClaudeMonitorLog.cwd(nil, isUnder: "/repo"))
        XCTAssertFalse(ClaudeMonitorLog.cwd("", isUnder: "/repo"))
    }

    func test_cwd_trailingSlashNormalized() {
        XCTAssertTrue(ClaudeMonitorLog.cwd("/repo/", isUnder: "/repo"))
        XCTAssertTrue(ClaudeMonitorLog.cwd("/repo", isUnder: "/repo/"))
    }

    // MARK: - projectEvents (the per-project feed)

    func test_projectEvents_filtersToTheRoot() {
        write("sess-a.jsonl", [
            #"{"event":"PostToolUse","tool":"Edit","cwd":"/proj","ts":"2026-06-04T07:00:00Z"}"#,
            #"{"event":"PostToolUse","tool":"Read","cwd":"/other","ts":"2026-06-04T07:00:01Z"}"#,
        ])
        let out = reader.projectEvents(inDir: dir, root: URL(fileURLWithPath: "/proj"))
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.tool, "Edit")
    }

    func test_projectEvents_mergesAcrossSessionFiles() {
        write("sess-a.jsonl", [
            #"{"event":"PostToolUse","tool":"Edit","cwd":"/proj","ts":"2026-06-04T07:00:00Z"}"#,
        ])
        write("sess-b.jsonl", [
            #"{"event":"PostToolUse","tool":"Bash","cwd":"/proj/sub","ts":"2026-06-04T08:00:00Z"}"#,
        ])
        let out = reader.projectEvents(inDir: dir, root: URL(fileURLWithPath: "/proj"))
        XCTAssertEqual(out.count, 2)
        // Most-recent first: 08:00 (Bash) before 07:00 (Edit).
        XCTAssertEqual(out.map(\.tool), ["Bash", "Edit"])
    }

    func test_projectEvents_dropsRecordsWithNoCwd() {
        write("sess.jsonl", [
            #"{"event":"Stop","ts":"2026-06-04T07:00:00Z"}"#,
            #"{"event":"PostToolUse","tool":"Edit","cwd":"/proj","ts":"2026-06-04T07:00:01Z"}"#,
        ])
        let out = reader.projectEvents(inDir: dir, root: URL(fileURLWithPath: "/proj"))
        XCTAssertEqual(out.count, 1, "the cwd-less Stop can't be attributed → dropped")
        XCTAssertEqual(out.first?.tool, "Edit")
    }

    func test_projectEvents_capsResults() {
        let lines = (0..<10).map {
            #"{"event":"PostToolUse","tool":"Edit","cwd":"/proj","ts":"2026-06-04T07:00:0\#($0)Z"}"#
        }
        write("sess.jsonl", lines)
        let out = reader.projectEvents(inDir: dir, root: URL(fileURLWithPath: "/proj"), cap: 3)
        XCTAssertEqual(out.count, 3)
        // Cap keeps the most recent: ...:09, ...:08, ...:07.
        XCTAssertEqual(out.first?.timestamp,
                       ISO8601DateFormatter().date(from: "2026-06-04T07:00:09Z"))
    }

    func test_projectEvents_missingDir_isEmpty() {
        let out = reader.projectEvents(
            inDir: dir.appendingPathComponent("nope", isDirectory: true),
            root: URL(fileURLWithPath: "/proj"))
        XCTAssertTrue(out.isEmpty)
    }

    func test_projectEvents_nilTimestampSinksToBottom() {
        write("sess.jsonl", [
            #"{"event":"PostToolUse","tool":"NoTs","cwd":"/proj"}"#,
            #"{"event":"PostToolUse","tool":"HasTs","cwd":"/proj","ts":"2026-06-04T07:00:00Z"}"#,
        ])
        let out = reader.projectEvents(inDir: dir, root: URL(fileURLWithPath: "/proj"))
        XCTAssertEqual(out.map(\.tool), ["HasTs", "NoTs"], "the timestamped event wins the top slot")
    }
}
