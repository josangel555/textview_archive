import XCTest
import AppKit
@testable import ViewerUI

/// TSK-1282: CodeMirrorEditorRegistry.current() must target the FOCUSED editor
/// pane, not the first-registered one — under MountedPanesLRU several editor
/// panes are mounted per window, so action-targeting (snippet insert, edit-apply)
/// would otherwise hit a parked pane (the owner's snippet-"random-places" bug).
/// focusedView is the pure preference helper, generic over NSView so no live
/// WebView is needed (a WKWebView is an NSView). The live key-window /
/// first-responder integration in current() itself is the VM lane.
@MainActor
final class CodeMirrorEditorRegistryTests: XCTestCase {

    private typealias Reg = CodeMirrorEditorRegistry

    func test_focusedView_picksThePaneContainingTheResponder() {
        let pane1 = NSView()
        let pane2 = NSView()
        let content2 = NSView()
        pane2.addSubview(content2)
        // Focus is inside pane2 → must return pane2, NOT the first-registered pane
        // (the old first-in-window behaviour returned pane1 → wrong-pane actions).
        XCTAssertTrue(Reg.focusedView(among: [pane1, pane2], firstResponder: content2) === pane2,
                      "returns the pane that contains the first responder, not the first pane")
        // The pane view itself as the responder also matches.
        XCTAssertTrue(Reg.focusedView(among: [pane1, pane2], firstResponder: pane1) === pane1)
    }

    func test_focusedView_nilWhenResponderOutsideAllPanes() {
        let pane1 = NSView()
        let pane2 = NSView()
        let elsewhere = NSView()   // a tool field — not inside any editor
        XCTAssertNil(Reg.focusedView(among: [pane1, pane2], firstResponder: elsewhere),
                     "focus outside every editor → nil (current() then falls back to first-in-window)")
        XCTAssertNil(Reg.focusedView(among: [pane1, pane2], firstResponder: nil),
                     "no responder → nil")
    }
}
