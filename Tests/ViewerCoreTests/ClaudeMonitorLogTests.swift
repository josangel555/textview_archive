import XCTest
@testable import ViewerCore

/// Coverage for `ClaudeMonitorLog` (the hook-monitor JSONL reader) and an
/// end-to-end smoke of the `scripts/hooks/monitor-log.sh` writer. All scratch
/// lives in a per-test temp dir — never `~/.claude`.
final class ClaudeMonitorLogTests: XCTestCase {

    private var dir: URL!
    private let reader = ClaudeMonitorLog()

    override func setUp() {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MonitorLog-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func write(_ name: String, _ lines: [String]) -> URL {
        let url = dir.appendingPathComponent(name)
        try? (lines.joined(separator: "\n") + "\n").data(using: .utf8)!.write(to: url)
        return url
    }

    // MARK: - Parsing

    func test_parseLine_postToolUse_extractsFlatEnvelope() {
        let line = #"{"ts":"2026-06-04T07:15:09Z","host":"mac","pid":40231,"event":"PostToolUse","tool":"Edit","cwd":"/repo","session_id":"sess-1","tool_input_bytes":81,"tool_succeeded":true}"#
        let ev = reader.parseLine(Data(line.utf8), sequence: 3)
        XCTAssertNotNil(ev)
        XCTAssertEqual(ev?.sequence, 3)
        XCTAssertEqual(ev?.event, "PostToolUse")
        XCTAssertEqual(ev?.tool, "Edit")
        XCTAssertEqual(ev?.host, "mac")
        XCTAssertEqual(ev?.pid, 40231)
        XCTAssertEqual(ev?.cwd, "/repo")
        XCTAssertEqual(ev?.sessionId, "sess-1")
        XCTAssertEqual(ev?.toolSucceeded, true)
        XCTAssertEqual(ev?.toolInputBytes, 81)
        XCTAssertNotNil(ev?.timestamp)
    }

    func test_parseLine_userPromptSubmit_carriesPrompt() {
        let line = #"{"ts":"2026-06-04T07:15:02Z","event":"UserPromptSubmit","session_id":"s","prompt":"refactor the sidebar","prompt_len":20}"#
        let ev = reader.parseLine(Data(line.utf8), sequence: 0)
        XCTAssertEqual(ev?.event, "UserPromptSubmit")
        XCTAssertEqual(ev?.prompt, "refactor the sidebar")
        XCTAssertNil(ev?.tool)
    }

    func test_parseLine_failure_carriesError() {
        let line = #"{"event":"PostToolUseFailure","tool":"Bash","error":"command not found"}"#
        let ev = reader.parseLine(Data(line.utf8), sequence: 0)
        XCTAssertEqual(ev?.errorMessage, "command not found")
        XCTAssertEqual(ev?.tool, "Bash")
    }

    func test_parseLine_missingOptionalFields_areNil() {
        // Minimal record: only event present; all other fields nil.
        let ev = reader.parseLine(Data(#"{"event":"Stop"}"#.utf8), sequence: 0)
        XCTAssertEqual(ev?.event, "Stop")
        XCTAssertNil(ev?.tool)
        XCTAssertNil(ev?.cwd)
        XCTAssertNil(ev?.sessionId)
        XCTAssertNil(ev?.toolInputBytes)
        XCTAssertNil(ev?.toolSucceeded)
    }

    func test_parseLine_blankOrGarbage_isNil() {
        XCTAssertNil(reader.parseLine(Data(), sequence: 0))
        XCTAssertNil(reader.parseLine(Data("not json".utf8), sequence: 0))
        XCTAssertNil(reader.parseLine(Data("[1,2,3]".utf8), sequence: 0), "array is not an object")
    }

    func test_parse_skipsBlankLines_butAdvancesSequence() {
        let blob = Data((
            #"{"event":"SessionStart"}"# + "\n"
            + "\n"   // blank line in the middle
            + #"{"event":"Stop"}"# + "\n"
        ).utf8)
        let events = reader.parse(blob)
        XCTAssertEqual(events.map(\.event), ["SessionStart", "Stop"])
        // The blank line consumed sequence 1, so Stop is sequence 2.
        XCTAssertEqual(events.last?.sequence, 2)
    }

    func test_eventsInFile_readsBackWhatWasWritten() throws {
        let url = write("s.jsonl", [
            #"{"event":"SessionStart"}"#,
            #"{"event":"PostToolUse","tool":"Read"}"#,
        ])
        let events = try reader.events(inFile: url)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[1].tool, "Read")
    }

    func test_eventsInFile_missing_throws() {
        XCTAssertThrowsError(try reader.events(inFile: dir.appendingPathComponent("nope.jsonl")))
    }

    func test_sessionsInDir_groupsByStem_sorted() throws {
        _ = write("b-sess.jsonl", [#"{"event":"Stop"}"#])
        _ = write("a-sess.jsonl", [#"{"event":"SessionStart"}"#])
        _ = write("notes.txt", ["ignored"])
        let sessions = reader.sessions(inDir: dir)
        XCTAssertEqual(sessions.map(\.key), ["a-sess", "b-sess"], "stems, sorted, .txt ignored")
    }

    // MARK: - Aggregations

    private func ev(_ event: String, tool: String? = nil, ts: String? = nil,
                    succeeded: Bool? = nil, error: String? = nil, seq: Int = 0) -> ClaudeMonitorEvent {
        let date = ts.flatMap { ISO8601DateFormatter().date(from: $0) }
        return ClaudeMonitorEvent(
            sequence: seq, timestamp: date, host: nil, pid: nil, event: event,
            tool: tool, cwd: nil, sessionId: nil, errorMessage: error,
            toolSucceeded: succeeded)
    }

    func test_toolFrequency_countsAndSorts() {
        let events = [ev("PostToolUse", tool: "Edit"), ev("PostToolUse", tool: "Read"),
                      ev("PostToolUse", tool: "Edit"), ev("Stop")]
        let freq = ClaudeMonitorLog.toolFrequency(events)
        XCTAssertEqual(freq.first?.tool, "Edit")
        XCTAssertEqual(freq.first?.count, 2)
        XCTAssertEqual(freq.map(\.tool), ["Edit", "Read"], "desc by count")
    }

    func test_failures_collectsAllThreeSignals() {
        let events = [
            ev("PostToolUseFailure", tool: "Bash"),
            ev("PostToolUse", tool: "Edit", succeeded: false),
            ev("Notification", error: "blocked"),
            ev("PostToolUse", tool: "Read", succeeded: true),   // not a failure
        ]
        XCTAssertEqual(ClaudeMonitorLog.failures(events).count, 3)
    }

    func test_turnLatencies_pairsPromptToStop() {
        let events = [
            ev("UserPromptSubmit", ts: "2026-06-04T07:00:00Z"),
            ev("PostToolUse", tool: "Edit"),
            ev("Stop", ts: "2026-06-04T07:00:05Z"),               // 5s turn
            ev("UserPromptSubmit", ts: "2026-06-04T07:01:00Z"),
            ev("Stop", ts: "2026-06-04T07:01:02Z"),               // 2s turn
            ev("UserPromptSubmit", ts: "2026-06-04T07:02:00Z"),   // in-flight, no Stop
        ]
        let lats = ClaudeMonitorLog.turnLatencies(events)
        XCTAssertEqual(lats, [5, 2], "two completed turns; the dangling prompt is omitted")
    }

    func test_turnLatencies_doubledPrompt_lastWins() {
        let events = [
            ev("UserPromptSubmit", ts: "2026-06-04T07:00:00Z"),
            ev("UserPromptSubmit", ts: "2026-06-04T07:00:10Z"),   // supersedes
            ev("Stop", ts: "2026-06-04T07:00:15Z"),               // 5s from the 2nd
        ]
        XCTAssertEqual(ClaudeMonitorLog.turnLatencies(events), [5])
    }

    // MARK: - End-to-end: the shell writer round-trips through the reader

    /// Runs the real `monitor-log.sh` against a temp `MDV_MONITOR_LOG_DIR`,
    /// feeds it a hook payload on stdin, then parses the file it wrote back
    /// with `ClaudeMonitorLog`. Skips when `jq`/`bash` are unavailable so the
    /// host gate never reds on environment shape. jq is located via `which`
    /// (PATH), not a hardcoded path, so it isn't silently skipped on MacPorts /
    /// custom installs.
    func test_scriptWriter_roundTripsThroughReader() throws {
        let bash = "/bin/bash"
        guard FileManager.default.isExecutableFile(atPath: bash), jqIsAvailable()
        else { throw XCTSkip("jq/bash not available on PATH") }

        let script = packageRoot().appendingPathComponent("scripts/hooks/monitor-log.sh")
        guard FileManager.default.fileExists(atPath: script.path) else {
            throw XCTSkip("monitor-log.sh not found at \(script.path)")
        }

        // Payload carries a secret in tool_input.contents — it must NOT reach disk.
        let secret = "SECRET_TOKEN_dead_beef_must_not_persist"
        let payload = #"{"hook_event_name":"PostToolUse","session_id":"sess-rt","tool_name":"Write","cwd":"/repo","tool_input":{"file_path":"/repo/y.swift","contents":"\#(secret)"},"tool_response":{"success":true}}"#

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bash)
        proc.arguments = [script.path]
        var env = ProcessInfo.processInfo.environment
        env["MDV_MONITOR_LOG_DIR"] = dir.path
        proc.environment = env
        let stdin = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try proc.run()
        stdin.fileHandleForWriting.write(Data(payload.utf8))
        try stdin.fileHandleForWriting.close()
        proc.waitUntilExit()
        XCTAssertEqual(proc.terminationStatus, 0, "monitor must always exit 0")

        let logFile = dir.appendingPathComponent("sess-rt.jsonl")
        let events = try reader.events(inFile: logFile)
        XCTAssertEqual(events.count, 1)
        let e = events[0]
        XCTAssertEqual(e.event, "PostToolUse")
        XCTAssertEqual(e.tool, "Write")
        XCTAssertEqual(e.sessionId, "sess-rt")
        XCTAssertEqual(e.cwd, "/repo")
        XCTAssertEqual(e.toolSucceeded, true)
        XCTAssertNotNil(e.toolInputBytes, "tool_input reduced to a byte count")
        XCTAssertNotNil(e.timestamp, "script stamps an ISO-8601 ts the reader parses")

        // Privacy regression guard: the raw secret must never be persisted.
        let onDisk = (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
        XCTAssertFalse(onDisk.contains(secret),
                       "monitor log leaked tool_input contents to disk")
    }

    /// True if `jq` is resolvable on PATH (via `which`), independent of where
    /// it's installed (/usr/bin, Homebrew, MacPorts, …).
    private func jqIsAvailable() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        p.arguments = ["jq"]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// Walk up from this test file to the package root (the dir holding
    /// `Package.swift`).
    private func packageRoot(file: StaticString = #filePath) -> URL {
        var url = URL(fileURLWithPath: "\(file)")
        for _ in 0..<8 {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath:
                url.appendingPathComponent("Package.swift").path) {
                return url
            }
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }
}
