import XCTest
@testable import ViewerCore

/// TSK-673 — teeth for the sheet formula-evaluation CONTRACT. STAGE-B
/// (TSK-649/1213, 2026-07-07): the Swift evaluator twin is deleted — every
/// rule below now pins the RUST engine through the production adapter
/// (formula planted in a grid cell, recalced, the cell's value asserted).
/// A1 addressing, builtin functions, error propagation, cycle detection.
final class FormulaEngineTests: XCTestCase {

    // MARK: - Helpers

    /// The A1 slot the formula-under-test is planted at — far from the
    /// fixtures' A1:D4 neighborhoods so grids never collide with it.
    private static let probe = "ZZ99"

    /// Evaluate a formula body (no leading `=`) against an optional small
    /// grid keyed by A1 text — through the RUST recalc engine.
    private func eval(_ body: String, grid: [String: String] = [:]) -> FormulaValue {
        var cells = grid
        cells[Self.probe] = "=" + body
        guard let out = try? RustFormulaAdapter.recalc(cells: cells),
              let ref = CellReference(a1: Self.probe),
              let value = out[ref] else {
            XCTFail("rust recalc produced no value for =\(body)")
            return .blank
        }
        return value
    }

    private func num(_ v: FormulaValue, _ file: StaticString = #filePath, _ line: UInt = #line) -> Double? {
        if case .number(let n) = v { return n }
        XCTFail("expected number, got \(v)", file: file, line: line)
        return nil
    }

    // MARK: - CellReference: bijective base-26 columns

    func test_columnLetters_bijectiveBase26() {
        XCTAssertEqual(CellReference.columnLetters(0), "A")
        XCTAssertEqual(CellReference.columnLetters(25), "Z")
        XCTAssertEqual(CellReference.columnLetters(26), "AA")
        XCTAssertEqual(CellReference.columnLetters(27), "AB")
        XCTAssertEqual(CellReference.columnLetters(51), "AZ")
        XCTAssertEqual(CellReference.columnLetters(52), "BA")
        XCTAssertEqual(CellReference.columnLetters(701), "ZZ")
        XCTAssertEqual(CellReference.columnLetters(702), "AAA")
    }

    func test_columnIndex_roundTripsLetters() {
        for i in [0, 1, 25, 26, 27, 51, 52, 701, 702, 1000] {
            let letters = CellReference.columnLetters(i)
            XCTAssertEqual(CellReference.columnIndex(fromLetters: Substring(letters)), i,
                           "round-trip failed for \(i) (\(letters))")
        }
        // Case-insensitive.
        XCTAssertEqual(CellReference.columnIndex(fromLetters: "aa"), 26)
        // Reject non-letters / empty.
        XCTAssertNil(CellReference.columnIndex(fromLetters: ""))
        XCTAssertNil(CellReference.columnIndex(fromLetters: "A1"))
    }

    func test_cellReference_parse_validAndInvalid() {
        XCTAssertEqual(CellReference(a1: "A1"), CellReference(row: 0, column: 0))
        XCTAssertEqual(CellReference(a1: "B12"), CellReference(row: 11, column: 1))
        XCTAssertEqual(CellReference(a1: "AA3"), CellReference(row: 2, column: 26))
        XCTAssertEqual(CellReference(a1: "bc42"), CellReference(row: 41, column: 54))
        // Round-trip the canonical text.
        XCTAssertEqual(CellReference(a1: "Z100")?.a1, "Z100")
        // Malformed.
        XCTAssertNil(CellReference(a1: ""))
        XCTAssertNil(CellReference(a1: "1A"))
        XCTAssertNil(CellReference(a1: "A"))
        XCTAssertNil(CellReference(a1: "12"))
        XCTAssertNil(CellReference(a1: "A 1"))
        XCTAssertNil(CellReference(a1: "$A$1"))
        XCTAssertNil(CellReference(a1: "A0"))   // 1-based rows; row 0 invalid
    }

    func test_cellRange_normalizesCornersAndEnumerates() {
        let r = CellRange(CellReference(a1: "B3")!, CellReference(a1: "A1")!)
        XCTAssertEqual(r.top, 0); XCTAssertEqual(r.left, 0)
        XCTAssertEqual(r.bottom, 2); XCTAssertEqual(r.right, 1)
        XCTAssertEqual(r.count, 6)
        // Row-major enumeration.
        XCTAssertEqual(r.cells.map(\.a1), ["A1", "B1", "A2", "B2", "A3", "B3"])
    }

