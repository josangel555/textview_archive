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

    // MARK: - Lookup family (MATCH / INDEX / VLOOKUP / HLOOKUP)

    func test_match_exactApproxAndText() {
        let g = ["A1": "10", "A2": "20", "A3": "30"]
        XCTAssertEqual(num(eval("MATCH(20,A1:A3,0)", g)), 2)         // exact
        XCTAssertEqual(num(eval("MATCH(25,A1:A3,1)", g)), 2)         // largest ≤ 25 (ascending) = 20 @ pos 2
        XCTAssertTrue(isError(eval("MATCH(5,A1:A3,0)", g)))          // not found → #N/A
        let gt = ["A1": "apple", "A2": "pear", "A3": "plum"]
        XCTAssertEqual(num(eval("MATCH(\"pear\",A1:A3,0)", gt)), 2)
    }

    func test_index_1dAnd2dAndBounds() {
        let g = ["A1": "x", "A2": "y", "A3": "z", "B1": "1", "B2": "2"]
        XCTAssertEqual(text(eval("INDEX(A1:A3,2)", g)), "y")         // single column → row index
        XCTAssertEqual(num(eval("INDEX(A1:B2,2,2)", g)), 2)          // 2-D (row 2, col 2) = B2
        XCTAssertTrue(isError(eval("INDEX(A1:A3,9)", g)))            // out of bounds → #REF
    }

    func test_vlookup_exactApproxAndMiss() {
        let g = ["A1": "10", "B1": "ten", "A2": "20", "B2": "twenty", "A3": "30", "B3": "thirty"]
        XCTAssertEqual(text(eval("VLOOKUP(20,A1:B3,2,0)", g)), "twenty")   // exact (range_lookup 0=FALSE)
        XCTAssertEqual(text(eval("VLOOKUP(25,A1:B3,2)", g)), "twenty")     // approx: largest ≤ 25 = row 20
        XCTAssertTrue(isError(eval("VLOOKUP(5,A1:B3,2,0)", g)))            // not found → #N/A
    }

    func test_hlookup_exact() {
        let g = ["A1": "a", "B1": "b", "C1": "c", "A2": "1", "B2": "2", "C2": "3"]
        XCTAssertEqual(num(eval("HLOOKUP(\"b\",A1:C2,2,0)", g)), 2)        // find "b" in row 1 → row 2 = B2
    }

    // MARK: - IFS / SWITCH / ISNA / ISERR

    func test_ifs() {
        XCTAssertEqual(num(eval("IFS(1>2,10,3>2,20,5>1,30)")), 20)         // first true cond (3>2) → 20
        XCTAssertTrue(isError(eval("IFS(1>2,10,2>3,20)")))                 // none true → #N/A
        XCTAssertTrue(isError(eval("IFS(1>2,10,3>2)")))                    // odd arg count → #VALUE
    }

    func test_switch_matchAndDefault() {
        XCTAssertEqual(text(eval("SWITCH(2,1,\"one\",2,\"two\",3,\"three\")")), "two")
        XCTAssertEqual(text(eval("SWITCH(9,1,\"one\",2,\"two\",\"other\")")), "other")   // trailing default
        XCTAssertTrue(isError(eval("SWITCH(9,1,\"one\",2,\"two\")")))                     // no match, no default → #N/A
    }

    func test_isna_iserr_distinguishNaFromOtherErrors() {
        let g = ["A1": "10"]
        XCTAssertTrue(bool(eval("ISNA(MATCH(5,A1:A1,0))", g)))    // a lookup miss is #N/A
        XCTAssertFalse(bool(eval("ISERR(MATCH(5,A1:A1,0))", g)))  // ISERR excludes #N/A
        XCTAssertTrue(bool(eval("ISERR(1/0)")))                   // #DIV/0 is an error but not #N/A
        XCTAssertFalse(bool(eval("ISNA(1/0)")))
        XCTAssertFalse(bool(eval("ISNA(5)")))                     // not an error at all
    }

    // MARK: - Date functions (ISO "YYYY-MM-DD")

    func test_date_buildsIsoAndRollsOverflow() {
        XCTAssertEqual(text(eval("DATE(2024,3,15)")), "2024-03-15")
        XCTAssertEqual(text(eval("DATE(2024,13,1)")), "2025-01-01")   // month overflow rolls the year
    }

    func test_year_month_day_extract() {
        XCTAssertEqual(num(eval("YEAR(\"2024-03-15\")")), 2024)
        XCTAssertEqual(num(eval("MONTH(\"2024-03-15\")")), 3)
        XCTAssertEqual(num(eval("DAY(\"2024-03-15\")")), 15)
        XCTAssertTrue(isError(eval("YEAR(\"2024-02-30\")")))          // impossible date rejected
        XCTAssertTrue(isError(eval("MONTH(\"not-a-date\")")))
    }

    func test_weekday_types() {
        XCTAssertEqual(num(eval("WEEKDAY(\"2024-03-15\")")), 6)       // Friday, type 1 (Sun=1)
        XCTAssertEqual(num(eval("WEEKDAY(\"2024-03-15\",2)")), 5)     // type 2 (Mon=1) → Fri=5
        XCTAssertEqual(num(eval("WEEKDAY(\"2024-03-17\")")), 1)       // Sunday → 1 (type 1)
    }

    func test_date_roundTripsThroughYear() {
        XCTAssertEqual(num(eval("YEAR(DATE(1999,12,31))")), 1999)
        XCTAssertEqual(num(eval("DAY(DATE(2000,1,1))")), 1)
    }
}
