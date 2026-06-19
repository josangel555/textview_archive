import CoreGraphics
import XCTest
@testable import ViewerCore

/// T1 host tests for `EditUndoStack` (TSK-749): the bounded push/undo/redo
/// history that backs the image editor's 1000+-entry undo. Pure value-type
/// logic — no rendering — so these run on the host gate with real teeth.
final class EditUndoStackTests: XCTestCase {

    /// Distinct op states are easy to build from a resize so equality is exact.
    private func state(_ n: Int) -> [EditOp] { [.resize(width: n, height: n)] }

    // MARK: - Baseline / empty

    func test_baseline_isCurrent_andHasNoUndoOrRedo() {
        let stack = EditUndoStack(baseline: [])
        XCTAssertEqual(stack.current, [])
        XCTAssertFalse(stack.canUndo)
        XCTAssertFalse(stack.canRedo)
        XCTAssertEqual(stack.count, 1, "the baseline is the sole state")
    }

    func test_seededBaseline_isTheStartingState() {
        let stack = EditUndoStack(baseline: state(7))
        XCTAssertEqual(stack.current, state(7))
        XCTAssertFalse(stack.canUndo, "baseline is the floor")
    }

    // MARK: - Push / undo / redo round trips

    func test_pushThenUndo_returnsToBaseline() {
        var stack = EditUndoStack(baseline: [])
        stack.push(state(1))
        XCTAssertEqual(stack.current, state(1))
        XCTAssertTrue(stack.canUndo)
        XCTAssertFalse(stack.canRedo)

        let after = stack.undo()
        XCTAssertEqual(after, [])
        XCTAssertEqual(stack.current, [])
        XCTAssertFalse(stack.canUndo)
        XCTAssertTrue(stack.canRedo, "the undone push is now redoable")
    }

    func test_undoThenRedo_restoresState() {
        var stack = EditUndoStack(baseline: [])
        stack.push(state(1))
        stack.push(state(2))
        stack.undo()
        XCTAssertEqual(stack.current, state(1))
        let redone = stack.redo()
        XCTAssertEqual(redone, state(2))
        XCTAssertEqual(stack.current, state(2))
        XCTAssertFalse(stack.canRedo, "redo exhausted at the tip")
    }

    func test_multiLevelUndoRedo_walksTheWholeHistory() {
        var stack = EditUndoStack(baseline: [])
        for i in 1...5 { stack.push(state(i)) }
        XCTAssertEqual(stack.current, state(5))
        // Undo all the way to baseline.
        for i in stride(from: 4, through: 0, by: -1) {
            let s = stack.undo()
            XCTAssertEqual(s, i == 0 ? [] : state(i))
        }
        XCTAssertFalse(stack.canUndo)
        // Redo all the way back to the tip.
        for i in 1...5 {
            let s = stack.redo()
            XCTAssertEqual(s, state(i))
        }
        XCTAssertFalse(stack.canRedo)
    }

    // MARK: - Redo-branch truncation

    func test_pushAfterUndo_truncatesRedoBranch() {
        var stack = EditUndoStack(baseline: [])
        stack.push(state(1))
        stack.push(state(2))
        stack.push(state(3))
        stack.undo()                  // back to state(2); state(3) is redoable
        stack.undo()                  // back to state(1); state(2),(3) redoable
        XCTAssertTrue(stack.canRedo)

        stack.push(state(99))         // new edit — must discard the redo branch
        XCTAssertEqual(stack.current, state(99))
        XCTAssertFalse(stack.canRedo, "a fresh push discards the orphaned future")
        // Undo now returns to state(1), not the discarded state(2).
        XCTAssertEqual(stack.undo(), state(1))
    }

    // MARK: - No-op collapse

    func test_pushIdenticalToCurrent_isCollapsed() {
        var stack = EditUndoStack(baseline: state(5))
        stack.push(state(5))          // identical → no new state
        XCTAssertEqual(stack.count, 1)
        XCTAssertFalse(stack.canUndo, "an identical push must not create history")
    }

    // MARK: - Boundary no-ops

    func test_undoAtBaseline_andRedoAtTip_areNoOps() {
        var stack = EditUndoStack(baseline: [])
        XCTAssertEqual(stack.undo(), [], "undo at floor is a no-op")
        stack.push(state(1))
        XCTAssertEqual(stack.redo(), state(1), "redo at tip is a no-op")
    }

    // MARK: - Cap behaviour (the 1000+ requirement)

    func test_defaultLimit_holdsOver1000Entries() {
        var stack = EditUndoStack()  // defaultLimit == 1024
        XCTAssertEqual(stack.limit, 1024)
        for i in 1...1000 { stack.push(state(i)) }
        // 1000 pushes + 1 baseline = 1001 states, all retained under the cap.
        XCTAssertEqual(stack.count, 1001)
        XCTAssertEqual(stack.current, state(1000))
        // Undo 1000 times must reach the baseline (proves all 1000 are present).
        for _ in 0..<1000 { stack.undo() }
        XCTAssertEqual(stack.current, [], "1000-deep undo reaches the baseline")
        XCTAssertFalse(stack.canUndo)
    }

    func test_exceedingLimit_evictsOldestFIFO() {
        var stack = EditUndoStack(limit: 4) // baseline + at most 3 more
        for i in 1...6 { stack.push(state(i)) }
        // Cap is 4 states total → the four newest survive: state(3),(4),(5),(6).
        XCTAssertEqual(stack.count, 4)
        XCTAssertEqual(stack.current, state(6))
        // Undo to the oldest surviving state — it must be state(3), not baseline.
        stack.undo(); stack.undo(); stack.undo()
        XCTAssertEqual(stack.current, state(3), "oldest two states (baseline, 1, 2) evicted")
        XCTAssertFalse(stack.canUndo, "no further history below the cap floor")
    }

    func test_limitFlooredAtOne() {
        var stack = EditUndoStack(limit: 0) // floored to 1
        XCTAssertEqual(stack.limit, 1)
        stack.push(state(1))
        stack.push(state(2))
        XCTAssertEqual(stack.count, 1, "a 1-deep stack keeps only the current state")
        XCTAssertEqual(stack.current, state(2))
        XCTAssertFalse(stack.canUndo)
    }

    // MARK: - Reset

    func test_reset_clearsHistory() {
        var stack = EditUndoStack(baseline: [])
        stack.push(state(1))
        stack.push(state(2))
        stack.undo()
        stack.reset(to: state(42))
        XCTAssertEqual(stack.current, state(42))
        XCTAssertFalse(stack.canUndo)
        XCTAssertFalse(stack.canRedo)
        XCTAssertEqual(stack.count, 1)
    }

    // MARK: - Equatable (snapshot/persistence)

    func test_equatable_distinguishesCursorPosition() {
        var a = EditUndoStack(baseline: [])
        a.push(state(1))
        var b = a
        b.undo()
        XCTAssertNotEqual(a, b, "same states, different cursor → not equal")
        b.redo()
        XCTAssertEqual(a, b, "redo back to the same cursor → equal")
    }
}
