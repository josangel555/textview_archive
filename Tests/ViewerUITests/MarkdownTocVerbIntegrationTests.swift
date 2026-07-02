import XCTest
import Foundation
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// TSK-1430 — end-to-end validation of the Insert-TOC fix through the REAL action
/// path a user triggers: the `edit-insert-toc` script verb → `ScriptVerb.apply`
/// (the palette/menu dispatch) → `model.insertTableOfContents()` → the active
/// file is mutated. Asserts the observable outcome: the inserted TOC anchors
/// EQUAL the rendered heading ids (`HTMLVisitor.uniqueSlug`), so the links
/// actually resolve — the thing that was broken (divergent slug). This is the
/// verb→dispatch→model→file hop the pure MarkdownTOC test can't cover.
@MainActor
final class MarkdownTocVerbIntegrationTests: HeadlessUITestCase {

    private var harness: HeadlessHarness!

    override func setUp() async throws {
        try await super.setUp()
        harness = HeadlessHarness(label: "MarkdownTocVerbIntegrationTests")
    }

    override func tearDown() async throws {
        harness?.cleanup()
        harness = nil
        try await super.tearDown()
    }

    private func openText(_ name: String, _ contents: String) throws -> (DocumentModel, URL) {
        let url = try harness.writeFile(name, contents)
        harness.model.open(url: url)
        return (harness.model, url)
    }

    func test_insertTOCVerb_anchorsMatchRenderedHeadingIDs() throws {
        // Headings that exercised the old divergent slug: punctuation, an
        // ampersand between spaces, and a duplicate.
        let doc = """
        # Q&A: Setup
        ## Setup & Config
        ## Setup & Config
        """
        let (model, url) = try openText("toc.md", doc)

        XCTAssertTrue(ScriptVerb.apply(verb: "edit-insert-toc", to: model, sessions: harness.sessions),
                      "the edit-insert-toc verb must be recognized + dispatched")

        let after = try String(contentsOf: url, encoding: .utf8)
        // The renderer's ids for these titles (collapse runs, trim, dedup):
        let ids = ["q-a-setup", "setup-config", "setup-config-1"]
        for id in ids {
            XCTAssertTrue(after.contains("(#\(id))"),
                          "the TOC must link #\(id) (the rendered heading id); got:\n\(after)")
        }
        // And it must NOT contain the OLD broken anchor form.
        XCTAssertFalse(after.contains("(#setup--config)"),
                       "the pre-fix double-dash anchor must be gone")
    }

    func test_insertTOCVerb_isIdempotent() throws {
        let (model, url) = try openText("toc2.md", "# Alpha\n## Beta\n")
        XCTAssertTrue(ScriptVerb.apply(verb: "edit-insert-toc", to: model, sessions: harness.sessions))
        let once = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(ScriptVerb.apply(verb: "edit-insert-toc", to: model, sessions: harness.sessions))
        let twice = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(once, twice, "re-running Insert-TOC must replace the block in place, not stack copies")
    }
}
