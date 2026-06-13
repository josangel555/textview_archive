import XCTest
import AppKit
@testable import ViewerUI

/// TSK-728/730: the app-wide sidebar key monitor must NOT steal Enter/arrows
/// from the CM6 editor (a WKWebView — neither NSText nor exempt) nor steal
/// modified arrows (⌘←/⌥←, editor/system commands). Pure-logic coverage of the
/// extracted `shouldYield(...)` decision; the real key→editor routing is the
/// VM lane. `editorView` is taken as a plain NSView (WKWebView is one) so these
/// need no live WebView.
@MainActor
final class SidebarKeyMonitorYieldTests: XCTestCase {

    private typealias Mon = SidebarKeyMonitor.Coordinator

    private final class FakeExempt: NSView, SidebarKeyMonitorExempt {}

    // MARK: modifiers — ⌘/⌥/⌃ + arrow are editor commands, never sidebar nav

    func test_commandModifier_yields_evenWithPlainResponder() {
        let plain = NSView()
        XCTAssertTrue(Mon.shouldYield(modifiers: .command, firstResponder: plain, editorView: nil))
    }

    func test_optionModifier_yields() {
        XCTAssertTrue(Mon.shouldYield(modifiers: .option, firstResponder: NSView(), editorView: nil))
    }

    func test_controlModifier_yields() {
        XCTAssertTrue(Mon.shouldYield(modifiers: .control, firstResponder: NSView(), editorView: nil))
    }

    func test_shiftAlone_doesNotForceYield() {
        // Shift+arrow may be sidebar range-select — must NOT auto-yield on shift.
        XCTAssertFalse(Mon.shouldYield(modifiers: .shift, firstResponder: NSView(), editorView: nil))
    }

    // MARK: focused responders that own their keys

    func test_textViewFocused_yields() {
        XCTAssertTrue(Mon.shouldYield(modifiers: [], firstResponder: NSTextView(), editorView: nil))
    }

    func test_exemptViewFocused_yields() {
        XCTAssertTrue(Mon.shouldYield(modifiers: [], firstResponder: FakeExempt(), editorView: nil))
    }

    // MARK: the bug — CM6 editor (WKWebView) focused must yield

    func test_editorWebViewItself_focused_yields() {
        let editor = NSView() // stands in for the WKWebView
        XCTAssertTrue(Mon.shouldYield(modifiers: [], firstResponder: editor, editorView: editor))
    }

    func test_descendantOfEditor_focused_yields() {
        // WKWebView focus often lands on an internal content subview.
        let editor = NSView()
        let content = NSView()
        editor.addSubview(content)
        XCTAssertTrue(Mon.shouldYield(modifiers: [], firstResponder: content, editorView: editor))
    }

    // MARK: sidebar nav must still work (the don't-over-yield guard)

    func test_plainResponder_noEditor_consumesForSidebarNav() {
        XCTAssertFalse(Mon.shouldYield(modifiers: [], firstResponder: NSView(), editorView: nil),
            "bare arrow with non-text focus drives the file tree — must NOT yield")
    }

    func test_editorOpenButUnfocused_stillConsumesForSidebarNav() {
        // An editor exists in the window (editorView != nil) but focus is
        // elsewhere (the tree) — sidebar arrow-nav must keep working.
        let editor = NSView()
        let elsewhere = NSView() // not within the editor
        XCTAssertFalse(Mon.shouldYield(modifiers: [], firstResponder: elsewhere, editorView: editor),
            "editor open-but-unfocused must not disable sidebar nav (the over-yield trap)")
    }

    func test_nilResponder_consumes() {
        XCTAssertFalse(Mon.shouldYield(modifiers: [], firstResponder: nil, editorView: nil))
    }
}
