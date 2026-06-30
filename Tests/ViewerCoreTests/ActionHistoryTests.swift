import XCTest
@testable import ViewerCore

/// Host tests for the unified action-history coordinator (TSK-703 foundation).
/// Exercises the MODEL: actions record + revert to the exact prior state,
/// undo/redo is symmetric, adjacent same-category edits coalesce, and the log
/// is size-capped (oldest evicted) while preserving insertion order.
final class ActionHistoryTests: XCTestCase {

    /// A concrete "real" reversible action: it mutates a shared box holding a
    /// value, capturing the old value so it can restore it exactly. Stands in
    /// for a CSV cell edit / any single-value mutation.
    private final class SetValueAction<T: Equatable>: ReversibleAction {
        let label: String
        let category: ActionCategory
        var timestamp: Date = Date()
        private let box: Box<T>
        private let newValue: T
        private var oldValue: T?
        /// When set, coalesces with another `SetValueAction` on the same box.
        private let mergeable: Bool

        init(box: Box<T>, to newValue: T, label: String,
             category: ActionCategory = .cell, mergeable: Bool = false) {
            self.box = box
            self.newValue = newValue
            self.label = label
            self.category = category
            self.mergeable = mergeable
        }

        func apply() {
            // Capture the pre-action value the FIRST time only, so redo
            // (apply→revert→apply) restores the right baseline.
            if oldValue == nil { oldValue = box.value }
            box.value = newValue
        }
        func revert() {
            if let old = oldValue { box.value = old }
        }
        func coalesce(with next: ReversibleAction) -> Bool {
            // Merge consecutive mergeable sets on the SAME box: keep my
            // captured oldValue (so the merged unit reverts to the original
            // baseline) and adopt next's newValue as the live state.
            guard mergeable,
                  let next = next as? SetValueAction<T>,
                  next.box === self.box,
                  next.mergeable else { return false }
            // next.apply() already ran (live state == next.newValue). My
            // oldValue still points at the original baseline, so revert() will
            // undo BOTH in one step. Nothing else to do.
            return true
        }
    }

    private final class Box<T> {
        var value: T
        init(_ value: T) { self.value = value }
    }

    // MARK: - record + revert to exact prior state

    func testExecuteAppliesAndRecords() {
        let history = ActionHistory()
        let box = Box("a")
        history.execute(SetValueAction(box: box, to: "b", label: "Set b"))
        XCTAssertEqual(box.value, "b", "execute must apply the action")
        XCTAssertEqual(history.log.count, 1)
        XCTAssertEqual(history.log.first?.label, "Set b")
        XCTAssertEqual(history.log.first?.category, .cell)
        XCTAssertTrue(history.canUndo)
        XCTAssertFalse(history.canRedo)
    }

    func testUndoRevertsToExactPriorState() {
        let history = ActionHistory()
        let box = Box(0)
        history.execute(SetValueAction(box: box, to: 42, label: "Set 42", category: .other))
        XCTAssertEqual(box.value, 42)
        history.undo()
        XCTAssertEqual(box.value, 0, "undo must restore the exact prior value")
        XCTAssertFalse(history.canUndo)
        XCTAssertTrue(history.canRedo)
    }

    // MARK: - undo/redo symmetry

    func testUndoThenRedoIsSymmetric() {
        let history = ActionHistory()
        let box = Box("start")
        history.execute(SetValueAction(box: box, to: "x", label: "x", category: .other))
        history.execute(SetValueAction(box: box, to: "y", label: "y", category: .other))
        XCTAssertEqual(box.value, "y")

        history.undo()
        XCTAssertEqual(box.value, "x")
        history.undo()
        XCTAssertEqual(box.value, "start")
        XCTAssertFalse(history.canUndo)

        history.redo()
        XCTAssertEqual(box.value, "x")
        history.redo()
        XCTAssertEqual(box.value, "y", "redo must re-apply to the exact post-action state")
        XCTAssertFalse(history.canRedo)
    }

