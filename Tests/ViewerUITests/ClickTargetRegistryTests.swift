import XCTest
import AppKit
import SwiftUI
@testable import ViewerUI
import ViewerCore

/// ClickTargetRegistry — the SwiftUI-side click-target channel (TSK-620
/// half B). The in-process AX tree is empty and SwiftUI controls are not
/// NSViews, so `.uiClickTarget` is the ONLY in-process way `ui-click` can
/// locate a SwiftUI control; these tests pin (1) registry semantics,
/// (2) the SwiftUI-global → AppKit-window coordinate conversion on BOTH
/// flippedness branches against hand-computed y-up window coords, and
/// (3) the real publish path: a hosted SwiftUI view's `.uiClickTarget`
/// frame resolving through `UIEventSynth.resolveTargetRect` to the
/// position AppKit's y-up convention demands — a y-flip bug puts the
/// rect at the wrong end of the window and goes red.
@MainActor
final class ClickTargetRegistryTests: XCTestCase {

    /// Borderless ⇒ contentView fills the frame exactly, so expected
    /// window coordinates are computable by hand (origin bottom-left).
    private func makeBorderlessWindow() -> NSWindow {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        return win
    }

    func test_registry_updateRemoveIdentifiers() {
        let reg = ClickTargetRegistry()
        XCTAssertNil(reg.frame(for: "a"))
        reg.update(id: "a", frame: CGRect(x: 1, y: 2, width: 3, height: 4))
        reg.update(id: "b", frame: CGRect(x: 5, y: 6, width: 7, height: 8))
        XCTAssertEqual(reg.frame(for: "a"), CGRect(x: 1, y: 2, width: 3, height: 4))
        XCTAssertEqual(reg.identifiers, ["a", "b"])
        // Re-publish replaces (onGeometryChange fires per layout change).
        reg.update(id: "a", frame: CGRect(x: 9, y: 9, width: 9, height: 9))
        XCTAssertEqual(reg.frame(for: "a"), CGRect(x: 9, y: 9, width: 9, height: 9))
        // Disappear withdraws — a dead control must not be clickable.
        reg.remove(id: "a")
        XCTAssertNil(reg.frame(for: "a"))
        XCTAssertEqual(reg.identifiers, ["b"])
    }

    /// Non-flipped contentView: the conversion must flip y. A target near
    /// the TOP in SwiftUI space (y-down 20) must come out near the TOP in
    /// window space (y-up 250 for a 300-tall window) — hand-computed, not
    /// derived from the code under test.
    func test_windowRect_unflippedContentView_flipsToYUp() {
        let win = makeBorderlessWindow()
        defer { win.close() }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        win.contentView = root
        XCTAssertFalse(root.isFlipped)

        let rect = ClickTargetRegistry.windowRect(
            fromSwiftUIGlobal: CGRect(x: 40, y: 20, width: 50, height: 30),
            contentView: root)
        XCTAssertEqual(rect, NSRect(x: 40, y: 250, width: 50, height: 30))
    }

    /// Flipped contentView (the production case — NSHostingView is
    /// flipped): SwiftUI-global coords pass straight through to the
    /// flipped local space and AppKit's convert does the y-up mapping.
    /// Same hand-computed expectation as the unflipped branch — both
    /// roads must lead to the same window rect.
    func test_windowRect_flippedContentView_sameWindowRect() {
        final class FlippedView: NSView {
            override var isFlipped: Bool { true }
        }
        let win = makeBorderlessWindow()
        defer { win.close() }
        let root = FlippedView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        win.contentView = root
        XCTAssertTrue(root.isFlipped)

        let rect = ClickTargetRegistry.windowRect(
            fromSwiftUIGlobal: CGRect(x: 40, y: 20, width: 50, height: 30),
            contentView: root)
        XCTAssertEqual(rect, NSRect(x: 40, y: 250, width: 50, height: 30))
    }

    /// End-to-end through the REAL publish path: a hosted SwiftUI view
    /// carrying `.uiClickTarget` at a known top-leading inset must
    /// resolve via `UIEventSynth.resolveTargetRect` (registry-first) to
    /// the hand-computed y-up window rect, and the event builder must
    /// produce a sequence centered inside it. This is the channel that
    /// replaces the dead AX walk — if onGeometryChange stops publishing,
    /// or the conversion flips the wrong way, this goes red.
    func test_resolveTargetRect_viaSwiftUIPublishedFrame() throws {
        let id = "mdv.test.swiftuiTarget"
        defer { ClickTargetRegistry.shared.remove(id: id) }

        let win = makeBorderlessWindow()
        defer { win.close() }
        let content = ZStack(alignment: .topLeading) {
            Color.clear
            Color.red
                .frame(width: 50, height: 30)
                .uiClickTarget(id)
                .padding(.leading, 40)
                .padding(.top, 20)
        }
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        win.contentView = host
        host.layoutSubtreeIfNeeded()

        // onGeometryChange delivers on the main run loop — pump until the
        // publish lands (bounded; headless, no window ever ordered in).
        let deadline = Date().addingTimeInterval(5)
        while ClickTargetRegistry.shared.frame(for: id) == nil,
              Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertNotNil(ClickTargetRegistry.shared.frame(for: id),
            "the .uiClickTarget modifier must publish the control's frame")

        let resolved = try XCTUnwrap(
            UIEventSynth.resolveTargetRect(identifier: id, in: win))
        // Hand-computed: SwiftUI top-leading inset (40, 20), size 50×30,
        // in a 300-tall y-up window ⇒ y = 300 − 20 − 30 = 250.
        XCTAssertEqual(resolved.minX, 40, accuracy: 0.5)
        XCTAssertEqual(resolved.minY, 250, accuracy: 0.5,
            "y-flip check: a target near the SwiftUI TOP must resolve near "
            + "the window's y-up TOP — minY≈20 means the flip went backwards")
        XCTAssertEqual(resolved.width, 50, accuracy: 0.5)
        XCTAssertEqual(resolved.height, 30, accuracy: 0.5)

        // And the event builder consumes it: default fractions = center.
        let spec = try XCTUnwrap(UIClickSpec.parse(verb: "ui-click", arg: id))
        let events = try XCTUnwrap(UIEventSynth.events(spec: spec, in: win))
        XCTAssertEqual(events.map(\.type), [.leftMouseDown, .leftMouseUp])
        XCTAssertEqual(events[0].locationInWindow.x, 65, accuracy: 1)
        XCTAssertEqual(events[0].locationInWindow.y, 265, accuracy: 1)
    }

    // NOTE (TSK-620): a "fake key" HarnessWindow (isKeyWindow override)
    // was tried and DISPROVEN here — NSWindow.sendEvent's non-key
    // suppression is not keyed on the overridable property (a probed
    // AppKit subview's mouseDown never arrived either), and SwiftUI's
    // gesture system refuses direct responder dispatch. Genuine key
    // status via a LaunchServices launch (`open --env`) is the only
    // route; see AppLauncher.runScript(viaOpen:) and LESSONS.md.
}
