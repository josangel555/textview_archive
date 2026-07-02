import XCTest
import Foundation
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// TSK-1429 — validate the "Check Links" fix through the REAL command path
/// (`model.checkLinksInActiveMarkdown()`, what the Tools ▸ Check Links menu item
/// invokes) with on-disk resolution: a `[text](url)` inside an inline code span
/// must NOT be treated as a link and must NOT be reported broken. This exercises
/// verb-command → MarkdownLinks → FileManager existence, a step above the pure
/// MarkdownLinks unit test.
@MainActor
final class CheckLinksCommandIntegrationTests: HeadlessUITestCase {

    private var harness: HeadlessHarness!

    override func setUp() async throws {
        try await super.setUp()
        harness = HeadlessHarness(label: "CheckLinksCommandIntegrationTests")
    }

    override func tearDown() async throws {
        harness?.cleanup()
        harness = nil
        try await super.tearDown()
    }

    func test_checkLinksCommand_ignoresCodeSpanLink_flagsOnlyRealBroken() throws {
        // A real sibling that exists, plus a genuinely-missing target, plus a
        // link-shaped example written inside an inline code span.
        _ = try harness.writeFile("exists.md", "# target\n")
        let docURL = try harness.writeFile("doc.md", """
        See [real](exists.md) and [gone](missing.md).
        To link, write `[label](path.md)` — this is a code example, `[x](alsomissing.md)`.
        """)
        harness.model.open(url: docURL)

        let report = try XCTUnwrap(harness.model.checkLinksInActiveMarkdown(),
                                   "Check Links must produce a report for an active .md file")

        // Only the genuinely-missing real link is broken; the code-span examples
        // are not links at all.
        XCTAssertEqual(report.broken.map(\.target), ["missing.md"],
                       "only the real missing link is broken; code-span links must be ignored")
        // Total extracted links excludes the two code-span examples (real + gone).
        XCTAssertEqual(report.total, 2,
                       "code-span link-shaped text must not be counted as links")
    }
}
