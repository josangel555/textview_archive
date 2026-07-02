import XCTest
import Foundation
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// TSK-1431 — validate the Promote/Demote-Headings code-safety fix through the
/// REAL action path a user triggers: the `edit-demote-heading` script verb →
/// `ScriptVerb.apply` → `model.shiftActiveMarkdownHeadings` → the active file is
/// rewritten. Asserts the observable outcome: a `#` inside an indented (4-space)
/// code block is NOT shifted (the user's code is preserved), while the real
/// heading IS demoted.
@MainActor
final class HeadingShiftVerbIntegrationTests: HeadlessUITestCase {

    private var harness: HeadlessHarness!

    override func setUp() async throws {
        try await super.setUp()
        harness = HeadlessHarness(label: "HeadingShiftVerbIntegrationTests")
    }

    override func tearDown() async throws {
        harness?.cleanup()
        harness = nil
        try await super.tearDown()
    }

    func test_demoteHeadingVerb_preservesIndentedCode() throws {
        let docURL = try harness.writeFile("shift.md", """
        # Title

            # this line is indented code, not a heading

        ## Section
        """)
        harness.model.open(url: docURL)

        XCTAssertTrue(ScriptVerb.apply(verb: "edit-demote-heading", to: harness.model, sessions: harness.sessions),
                      "the edit-demote-heading verb must be recognized + dispatched")

        let after = try String(contentsOf: docURL, encoding: .utf8)
        XCTAssertTrue(after.contains("    # this line is indented code, not a heading"),
                      "the indented-code line must be UNCHANGED (not corrupted); got:\n\(after)")
        XCTAssertTrue(after.contains("## Title"), "the real H1 must be demoted to H2")
        XCTAssertTrue(after.contains("### Section"), "the real H2 must be demoted to H3")
    }
}
