import XCTest
import Foundation
import ViewerCore

/// UAT (usability audit 2026-07-02, TSK-1411): the in-app HTTP client is a real,
/// reachable feature (HTTPClientView — request builder + response/error/empty
/// states; pure host-tested HTTPClientCore) reachable via File → New HTTP
/// Request (TSK-721). It had NO script-verb (a cohesion gap vs show-folder-
/// treemap) and NO real-app UI-drive coverage. This tick added the
/// `show-http-client` verb; this UAT drives it on the assembled app and asserts
/// the "HTTP Request" hosted tab opens live.
///
/// TIER-JUSTIFY: T4 — the observable is the assembled bundle's real verb →
/// openHostedView path via `--script`; self-skips off the VM GUI lane. (The
/// request/response PIXELS are the TSK-1334-gated tail; this confirms reach +
/// open — "can the user actually get to the HTTP tool".)
@MainActor
final class HTTPClientUATTests: MultiScenarioTestCase {

    override class var harnessLabel: String { "HTTPClientUAT" }

    private func modelString(_ dump: [String: Any], _ key: String) -> String {
        (dump["model"] as? [String: Any])?[key] as? String ?? ""
    }
    private func modelInt(_ dump: [String: Any], _ key: String) -> Int {
        (dump["model"] as? [String: Any])?[key] as? Int ?? -1
    }

    /// HTTP-UAT-01 — run `show-http-client`; the "HTTP Request" hosted tab opens
    /// on the real app (window title names it + the tab is additive).
    func test_HTTP01_showHTTPClient_opensHostedTabLive() throws {
        let readme = try harness.writeFile("readme.md", "# launch doc\n")
        let script = """
        show-http-client
        delay
        delay
        """
        try runScenarios([
            Scenario(
                name: "http-client-opens",
                argFile: readme,
                script: script,
                assert: { [self] dumps, file, line in
                    XCTAssertFalse(dumps.isEmpty, "[http01] no dumps — app may not have launched",
                                   file: file, line: line)
                    let opened = dumps.contains { modelString($0, "windowTitle").contains("HTTP Request") }
                    XCTAssertTrue(opened,
                        "[http01] show-http-client did not open an 'HTTP Request' hosted tab live; "
                        + "titles seen=\(dumps.map { modelString($0, "windowTitle") }.suffix(4))",
                        file: file, line: line)
                    let maxTabs = dumps.map { modelInt($0, "tabCount") }.max() ?? 0
                    XCTAssertGreaterThanOrEqual(maxTabs, 2,
                        "[http01] expected the HTTP tab to be additive (>=2 tabs); max=\(maxTabs)",
                        file: file, line: line)
                })
        ])
    }
}
