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
}
