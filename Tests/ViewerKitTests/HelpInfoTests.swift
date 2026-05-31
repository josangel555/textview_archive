import XCTest
@testable import ViewerKit

/// Value-type tests for `HelpInfo` (0c). Equatable is load-bearing: the
/// hover sink dedupes on it to avoid republishing on every pointer move.
final class HelpInfoTests: XCTestCase {

    func test_equality_byTitleAndDescription() {
        let a = HelpInfo(title: "T", description: "D")
        let b = HelpInfo(title: "T", description: "D")
        XCTAssertEqual(a, b)
    }

    func test_inequality_onTitle() {
        XCTAssertNotEqual(HelpInfo(title: "A", description: "D"),
                          HelpInfo(title: "B", description: "D"))
    }

    func test_inequality_onDescription() {
        XCTAssertNotEqual(HelpInfo(title: "T", description: "X"),
                          HelpInfo(title: "T", description: "Y"))
    }

    func test_storesBothFields() {
        let h = HelpInfo(title: "New Tab", description: "Open a new empty tab")
        XCTAssertEqual(h.title, "New Tab")
        XCTAssertEqual(h.description, "Open a new empty tab")
    }
}
