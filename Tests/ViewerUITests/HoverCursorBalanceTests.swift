import XCTest
@testable import ViewerUI

/// TSK-892 — File-tree hover felt slow because the open-coded sidebar
/// hover sites pushed/popped the PROCESS-GLOBAL `NSCursor` stack on EVERY
/// `onHover` callback, with no balance guard. AppKit emits back-to-back
/// `onHover(true)` callbacks for one view during a fast drag and can
/// deliver a stray `onHover(false)` with no matching prior `true`, so the
/// unguarded code grew the global stack without bound (and over-popped a
/// foreign cursor) — a storm of redundant global-stack mutations that read
/// as hover lag/jank.
///
/// `HoverCursorBalance` is the extracted pure guard. These tests pin the
/// balance invariants host-side so a regression of the rule (back to
/// double-push / over-pop) fails the merge gate rather than only showing
/// up as a live drag stutter. The actual `NSCursor.push()/pop()` calls are
/// AppKit side effects exercised by the VM UI lane + manual checklist;
/// here we assert the decision core that gates them.
///
/// Host-safe: pure value-type logic, no window, no NSCursor mutation.
/// Run with the class filter `ViewerUITests.HoverCursorBalanceTests`.
final class HoverCursorBalanceTests: XCTestCase {

    /// A fresh balance owns no push.
    func test_initial_ownsNoPush() {
        let b = HoverCursorBalance()
        XCTAssertFalse(b.isPushed)
    }

    /// The first `hovering: true` pushes exactly once and takes ownership.
    func test_firstEnter_pushesOnce() {
        var b = HoverCursorBalance()
        XCTAssertEqual(b.update(hovering: true), .push)
        XCTAssertTrue(b.isPushed)
    }

    /// THE core fix: repeated `hovering: true` (AppKit's back-to-back
    /// callbacks) is a no-op fast path — no second push onto the global
    /// stack. This is the redundant-push storm that made hover feel slow.
    func test_repeatedEnter_isNoOp() {
        var b = HoverCursorBalance()
        XCTAssertEqual(b.update(hovering: true), .push)
        // Several more enter callbacks for the same view → all no-ops.
        for _ in 0..<5 {
            XCTAssertEqual(b.update(hovering: true), .none)
        }
        XCTAssertTrue(b.isPushed, "still owns exactly one push")
    }

    /// Leaving after an enter pops exactly once and releases ownership.
    func test_exitAfterEnter_popsOnce() {
        var b = HoverCursorBalance()
        _ = b.update(hovering: true)
        XCTAssertEqual(b.update(hovering: false), .pop)
        XCTAssertFalse(b.isPushed)
    }

    /// THE other half of the fix: a `hovering: false` with no outstanding
    /// push is a no-op — it never over-pops a cursor THIS view never
    /// pushed (which would strand a foreign cursor, e.g. the resize cursor
    /// over a column edge).
    func test_exitWithoutEnter_isNoOpNoOverPop() {
        var b = HoverCursorBalance()
        XCTAssertEqual(b.update(hovering: false), .none)
        XCTAssertFalse(b.isPushed)
    }

    /// Repeated `hovering: false` after a single pop stays a no-op (only
    /// the first leave that owns a push pops).
    func test_repeatedExit_onlyFirstPops() {
        var b = HoverCursorBalance()
        _ = b.update(hovering: true)
        XCTAssertEqual(b.update(hovering: false), .pop)
        for _ in 0..<5 {
            XCTAssertEqual(b.update(hovering: false), .none)
        }
        XCTAssertFalse(b.isPushed)
    }

    /// A realistic drag across many rows: repeated enter/leave cycles each
    /// net exactly one push + one pop — the stack is balanced at the end,
    /// never deeper than 1, regardless of how many spurious repeats AppKit
    /// interleaves.
    func test_dragSequence_staysBalanced() {
        var b = HoverCursorBalance()
        var depth = 0
        // Simulate 20 enter/leave cycles, each padded with redundant
        // same-state callbacks (what AppKit actually delivers).
        for _ in 0..<20 {
            for _ in 0..<3 {
                switch b.update(hovering: true) {
                case .push: depth += 1
                case .pop: depth -= 1
                case .none: break
                }
                XCTAssertLessThanOrEqual(depth, 1, "never more than one push on the stack")
            }
            for _ in 0..<3 {
                switch b.update(hovering: false) {
                case .push: depth += 1
                case .pop: depth -= 1
                case .none: break
                }
                XCTAssertGreaterThanOrEqual(depth, 0, "never over-pops below zero")
            }
        }
        XCTAssertEqual(depth, 0, "every push was balanced by exactly one pop")
        XCTAssertFalse(b.isPushed)
    }

    /// Teardown while hovered (view `onDisappear` mid-hover) pops the
    /// outstanding push so it doesn't leak onto the global stack.
    func test_teardownWhileHovered_pops() {
        var b = HoverCursorBalance()
        _ = b.update(hovering: true)
        XCTAssertEqual(b.teardown(), .pop)
        XCTAssertFalse(b.isPushed)
    }

    /// Teardown while NOT hovered is a no-op — nothing to release.
    func test_teardownWhileNotHovered_isNoOp() {
        var b = HoverCursorBalance()
        XCTAssertEqual(b.teardown(), .none)
        XCTAssertFalse(b.isPushed)
    }

    /// Teardown is idempotent: a second teardown after the first releases
    /// nothing (guards a double-onDisappear).
    func test_teardownTwice_secondIsNoOp() {
        var b = HoverCursorBalance()
        _ = b.update(hovering: true)
        XCTAssertEqual(b.teardown(), .pop)
        XCTAssertEqual(b.teardown(), .none)
    }
}