    // MARK: - Literals

    func test_literalCells_coerceThroughTheEngine() {
        // Stage-B: literal handling pinned through the engine — a formula
        // referencing a literal cell sees its coerced value.
        XCTAssertEqual(num(eval("A1+0", grid: ["A1": "42"])), 42)
        XCTAssertEqual(num(eval("A1+0", grid: ["A1": "3.5"])), 3.5)
        XCTAssertEqual(eval("A1&\"\"", grid: ["A1": "hello"]), .text("hello"))
    }

    // MARK: - Arithmetic + precedence

    func test_arithmetic_precedenceAndAssociativity() {
        XCTAssertEqual(num(eval("1+2*3")), 7)            // * before +
        XCTAssertEqual(num(eval("(1+2)*3")), 9)          // parens
        XCTAssertEqual(num(eval("10-3-2")), 5)           // left-assoc -
        XCTAssertEqual(num(eval("2^3^2")), 512)          // right-assoc ^
        XCTAssertEqual(num(eval("-2^2")), -4)            // unary minus binds looser than ^ → -(2^2)
        XCTAssertEqual(num(eval("8/2/2")), 2)            // left-assoc /
    }

    func test_unaryAndPercent() {
        XCTAssertEqual(num(eval("-5")), -5)
        XCTAssertEqual(num(eval("--5")), 5)
        XCTAssertEqual(num(eval("+7")), 7)
        XCTAssertEqual(num(eval("50%")), 0.5)
        XCTAssertEqual(num(eval("10+50%")), 10.5)
    }

    func test_divideByZero_isError() {
        XCTAssertEqual(eval("1/0"), .error(.divideByZero))
        XCTAssertEqual(eval("5/(2-2)"), .error(.divideByZero))
    }

    // MARK: - Strings + concat + comparison

    func test_stringConcat() {
        XCTAssertEqual(eval("\"foo\" & \"bar\""), .text("foobar"))
        XCTAssertEqual(eval("\"a\" & 1 & \"b\""), .text("a1b"))
    }

    func test_comparisons_yieldBooleans() {
        XCTAssertEqual(eval("1 < 2"), .boolean(true))
        XCTAssertEqual(eval("2 <= 2"), .boolean(true))
        XCTAssertEqual(eval("3 <> 3"), .boolean(false))
        XCTAssertEqual(eval("3 = 3"), .boolean(true))
        XCTAssertEqual(eval("\"abc\" = \"ABC\""), .boolean(true))   // case-insensitive text
        XCTAssertEqual(eval("\"apple\" < \"banana\""), .boolean(true))
    }

    // MARK: - Functions over scalars + ranges

    func test_aggregateFunctions_overGrid() {
        let g = ["A1": "1", "A2": "2", "A3": "3", "A4": "4"]
        XCTAssertEqual(num(eval("SUM(A1:A4)", grid: g)), 10)
        XCTAssertEqual(num(eval("AVERAGE(A1:A4)", grid: g)), 2.5)
        XCTAssertEqual(num(eval("MIN(A1:A4)", grid: g)), 1)
        XCTAssertEqual(num(eval("MAX(A1:A4)", grid: g)), 4)
        XCTAssertEqual(num(eval("COUNT(A1:A4)", grid: g)), 4)
        XCTAssertEqual(num(eval("PRODUCT(A1:A4)", grid: g)), 24)
        // Mixed args: range + scalar.
        XCTAssertEqual(num(eval("SUM(A1:A2, 10)", grid: g)), 13)
    }

    func test_aggregate_skipsBlanksAndText() {
        let g = ["A1": "1", "A2": "", "A3": "hello", "A4": "4"]
        // SUM/COUNT ignore blanks + non-numeric text.
        XCTAssertEqual(num(eval("SUM(A1:A4)", grid: g)), 5)
        XCTAssertEqual(num(eval("COUNT(A1:A4)", grid: g)), 2)
        // COUNTA counts non-blank (text included).
        XCTAssertEqual(num(eval("COUNTA(A1:A4)", grid: g)), 3)
    }

