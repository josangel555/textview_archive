import XCTest
@testable import ViewerCore

/// The `ui-click` grammar — strict by design: a typo'd modifier must FAIL
/// the parse, never silently degrade into an unmodified click (a test
/// that "passes" with the wrong gesture is the false green we kill).
final class UIClickSpecTests: XCTestCase {

    func test_plainClick_defaultsToCenter() throws {
        let s = try XCTUnwrap(UIClickSpec.parse(verb: "ui-click", arg: "mdv.thing"))
        XCTAssertEqual(s, UIClickSpec(identifier: "mdv.thing", clickCount: 1,
                                      command: false, shift: false, fx: 0.5, fy: 0.5))
    }

    func test_doubleClick_modifiers_andFractions() throws {
        let s = try XCTUnwrap(UIClickSpec.parse(
            verb: "ui-double-click", arg: "mdv.strip cmd shift at 0.9 0.25"))
        XCTAssertEqual(s.identifier, "mdv.strip")
        XCTAssertEqual(s.clickCount, 2)
        XCTAssertTrue(s.command)
        XCTAssertTrue(s.shift)
        XCTAssertEqual(s.fx, 0.9, accuracy: 0.0001)
        XCTAssertEqual(s.fy, 0.25, accuracy: 0.0001)
    }

    func test_fractions_clampToUnitRange() throws {
        let s = try XCTUnwrap(UIClickSpec.parse(verb: "ui-click", arg: "id at -1 7"))
        XCTAssertEqual(s.fx, 0)
        XCTAssertEqual(s.fy, 1)
    }

    func test_invalidForms_rejected() {
        XCTAssertNil(UIClickSpec.parse(verb: "ui-click", arg: ""), "missing id")
        XCTAssertNil(UIClickSpec.parse(verb: "ui-triple-click", arg: "id"), "unknown verb")
        XCTAssertNil(UIClickSpec.parse(verb: "ui-click", arg: "id cmdd"),
                     "typo'd modifier must FAIL, not degrade")
        XCTAssertNil(UIClickSpec.parse(verb: "ui-click", arg: "id at 0.5"), "at needs two args")
        XCTAssertNil(UIClickSpec.parse(verb: "ui-click", arg: "id at x y"), "non-numeric at")
        XCTAssertNil(UIClickSpec.parse(verb: "ui-click", arg: "id at nan 0.5"), "non-finite at")
    }
}
