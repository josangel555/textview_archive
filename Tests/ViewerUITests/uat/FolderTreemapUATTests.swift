import XCTest
import Foundation
import ViewerCore

/// UAT (usability audit 2026-07-02, TSK-1411): the folder treemap is a real,
/// reachable feature (FolderTreemapView Canvas renderer + TreemapLayout engine
/// + off-main scan model; host-tested engine/wiring/palette) — but it had NO
/// real-app UI-drive coverage. This drives the `show-folder-treemap` script-verb
/// on the assembled app and asserts the "Folder Sizes:" hosted tab actually
/// opens live (the wiring test proves it at the model level; this proves the
/// FULL verb → openHostedView path fires in the real running app).
///
/// TIER-JUSTIFY: T4 — the observable is the assembled bundle's real verb-
/// dispatch → hosted-tab-open path via `--script`; self-skips off the VM GUI
/// lane. (The Canvas tile PIXELS are the TSK-1334-gated tail; this confirms the
/// reach + open behavior — "can the user actually get to the treemap".)
@MainActor
final class FolderTreemapUATTests: MultiScenarioTestCase {

    override class var harnessLabel: String { "FolderTreemapUAT" }

    private func modelString(_ dump: [String: Any], _ key: String) -> String {
        (dump["model"] as? [String: Any])?[key] as? String ?? ""
    }
    private func modelInt(_ dump: [String: Any], _ key: String) -> Int {
        (dump["model"] as? [String: Any])?[key] as? Int ?? -1
    }

    /// TM-UAT-01 — set a folder root, then run `show-folder-treemap`; a hosted
    /// "Folder Sizes:" tab opens on the real app (tab count grows + the active
    /// window title names the treemap).
    func test_TM01_showFolderTreemap_opensHostedTabLive() throws {
        // A small project folder with a couple of files to scan.
        _ = try harness.writeFile("proj/big.txt", String(repeating: "x", count: 4096))
        _ = try harness.writeFile("proj/small.txt", "y\n")
        let readme = try harness.writeFile("readme.md", "# launch doc\n")
        let projPath = harness.tmpDir.appendingPathComponent("proj").path

        let script = """
        sidebar-set-root \(projPath)
        delay
        show-folder-treemap
        delay
        delay
        """
        try runScenarios([
            Scenario(
                name: "treemap-opens",
                argFile: readme,
                script: script,
                assert: { [self] dumps, file, line in
                    XCTAssertFalse(dumps.isEmpty, "[tm01] no dumps — app may not have launched",
                                   file: file, line: line)
                    let opened = dumps.contains { modelString($0, "windowTitle").contains("Folder Sizes") }
                    XCTAssertTrue(opened,
                        "[tm01] show-folder-treemap did not open a 'Folder Sizes' hosted tab live; "
                        + "titles seen=\(dumps.map { modelString($0, "windowTitle") }.suffix(4))",
                        file: file, line: line)
                    // The treemap tab is additive (launch doc + treemap => >= 2).
                    let maxTabs = dumps.map { modelInt($0, "tabCount") }.max() ?? 0
                    XCTAssertGreaterThanOrEqual(maxTabs, 2,
                        "[tm01] expected the treemap tab to be additive (>=2 tabs); max=\(maxTabs)",
                        file: file, line: line)
                })
        ])
    }
}
