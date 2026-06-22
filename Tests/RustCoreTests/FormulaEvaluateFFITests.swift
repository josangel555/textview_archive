import XCTest
@testable import RustCore

/// TSK-1213 slice 4c — the Rust formula evaluator over the real FFI envelope
/// (mdvcore_call → dispatch::FormulaEvaluate → formula::evaluate_wire → frame).
/// Exercises the linked libmdvcore_ffi.a, the MessagePack wire round-trip
/// (incl. float values via slice 4b), and the CoreFormulaValue mapping.
final class FormulaEvaluateFFITests: XCTestCase {

    func test_evaluate_formulas_over_ffi() throws {
        let cells = ["A1": "5", "A2": "10", "B1": "abc"]
        let out = try mdvCoreEvaluateFormulas(
            ["A1+A2", "SUM(A1:A2)", "UPPER(\"hi\")", "1/0", "IF(A1>3, 1, 2)", "Z9"],
            cells: cells
        )
        XCTAssertEqual(out, [
            .number(15.0),
            .number(15.0),
            .text("HI"),
            .error("dividebyzero"),
            .number(1.0),
            .blank, // a missing cell resolves to blank
        ])
    }

    func test_empty_formula_list() throws {
        XCTAssertEqual(try mdvCoreEvaluateFormulas([], cells: [:]), [])
    }

    func test_recalc_over_ffi() throws {
        // The recalc path resolves formula-cell references to computed values
        // (the recursion the per-formula path can't do) and flags cycles.
        let cells = ["A1": "5", "A2": "=A1+1", "A3": "=A2*2", "B1": "=B2", "B2": "=B1"]
        let out = try mdvCoreRecalc(cells: cells)
        XCTAssertEqual(out["A2"], .number(6))
        XCTAssertEqual(out["A3"], .number(12)) // A3 sees A2's computed 6, not its raw text
        XCTAssertEqual(out["B1"], .error("cycle"))
        XCTAssertNil(out["A1"]) // data cell omitted from the result
    }
}
