import XCTest
import AppKit
@testable import ViewerUI

/// TSK-1591 — the four extra tab-nav shortcuts: ⌃Tab / ⌃⇧Tab and ⌘] / ⌘[.
/// Pure classifier only (host-safe; the live NSEvent monitor + focus behaviour
/// is the VM/AX rung). keyCode 48 = Tab.
final class TabNavKeyMonitorTests: XCTestCase {
    private typealias M = TabNavKeyMonitor

    func test_ctrlTab_next_ctrlShiftTab_prev() {
        XCTAssertEqual(M.classify(keyCode: 48, chars: "\t", modifiers: [.control], walkthroughActive: false), .next)
        XCTAssertEqual(M.classify(keyCode: 48, chars: "\t", modifiers: [.control, .shift], walkthroughActive: false), .prev)
    }

    func test_cmdBracket_next_prev() {
        XCTAssertEqual(M.classify(keyCode: 30, chars: "]", modifiers: [.command], walkthroughActive: false), .next)
        XCTAssertEqual(M.classify(keyCode: 33, chars: "[", modifiers: [.command], walkthroughActive: false), .prev)
    }

    func test_cmdBracket_deferredToActiveWalkthrough() {
        // While a walkthrough plays, ⌘[/⌘] belong to its step navigation.
        XCTAssertEqual(M.classify(keyCode: 30, chars: "]", modifiers: [.command], walkthroughActive: true), .none)
        XCTAssertEqual(M.classify(keyCode: 33, chars: "[", modifiers: [.command], walkthroughActive: true), .none)
        // ⌃Tab is NOT a walkthrough combo, so it still switches tabs.
        XCTAssertEqual(M.classify(keyCode: 48, chars: "\t", modifiers: [.control], walkthroughActive: true), .next)
    }

    func test_existingShortcuts_notHijacked() {
        // ⌘⇧] (existing Next Tab menu item) is NOT claimed here — command+shift
        // ≠ command-only, so the monitor leaves it to the menu.
        XCTAssertEqual(M.classify(keyCode: 30, chars: "]", modifiers: [.command, .shift], walkthroughActive: false), .none)
        // ⌥⌘[ (Fold All) is left alone.
        XCTAssertEqual(M.classify(keyCode: 33, chars: "[", modifiers: [.command, .option], walkthroughActive: false), .none)
        // A bare Tab (indent) is not a switch.
        XCTAssertEqual(M.classify(keyCode: 48, chars: "\t", modifiers: [], walkthroughActive: false), .none)
        // A plain "]" keystroke (typing) is not a switch.
        XCTAssertEqual(M.classify(keyCode: 30, chars: "]", modifiers: [], walkthroughActive: false), .none)
    }
}
