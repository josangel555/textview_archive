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
}
