import XCTest
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// TSK-705 — host coverage for the snippet tab-stop navigation DRIVING that the
/// CM6 Tab key triggers. `EditorCoordinator` owns the `SnippetSession`, walks it
/// on `snippetTab()` / `snippetShiftTab()`, and pushes a `CMSelectRequest` for
/// each stop. The Tab keypress interception + caret rendering is the editor/VM
/// tail; this pins the model/state outcome so a logic regression fails on the
/// host gate (CLAUDE.md rule 6).
@MainActor
final class SnippetSessionDrivingTests: XCTestCase {

    private func makeCoordinator() -> EditorCoordinator {
        EditorCoordinator(tabCoordinator: TabCoordinator())
    }

    // body "a${1:X}b$2c$0" → plainText "aXbc"; stops (relative): 1@1(1), 2@3(0), 0@4(0).
    private let snippet = Snippet(id: "t", name: "T", body: "a${1:X}b$2c$0")

    func test_begin_selectsFirstStop_andActivates() {
        let ec = makeCoordinator()
        XCTAssertFalse(ec.isSnippetSessionActive)
        XCTAssertTrue(ec.beginSnippetSession(snippet, insertedAt: 10))
        XCTAssertTrue(ec.isSnippetSessionActive,
                      "a session with stops flips the active flag so JS routes Tab")
        // First stop $1 at base+1, length 1 (selects the "X" placeholder).
        XCTAssertEqual(ec.editorSelectRequest?.anchor, 11)
        XCTAssertEqual(ec.editorSelectRequest?.head, 12)
        XCTAssertEqual(ec.activeSnippetSession?.current?.index, 1)
    }

    func test_begin_noTabStops_returnsFalse_noSession() {
        let ec = makeCoordinator()
        let plain = Snippet(id: "p", name: "P", body: "no stops here")
        XCTAssertFalse(ec.beginSnippetSession(plain, insertedAt: 0))
        XCTAssertFalse(ec.isSnippetSessionActive)
        XCTAssertNil(ec.editorSelectRequest)
    }

    func test_tab_walksStops_thenEndsAtFinal() {
        let ec = makeCoordinator()
        ec.beginSnippetSession(snippet, insertedAt: 10)

        // Tab → $2 at base+3, empty selection (bare caret).
        XCTAssertTrue(ec.snippetTab())
        XCTAssertEqual(ec.activeSnippetSession?.current?.index, 2)
        XCTAssertEqual(ec.editorSelectRequest?.anchor, 13)
        XCTAssertEqual(ec.editorSelectRequest?.head, 13)

        // Tab → $0 at base+4 (the final stop), bare caret. Session ends here.
        XCTAssertTrue(ec.snippetTab())
        XCTAssertFalse(ec.isSnippetSessionActive,
                       "passing onto the final $0 ends the session")
        XCTAssertEqual(ec.editorSelectRequest?.anchor, 14)
        XCTAssertEqual(ec.editorSelectRequest?.head, 14)
    }

    func test_tab_withNoSession_returnsFalse() {
        let ec = makeCoordinator()
        XCTAssertFalse(ec.snippetTab(), "Tab falls through to normal indent")
    }

    func test_shiftTab_retreats_clampedAtFirst() {
        let ec = makeCoordinator()
        ec.beginSnippetSession(snippet, insertedAt: 10)
        ec.snippetTab()                       // now at $2
        XCTAssertEqual(ec.activeSnippetSession?.current?.index, 2)

        XCTAssertTrue(ec.snippetShiftTab())   // back to $1
        XCTAssertEqual(ec.activeSnippetSession?.current?.index, 1)
        XCTAssertEqual(ec.editorSelectRequest?.anchor, 11)

        XCTAssertTrue(ec.snippetShiftTab())   // clamped at $1
        XCTAssertEqual(ec.activeSnippetSession?.current?.index, 1)
    }

    func test_beginSnippetSession_replacesPriorSession() {
        let ec = makeCoordinator()
        ec.beginSnippetSession(snippet, insertedAt: 10)
        ec.snippetTab()                       // advance the first session
        // A second insert starts fresh at the new base.
        XCTAssertTrue(ec.beginSnippetSession(snippet, insertedAt: 100))
        XCTAssertEqual(ec.activeSnippetSession?.current?.index, 1)
        XCTAssertEqual(ec.editorSelectRequest?.anchor, 101)
    }

    func test_endSnippetSession_isIdempotent() {
        let ec = makeCoordinator()
        ec.beginSnippetSession(snippet, insertedAt: 0)
        ec.endSnippetSession()
        ec.endSnippetSession()
        XCTAssertFalse(ec.isSnippetSessionActive)
    }
}
