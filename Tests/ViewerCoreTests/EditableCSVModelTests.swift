import XCTest
@testable import ViewerCore

/// TSK-711 — editable-cell CSV model: overlay edits, dirty flag, undo/redo, and
/// RFC-4180 write-back serialization. Pure + host-safe (no window).
final class EditableCSVModelTests: XCTestCase {

    // MARK: helpers

    /// Parse via the Swift parser directly (gate-independent) and wrap.
    private func model(_ csv: String) -> EditableCSVModel {
        EditableCSVModel(RustCSVAdapter.parse(csv))
    }

    // MARK: geometry

    func test_geometry_headerIsRowZero_bodyFollows() {
        let m = model("a,b,c\n1,2,3\n4,5,6")
        XCTAssertEqual(m.rowCount, 3, "header + 2 body rows")
        XCTAssertEqual(m.bodyRowCount, 2)
        XCTAssertEqual(m.columnCount, 3)
        XCTAssertFalse(m.isEmpty)
        XCTAssertEqual(m.getCell(row: 0, column: 0), "a", "row 0 is the header")
        XCTAssertEqual(m.getCell(row: 1, column: 0), "1")
        XCTAssertEqual(m.getCell(row: 2, column: 2), "6")
    }

    func test_getCell_outOfRange_isNil() {
        let m = model("a,b\n1,2")
        XCTAssertNil(m.getCell(row: -1, column: 0))
        XCTAssertNil(m.getCell(row: 5, column: 0))
        XCTAssertNil(m.getCell(row: 0, column: 9))
        XCTAssertNil(m.getCell(row: 0, column: -1))
    }

    // MARK: setCell + dirty

    func test_setCell_marksDirty_andIsObservableViaGetCell() {
        var m = model("a,b\n1,2")
        XCTAssertFalse(m.isDirty)

        XCTAssertTrue(m.setCell(row: 1, column: 0, to: "X"))
        XCTAssertTrue(m.isDirty)
        XCTAssertTrue(m.isEdited(row: 1, column: 0))
        XCTAssertEqual(m.getCell(row: 1, column: 0), "X", "edit observable through getCell")
        XCTAssertEqual(m.getCell(row: 1, column: 1), "2", "untouched cell unchanged")
        XCTAssertEqual(m.editedCells.count, 1)
    }

    func test_setCell_backToBaseValue_clearsDirty_coalesces() {
        var m = model("a,b\n1,2")
        m.setCell(row: 1, column: 0, to: "X")
        XCTAssertTrue(m.isDirty)
        // Setting it back to the original base value drops the overlay entry.
        XCTAssertTrue(m.setCell(row: 1, column: 0, to: "1"))
        XCTAssertFalse(m.isDirty, "restoring base value coalesces to clean")
        XCTAssertFalse(m.isEdited(row: 1, column: 0))
        XCTAssertEqual(m.getCell(row: 1, column: 0), "1")
    }

    func test_setCell_noOp_whenValueUnchanged_returnsFalse() {
        var m = model("a,b\n1,2")
        XCTAssertFalse(m.setCell(row: 1, column: 0, to: "1"), "same value = no-op")
        XCTAssertFalse(m.isDirty)
        XCTAssertFalse(m.canUndo, "a no-op records no undo step")
    }

    func test_setCell_outOfRange_isIgnored() {
        var m = model("a,b\n1,2")
        XCTAssertFalse(m.setCell(row: 9, column: 0, to: "Z"))
        XCTAssertFalse(m.setCell(row: 1, column: 9, to: "Z"), "column beyond header width rejected")
        XCTAssertFalse(m.isDirty)
    }

    func test_canEditHeaderRow() {
        var m = model("a,b\n1,2")
        XCTAssertTrue(m.setCell(row: 0, column: 1, to: "renamed"))
        XCTAssertEqual(m.getCell(row: 0, column: 1), "renamed")
        XCTAssertTrue(m.serialize().hasPrefix("a,renamed\r\n"))
    }

    func test_discardEdits_returnsToPristine() {
        var m = model("a,b\n1,2")
        m.setCell(row: 1, column: 0, to: "X")
        m.setCell(row: 1, column: 1, to: "Y")
        XCTAssertTrue(m.isDirty)
        m.discardEdits()
        XCTAssertFalse(m.isDirty)
        XCTAssertFalse(m.canUndo)
        XCTAssertFalse(m.canRedo)
        XCTAssertEqual(m.getCell(row: 1, column: 0), "1")
        XCTAssertEqual(m.getCell(row: 1, column: 1), "2")
    }

