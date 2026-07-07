import XCTest
import ViewerCore
@testable import ViewerUI

/// TSK-1215 — the host-testable core of the CSV formula on-screen display: a cell
/// shows its formula's COMPUTED value when one was resolved, else its raw text.
/// The view wiring (gated map + threading) + on-screen behavior is VM/owner review.
final class CSVFormulaDisplayTests: XCTestCase {
    func test_formulaCellDisplay_computed_else_raw() {
        // Literal cell (no computed value) → raw text, unchanged.
        XCTAssertEqual(CSVTableView.formulaCellDisplay(raw: "literal", computed: nil), "literal")
        // Formula cell with a computed value → that value's display string.
        let n = FormulaValue.number(42)
        XCTAssertEqual(CSVTableView.formulaCellDisplay(raw: "=A1+1", computed: n), n.display)
        XCTAssertEqual(CSVTableView.formulaCellDisplay(raw: "=UPPER(\"hi\")", computed: .text("HI")), "HI")
    }

    /// B6 UAT slice (host half): a real grid end-to-end through the DEFAULT
    /// path — which, post-flip (2026-07-07), is the RUST formula engine. One
    /// scenario exercises recalc → in-grid computed display → ƒ marker →
    /// formula-box edit routing, the whole owner-designed surface.
    func test_endToEnd_formulaGrid_computesDisplaysAndRoutes() {
        XCTAssertTrue(RustFormulaGate.isEnabled(environment: [:]),
                      "the flip: formula ships ON by default")
        let model = EditableCSVModel(
            RustCSVAdapter.parse("a,b,sum\n1,2,=A1+B1\n3,4,=A2+B2\n"))
        let values = model.recalcAllFormulas(environment: [:])
        let s1 = values[CellReference(row: 0, column: 2)]
        let s2 = values[CellReference(row: 1, column: 2)]
        XCTAssertEqual(s1, .number(3), "=A1+B1 over 1,2")
        XCTAssertEqual(s2, .number(7), "=A2+B2 over 3,4")
        // The grid cell shows the COMPUTED value…
        XCTAssertEqual(CSVTableView.formulaCellDisplay(raw: "=A1+B1", computed: s1),
                       FormulaValue.number(3).display)
        // …carries the subtle ƒ marker…
        XCTAssertTrue(CSVTableView.showsComputedMarker(raw: "=A1+B1", hasComputed: true))
        // …and a double-click edits the RAW source in the formula box.
        XCTAssertEqual(CSVTableView.editRoute(raw: "=A1+B1", formulaDisplayOn: true),
                       .formulaBox)
    }

    /// TSK-1515: the subtle "ƒ" computed marker — only on formula-backed cells
    /// that actually resolved (a typed 42 and a broken formula are unmarked).
    func test_computedMarker_onlyOnResolvedFormulaCells() {
        XCTAssertTrue(CSVTableView.showsComputedMarker(raw: "=A1+1", hasComputed: true))
        XCTAssertFalse(CSVTableView.showsComputedMarker(raw: "42", hasComputed: false),
                       "a typed literal is unmarked")
        XCTAssertFalse(CSVTableView.showsComputedMarker(raw: "42", hasComputed: true),
                       "a non-formula cell can't be computed — never mark it")
        XCTAssertFalse(CSVTableView.showsComputedMarker(raw: "=BROKEN(", hasComputed: false),
                       "an unresolved formula shows raw source, unmarked")
    }
}
