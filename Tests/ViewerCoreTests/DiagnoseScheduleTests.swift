import XCTest
@testable import ViewerCore

/// TSK-493 — the MDV_DIAGNOSE_DELAY parse contract. main.swift defers the
/// --diagnose dump by exactly this value, which is what lets the harness
/// sequence the dump AFTER an MDV_UI_SCENE apply.
final class DiagnoseScheduleTests: XCTestCase {

    func test_nilGarbageAndNonPositive_meanImmediate() {
        XCTAssertEqual(DiagnoseSchedule.delay(nil), 0)
        XCTAssertEqual(DiagnoseSchedule.delay(""), 0)
        XCTAssertEqual(DiagnoseSchedule.delay("abc"), 0)
        XCTAssertEqual(DiagnoseSchedule.delay("0"), 0)
        XCTAssertEqual(DiagnoseSchedule.delay("-2"), 0)
    }

    func test_validDelay_passesThrough() {
        XCTAssertEqual(DiagnoseSchedule.delay("1.5"), 1.5)
        XCTAssertEqual(DiagnoseSchedule.delay("0.1"), 0.1)
    }

    func test_hugeDelay_cappedSoATypoCannotHangTheHarness() {
        XCTAssertEqual(DiagnoseSchedule.delay("9999"), DiagnoseSchedule.maxDelay)
    }
}
