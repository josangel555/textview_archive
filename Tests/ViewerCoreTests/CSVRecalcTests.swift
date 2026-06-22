import XCTest
@testable import ViewerCore

/// TSK-1213 slice 6d — EditableCSVModel batch recalc. The Rust recalc path and
/// the Swift per-cell path must agree cell-for-cell (A/B parity), including
/// formula cells that reference other formula cells (B1←A1, C1←B1, B2←B1, C2←C1).
final class CSVRecalcTests: XCTestCase {
    // A1=5, B1==A1+1=6, C1==B1*2=12 / A2=10, B2==A2*B1=60, C2==C1+A2=22
    private let csv = """
    a,b,c
    5,=A1+1,=B1*2
    10,=A2*B1,=C1+A2
    """

    func test_recalc_values() {
        let model = EditableCSVModel(parsing: csv)
        let out = model.recalcAllFormulas(environment: ["MDV_RUST_FORMULA": "1"])
        XCTAssertEqual(out[CellReference(a1: "B1")!], .number(6))
        XCTAssertEqual(out[CellReference(a1: "C1")!], .number(12))
        XCTAssertEqual(out[CellReference(a1: "B2")!], .number(60)) // refs formula B1
        XCTAssertEqual(out[CellReference(a1: "C2")!], .number(22)) // refs formula C1
        XCTAssertNil(out[CellReference(a1: "A1")!]) // data cell omitted
    }

    func test_AB_parity_rust_vs_swift() {
        let model = EditableCSVModel(parsing: csv)
        let rust = model.recalcAllFormulas(environment: ["MDV_RUST_FORMULA": "1"])
        let swift = model.recalcAllFormulas(environment: ["MDV_RUST_FORMULA": "0"])
        XCTAssertEqual(rust, swift, "Rust recalc must match Swift per-cell, incl. formula-cell refs")
        XCTAssertFalse(rust.isEmpty)
    }
}
