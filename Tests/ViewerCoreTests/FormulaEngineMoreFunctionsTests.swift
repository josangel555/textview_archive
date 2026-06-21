import XCTest
@testable import ViewerCore

/// TSK-1141 — teeth for the formula functions added on top of the base set:
/// MEDIAN, SIGN, EXP/LN/LOG10, TRUNC, PROPER, EXACT, REPT, SUBSTITUTE. Pure-logic
/// (CSV `=` cells consume these via FormulaEngine; advances the sheet epic 673).
final class FormulaEngineMoreFunctionsTests: XCTestCase {

    private func eval(_ body: String) -> FormulaValue {
        var visiting = Set<CellReference>()
        return FormulaEngine.evaluateFormula(body, visiting: &visiting)
    }
    private func num(_ v: FormulaValue, _ f: StaticString = #filePath, _ l: UInt = #line) -> Double {
        guard case .number(let n) = v else { XCTFail("expected number, got \(v)", file: f, line: l); return .nan }
        return n
    }
    private func text(_ v: FormulaValue, _ f: StaticString = #filePath, _ l: UInt = #line) -> String {
        guard case .text(let s) = v else { XCTFail("expected text, got \(v)", file: f, line: l); return "" }
        return s
    }
    private func bool(_ v: FormulaValue, _ f: StaticString = #filePath, _ l: UInt = #line) -> Bool {
        guard case .boolean(let b) = v else { XCTFail("expected boolean, got \(v)", file: f, line: l); return false }
        return b
    }
    private func isError(_ v: FormulaValue) -> Bool { if case .error = v { return true }; return false }

    func test_median_oddAndEven_andUnsorted() {
        XCTAssertEqual(num(eval("MEDIAN(3,1,2)")), 2, accuracy: 1e-9)        // unsorted input
        XCTAssertEqual(num(eval("MEDIAN(1,2,3,4)")), 2.5, accuracy: 1e-9)    // even → mean of middle two
        XCTAssertTrue(isError(eval("MEDIAN()")))
    }

    func test_sign() {
        XCTAssertEqual(num(eval("SIGN(5)")), 1)
        XCTAssertEqual(num(eval("SIGN(-3)")), -1)
        XCTAssertEqual(num(eval("SIGN(0)")), 0)
    }

    func test_exp_ln_log10_andDomainErrors() {
        XCTAssertEqual(num(eval("EXP(0)")), 1, accuracy: 1e-9)
        XCTAssertEqual(num(eval("LN(1)")), 0, accuracy: 1e-9)
        XCTAssertEqual(num(eval("LOG10(1000)")), 3, accuracy: 1e-9)
        XCTAssertTrue(isError(eval("LN(0)")))       // x must be > 0
        XCTAssertTrue(isError(eval("LOG10(-5)")))
    }

    func test_trunc_towardZero_notFloor() {
        XCTAssertEqual(num(eval("TRUNC(3.9)")), 3)
        XCTAssertEqual(num(eval("TRUNC(-3.9)")), -3)               // toward zero (FLOOR would give -4)
        XCTAssertEqual(num(eval("TRUNC(3.14159,2)")), 3.14, accuracy: 1e-9)
    }

    func test_proper_titleCases() {
        XCTAssertEqual(text(eval("PROPER(\"hello world\")")), "Hello World")
    }

    func test_exact_isCaseSensitive() {
        XCTAssertTrue(bool(eval("EXACT(\"abc\",\"abc\")")))
        XCTAssertFalse(bool(eval("EXACT(\"abc\",\"ABC\")")))       // unlike =, EXACT is case-sensitive
    }

    func test_rept() {
        XCTAssertEqual(text(eval("REPT(\"ab\",3)")), "ababab")
        XCTAssertEqual(text(eval("REPT(\"x\",0)")), "")
        XCTAssertTrue(isError(eval("REPT(\"x\",-1)")))            // negative count rejected
    }

    func test_substitute_allAndNth() {
        XCTAssertEqual(text(eval("SUBSTITUTE(\"a-b-c\",\"-\",\"+\")")), "a+b+c")       // replace all
        XCTAssertEqual(text(eval("SUBSTITUTE(\"a-b-c\",\"-\",\"+\",2)")), "a-b+c")     // only the 2nd
        XCTAssertEqual(text(eval("SUBSTITUTE(\"a-b-c\",\"-\",\"+\",9)")), "a-b-c")     // fewer than N → unchanged
    }
}
