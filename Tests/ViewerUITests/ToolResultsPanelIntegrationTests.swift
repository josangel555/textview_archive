import XCTest
import Foundation
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// TSK-1434 — command-path validation of the shared results panel: drive the
/// four tools via their REAL script verbs (the same dispatch the menu/palette
/// trigger) and assert the panel's observable model state — populated rows,
/// row-click → goto-line channel, dismiss. This is what replaced the modal
/// alerts, so the wiring itself is the feature.
@MainActor
final class ToolResultsPanelIntegrationTests: HeadlessUITestCase {

    private var harness: HeadlessHarness!

    override func setUp() async throws {
        try await super.setUp()
        harness = HeadlessHarness(label: "ToolResultsPanelIntegrationTests")
    }

    override func tearDown() async throws {
        harness?.cleanup()
        harness = nil
        try await super.tearDown()
    }

    private func apply(_ verb: String) -> Bool {
        ScriptVerb.apply(verb: verb, to: harness.model, sessions: harness.sessions)
    }

    func test_checkLinksVerb_populatesPanel_rowClickGoesToLine() throws {
        let url = try harness.writeFile("links.md", "ok [a](missing.md)\n\nand [b](alsomissing.md)\n")
        harness.model.open(url: url)

        XCTAssertNil(harness.model.toolResults, "panel starts hidden")
        XCTAssertTrue(apply("check-links"))
        let results = try XCTUnwrap(harness.model.toolResults, "check-links must populate the panel")
        XCTAssertTrue(results.title.contains("2 of 2 broken"), results.title)
        XCTAssertEqual(results.rows.map(\.line), [1, 3])
        XCTAssertTrue(results.rows.allSatisfy { $0.severity == .error })

        // Row click routes to the goto-line channel (same primitive as the verb).
        let nonceBefore = harness.model.sourceScrollLineNonce
        harness.model.activateToolResultRow(results.rows[1])
        XCTAssertEqual(harness.model.sourceScrollLineTarget, 3, "row click must target its line")
        XCTAssertGreaterThan(harness.model.sourceScrollLineNonce, nonceBefore)
        XCTAssertNotNil(harness.model.toolResults, "panel stays open while walking results")
    }

    func test_lintAndStatsAndCSVVerbs_populate_dismissCloses() throws {
        let md = try harness.writeFile("doc.md", "# A\n\n![](x.png)\n")
        harness.model.open(url: md)
        XCTAssertTrue(apply("lint-markdown"))
        XCTAssertTrue(harness.model.toolResults?.title.hasPrefix("Lint") ?? false)

        XCTAssertTrue(apply("document-stats"))
        XCTAssertEqual(harness.model.toolResults?.title, "Document Statistics")
        XCTAssertEqual(harness.model.toolResults?.rows.count, 4)

        let csv = try harness.writeFile("d.csv", "a,b\n1,2\n")
        harness.model.open(url: csv)
        XCTAssertTrue(apply("csv-summary"))
        XCTAssertTrue(harness.model.toolResults?.title.contains("CSV") ?? false)

        XCTAssertTrue(apply("dismiss-tool-results"))
        XCTAssertNil(harness.model.toolResults, "dismiss closes the panel")
    }

    func test_checkLinks_noMarkdownActive_noPanel() throws {
        let txt = try harness.writeFile("t.txt", "no markdown here")
        harness.model.open(url: txt)
        _ = apply("check-links")
        XCTAssertNil(harness.model.toolResults, "non-markdown: tool doesn't run, panel stays hidden")
    }
}
