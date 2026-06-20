import XCTest
@testable import ViewerCore

/// Pure-logic coverage for the WRITE-TIME no-clobber save guard
/// (`SaveConflictDecision`). This is the contract that stops ⌘S from
/// blind-overwriting a change another process made to the file under a dirty
/// buffer (the 2026-06-20 data-loss incident, TSK-768).
///
/// The decision table being pinned (mirrors `DiskConflictResolver.classify`):
///
///     dirty?  hasExternalEdit  hasUnknownDiskState  →  decision
///     -----   ---------------  -------------------     ----------------------
///     no      false            *                       proceed
///     no      true             *                       reloadSilently
///     yes     false            false                   proceed (proven unchanged)
///     yes     true             *                       conflict
///     yes     false            true                    conflict (can't prove)
final class SaveConflictDecisionTests: XCTestCase {

    // MARK: - The data-loss case: dirty buffer + changed disk → conflict

    func test_dirty_diskChanged_isConflict_noSilentWrite() {
        let d = SaveConflictDecision.decide(
            dirty: true, hasExternalEdit: true, hasUnknownDiskState: false)
        guard case .conflict(let actions) = d else {
            return XCTFail("a dirty buffer over a changed disk MUST be a conflict, got \(d)")
        }
        XCTAssertEqual(actions, SaveConflictDecision.conflictActions,
            "conflict must offer the full resolution set")
    }

    func test_dirty_unknownDiskState_isConflict_beSafe() {
        // We can't PROVE the disk is unchanged (a needed fingerprint operand is
        // nil) and the buffer is dirty → escalate to a conflict rather than
        // risk a silent clobber.
        let d = SaveConflictDecision.decide(
            dirty: true, hasExternalEdit: false, hasUnknownDiskState: true)
        guard case .conflict = d else {
            return XCTFail("dirty + can't-prove-unchanged MUST be a conflict, got \(d)")
        }
    }

    // MARK: - The normal proceed cases

    func test_dirty_diskProvenUnchanged_proceeds() {
        let d = SaveConflictDecision.decide(
            dirty: true, hasExternalEdit: false, hasUnknownDiskState: false)
        XCTAssertEqual(d, .proceed,
            "a dirty buffer over a PROVABLY-unchanged disk is the normal save")
    }

    func test_clean_diskUnchanged_proceeds() {
        let d = SaveConflictDecision.decide(
            dirty: false, hasExternalEdit: false, hasUnknownDiskState: false)
        XCTAssertEqual(d, .proceed)
    }

    func test_clean_unknownDiskState_proceeds_nothingToLose() {
        // Clean buffer: even if we can't prove the disk state, there are no
        // edits to lose, so a (no-op) save may proceed — no prompt.
        let d = SaveConflictDecision.decide(
            dirty: false, hasExternalEdit: false, hasUnknownDiskState: true)
        XCTAssertEqual(d, .proceed)
    }

    // MARK: - Clean buffer + changed disk → reload, never prompt

    func test_clean_diskChanged_reloadsSilently_noPrompt() {
        let d = SaveConflictDecision.decide(
            dirty: false, hasExternalEdit: true, hasUnknownDiskState: false)
        XCTAssertEqual(d, .reloadSilently,
            "a clean buffer over a changed disk is the normal external-update "
            + "path: reload, do NOT prompt")
    }

    // MARK: - Action ordering: destructive option is never the default

    func test_conflictActions_orderPutsOverwriteLast_viewDiffFirst() {
        let actions = SaveConflictDecision.conflictActions
        XCTAssertEqual(actions.first, .viewDiff,
            "the safest non-destructive option leads the menu")
        XCTAssertEqual(actions.last, .overwrite,
            "the destructive overwrite is last so it's never the accidental default")
        XCTAssertEqual(Set(actions), Set(SaveConflictAction.allCases),
            "every defined resolution must be offered")
    }

    // MARK: - EditorBuffer convenience overload

    func test_decideAgainstBuffer_dirtyAndMTimeChanged_isConflict() {
        let base = Date(timeIntervalSince1970: 1_000)
        var buf = EditorBuffer(
            url: URL(fileURLWithPath: "/tmp/x.txt"),
            original: "hello",
            lastSavedMTime: base, lastSavedSize: 5)
        buf.setText("hello world")   // now dirty
        // Disk mtime moved (another process wrote).
        let d = SaveConflictDecision.decide(
            buffer: buf,
            currentMTime: base.addingTimeInterval(60), currentSize: 99)
        guard case .conflict = d else {
            return XCTFail("dirty buffer + moved disk mtime/size MUST conflict, got \(d)")
        }
    }

    func test_decideAgainstBuffer_dirtyAndDiskUnchanged_proceeds() {
        let base = Date(timeIntervalSince1970: 1_000)
        var buf = EditorBuffer(
            url: URL(fileURLWithPath: "/tmp/x.txt"),
            original: "hello",
            lastSavedMTime: base, lastSavedSize: 5)
        buf.setText("hello world")
        let d = SaveConflictDecision.decide(
            buffer: buf, currentMTime: base, currentSize: 5)
        XCTAssertEqual(d, .proceed)
    }

    func test_decideAgainstBuffer_noBaseline_dirty_isConflict() {
        // Buffer never captured a baseline (file unreadable at load) → can't
        // prove unchanged → a dirty save must conflict, not clobber.
        var buf = EditorBuffer(
            url: URL(fileURLWithPath: "/tmp/x.txt"),
            original: "hello",
            lastSavedMTime: nil, lastSavedSize: nil)
        buf.setText("edited")
        let d = SaveConflictDecision.decide(
            buffer: buf, currentMTime: Date(), currentSize: 6)
        guard case .conflict = d else {
            return XCTFail("no baseline + dirty MUST conflict, got \(d)")
        }
    }
}
