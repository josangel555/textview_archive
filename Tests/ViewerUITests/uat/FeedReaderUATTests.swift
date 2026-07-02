import XCTest
import Foundation
import ViewerCore

/// UAT (usability audit 2026-07-02, TSK-1417): the RSS/feed reader was fully
/// built + host-tested but ORPHANED (nothing instantiated it → unreachable).
/// Owner chose FINISH → wired File → Feed Reader + the `show-feed-reader` verb.
/// This drives the verb on the assembled app and asserts the "Feeds" hosted tab
/// opens live — proving the previously-dead feature is now reachable by a user.
///
/// TIER-JUSTIFY: T4 — the observable is the assembled bundle's real verb →
/// openFeedReader → openHostedView path via `--script`; self-skips off the VM
/// GUI lane. (Feed-list/reader PIXELS are the TSK-1334-gated tail; this confirms
/// reach + open — "can the user actually get to the feed reader now".)
@MainActor
final class FeedReaderUATTests: MultiScenarioTestCase {

    override class var harnessLabel: String { "FeedReaderUAT" }

    private func modelString(_ dump: [String: Any], _ key: String) -> String {
        (dump["model"] as? [String: Any])?[key] as? String ?? ""
    }
    private func modelInt(_ dump: [String: Any], _ key: String) -> Int {
        (dump["model"] as? [String: Any])?[key] as? Int ?? -1
    }

    /// FEED-UAT-01 — run `show-feed-reader`; the "Feeds" hosted tab opens on the
    /// real app (window title names it + the tab is additive). Proves the orphan
    /// is now reachable end-to-end.
    func test_FEED01_showFeedReader_opensHostedTabLive() throws {
        let readme = try harness.writeFile("readme.md", "# launch doc\n")
        let script = """
        show-feed-reader
        delay
        delay
        """
        try runScenarios([
            Scenario(
                name: "feed-reader-opens",
                argFile: readme,
                script: script,
                assert: { [self] dumps, file, line in
                    XCTAssertFalse(dumps.isEmpty, "[feed01] no dumps — app may not have launched",
                                   file: file, line: line)
                    let opened = dumps.contains { modelString($0, "windowTitle").contains("Feeds") }
                    XCTAssertTrue(opened,
                        "[feed01] show-feed-reader did not open a 'Feeds' hosted tab live; "
                        + "titles seen=\(dumps.map { modelString($0, "windowTitle") }.suffix(4))",
                        file: file, line: line)
                    let maxTabs = dumps.map { modelInt($0, "tabCount") }.max() ?? 0
                    XCTAssertGreaterThanOrEqual(maxTabs, 2,
                        "[feed01] expected the Feeds tab to be additive (>=2 tabs); max=\(maxTabs)",
                        file: file, line: line)
                })
        ])
    }
}
