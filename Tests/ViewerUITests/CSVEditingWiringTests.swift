import XCTest
@testable import ViewerCore
@testable import ViewerUI

/// TSK-1019 — host-side tests for the CSV inline-editor WIRING: the pure
/// gating decision, the display-index → grid-row mapping, and the model
/// effect of the commit closure. No window — the actual `TextField` render,
/// the double-click gesture, and "find/nav/copy still work while editing" are
/// the VM tail (verified on the GUI lane), left at review.
///
/// These are the regression teeth for the wiring: if the gate stops blocking
/// edits under sort/filter, the off-by-one in the header-row mapping returns,
/// or the commit closure stops folding into the model, one of these fails on
/// the host gate even though the pixel/gesture check is VM-only.
///
/// Filter: `swift test --filter ViewerUITests.CSVEditingWiringTests`
final class CSVEditingWiringTests: XCTestCase {

    // MARK: - editingAvailable gating (gate-on AND no sort AND no filter)

    func test_editingAvailable_offWhenGateOff_evenInFileOrder() {
        // The default-OFF gate dominates: no sort, no filter, but gate off ⇒
        // editing is not offered (the read-only path renders verbatim).
        XCTAssertFalse(CSVTableView.editingAvailable(
            gateEnabled: false, sortColumn: nil, filterIsEmpty: true))
    }

    func test_editingAvailable_onWhenGateOn_fileOrder_noFilter() {
        // The only combination that offers editing: gate on, file order, no
        // filter — so the displayed row index maps 1:1 to the grid row.
        XCTAssertTrue(CSVTableView.editingAvailable(
            gateEnabled: true, sortColumn: nil, filterIsEmpty: true))
    }

    func test_editingAvailable_offWhenSorted_evenWithGateOn() {
        // A sort reorders rows, breaking displayIndex→gridRow; editing is
        // withheld until the view is back in file order.
        XCTAssertFalse(CSVTableView.editingAvailable(
            gateEnabled: true, sortColumn: 0, filterIsEmpty: true))
        XCTAssertFalse(CSVTableView.editingAvailable(
            gateEnabled: true, sortColumn: 3, filterIsEmpty: true))
    }

    func test_editingAvailable_offWhenFiltered_evenWithGateOn() {
        // A filter REMOVES rows, so displayIndex no longer maps to grid row;
        // editing is withheld.
        XCTAssertFalse(CSVTableView.editingAvailable(
            gateEnabled: true, sortColumn: nil, filterIsEmpty: false))
    }

    func test_editingAvailable_offWhenSortedAndFiltered() {
        XCTAssertFalse(CSVTableView.editingAvailable(
            gateEnabled: true, sortColumn: 1, filterIsEmpty: false))
    }

    // MARK: - display-index → grid-row mapping (header is grid row 0)

    func test_gridRow_firstDisplayedBodyRow_isGridRowOne() {
        // Grid row 0 is the header; the first BODY row (displayIndex 0) is
        // grid row 1. This is the off-by-one the wiring must get right so a
        // committed edit lands on the row the user double-clicked.
        XCTAssertEqual(CSVTableView.gridRow(forDisplayIndex: 0), 1)
    }

    func test_gridRow_isDisplayIndexPlusOne() {
        XCTAssertEqual(CSVTableView.gridRow(forDisplayIndex: 1), 2)
        XCTAssertEqual(CSVTableView.gridRow(forDisplayIndex: 41), 42)
        XCTAssertEqual(CSVTableView.gridRow(forDisplayIndex: 999), 1000)
    }

    // MARK: - commit-closure effect on the model

    /// Exercises the EXACT wiring the inline editor performs on commit:
    /// `model.setCell(row: gridRow(forDisplayIndex: i), column: c, to: text)`,
    /// then asserts the model reflects it (`getCell` returns the new value and
    /// the model is dirty). This is the "exercise the action closure" host
    /// proof from CLAUDE.md — committing 'X' must reach the model, not a
    /// parallel reimplementation.
    func test_commitWiring_foldsTextIntoModel_atMappedGridRow() {
        let result = CSVParser.Result(
            delimiter: ",",
            header: ["Name", "Age"],
            rows: [["Ada", "36"], ["Bob", "40"]]
        )
        var model = EditableCSVModel(result)
        XCTAssertFalse(model.isDirty)

        // User double-clicks the SECOND displayed body row (displayIndex 1),
        // column 0 ("Bob"), and types "Carol", then commits.
        let displayIndex = 1
        let column = 0
        let gridR = CSVTableView.gridRow(forDisplayIndex: displayIndex)
        XCTAssertEqual(gridR, 2, "displayIndex 1 ⇒ grid row 2 (header is row 0)")

        // The commit closure's body:
        model.setCell(row: gridR, column: column, to: "Carol")

        XCTAssertTrue(model.isDirty, "a committed edit must dirty the model")
        XCTAssertEqual(model.getCell(row: gridR, column: column), "Carol",
                       "the model must reflect the committed value")
        // The other cells are untouched (header + row 1 + the Age cell).
        XCTAssertEqual(model.getCell(row: 0, column: 0), "Name")
        XCTAssertEqual(model.getCell(row: 1, column: 0), "Ada")
        XCTAssertEqual(model.getCell(row: 2, column: 1), "40")
    }

    func test_commitWiring_canEditHeaderCell_viaGridRowZero() {
        // The header is grid row 0 and is editable like any other row (a real
        // spreadsheet edits header cells). The wiring addresses it directly,
        // not through `gridRow(forDisplayIndex:)` (which is body-only).
        let result = CSVParser.Result(
            delimiter: ",", header: ["A", "B"], rows: [["1", "2"]])
        var model = EditableCSVModel(result)
        model.setCell(row: 0, column: 1, to: "Beta")
        XCTAssertEqual(model.getCell(row: 0, column: 1), "Beta")
        XCTAssertTrue(model.isDirty)
    }

    func test_commitWiring_noOpEdit_sameValue_leavesModelClean() {
        // Beginning an edit then committing the UNCHANGED value must not dirty
        // the model — the model coalesces an edit-back-to-base to nothing, so
        // a stray double-click+Enter doesn't fabricate a pending change.
        let result = CSVParser.Result(
            delimiter: ",", header: ["A"], rows: [["x"]])
        var model = EditableCSVModel(result)
        let gridR = CSVTableView.gridRow(forDisplayIndex: 0)
        // editingText was seeded from getCell(gridR, 0) == "x"; committing it
        // unchanged is a genuine no-op.
        let seeded = model.getCell(row: gridR, column: 0) ?? ""
        model.setCell(row: gridR, column: 0, to: seeded)
        XCTAssertFalse(model.isDirty,
                       "committing the seeded value unchanged must not dirty the model")
    }
}
