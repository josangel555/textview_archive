import XCTest
@testable import ViewerUI

/// TSK-1207 — the Rendered + Source find bars restore the previous find text on
/// reopen (Cmd+F), matching the editor bar (TSK-770). Implemented as a preserved
/// draft: dismiss empties the live query (so highlights clear via the existing
/// empty-query path) but saves it; show restores it.
@MainActor
final class FindCoordinatorDraftTests: XCTestCase {

    func test_rendered_reopenRestoresPreviousQuery() {
        let c = FindCoordinator()
        c.showRenderedBar()
        c.renderedQuery = "foo"
        c.dismissRenderedBar()
        XCTAssertEqual(c.renderedQuery, "",
                       "dismiss empties the live query so the <mark> highlights clear")
        c.showRenderedBar()
        XCTAssertEqual(c.renderedQuery, "foo",
                       "reopen restores the previous find text")
    }

    func test_source_reopenRestoresPreviousQuery() {
        let c = FindCoordinator()
        c.showSourceBar()
        c.sourceQuery = "bar"
        c.dismissSourceBar()
        XCTAssertEqual(c.sourceQuery, "", "dismiss empties the live query")
        c.showSourceBar()
        XCTAssertEqual(c.sourceQuery, "bar", "reopen restores the previous find text")
    }

    func test_dismissWithEmptyQuery_doesNotClobberDraft() {
        let c = FindCoordinator()
        c.renderedQuery = "keep"
        c.dismissRenderedBar()   // draft="keep", query=""
        c.dismissRenderedBar()   // query already "" → must NOT overwrite draft with ""
        c.showRenderedBar()
        XCTAssertEqual(c.renderedQuery, "keep",
                       "a second empty dismiss must not wipe the saved draft")
    }

    func test_freshBar_hasNoDraftToRestore() {
        let c = FindCoordinator()
        c.showRenderedBar()
        XCTAssertEqual(c.renderedQuery, "", "no prior search → opens empty")
    }
}
