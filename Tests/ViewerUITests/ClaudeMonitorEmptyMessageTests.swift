import XCTest
@testable import ViewerUI
@testable import ViewerCore

/// TSK-1477 — the monitor's actionable empty-state message mapping (host).
/// The classification + refresh fingerprint are tested in ViewerCoreTests;
/// this pins that each empty reason yields a distinct, path-bearing message
/// (not the old generic "none found").
final class ClaudeMonitorEmptyMessageTests: XCTestCase {

    func test_rootMissing_namesPathAndFix() {
        let msg = ClaudeMonitorView.emptyMessage(.empty(.rootMissing(path: "/x/gone")))
        XCTAssertTrue(msg.contains("/x/gone"))
        XCTAssertTrue(msg.lowercased().contains("doesn't exist"))
        XCTAssertTrue(msg.contains("MDV_MONITOR_ROOT"), "points at the configurable path")
    }

    func test_notAClaudeDir_asksIfItsTheRightFolder() {
        let msg = ClaudeMonitorView.emptyMessage(.empty(.notAClaudeDir(path: "/x/home")))
        XCTAssertTrue(msg.contains("/x/home"))
        XCTAssertTrue(msg.contains("projects/"), "explains the missing marker dir")
    }

    func test_noTranscripts_isDistinctFromMissing() {
        let missing = ClaudeMonitorView.emptyMessage(.empty(.rootMissing(path: "/p")))
        let empty = ClaudeMonitorView.emptyMessage(.empty(.noTranscripts(path: "/p")))
        XCTAssertNotEqual(missing, empty, "each reason reads differently")
        XCTAssertTrue(empty.lowercased().contains("no transcripts"))
    }

    func test_everyEmptyReason_isDistinct() {
        let msgs = [
            ClaudeMonitorView.emptyMessage(.empty(.rootMissing(path: "/p"))),
            ClaudeMonitorView.emptyMessage(.empty(.notAClaudeDir(path: "/p"))),
            ClaudeMonitorView.emptyMessage(.empty(.noTranscripts(path: "/p"))),
        ]
        XCTAssertEqual(Set(msgs).count, 3, "no two empty reasons collapse to the same text")
    }
}
