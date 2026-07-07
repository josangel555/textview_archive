import XCTest
import RustCore
@testable import ViewerCore

/// TSK-1213 — the ViewerCore RustFormulaAdapter: CoreFormulaValue →
/// FormulaValue mapping (pure) and the real-FFI evaluate/recalc paths.
/// STAGE-B (2026-07-07): the gated Swift-fallback wrapper died with the
/// Swift evaluator twin — rust is the only engine (PROPER, its last
/// Swift-only function, was ported in the same change).
final class RustFormulaAdapterTests: XCTestCase {

    func test_mapValue_all_cases() {
        XCTAssertEqual(RustFormulaAdapter.mapValue(.number(5)), .number(5))
        XCTAssertEqual(RustFormulaAdapter.mapValue(.text("x")), .text("x"))
        XCTAssertEqual(RustFormulaAdapter.mapValue(.boolean(true)), .boolean(true))
        XCTAssertEqual(RustFormulaAdapter.mapValue(.blank), .blank)
        XCTAssertEqual(RustFormulaAdapter.mapValue(.error("dividebyzero")), .error(.divideByZero))
        XCTAssertEqual(RustFormulaAdapter.mapValue(.error("na")), .error(.na))
        XCTAssertEqual(RustFormulaAdapter.mapValue(.error("parse")), .error(.parse))
        XCTAssertEqual(RustFormulaAdapter.mapValue(.error("bogus")), .error(.value)) // unknown → #VALUE
    }

    func test_rustEvaluate_endToEnd() throws {
        XCTAssertEqual(try RustFormulaAdapter.rustEvaluate("A1+A2", cells: ["A1": "5", "A2": "10"]), .number(15))
        XCTAssertEqual(try RustFormulaAdapter.rustEvaluate("UPPER(\"hi\")", cells: [:]), .text("HI"))
        XCTAssertEqual(try RustFormulaAdapter.rustEvaluate("1/0", cells: [:]), .error(.divideByZero))
    }

    func test_proper_isRustSide_now() throws {
        // Stage-B: PROPER was the last Swift-only function (the old adapter
        // fell back to Foundation .capitalized for it). It is now ported —
        // same semantics — and the fallback is gone with the twin.
        XCTAssertEqual(try RustFormulaAdapter.rustEvaluate("PROPER(\"hello world\")", cells: [:]),
                       .text("Hello World"))
    }

    func test_genuine_name_error_surfaces() throws {
        // An unknown function is #NAME! — nothing to fall back to, by design.
        XCTAssertEqual(try RustFormulaAdapter.rustEvaluate("NOPENOTAFUNC(1)", cells: [:]),
                       .error(.name))
    }

    func test_recalc_maps_to_cellreference_and_formulavalue() throws {
        let out = try RustFormulaAdapter.recalc(cells: ["A1": "5", "A2": "=A1+1", "A3": "=A2*2"])
        XCTAssertEqual(out[CellReference(a1: "A2")!], .number(6))
        XCTAssertEqual(out[CellReference(a1: "A3")!], .number(12)) // recursion resolved
        XCTAssertNil(out[CellReference(a1: "A1")!]) // data cell omitted
    }
}
