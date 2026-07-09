import XCTest
import ViewerCore
@testable import ViewerUI

/// TSK-1171 — host coverage for the 3-pane conflict-resolution VIEW MODEL: the
/// per-conflict choice bookkeeping + the derived resolved text. The diff3 merge +
/// the `resolved(_:)` apply are pinned by ThreeWayMergeTests; these pin the UI
/// state machine (the 3-pane SwiftUI render is the VM tail).
@MainActor
final class ConflictResolutionModelTests: XCTestCase {

    /// Two separate conflicts (line 2 and line 4).
    private func twoConflicts() -> ThreeWayMerge.Result {
        ThreeWayMerge.merge(
            base:   ["1", "a", "2", "b", "3"],
            ours:   ["1", "OA", "2", "OB", "3"],
            theirs: ["1", "TA", "2", "TB", "3"])
    }

    func test_startsUnresolved_noTextUntilAllChosen() {
        let m = ConflictResolutionModel(result: twoConflicts())
        XCTAssertEqual(m.conflicts.count, 2)
        XCTAssertEqual(m.unresolvedCount, 2)
        XCTAssertFalse(m.allResolved)
        XCTAssertNil(m.resolvedText, "no output until every conflict is resolved")
    }

    func test_selectEachConflict_producesResolvedText() {
        let m = ConflictResolutionModel(result: twoConflicts())
        m.select(.ours, at: 0)
        XCTAssertFalse(m.allResolved, "still one conflict open")
        XCTAssertNil(m.resolvedText)
        m.select(.theirs, at: 1)
        XCTAssertTrue(m.allResolved)
        XCTAssertEqual(m.resolvedText, "1\nOA\n2\nTB\n3")
    }

    func test_changingAChoice_updatesOutput() {
        let m = ConflictResolutionModel(result: twoConflicts())
        m.select(.ours, at: 0)
        m.select(.ours, at: 1)
        XCTAssertEqual(m.resolvedText, "1\nOA\n2\nOB\n3")
        m.select(.theirs, at: 0)   // change the first choice
        XCTAssertEqual(m.resolvedText, "1\nTA\n2\nOB\n3")
    }

    func test_selectOutOfRange_isIgnored() {
        let m = ConflictResolutionModel(result: twoConflicts())
        m.select(.ours, at: 9)     // no such conflict
        XCTAssertEqual(m.unresolvedCount, 2)
    }

    func test_resolveAllRemaining_bulkAction() {
        let m = ConflictResolutionModel(result: twoConflicts())
        m.select(.theirs, at: 0)                 // one hand-picked
        m.resolveAllRemaining(with: .ours)        // the rest → ours
        XCTAssertTrue(m.allResolved)
        XCTAssertEqual(m.resolvedText, "1\nTA\n2\nOB\n3",
                       "the pre-chosen conflict keeps its choice; only the rest take the bulk value")
    }

    func test_customResolution_flows() {
        let m = ConflictResolutionModel(result: twoConflicts())
        m.select(.custom(["X"]), at: 0)
        m.select(.custom(["Y"]), at: 1)
        XCTAssertEqual(m.resolvedText, "1\nX\n2\nY\n3")
    }
}
