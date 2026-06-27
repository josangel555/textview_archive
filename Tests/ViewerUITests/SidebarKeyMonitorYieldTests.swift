import XCTest
import AppKit
@testable import ViewerUI

/// TSK-728/730 + TSK-1280 (multi-pane): the app-wide sidebar key monitor must
/// NOT steal Enter/arrows from the CM6 editor (a WKWebView — neither NSText nor
/// exempt) nor steal modified arrows (⌘←/⌥←, editor/system commands), and must
/// honour EVERY mounted editor pane, not just the topmost. Pure-logic coverage
/// of the extracted `shouldYield(...)` decision; the real key→editor routing is
/// the VM lane. Editors are taken as plain NSViews (WKWebView is one) so these
/// need no live WebView.
@MainActor
final class SidebarKeyMonitorYieldTests: XCTestCase {

    private typealias Mon = SidebarKeyMonitor.Coordinator

    private final class FakeExempt: NSView, SidebarKeyMonitorExempt {}

    // MARK: modifiers — ⌘/⌥/⌃ + arrow are editor commands, never sidebar nav

    func test_commandModifier_yields_evenWithPlainResponder() {
        let plain = NSView()
        XCTAssertTrue(Mon.shouldYield(modifiers: .command, firstResponder: plain, editorViews: []))
    }

    func test_optionModifier_yields() {
        XCTAssertTrue(Mon.shouldYield(modifiers: .option, firstResponder: NSView(), editorViews: []))
    }

    func test_controlModifier_yields() {
        XCTAssertTrue(Mon.shouldYield(modifiers: .control, firstResponder: NSView(), editorViews: []))
    }

    func test_shiftAlone_doesNotForceYield() {
        // Shift+arrow may be sidebar range-select — must NOT auto-yield on shift.
        XCTAssertFalse(Mon.shouldYield(modifiers: .shift, firstResponder: NSView(), editorViews: []))
    }

    // MARK: focused responders that own their keys

    func test_textViewFocused_yields() {
        XCTAssertTrue(Mon.shouldYield(modifiers: [], firstResponder: NSTextView(), editorViews: []))
    }

    func test_exemptViewFocused_yields() {
        XCTAssertTrue(Mon.shouldYield(modifiers: [], firstResponder: FakeExempt(), editorViews: []))
    }

    // MARK: the bug — CM6 editor (WKWebView) focused must yield

    func test_editorWebViewItself_focused_yields() {
        let editor = NSView() // stands in for the WKWebView
        XCTAssertTrue(Mon.shouldYield(modifiers: [], firstResponder: editor, editorViews: [editor]))
    }

    func test_descendantOfEditor_focused_yields() {
        // WKWebView focus often lands on an internal content subview.
        let editor = NSView()
        let content = NSView()
        editor.addSubview(content)
        XCTAssertTrue(Mon.shouldYield(modifiers: [], firstResponder: content, editorViews: [editor]))
    }

    // MARK: TSK-1280 — multi-pane (MountedPanesLRU): yield for ANY mounted editor

    func test_focusInSecondMountedEditor_yields_multiPane() {
        // MountedPanesLRU mounts several editor webviews in one window. Focus is
        // inside the SECOND (genuinely-focused) pane; the topmost current() used
        // to return the FIRST (inactive) pane, so the old single-editor guard
        // failed and Enter leaked to the sidebar. The guard now checks ALL live
        // editors, so it yields.
        let pane1 = NSView()              // inactive mounted pane (old current())
        let pane2 = NSView()              // genuinely-focused pane
        let content2 = NSView()
        pane2.addSubview(content2)
        XCTAssertTrue(
            Mon.shouldYield(modifiers: [], firstResponder: content2,
                            editorViews: [pane1, pane2]),
            "focus inside any mounted editor must yield Enter (multi-pane leak fix)")
        // Teeth: with ONLY the inactive pane known (the old current() behaviour),
        // the same responder would NOT yield → exactly the leak this fix closes.
        XCTAssertFalse(
            Mon.shouldYield(modifiers: [], firstResponder: content2,
                            editorViews: [pane1]),
            "control: responder outside the only known editor leaks (the old bug)")
    }

    // MARK: sidebar nav must still work (the don't-over-yield guard)

    func test_plainResponder_noEditor_consumesForSidebarNav() {
        XCTAssertFalse(Mon.shouldYield(modifiers: [], firstResponder: NSView(), editorViews: []),
            "bare arrow with non-text focus drives the file tree — must NOT yield")
    }

    func test_editorOpenButUnfocused_stillConsumesForSidebarNav() {
        // An editor exists in the window (editorView != nil) but focus is
        // elsewhere (the tree) — sidebar arrow-nav must keep working.
        let editor = NSView()
        let elsewhere = NSView() // not within the editor
        XCTAssertFalse(Mon.shouldYield(modifiers: [], firstResponder: elsewhere, editorViews: [editor]),
            "editor open-but-unfocused must not disable sidebar nav (the over-yield trap)")
    }

    func test_nilResponder_consumes() {
        XCTAssertFalse(Mon.shouldYield(modifiers: [], firstResponder: nil, editorViews: []))
    }
}