    // MARK: undo / redo

    func test_undoRedo_restoresExactPriorGrid() {
        var m = model("a,b,c\n1,2,3\n4,5,6")
        let pristine = m

        m.setCell(row: 1, column: 0, to: "X")
        m.setCell(row: 2, column: 2, to: "Z")
        XCTAssertEqual(m.editedCells.count, 2)

        // Undo Z, then X — each restores the prior overlay state exactly.
        XCTAssertEqual(m.undo(), EditableCSVModel.Cell(row: 2, column: 2))
        XCTAssertEqual(m.getCell(row: 2, column: 2), "6")
        XCTAssertTrue(m.isDirty, "the X edit still stands")

        XCTAssertEqual(m.undo(), EditableCSVModel.Cell(row: 1, column: 0))
        XCTAssertFalse(m.isDirty)
        XCTAssertEqual(m, pristine, "fully undone == pristine grid")
        XCTAssertNil(m.undo(), "nothing left to undo")

        // Redo both.
        XCTAssertEqual(m.redo(), EditableCSVModel.Cell(row: 1, column: 0))
        XCTAssertEqual(m.getCell(row: 1, column: 0), "X")
        XCTAssertEqual(m.redo(), EditableCSVModel.Cell(row: 2, column: 2))
        XCTAssertEqual(m.getCell(row: 2, column: 2), "Z")
        XCTAssertNil(m.redo())
    }

    func test_undoOfCoalescedEdit_restoresOverlayState() {
        // Edit a cell twice (X then Y); each is its own undo step.
        var m = model("a\n1")
        m.setCell(row: 1, column: 0, to: "X")
        m.setCell(row: 1, column: 0, to: "Y")
        XCTAssertEqual(m.getCell(row: 1, column: 0), "Y")

        m.undo()
        XCTAssertEqual(m.getCell(row: 1, column: 0), "X", "undo Y → back to X (not base)")
        m.undo()
        XCTAssertEqual(m.getCell(row: 1, column: 0), "1", "undo X → back to base")
        XCTAssertFalse(m.isDirty)
    }

    func test_newEdit_clearsRedoStack() {
        var m = model("a\n1")
        m.setCell(row: 1, column: 0, to: "X")
        m.undo()
        XCTAssertTrue(m.canRedo)
        m.setCell(row: 1, column: 0, to: "Y")   // forks the redo future
        XCTAssertFalse(m.canRedo, "a fresh edit drops the redo stack")
        XCTAssertEqual(m.getCell(row: 1, column: 0), "Y")
    }

    // MARK: serialization — quoting / escaping

    func test_serialize_quotesOnlyWhatNeedsIt() {
        // delimiter is ','; quote a cell only if it has comma / quote / CR / LF.
        let m = model("a,b,c\nplain,has space,x")
        // Edit cells to introduce specials, then check exact quoting.
        var e = m
        e.setCell(row: 1, column: 0, to: "embed,comma")
        e.setCell(row: 1, column: 1, to: "say \"hi\"")
        e.setCell(row: 1, column: 2, to: "line1\nline2")
        let out = e.serialize()
        XCTAssertEqual(out,
            "a,b,c\r\n\"embed,comma\",\"say \"\"hi\"\"\",\"line1\nline2\"")
    }

    func test_needsQuoting_predicate() {
        XCTAssertFalse(EditableCSVModel.needsQuoting("plain", delimiter: ","))
        XCTAssertFalse(EditableCSVModel.needsQuoting("has space", delimiter: ","))
        XCTAssertTrue(EditableCSVModel.needsQuoting("a,b", delimiter: ","))
        XCTAssertTrue(EditableCSVModel.needsQuoting("a\"b", delimiter: ","))
        XCTAssertTrue(EditableCSVModel.needsQuoting("a\nb", delimiter: ","))
        XCTAssertTrue(EditableCSVModel.needsQuoting("a\rb", delimiter: ","))
        // Delimiter-specific: a comma is fine in a TSV.
        XCTAssertFalse(EditableCSVModel.needsQuoting("a,b", delimiter: "\t"))
        XCTAssertTrue(EditableCSVModel.needsQuoting("a\tb", delimiter: "\t"))
    }