    func testRedoTailDiscardedOnNewAction() {
        let history = ActionHistory()
        let box = Box(0)
        history.execute(SetValueAction(box: box, to: 1, label: "1", category: .other))
        history.execute(SetValueAction(box: box, to: 2, label: "2", category: .other))
        history.undo()                  // back to 1, "2" is redoable
        XCTAssertTrue(history.canRedo)
        XCTAssertEqual(history.log.count, 2)

        // A fresh action forks history: the redo tail ("2") is dropped.
        history.execute(SetValueAction(box: box, to: 3, label: "3", category: .other))
        XCTAssertEqual(box.value, 3)
        XCTAssertFalse(history.canRedo)
        XCTAssertEqual(history.log.map(\.label), ["1", "3"],
                       "forking must discard the reverted tail")
    }

    func testUndoRedoNoOpAtBoundaries() {
        let history = ActionHistory()
        XCTAssertNil(history.undo())
        XCTAssertNil(history.redo())
        let box = Box(0)
        history.execute(SetValueAction(box: box, to: 1, label: "1", category: .other))
        XCTAssertNil(history.redo(), "redo at the tip is a no-op")
        XCTAssertEqual(box.value, 1)
    }

    func testUndoRedoLabels() {
        let history = ActionHistory()
        let box = Box(0)
        history.execute(SetValueAction(box: box, to: 1, label: "Set one", category: .other))
        XCTAssertEqual(history.undoLabel, "Set one")
        XCTAssertNil(history.redoLabel)
        history.undo()
        XCTAssertNil(history.undoLabel)
        XCTAssertEqual(history.redoLabel, "Set one")
    }

    // MARK: - jump-to-step (TSK-1155 live timeline)

    func testJumpToCursor_revertsAndReappliesToStep() {
        let box = Box(0)
        let history = ActionHistory()
        history.execute(SetValueAction(box: box, to: 1, label: "1", category: .other))
        history.execute(SetValueAction(box: box, to: 2, label: "2", category: .other))
        history.execute(SetValueAction(box: box, to: 3, label: "3", category: .other))
        XCTAssertEqual(box.value, 3)
        XCTAssertEqual(history.appliedCount, 3)

        history.jump(toCursor: 1)   // undo 2 → state after action "1"
        XCTAssertEqual(box.value, 1)
        XCTAssertEqual(history.appliedCount, 1)

        history.jump(toCursor: 3)   // redo 2 → back to the tip
        XCTAssertEqual(box.value, 3)
        XCTAssertEqual(history.appliedCount, 3)

        history.jump(toCursor: 0)   // undo all → baseline
        XCTAssertEqual(box.value, 0)
        XCTAssertEqual(history.appliedCount, 0)

        history.jump(toCursor: 99)  // clamps to order.count → all reapplied
        XCTAssertEqual(box.value, 3)
        XCTAssertEqual(history.appliedCount, 3)
    }

    // MARK: - coalescing

    func testAdjacentSameCategoryCoalesces() {
        let history = ActionHistory(coalesceWindow: 100)
        let box = Box("")
        // Three mergeable edits on the same box, within the window.
        history.execute(SetValueAction(box: box, to: "a", label: "type a",
                                       category: .edit, mergeable: true))
        history.execute(SetValueAction(box: box, to: "ab", label: "type b",
                                       category: .edit, mergeable: true))
        history.execute(SetValueAction(box: box, to: "abc", label: "type c",
                                       category: .edit, mergeable: true))
        XCTAssertEqual(box.value, "abc")
        XCTAssertEqual(history.log.count, 1, "adjacent same-category edits collapse to one entry")
        XCTAssertEqual(history.log.first?.coalescedCount, 3)
        XCTAssertEqual(history.log.first?.label, "type c", "newest label wins")

        // One undo reverts the whole coalesced run back to the baseline.
        history.undo()
        XCTAssertEqual(box.value, "", "a coalesced run undoes as a single step")
        XCTAssertFalse(history.canUndo)
    }

    func testDifferentCategoriesDoNotCoalesce() {
        let history = ActionHistory(coalesceWindow: 100)
        let box = Box("")
        history.execute(SetValueAction(box: box, to: "a", label: "edit",
                                       category: .edit, mergeable: true))
        history.execute(SetValueAction(box: box, to: "ab", label: "cell",
                                       category: .cell, mergeable: true))
        XCTAssertEqual(history.log.count, 2, "different categories stay distinct")
    }

    func testOtherCategoryNeverCoalesces() {
        let history = ActionHistory(coalesceWindow: 100)
        let box = Box(0)
        history.execute(SetValueAction(box: box, to: 1, label: "a", category: .other, mergeable: true))
        history.execute(SetValueAction(box: box, to: 2, label: "b", category: .other, mergeable: true))
        XCTAssertEqual(history.log.count, 2, ".other is non-coalescing by category")
    }

