import XCTest
import ViewerCore

/// Coverage for `ClaudeMonitorLog.eventCounts` / `.toolFrequency` — the
/// monitor's per-type aggregations. Both were untested. The load-bearing
/// contract is the sort: descending by count, then ascending by name as a
/// stable tie-break (so equal-count rows have a deterministic order), plus
/// `toolFrequency`'s skip of events with no `tool`.
final class ClaudeMonitorAggregationTests: XCTestCase {

    private func ev(_ event: String, tool: String? = nil) -> ClaudeMonitorEvent {
        ClaudeMonitorEvent(
            sequence: 0, timestamp: nil, host: nil, pid: nil,
            event: event, tool: tool, cwd: nil, sessionId: nil)
    }

    // MARK: - eventCounts

    func test_eventCounts_empty() {
        XCTAssertTrue(ClaudeMonitorLog.eventCounts([]).isEmpty)
    }

    func test_eventCounts_descendingByCount() {
        let events = [ev("Pre"), ev("Pre"), ev("Pre"), ev("Post"), ev("Post"), ev("Stop")]
        let r = ClaudeMonitorLog.eventCounts(events)
        XCTAssertEqual(r.map(\.event), ["Pre", "Post", "Stop"])
        XCTAssertEqual(r.map(\.count), [3, 2, 1])
    }

    func test_eventCounts_tieBreakAscendingByName() {
        let r = ClaudeMonitorLog.eventCounts([ev("Zeta"), ev("Alpha"), ev("Mid")])
        // All count 1 → alphabetical.
        XCTAssertEqual(r.map(\.event), ["Alpha", "Mid", "Zeta"])
    }

    // MARK: - toolFrequency

    func test_toolFrequency_skipsEventsWithoutTool() {
        let events = [
            ev("PreToolUse", tool: "Bash"),
            ev("Stop"),                      // no tool → ignored
            ev("PreToolUse", tool: "Bash"),
            ev("PreToolUse", tool: "Read"),
        ]
        let r = ClaudeMonitorLog.toolFrequency(events)
        XCTAssertEqual(r.map(\.tool), ["Bash", "Read"])
        XCTAssertEqual(r.map(\.count), [2, 1])
    }

    func test_toolFrequency_tieBreakAscendingByName() {
        let r = ClaudeMonitorLog.toolFrequency([ev("x", tool: "Write"), ev("x", tool: "Edit")])
        XCTAssertEqual(r.map(\.tool), ["Edit", "Write"])
    }

    func test_toolFrequency_allNil_isEmpty() {
        XCTAssertTrue(ClaudeMonitorLog.toolFrequency([ev("Stop"), ev("Notification")]).isEmpty)
    }
}
