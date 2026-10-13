import XCTest
import AppKit
import ViewerCore
@testable import ViewerUI

/// TSK-489 — the scrollback viewport offset must round-trip view ↔ model:
/// seeded from `TerminalModel.scrollOffset` on init (clamped), and written
/// BACK through `onScrollOffsetChange` on EVERY user-driven mutation. The
/// original 3a4c46c fix only fired the write-back from `update()`'s
/// pin/shrink paths; `scrollWheel`, `snapToBottom` (typing), and the
/// scrollbar drag mutated the offset silently — so with a quiet shell a
/// tab switch still snapped to the bottom (the owner's complaint), and a
/// stale model offset made the returning tab jump back up after typing.
///
/// These tests drive the REAL `scrollWheel(with:)` / `keyDown(with:)`
/// overrides with synthesized `NSEvent`s — the exact handlers the user's
/// input reaches — against a windowless `TerminalNSView` (host-safe; same
/// floor as `TerminalNSViewResizeTests`).
@MainActor
final class TerminalScrollOffsetPersistenceTests: HeadlessUITestCase {

    /// A screen whose scrollback is populated by feeding real output
    /// through the parser (rows beyond the grid height get evicted into
    /// scrollback).
    private func screenWithScrollback(rows: Int = 5, cols: Int = 20) -> TerminalScreen {
        var parser = ANSIParser(rows: rows, cols: cols)
        for i in 0..<40 { parser.feed(Data("line\(i)\r\n".utf8)) }
        let screen = parser.screen
        XCTAssertGreaterThanOrEqual(screen.scrollback.count, 10,
                                    "fixture must have real scrollback")
        return screen
    }

    private func wheelEvent(deltaY: Int32) -> NSEvent {
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                         wheelCount: 1, wheel1: deltaY, wheel2: 0, wheel3: 0)!
        return NSEvent(cgEvent: cg)!
    }

    private func keyEvent(_ ch: String) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                         timestamp: 0, windowNumber: 0, context: nil,
                         characters: ch, charactersIgnoringModifiers: ch,
                         isARepeat: false, keyCode: 0)!
    }

    /// Capture box for the write-back values the view reports to the model.
    private final class Captured {
        var values: [Int] = []
    }

    private func makeView(seedOffset: Int = 0,
                          screen: TerminalScreen? = nil) -> (TerminalNSView, Captured) {
        let view = TerminalNSView(initialScreen: screen ?? screenWithScrollback(),
                                  fontSize: 12,
                                  initialScrollOffset: seedOffset)
        let cap = Captured()
        view.onScrollOffsetChange = { cap.values.append($0) }
        return (view, cap)
    }

    func test_scrollWheel_writesOffsetBackToModel() {
        let (view, cap) = makeView()
        // A large positive delta scrolls several lines up into history.
        view.scrollWheel(with: wheelEvent(deltaY: 300))
        XCTAssertFalse(cap.values.isEmpty,
            "wheel scroll mutated the viewport without persisting it to the "
            + "per-tab model — the next tab switch loses the position (TSK-489)")
        XCTAssertGreaterThan(cap.values.last ?? 0, 0)
    }

    func test_initialScrollOffset_seedsViewport() {
        // Seed at 5; one wheel notch DOWN must land at 4 — proving the view
        // started from the model's 5, not from 0 (where a down-scroll is a
        // clamped no-op and the callback never fires).
        let (view, cap) = makeView(seedOffset: 5)
        view.scrollWheel(with: wheelEvent(deltaY: -16))
        XCTAssertEqual(cap.values.last, 4,
            "view did not seed its viewport from the model's offset (TSK-489)")
    }

    func test_initialScrollOffset_clampsToScrollback() {
        let screen = screenWithScrollback()
        let maxOff = screen.scrollback.count
        let (view, cap) = makeView(seedOffset: 9_999, screen: screen)
        view.scrollWheel(with: wheelEvent(deltaY: -16))
        XCTAssertEqual(cap.values.last, maxOff - 1,
            "an over-large persisted offset must clamp to the scrollback size")
    }

    func test_typing_snapsToBottom_andWritesBackZero() {
        let (view, cap) = makeView(seedOffset: 5)
        view.keyDown(with: keyEvent("a"))
        XCTAssertEqual(cap.values.last, 0,
            "typing snaps the live view to the bottom — the model must learn "
            + "about it, or the next tab switch jumps back up (TSK-489)")
    }
}