    func test_mathFunctions() {
        XCTAssertEqual(num(eval("ABS(-7)")), 7)
        XCTAssertEqual(num(eval("INT(3.9)")), 3)
        XCTAssertEqual(num(eval("INT(-3.1)")), -4)        // floor
        XCTAssertEqual(num(eval("SQRT(16)")), 4)
        XCTAssertEqual(eval("SQRT(-1)"), .error(.num))
        XCTAssertEqual(num(eval("ROUND(3.14159, 2)")), 3.14)
        XCTAssertEqual(num(eval("ROUND(2.5)")), 3)        // 0 digits default
        XCTAssertEqual(num(eval("POWER(2, 10)")), 1024)
        XCTAssertEqual(num(eval("MOD(7, 3)")), 1)
        XCTAssertEqual(num(eval("MOD(-1, 3)")), 2)        // Excel sign-of-divisor
        XCTAssertEqual(eval("MOD(5, 0)"), .error(.divideByZero))
    }

    func test_logicalFunctions() {
        XCTAssertEqual(eval("IF(1<2, \"yes\", \"no\")"), .text("yes"))
        XCTAssertEqual(eval("IF(1>2, \"yes\", \"no\")"), .text("no"))
        XCTAssertEqual(num(eval("IF(TRUE, 10, 20)")), 10)
        XCTAssertEqual(eval("AND(TRUE, TRUE, 1=1)"), .boolean(true))
        XCTAssertEqual(eval("AND(TRUE, FALSE)"), .boolean(false))
        XCTAssertEqual(eval("OR(FALSE, FALSE, TRUE)"), .boolean(true))
        XCTAssertEqual(eval("NOT(FALSE)"), .boolean(true))
    }

    func test_textFunctions() {
        XCTAssertEqual(num(eval("LEN(\"hello\")")), 5)
        XCTAssertEqual(eval("UPPER(\"abc\")"), .text("ABC"))
        XCTAssertEqual(eval("LOWER(\"ABC\")"), .text("abc"))
        XCTAssertEqual(eval("TRIM(\"  hi  \")"), .text("hi"))
        XCTAssertEqual(eval("CONCAT(\"a\", \"b\", \"c\")"), .text("abc"))
    }

    // MARK: - Cell references that are themselves formulas

    func test_cellReferences_resolveAndChainFormulas() {
        let g = ["A1": "2", "A2": "3", "B1": "=A1+A2"]
        XCTAssertEqual(num(eval("A1+A2", grid: g)), 5)
        // A reference to a formula cell evaluates that cell's formula.
        XCTAssertEqual(num(eval("B1*2", grid: g)), 10)
    }

    func test_blankCellIsZero() {
        XCTAssertEqual(num(eval("A1+5", grid: [:])), 5)   // A1 blank → 0
    }

    // MARK: - Error propagation + cycle detection

    func test_errorPropagatesThroughOperators() {
        XCTAssertEqual(eval("1 + (1/0)"), .error(.divideByZero))
        XCTAssertEqual(eval("SUM(1, 1/0)"), .error(.divideByZero))
        XCTAssertEqual(eval("SQRT(\"text\")"), .error(.value))
    }

    func test_unknownFunctionIsNameError() {
        XCTAssertEqual(eval("BOGUS(1)"), .error(.name))
    }

    func test_unknownBareNameIsNameError() {
        // A bare name that isn't a function or a valid cell ref.
        XCTAssertEqual(eval("foobar123baz"), .error(.name))
    }

    func test_malformedFormulaIsParseError() {
        XCTAssertEqual(eval("1 +"), .error(.parse))
        XCTAssertEqual(eval("(1 + 2"), .error(.parse))
        XCTAssertEqual(eval("1 2"), .error(.parse))
        XCTAssertEqual(eval("@#$"), .error(.parse))
    }

    func test_directSelfReference_isCycle() {
        // A1 = A1 (the probe references the grid's self-cycle).
        XCTAssertEqual(eval("A1+0", grid: ["A1": "=A1"]), .error(.cycle))
    }

    func test_indirectCycle_isCycle() {
        // A1 -> B1 -> A1.
        XCTAssertEqual(eval("A1+0", grid: ["A1": "=B1+1", "B1": "=A1+1"]),
                       .error(.cycle))
    }