    func testCoalesceWindowExpiryStartsNewEntry() {
        // Drive the clock so the second edit falls OUTSIDE the 1s window.
        var t = Date(timeIntervalSince1970: 1_000_000)
        let history = ActionHistory(coalesceWindow: 1.0, clock: { t })
        let box = Box("")
        history.execute(SetValueAction(box: box, to: "a", label: "a",
                                       category: .edit, mergeable: true))
        t = t.addingTimeInterval(5)   // 5s later — past the window
        history.execute(SetValueAction(box: box, to: "ab", label: "b",
                                       category: .edit, mergeable: true))
        XCTAssertEqual(history.log.count, 2, "a pause past the window starts a fresh entry")
    }

    func testNonMergeableSameCategoryStaysDistinct() {
        let history = ActionHistory(coalesceWindow: 100)
        let box = Box(0)
        // Same coalescing category but the action refuses the merge.
        history.execute(SetValueAction(box: box, to: 1, label: "a", category: .cell, mergeable: false))
        history.execute(SetValueAction(box: box, to: 2, label: "b", category: .cell, mergeable: false))
        XCTAssertEqual(history.log.count, 2)
    }

    // MARK: - cap + insertion order

    func testLogIsCappedOldestEvicted() {
        let history = ActionHistory(maxEntries: 3)
        let box = Box(0)
        for i in 1...5 {
            history.execute(SetValueAction(box: box, to: i, label: "set \(i)", category: .other))
        }
        XCTAssertEqual(history.log.count, 3, "log capped at maxEntries")
        XCTAssertEqual(history.log.map(\.label), ["set 3", "set 4", "set 5"],
                       "oldest entries evicted; insertion order preserved")
    }

    func testInsertionOrderPreserved() {
        let history = ActionHistory()
        let box = Box(0)
        let labels = ["one", "two", "three", "four"]
        for (i, l) in labels.enumerated() {
            history.execute(SetValueAction(box: box, to: i, label: l, category: .other))
        }
        XCTAssertEqual(history.log.map(\.label), labels,
                       "the log's data source reflects insertion order, oldest-first")
        // ids are monotonically increasing in insertion order.
        XCTAssertEqual(history.log.map(\.id), history.log.map(\.id).sorted())
    }

    func testEvictionAdjustsAppliedCount() {
        let history = ActionHistory(maxEntries: 2)
        let box = Box(0)
        history.execute(SetValueAction(box: box, to: 1, label: "1", category: .other))
        history.execute(SetValueAction(box: box, to: 2, label: "2", category: .other))
        history.execute(SetValueAction(box: box, to: 3, label: "3", category: .other))
        // Three executed, cap 2 → "1" evicted. All retained are applied.
        XCTAssertEqual(history.appliedCount, 2)
        XCTAssertEqual(history.log.count, 2)
        // Undo still works on the retained entries.
        history.undo()
        XCTAssertEqual(box.value, 2)
    }

    func testClearWipesLogWithoutReverting() {
        let history = ActionHistory()
        let box = Box(0)
        history.execute(SetValueAction(box: box, to: 9, label: "9", category: .other))
        history.clear()
        XCTAssertTrue(history.log.isEmpty)
        XCTAssertFalse(history.canUndo)
        XCTAssertFalse(history.canRedo)
        XCTAssertEqual(box.value, 9, "clear does not revert live state")
    }

    // MARK: - ClosureAction adapter seam

    func testClosureActionAppliesAndReverts() {
        let history = ActionHistory()
        var value = 0
        let action = ClosureAction(
            label: "increment",
            category: .other,
            apply: { value += 1 },
            revert: { value -= 1 }
        )
        history.execute(action)
        XCTAssertEqual(value, 1)
        history.undo()
        XCTAssertEqual(value, 0)
        history.redo()
        XCTAssertEqual(value, 1)
    }

    func testExecuteStampsTimestampFromClock() {
        let fixed = Date(timeIntervalSince1970: 42)
        let history = ActionHistory(clock: { fixed })
        let box = Box(0)
        history.execute(SetValueAction(box: box, to: 1, label: "1", category: .other))
        XCTAssertEqual(history.log.first?.timestamp, fixed,
                       "the coordinator stamps the action timestamp from its clock")
    }
}
