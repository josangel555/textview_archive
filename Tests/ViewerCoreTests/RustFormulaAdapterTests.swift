import XCTest
import RustCore
@testable import ViewerCore

/// TSK-1213 slice 4d — the ViewerCore RustFormulaAdapter: CoreFormulaValue →
/// FormulaValue mapping (pure), the real-FFI rustEvaluate, and the gated
/// evaluate (Rust when on + succeeds; Swift fallback otherwise).
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

    func test_evaluate_gate_off_uses_swift_fallback() {
        var swiftCalled = false
        let r = RustFormulaAdapter.evaluate("A1", cells: [:], environment: ["MDV_RUST_FORMULA": "0"]) {
            swiftCalled = true
            return .number(99)
        }
        XCTAssertTrue(swiftCalled, "gate off must use the Swift fallback")
        XCTAssertEqual(r, .number(99))
    }

    func test_evaluate_gate_on_uses_rust() {
        let r = RustFormulaAdapter.evaluate(
            "A1+A2", cells: ["A1": "5", "A2": "10"], environment: ["MDV_RUST_FORMULA": "1"]
        ) {
            .error(.parse) // the Swift fallback must NOT run when Rust succeeds
        }
        XCTAssertEqual(r, .number(15))
    }
}
