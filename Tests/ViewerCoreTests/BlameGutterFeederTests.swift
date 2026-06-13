import XCTest
@testable import ViewerCore

/// TSK-814 — `BlameGutterFeeder` maps `git blame` lines to the CM6 gutter
/// marker payload. Pure + host-testable (`now` injected for a deterministic
/// relative-time tooltip).
final class BlameGutterFeederTests: XCTestCase {

    private func line(_ l: Int, _ sha: String, _ author: String, _ ts: Int, _ summary: String)
        -> GitClient.BlameLine {
        GitClient.BlameLine(line: l, sha: sha, author: author, timestamp: ts, summary: summary)
    }

    func test_markers_sortedBlameKind_withAuthorTimeSummaryShaTooltip() {
        let now = Date(timeIntervalSince1970: 1_700_300_000)
        // Deliberately out of order → must come back sorted by line.
        let blame = [
            line(3, "a1b2c3d4", "Alice", 1_700_000_000, "Add the parser"),
            line(1, "e5f6a7b8", "Bob", 1_700_200_000, "Fix the bug"),
        ]
        let markers = BlameGutterFeeder.markers(from: blame, now: now)

        XCTAssertEqual(markers.map(\.line), [1, 3], "sorted ascending by line")
        XCTAssertTrue(markers.allSatisfy { $0.kind == "blame" }, "all markers are blame-kind")

        let tip = markers[0].tooltip ?? ""   // line 1 = Bob's
        XCTAssertTrue(tip.contains("Bob"), tip)
        XCTAssertTrue(tip.contains("Fix the bug"), tip)
        XCTAssertTrue(tip.contains("e5f6a7b8"), tip)
        XCTAssertTrue(tip.contains(GitRelativeTime.format(unix: 1_700_200_000, now: now)),
                      "tooltip carries the relative author-time: \(tip)")
    }

    func test_blankSummary_dropsTheTrailingSummaryField() {
        let now = Date(timeIntervalSince1970: 1_700_300_000)
        let when = GitRelativeTime.format(unix: 1_700_000_000, now: now)
        let tip = BlameGutterFeeder.markers(
            from: [line(1, "deadbeef", "Uncommitted", 1_700_000_000, "")], now: now)[0].tooltip ?? ""
        XCTAssertEqual(tip, "Uncommitted · \(when)  [deadbeef]",
                       "an empty summary must not leave a dangling ` · ` field")
    }
}
