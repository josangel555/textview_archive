import XCTest
import AppKit
@testable import ViewerUI
import ViewerCore

/// UIEventSynth — the harness's real-event click layer. Headless: the
/// NSWindow is created but never ordered onto the screen; `sendEvent`
/// hit-testing works against the laid-out view tree regardless, so the
/// full click path (id lookup → coordinate mapping → NSEvent → responder
/// chain → action) is exercised without a GUI session.
@MainActor
final class UIEventSynthTests: XCTestCase {

    private func makeWindow() -> NSWindow {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        return win
    }

    func test_findView_locatesNestedIdentifier() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let mid = NSView(frame: NSRect(x: 10, y: 10, width: 200, height: 200))
        let leaf = NSView(frame: NSRect(x: 5, y: 5, width: 50, height: 50))
        leaf.setAccessibilityIdentifier("mdv.test.leaf")
        mid.addSubview(leaf)
        root.addSubview(mid)

        XCTAssertTrue(UIEventSynth.findView(identifier: "mdv.test.leaf", under: root) === leaf)
        XCTAssertNil(UIEventSynth.findView(identifier: "mdv.test.missing", under: root))
    }

    /// The full synthesized stream for a modified double-click: alternating
    /// down/up at ONE point inside the target, click counts [1,1,2,2], and
    /// modifier flags carried on every event. (End-to-end delivery needs a
    /// window DEVICE — an unordered window has windowNumber <= 0, so queued
    /// events can't route to it; that half is the VM T4 suite's job.)
    func test_events_modifiedDoubleClick_buildsRealSequence() throws {
        let win = makeWindow()
        defer { win.close() }
        let target = NSView(frame: NSRect(x: 40, y: 60, width: 120, height: 80))
        target.setAccessibilityIdentifier("mdv.test.pane")
        win.contentView?.addSubview(target)

        let spec = try XCTUnwrap(UIClickSpec.parse(
            verb: "ui-double-click", arg: "mdv.test.pane cmd shift at 0.25 0.5"))
        let events = try XCTUnwrap(UIEventSynth.events(spec: spec, in: win))

        XCTAssertEqual(events.map(\.type),
                       [.leftMouseDown, .leftMouseUp, .leftMouseDown, .leftMouseUp])
        XCTAssertEqual(events.map(\.clickCount), [1, 1, 2, 2])
        for e in events {
            XCTAssertTrue(e.modifierFlags.contains(.command))
            XCTAssertTrue(e.modifierFlags.contains(.shift))
            XCTAssertEqual(e.locationInWindow, events[0].locationInWindow,
                           "all four events must land on the same point")
        }
        // The point must be INSIDE the target: hit-test the content view at
        // the synthesized location and require the target (window-space →
        // contentView superview space is identity here).
        let hit = win.contentView?.hitTest(events[0].locationInWindow)
        XCTAssertTrue(hit === target,
            "synthesized location must hit-test to the addressed view")
    }

    /// The non-key fallback: a headless window can never be key, so
    /// `click` must dispatch straight to the hit-tested view's responder
    /// methods — the path the VM harness takes when WindowServer refuses
    /// key status (root app in a user GUI session). Pins that the target
    /// view actually RECEIVES the down/up pair.
    func test_click_nonKeyWindow_dispatchesToResponder() throws {
        final class RecordingView: NSView {
            var downs = 0, ups = 0
            override func mouseDown(with event: NSEvent) { downs += 1 }
            override func mouseUp(with event: NSEvent) { ups += 1 }
        }
        let win = makeWindow()
        defer { win.close() }
        let target = RecordingView(frame: NSRect(x: 40, y: 60, width: 120, height: 80))
        target.setAccessibilityIdentifier("mdv.test.recorder")
        win.contentView?.addSubview(target)
        XCTAssertFalse(win.isKeyWindow, "headless window must not be key")

        let spec = try XCTUnwrap(UIClickSpec.parse(verb: "ui-click", arg: "mdv.test.recorder"))
        XCTAssertTrue(UIEventSynth.click(spec: spec, in: win))
        XCTAssertEqual(target.downs, 1, "responder fallback must deliver mouseDown")
        XCTAssertEqual(target.ups, 1, "responder fallback must deliver mouseUp")
        XCTAssertTrue(UIEventSynth.lastTrace.contains("via=responder"),
            "trace must say which delivery path ran: \(UIEventSynth.lastTrace)")
    }

    func test_click_missingTarget_sendsNothing_returnsFalse() throws {
        let win = makeWindow()
        defer { win.close() }
        let spec = try XCTUnwrap(UIClickSpec.parse(verb: "ui-click", arg: "mdv.test.absent"))
        XCTAssertFalse(UIEventSynth.click(spec: spec, in: win),
            "a missing id must be a LOUD no — not a click on nothing")
    }
}
