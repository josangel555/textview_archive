import XCTest
import AppKit
import ViewerCore
@testable import ViewerUI

/// TSK-448 — Return/keypad-Enter must reach the PTY while the terminal is
/// focused. AppKit routes Return through the key-equivalent (window
/// default-button) machinery BEFORE `keyDown`; with SwiftUI chrome
/// installing a default button, Return fired that button and the shell
/// never saw a CR ("typing works, Enter does nothing"). The fix claims
/// Return in `performKeyEquivalent` and routes it through `keyDown`.
///
/// These tests drive the EXACT override. The view must be its window's
/// first responder for the override to engage, so a borderless NSWindow
/// is created but NEVER ordered on screen — no visible UI, host-safe
/// (the window is an object, not a surface; nothing is displayed).
@MainActor
final class TerminalReturnKeyRoutingTests: XCTestCase {

    private final class Captured: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()
        func append(_ d: Data) { lock.lock(); bytes.append(d); lock.unlock() }
        var value: Data { lock.lock(); defer { lock.unlock() }; return bytes }
    }

    private func makeFocusedView() -> (TerminalNSView, NSWindow, Captured) {
        let view = TerminalNSView(initialScreen: TerminalScreen(rows: 4, cols: 20),
                                  fontSize: 12)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: .borderless, backing: .buffered, defer: true)
        window.contentView = view
        window.makeFirstResponder(view)
        let cap = Captured()
        view.onInput = { cap.append($0) }
        return (view, window, cap)
    }

    private func key(_ code: UInt16, chars: String, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                         timestamp: 0, windowNumber: 0, context: nil,
                         characters: chars, charactersIgnoringModifiers: chars,
                         isARepeat: false, keyCode: code)!
    }

    func test_return_whileFocused_isClaimedAndReachesPTY() {
        let (view, _, cap) = makeFocusedView()
        let claimed = view.performKeyEquivalent(with: key(36, chars: "\r"))
        XCTAssertTrue(claimed,
            "Return must be claimed before the window default-button machinery "
            + "eats it (TSK-448)")
        XCTAssertEqual(cap.value, Data([0x0D]),
            "the claimed Return must route through keyDown to the PTY as CR")
    }

    func test_keypadEnter_whileFocused_isClaimed() {
        let (view, _, cap) = makeFocusedView()
        XCTAssertTrue(view.performKeyEquivalent(with: key(76, chars: "\u{3}")))
        XCTAssertFalse(cap.value.isEmpty, "keypad Enter must reach the PTY")
    }

    func test_commandChord_fallsThroughToMenu() {
        let (view, _, cap) = makeFocusedView()
        XCTAssertFalse(view.performKeyEquivalent(with: key(8, chars: "c", flags: .command)),
            "⌘C must fall through so the Edit menu's copy: resolves")
        XCTAssertTrue(cap.value.isEmpty)
    }

    func test_notFirstResponder_doesNotClaim() {
        let (view, window, cap) = makeFocusedView()
        window.makeFirstResponder(nil)
        XCTAssertFalse(view.performKeyEquivalent(with: key(36, chars: "\r")),
            "an unfocused terminal must not steal the window's Return")
        XCTAssertTrue(cap.value.isEmpty)
    }
}