    func test_diamondReference_notACycle() {
        // A1 -> B1, A1 -> C1, both -> D1. Shared dep is fine (not a cycle).
        XCTAssertEqual(
            eval("A1", grid: ["A1": "=B1+C1", "B1": "=D1", "C1": "=D1", "D1": "5"]),
            .number(10))
    }

    // MARK: - Value coercion / formatting

    func test_numberFormatting_trimsIntegerDecimals() {
        XCTAssertEqual(FormulaValue.number(5).asText, "5")
        XCTAssertEqual(FormulaValue.number(5.5).asText, "5.5")
        XCTAssertEqual(FormulaValue.number(-0.0).asText, "0")
        XCTAssertEqual(FormulaValue.boolean(true).asText, "TRUE")
        XCTAssertEqual(FormulaValue.blank.asText, "")
        XCTAssertEqual(FormulaValue.error(.divideByZero).asText, "#DIV/0!")
    }

    func test_errorDisplayTokens() {
        XCTAssertEqual(FormulaError.divideByZero.display, "#DIV/0!")
        XCTAssertEqual(FormulaError.value.display, "#VALUE!")
        XCTAssertEqual(FormulaError.ref.display, "#REF!")
        XCTAssertEqual(FormulaError.name.display, "#NAME?")
        XCTAssertEqual(FormulaError.num.display, "#NUM!")
        XCTAssertEqual(FormulaError.cycle.display, "#CYCLE!")
        XCTAssertEqual(FormulaError.parse.display, "#ERROR!")
    }

    // MARK: - EditableCSVModel bridge

    func test_csvBridge_a1SkipsHeaderRow_andRecalcResolves() {
        // Grid: header a,b ; data rows. A1 = first DATA row col A. The bridge
        // snapshot + rust recalc resolve formula cells against that space.
        let model = EditableCSVModel(RustCSVAdapter.parse("a,b\n10,=A1*2\n30,=SUM(A1:A2)"))
        let out = model.recalcAllFormulas(environment: [:])
        XCTAssertEqual(out[CellReference(a1: "B1")!], .number(20), "=A1*2 over A1=10")
        XCTAssertEqual(out[CellReference(a1: "B2")!], .number(40), "=SUM(10,30)")
        // Literal cells are not in the recalc output (formula cells only).
        XCTAssertNil(out[CellReference(a1: "A1")!])
    }

    // MARK: - TSK-1141 added builtins (LEFT/RIGHT/MID, ROUNDUP/DOWN, CEILING/FLOOR, IFERROR)

    private func txt(_ v: FormulaValue) -> String? {
        if case .text(let s) = v { return s }; return nil
    }

    func test_textExtractionFunctions() {
        XCTAssertEqual(txt(eval("LEFT(\"hello\", 3)")), "hel")
        XCTAssertEqual(txt(eval("RIGHT(\"hello\", 2)")), "lo")
        XCTAssertEqual(txt(eval("MID(\"hello\", 2, 3)")), "ell")
        XCTAssertEqual(txt(eval("LEFT(\"hi\", 10)")), "hi", "n past end clamps")
        XCTAssertEqual(txt(eval("LEFT(\"hello\")")), "h", "default length 1")
        XCTAssertEqual(txt(eval("MID(\"hi\", 5, 2)")), "", "start past end → empty")
    }

    func test_roundUpDown() {
        XCTAssertEqual(num(eval("ROUNDUP(2.1, 0)")), 3)
        XCTAssertEqual(num(eval("ROUNDDOWN(2.9, 0)")), 2)
        if let v = num(eval("ROUNDUP(2.345, 2)")) { XCTAssertEqual(v, 2.35, accuracy: 1e-9) }
        if let v = num(eval("ROUNDDOWN(2.349, 2)")) { XCTAssertEqual(v, 2.34, accuracy: 1e-9) }
    }

    func test_ceilingFloor() {
        XCTAssertEqual(num(eval("CEILING(4.1)")), 5)
        XCTAssertEqual(num(eval("FLOOR(4.9)")), 4)
        XCTAssertEqual(num(eval("CEILING(12, 5)")), 15, "round up to a multiple of 5")
    }

    func test_iferror() {
        XCTAssertEqual(num(eval("IFERROR(1/0, 99)")), 99)
        XCTAssertEqual(num(eval("IFERROR(5, 99)")), 5)
    }
}
