import XCTest
import ViewerCore
@testable import ViewerUI

/// TSK-1215 — the formula edit box (owner design 2026-07-04: the grid ALWAYS
/// shows the computed value; a formula's raw "=" source is edited in the
/// dedicated box, never in-cell). Host-testable halves: the edit-routing
/// decision, the A1 box label, and the commit→recalc model round-trip. The
/// on-screen box is the agent-driven VM slice per
/// docs/STAGE_B_DELETION_UAT_2026-07-04.md.
final class CSVFormulaEditBoxTests: XCTestCase {

    // MARK: Routing — formula cells go to the box ONLY when formula display is on

    func test_editRoute_formulaCell_boxWhenDisplayOn_inlineWhenOff() {
        XCTAssertEqual(CSVTableView.editRoute(raw: "=A1+B1", formulaDisplayOn: true), .formulaBox)
        // Gate off → the legacy raw in-cell edit stands (byte-identical path).
        XCTAssertEqual(CSVTableView.editRoute(raw: "=A1+B1", formulaDisplayOn: false), .inline)
    }

    func test_editRoute_nonFormulaCells_stayInline() {
        XCTAssertEqual(CSVTableView.editRoute(raw: "literal", formulaDisplayOn: true), .inline)
        XCTAssertEqual(CSVTableView.editRoute(raw: "", formulaDisplayOn: true), .inline)
        // Excel semantics: a leading space makes it literal text, not a formula.
        XCTAssertEqual(CSVTableView.editRoute(raw: " =A1", formulaDisplayOn: true), .inline)
    }

    // MARK: A1 label — grid coords (header = row 0) → A1 (first data row = 1)

    func test_formulaBoxLabel_mapsGridCoordsToA1() {
        XCTAssertEqual(CSVTableView.formulaBoxLabel(
            gridCell: .init(row: 1, column: 0)), "A1")
        XCTAssertEqual(CSVTableView.formulaBoxLabel(
            gridCell: .init(row: 3, column: 1)), "B3")
        XCTAssertEqual(CSVTableView.formulaBoxLabel(
            gridCell: .init(row: 1, column: 26)), "AA1")
    }

    // MARK: Commit → recalc — the model write recomputes the cell AND dependents

    func test_formulaCommit_recalculatesCellAndDependents() {
        var model = EditableCSVModel(parsing: "h1,h2,h3\n1,2,=A1+B1\n")

        let before = model.recalcAllFormulas()
        XCTAssertEqual(before[CellReference(a1: "C1")!]?.display, "3",
                       "=A1+B1 over 1,2 must compute 3")

        // The formula-box commit path: setCell with the new raw source
        // (grid row 1 = data row A1-row 1).
        XCTAssertTrue(model.setCell(row: 1, column: 0, to: "5"))
        let after = model.recalcAllFormulas()
        XCTAssertEqual(after[CellReference(a1: "C1")!]?.display, "7",
                       "editing a dependency must recompute the formula cell")

        // Rewriting the formula itself through the same path also recomputes.
        XCTAssertTrue(model.setCell(row: 1, column: 2, to: "=A1*B1"))
        let rewritten = model.recalcAllFormulas()
        XCTAssertEqual(rewritten[CellReference(a1: "C1")!]?.display, "10")
    }
}
