import XCTest
@testable import ViewerCore

/// TSK-1134 — teeth for the negative-control switch itself.
final class MDVNegativeControlTests: XCTestCase {

    func test_isBroken_trueWhenSetToOne() {
        XCTAssertTrue(MDVNegativeControl.isBroken("RULER", env: ["MDV_ENABLE_BROKEN_RULER": "1"]))
    }

    func test_isBroken_falseWhenUnsetOrOther() {
        XCTAssertFalse(MDVNegativeControl.isBroken("RULER", env: [:]))
        XCTAssertFalse(MDVNegativeControl.isBroken("RULER", env: ["MDV_ENABLE_BROKEN_RULER": "0"]))
        XCTAssertFalse(MDVNegativeControl.isBroken("RULER", env: ["MDV_ENABLE_BROKEN_OTHER": "1"]))
    }

    func test_prefixIsAddedToTheName() {
        XCTAssertTrue(MDVNegativeControl.isBroken("FOO", env: ["MDV_ENABLE_BROKEN_FOO": "1"]))
    }
}
