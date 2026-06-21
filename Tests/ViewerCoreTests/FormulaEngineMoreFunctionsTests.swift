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

    // MARK: - Conditional aggregates (range + criterion)

    private func eval(_ body: String, _ grid: [String: String]) -> FormulaValue {
        var visiting = Set<CellReference>()
        let resolve: CellResolver = { ref in grid[ref.a1] }
        return FormulaEngine.evaluateFormula(body, resolve: resolve, visiting: &visiting)
    }

    func test_countif_numericAndComparison() {
        let g = ["A1": "5", "A2": "10", "A3": "15", "A4": "3"]
        XCTAssertEqual(num(eval("COUNTIF(A1:A4,\">5\")", g)), 2)    // 10, 15
        XCTAssertEqual(num(eval("COUNTIF(A1:A4,5)", g)), 1)
        XCTAssertEqual(num(eval("COUNTIF(A1:A4,\">=5\")", g)), 3)   // 5, 10, 15
        XCTAssertEqual(num(eval("COUNTIF(A1:A4,\"<>5\")", g)), 3)
    }

    func test_countif_textIsCaseInsensitive() {
        let g = ["A1": "apple", "A2": "Apple", "A3": "pear"]
        XCTAssertEqual(num(eval("COUNTIF(A1:A3,\"apple\")", g)), 2)
        XCTAssertEqual(num(eval("COUNTIF(A1:A3,\"<>apple\")", g)), 1)
    }

    func test_sumif_sameRangeAndSeparateSumRange() {
        let g = ["A1": "5", "A2": "10", "A3": "15", "B1": "1", "B2": "2", "B3": "3"]
        XCTAssertEqual(num(eval("SUMIF(A1:A3,\">5\")", g)), 25)         // 10 + 15
        XCTAssertEqual(num(eval("SUMIF(A1:A3,\">5\",B1:B3)", g)), 5)    // B2 + B3 = 2 + 3
    }

    func test_averageif_andEmptyMatchIsError() {
        let g = ["A1": "5", "A2": "10", "A3": "15"]
        XCTAssertEqual(num(eval("AVERAGEIF(A1:A3,\">5\")", g)), 12.5, accuracy: 1e-9)   // (10+15)/2
        XCTAssertTrue(isError(eval("AVERAGEIF(A1:A3,\">100\")", g)))                     // none → #DIV/0
    }

    // MARK: - Type predicates (IS*)

    func test_isPredicates_byType() {
        XCTAssertTrue(bool(eval("ISNUMBER(5)")))
        XCTAssertFalse(bool(eval("ISNUMBER(\"x\")")))
        XCTAssertTrue(bool(eval("ISTEXT(\"x\")")))
        XCTAssertFalse(bool(eval("ISTEXT(5)")))
        XCTAssertTrue(bool(eval("ISNONTEXT(5)")))
        XCTAssertFalse(bool(eval("ISNONTEXT(\"x\")")))
        XCTAssertTrue(bool(eval("ISLOGICAL(1>0)")))     // a comparison yields a boolean
        XCTAssertFalse(bool(eval("ISLOGICAL(1)")))
    }

    func test_iserror_doesNotPropagate() {
        XCTAssertTrue(bool(eval("ISERROR(1/0)")))       // detects the #DIV/0 instead of propagating it
        XCTAssertFalse(bool(eval("ISERROR(5)")))
    }

    func test_isblank_onAbsentCell() {
        let g = ["A1": "5"]                              // A2 is absent → blank
        XCTAssertTrue(bool(eval("ISBLANK(A2)", g)))
        XCTAssertFalse(bool(eval("ISBLANK(A1)", g)))
    }
}
