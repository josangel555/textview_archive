import XCTest
import RustCore
@testable import ViewerCore

/// TSK-1213 slice 5 — cross-language A/B PARITY. The same formula, over the same
/// A1→raw cell snapshot, MUST produce the same FormulaValue from the Swift
/// FormulaEngine and the Rust port. This is the soak evidence that the Rust
/// evaluator matches the incumbent across the function library.
///
/// Cells hold LITERALS only (numbers/text) — a cell referencing another *formula*
/// cell needs recursive eval (the Swift `visiting` path), which the stateless Rust
/// snapshot does not yet do; that's the slice-6 recalc concern, validated
/// separately. Here we pin the formula-evaluation engine itself.
final class FormulaParityTests: XCTestCase {

    private func assertParity(_ formula: String, _ cells: [String: String]) throws {
        let resolver: CellResolver = { ref in cells[ref.a1] }
        let swiftResult = FormulaEngine.evaluate(raw: formula, resolve: resolver)
        let rustResult = try RustFormulaAdapter.rustEvaluate(formula, cells: cells)
        XCTAssertEqual(rustResult, swiftResult, "parity diverged for `\(formula)`")
    }

    func test_parity_across_function_library() throws {
        let cases: [(String, [String: String])] = [
            // arithmetic + precedence + unary + power right-assoc
            ("=A1+A2*2", ["A1": "5", "A2": "10"]),
            ("=(A1+A2)*2", ["A1": "5", "A2": "10"]),
            ("=A1-A2/A3", ["A1": "100", "A2": "20", "A3": "4"]),
            ("=2^3^2", [:]),
            ("=-A1", ["A1": "7"]),
            // comparisons
            ("=A1=A2", ["A1": "5", "A2": "5"]),
            ("=A1<>A2", ["A1": "5", "A2": "6"]),
            ("=A1>=A2", ["A1": "5", "A2": "5"]),
            ("=A1<A2", ["A1": "5", "A2": "6"]),
            // aggregates
            ("=SUM(A1:A3)", ["A1": "1", "A2": "2", "A3": "3"]),
            ("=AVERAGE(A1:A3)", ["A1": "2", "A2": "4", "A3": "6"]),
            ("=MIN(A1:A3)", ["A1": "5", "A2": "2", "A3": "9"]),
            ("=MAX(A1:A3)", ["A1": "5", "A2": "2", "A3": "9"]),
            ("=COUNT(A1:A3)", ["A1": "5", "A2": "x", "A3": "9"]),
            ("=PRODUCT(A1:A2)", ["A1": "4", "A2": "5"]),
            // logical
            ("=IF(A1>3, \"big\", \"small\")", ["A1": "5"]),
            ("=AND(A1>0, A2>0)", ["A1": "1", "A2": "2"]),
            ("=OR(A1>5, A2>5)", ["A1": "1", "A2": "7"]),
            ("=NOT(A1>0)", ["A1": "1"]),
            // text
            ("=UPPER(A1)", ["A1": "hi"]),
            ("=LOWER(A1)", ["A1": "HI"]),
            ("=TRIM(A1)", ["A1": "  x  "]),
            ("=LEN(A1)", ["A1": "hello"]),
            ("=LEFT(A1, 2)", ["A1": "hello"]),
            ("=RIGHT(A1, 2)", ["A1": "hello"]),
            ("=MID(A1, 2, 3)", ["A1": "hello"]),
            ("=CONCAT(A1, A2)", ["A1": "foo", "A2": "bar"]),
            // math
            ("=ABS(A1)", ["A1": "-5"]),
            ("=INT(A1)", ["A1": "3.7"]),
            ("=SQRT(A1)", ["A1": "16"]),
            ("=ROUND(A1, 1)", ["A1": "3.14159"]),
            ("=MOD(A1, A2)", ["A1": "10", "A2": "3"]),
            ("=POWER(A1, A2)", ["A1": "2", "A2": "10"]),
            // conditional aggregates
            ("=COUNTIF(A1:A3, \">2\")", ["A1": "1", "A2": "3", "A3": "5"]),
            ("=SUMIF(A1:A3, \">2\")", ["A1": "1", "A2": "3", "A3": "5"]),
            // IS* predicates
            ("=ISBLANK(Z9)", [:]),
            ("=ISNUMBER(A1)", ["A1": "5"]),
            ("=ISTEXT(A1)", ["A1": "hi"]),
            // lookup
            ("=MATCH(3, A1:A3, 0)", ["A1": "1", "A2": "3", "A3": "5"]),
            ("=INDEX(A1:A3, 2)", ["A1": "x", "A2": "y", "A3": "z"]),
            ("=VLOOKUP(2, A1:B3, 2, 0)",
             ["A1": "1", "B1": "a", "A2": "2", "B2": "b", "A3": "3", "B3": "c"]),
            // errors
            ("=1/0", [:]),
            ("=SQRT(-1)", [:]),
            ("=NOTAFUNC(1)", [:]),
        ]
        for (formula, cells) in cases {
            try assertParity(formula, cells)
        }
    }

    /// Extended math batch (TSK-1213 parity round 2): CEILING/FLOOR/ROUNDUP/
    /// ROUNDDOWN/TRUNC/SIGN/EXP/LN/LOG10 — Swift had these, the Rust port gained
    /// them to close the parity gap. Inputs chosen for exact/representable results.
    func test_parity_extended_math() throws {
        let cases: [(String, [String: String])] = [
            ("=ROUNDUP(A1, 2)", ["A1": "3.14159"]),
            ("=ROUNDUP(A1, 2)", ["A1": "-3.14159"]),
            ("=ROUNDDOWN(A1, 1)", ["A1": "3.789"]),
            ("=TRUNC(A1)", ["A1": "3.789"]),
            ("=TRUNC(A1)", ["A1": "-3.789"]),
            ("=TRUNC(A1, 2)", ["A1": "3.14159"]),
            ("=CEILING(A1)", ["A1": "4.2"]),
            ("=CEILING(A1, 0.5)", ["A1": "4.2"]),
            ("=FLOOR(A1)", ["A1": "4.8"]),
            ("=FLOOR(A1, 0.5)", ["A1": "4.8"]),
            ("=SIGN(A1)", ["A1": "-3"]),
            ("=SIGN(A1)", ["A1": "0"]),
            ("=SIGN(A1)", ["A1": "7"]),
            ("=EXP(A1)", ["A1": "0"]),
            ("=EXP(A1)", ["A1": "1"]),
            ("=LN(A1)", ["A1": "1"]),
            ("=LN(A1)", ["A1": "-1"]), // #NUM
            ("=LOG10(A1)", ["A1": "1000"]),
        ]
        for (formula, cells) in cases {
            try assertParity(formula, cells)
        }
    }
}
