import XCTest
@testable import ViewerCore

/// TSK-764: non-blocking external-edit reconciliation (composes TSK-712's
/// three-way merge). Pure logic — host-tested with teeth.
final class ExternalEditReconcilerTests: XCTestCase {

    private let base = "line1\nline2\nline3\nline4\nline5"

    func test_diskUnchanged_isNoExternalChange() {
        // Local has edits, but the disk still matches the baseline → keep local.
        let out = ExternalEditReconciler.reconcile(
            base: base, local: "EDITED1\nline2\nline3\nline4\nline5", disk: base)
        XCTAssertEqual(out, .noExternalChange)
    }

    func test_noLocalEdits_isCleanReload() {
        let disk = "line1\nline2\nline3\nline4\nLINE5"
        let out = ExternalEditReconciler.reconcile(base: base, local: base, disk: disk)
        XCTAssertEqual(out, .cleanReload(disk))
    }

    func test_nonOverlappingEdits_autoMerge() {
        // Local edits line1; disk edits line5 — disjoint → clean auto-merge of both.
        let local = "LINE1\nline2\nline3\nline4\nline5"
        let disk  = "line1\nline2\nline3\nline4\nLINE5"
        let out = ExternalEditReconciler.reconcile(base: base, local: local, disk: disk)
        guard case let .autoMerged(merged) = out else {
            return XCTFail("expected autoMerged, got \(out)")
        }
        XCTAssertTrue(merged.contains("LINE1"), "local edit kept")
        XCTAssertTrue(merged.contains("LINE5"), "disk edit kept")
    }

    func test_overlappingEdits_conflict_withMarkers() {
        // Both edit line3 differently → conflict.
        let local = "line1\nline2\nLOCAL3\nline4\nline5"
        let disk  = "line1\nline2\nDISK3\nline4\nline5"
        let out = ExternalEditReconciler.reconcile(base: base, local: local, disk: disk)
        guard case let .conflict(merged, count) = out else {
            return XCTFail("expected conflict, got \(out)")
        }
        XCTAssertGreaterThanOrEqual(count, 1)
        XCTAssertTrue(merged.contains("<<<<<<<"), "conflict markers present")
        XCTAssertTrue(merged.contains("LOCAL3") && merged.contains("DISK3"),
                      "both sides represented in the conflict")
    }

    func test_identicalEditBothSides_autoMergesNoConflict() {
        // Local and disk independently made the SAME edit → no conflict.
        let same = "line1\nline2\nSHARED3\nline4\nline5"
        let out = ExternalEditReconciler.reconcile(base: base, local: same, disk: same)
        guard case let .autoMerged(merged) = out else {
            return XCTFail("expected autoMerged, got \(out)")
        }
        XCTAssertTrue(merged.contains("SHARED3"))
        XCTAssertFalse(merged.contains("<<<<<<<"), "no conflict markers")
    }
}
