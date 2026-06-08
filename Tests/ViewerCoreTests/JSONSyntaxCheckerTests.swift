import XCTest
@testable import ViewerCore

/// Coverage for the JSON syntax-error locator (TSK-513). Valid cases must pass;
/// each error class must report the correct 1-based line:column (the whole
/// point — Foundation gives no position).
final class JSONSyntaxCheckerTests: XCTestCase {

    private func assertValid(_ t: String, _ f: StaticString = #file, _ l: UInt = #line) {
        XCTAssertEqual(JSONSyntaxChecker.check(t), .valid, file: f, line: l)
    }
    private func assertInvalid(_ t: String, line: Int, column: Int,
                               _ f: StaticString = #file, _ l: UInt = #line) {
        guard case .invalid(let gl, let gc, _) = JSONSyntaxChecker.check(t) else {
            return XCTFail("expected .invalid for \(t.debugDescription)", file: f, line: l)
        }
        XCTAssertEqual(gl, line, "line", file: f, line: l)
        XCTAssertEqual(gc, column, "column", file: f, line: l)
    }

    // MARK: valid

    func test_validScalarsAndContainers() {
        assertValid("{}")
        assertValid("[]")
        assertValid("\"hello\"")
        assertValid("42")
        assertValid("-3.14")
        assertValid("1e10")
        assertValid("1E+10")
        assertValid("true"); assertValid("false"); assertValid("null")
        assertValid("0"); assertValid("-0"); assertValid("0.5")
        assertValid("  {}  \n")   // surrounding whitespace
    }

    func test_validNestedAndEscapes() {
        assertValid(#"{"a":[1,2,{"b":true}],"c":null}"#)
        assertValid("\"a\\n\\t\\\"\\\\\\/\\u00e9\"")   // "a\n\t\"\\\/é"
    }

    // MARK: invalid — position is the point

    func test_emptyInput() { assertInvalid("", line: 1, column: 1) }

    func test_leadingZero() { assertInvalid("01", line: 1, column: 2) }

    func test_trailingCommaInArray() { assertInvalid("[1,]", line: 1, column: 4) }

    func test_bareMinus() { assertInvalid("-", line: 1, column: 2) }

    func test_fractionNeedsDigit() { assertInvalid("1.", line: 1, column: 3) }

    func test_exponentNeedsDigit() { assertInvalid("1e", line: 1, column: 3) }

    func test_unterminatedString() { assertInvalid("\"abc", line: 1, column: 5) }

    func test_invalidEscape() {
        // "a\x"  → bad escape at the 'x' (col 4)
        assertInvalid("\"a\\x\"", line: 1, column: 4)
    }

    func test_truncatedLiteral() { assertInvalid("tru", line: 1, column: 4) }

    func test_trailingContent() { assertInvalid("{} x", line: 1, column: 4) }

    func test_missingColon() { assertInvalid("{\"a\" 1}", line: 1, column: 6) }

    func test_multilinePositionTracking() {
        // line 2 is `"x": }` → the '}' where a value is expected is col 6.
        assertInvalid("{\n\"x\": }", line: 2, column: 6)
    }

    func test_unescapedControlCharInString() {
        // a raw newline inside a string is illegal JSON.
        assertInvalid("\"a\nb\"", line: 1, column: 3)
    }

    func test_deepNesting_isReportedNotCrashed() {
        let deep = String(repeating: "[", count: 600)
        guard case .invalid = JSONSyntaxChecker.check(deep) else {
            return XCTFail("deep nesting should report an error, not overflow")
        }
    }
}
