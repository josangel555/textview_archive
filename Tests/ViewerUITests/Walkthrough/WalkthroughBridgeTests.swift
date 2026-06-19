import XCTest
@testable import ViewerUI
import ViewerCore

/// Pure-logic tests for the per-`DocumentModel` walkthrough bridge.
/// These don't touch SwiftUI — just verify the nonce channels behave
/// as documented (monotonic increment, clear-when-already-clear is a
/// no-op, idempotent repeated identical requests still fire).
@MainActor
final class WalkthroughBridgeTests: XCTestCase {

    func test_bridge_isSingletonPerModel() {
        let m = DocumentModel()
        let a = m.walkthroughBridge
        let b = m.walkthroughBridge
        XCTAssertTrue(a === b)
    }

    func test_requestHighlight_bumpsNonce() {
        let m = DocumentModel()
        let b = m.walkthroughBridge
        let before = b.highlightNonce
        b.requestHighlight(
            .init(
                url: URL(fileURLWithPath: "/tmp/a.swift"),
                startLine: 1, endLine: 3, style: .focus
            )
        )
        XCTAssertEqual(b.highlightNonce, before &+ 1)
        XCTAssertNotNil(b.highlight)
    }

    func test_requestHighlight_sameTarget_stillBumps() {
        // Re-issuing the same range MUST advance the nonce so a
        // sub-view that observes only the nonce re-renders. Without
        // this, "highlight the same lines twice in a row" silently
        // dropped the second request.
        let m = DocumentModel()
        let b = m.walkthroughBridge
        let range = WalkthroughBridge.HighlightRange(
            url: URL(fileURLWithPath: "/tmp/a.swift"),
            startLine: 1, endLine: 3, style: .focus
        )
        b.requestHighlight(range)
        let n1 = b.highlightNonce
        b.requestHighlight(range)
        XCTAssertEqual(b.highlightNonce, n1 &+ 1)
    }

    func test_clearHighlight_noOpsWhenNoneSet() {
        let m = DocumentModel()
        let b = m.walkthroughBridge
        let before = b.highlightNonce
        b.clearHighlight()
        XCTAssertEqual(b.highlightNonce, before,
                       "clear with nothing set must not bump nonce")
    }

    func test_clearHighlight_bumpsNonce_whenSet() {
        let m = DocumentModel()
        let b = m.walkthroughBridge
        b.requestHighlight(
            .init(
                url: URL(fileURLWithPath: "/tmp/a.swift"),
                startLine: 1, endLine: 3, style: .focus
            )
        )
        let after = b.highlightNonce
        b.clearHighlight()
        XCTAssertEqual(b.highlightNonce, after &+ 1)
        XCTAssertNil(b.highlight)
    }

    func test_requestPopover_bumpsNonce() {
        let m = DocumentModel()
        let b = m.walkthroughBridge
        let before = b.popoverNonce
        b.requestPopover(
            .init(body: "hi", anchor: .window, style: .floating)
        )
        XCTAssertEqual(b.popoverNonce, before &+ 1)
    }

    func test_requestDiagram_bumpsNonceAndStores() {
        let m = DocumentModel()
        let b = m.walkthroughBridge
        let before = b.diagramNonce
        b.requestDiagram(
            .init(kind: .mermaid, data: "graph TD; A-->B;", caption: "flow")
        )
        XCTAssertEqual(b.diagramNonce, before &+ 1)
        XCTAssertEqual(b.diagram?.kind, .mermaid)
        XCTAssertEqual(b.diagram?.data, "graph TD; A-->B;")
        XCTAssertEqual(b.diagram?.caption, "flow")
    }

    func test_requestDiagram_sameRequest_stillBumps() {
        let m = DocumentModel()
        let b = m.walkthroughBridge
        let req = WalkthroughBridge.DiagramRequest(
            kind: .ascii, data: "+--+"
        )
        b.requestDiagram(req)
        let n1 = b.diagramNonce
        b.requestDiagram(req)
        XCTAssertEqual(b.diagramNonce, n1 &+ 1)
    }

    func test_clearDiagram_noOpsWhenNoneSet() {
        let m = DocumentModel()
        let b = m.walkthroughBridge
        let before = b.diagramNonce
        b.clearDiagram()
        XCTAssertEqual(b.diagramNonce, before,
                       "clear with nothing set must not bump nonce")
    }

    func test_clearDiagram_bumpsNonce_whenSet() {
        let m = DocumentModel()
        let b = m.walkthroughBridge
        b.requestDiagram(.init(kind: .ascii, data: "x"))
        let after = b.diagramNonce
        b.clearDiagram()
        XCTAssertEqual(b.diagramNonce, after &+ 1)
        XCTAssertNil(b.diagram)
    }

    func test_requestNote_bumpsNonceAndStashesStepID() {
        let m = DocumentModel()
        let b = m.walkthroughBridge
        let before = b.noteNonce
        b.requestNote(forStepID: "s7")
        XCTAssertEqual(b.noteNonce, before &+ 1)
        XCTAssertEqual(b.lastNoteStepID, "s7")
    }
}