    func test_serialize_preservesDetectedDelimiter_tsvAndSemicolon() {
        let tsv = model("a\tb\n1\t2")
        XCTAssertEqual(tsv.delimiter, "\t")
        XCTAssertEqual(tsv.serialize(), "a\tb\r\n1\t2")

        let semi = model("a;b\n1;2")
        XCTAssertEqual(semi.delimiter, ";")
        XCTAssertEqual(semi.serialize(), "a;b\r\n1;2")
    }

    // MARK: serialization — round-trip a tricky corpus

    func test_serialize_roundTrips_corpusWithSpecialsAndUnicode() {
        // A grid carrying embedded commas, quotes, newlines, and unicode. We
        // build it via edits over a same-shape skeleton so the values are
        // exactly what we assert round-trip.
        var m = model("name,note,emoji\nx,y,z\np,q,r")
        m.setCell(row: 1, column: 0, to: "O'Brien, Jr.")
        m.setCell(row: 1, column: 1, to: "she said \"go\"")
        m.setCell(row: 1, column: 2, to: "🌍\n日本語")
        m.setCell(row: 2, column: 0, to: "café")
        m.setCell(row: 2, column: 1, to: "a\tb")          // tab is literal under ',' delim
        m.setCell(row: 2, column: 2, to: "trailing,")

        let serialized = m.serialize()
        let reparsed = EditableCSVModel(RustCSVAdapter.parse(serialized))

        // Every current cell survives the parse → serialize → parse cycle.
        for r in 0..<m.rowCount {
            for c in 0..<m.columnCount {
                XCTAssertEqual(reparsed.getCell(row: r, column: c),
                               m.getCell(row: r, column: c),
                               "cell (\(r),\(c)) must round-trip")
            }
        }
        // And the re-serialized form is byte-stable (idempotent).
        XCTAssertEqual(reparsed.serialize(), serialized, "serialize is idempotent")
    }

    func test_serialize_emptyCellsAndEmptyGrid() {
        let m = model("a,b,c\n,,\n1,,3")
        XCTAssertEqual(m.serialize(), "a,b,c\r\n,,\r\n1,,3")

        var empty = EditableCSVModel(RustCSVAdapter.parse(""))
        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(empty.serialize(), "")
        XCTAssertFalse(empty.setCell(row: 0, column: 0, to: "x"), "no cells to edit")
    }

    // MARK: serialization — untouched rows preserved byte-for-byte

    func test_editingOneCell_leavesEveryOtherRowByteIdentical() {
        // Build an N-row grid. Editing one cell must perturb ONLY that cell's
        // row in the serialized output — every other row is byte-for-byte the
        // same as the unedited serialization (the slice's core invariant).
        let n = 200
        var lines = ["c0,c1,c2,c3"]
        for i in 0..<n {
            lines.append("r\(i)a,r\(i)b,r\(i)c,r\(i)d")
        }
        let csv = lines.joined(separator: "\n")
        let pristine = model(csv)
        let baselineRows = pristine.serialize().components(separatedBy: "\r\n")

        var edited = pristine
        let editedRowIndex = 137                     // grid row (body row 136)
        XCTAssertTrue(edited.setCell(row: editedRowIndex, column: 2, to: "CHANGED"))
        let editedRows = edited.serialize().components(separatedBy: "\r\n")

        XCTAssertEqual(editedRows.count, baselineRows.count)
        for i in baselineRows.indices {
            if i == editedRowIndex {
                XCTAssertNotEqual(editedRows[i], baselineRows[i], "edited row must differ")
                XCTAssertEqual(editedRows[i], "r136a,r136b,CHANGED,r136d")
            } else {
                XCTAssertEqual(editedRows[i], baselineRows[i],
                               "row \(i) untouched ⇒ byte-identical serialization")
            }
        }
    }

    func test_wasTruncated_surfacedFromParse() {
        // Force a tiny cap so the parse truncates, and confirm the flag rides
        // through to the model (the save path gates on it). Stage-B: the cap
        // rides the forced-delimiter wire (per-row cells cap).
        let result = RustCSVAdapter.parseWith(
            "a,b,c\n1,2,3\n4,5,6", delimiter: ",", maxCellsPerRow: 2)
        XCTAssertTrue(result.truncated)
        let m = EditableCSVModel(result)
        XCTAssertTrue(m.wasTruncated)
    }
}
