import XCTest
@testable import ViewerCore

/// TSK-627 — pure-logic coverage for `LSPTextEditApplier` (the
/// formatting half that has no server in the loop) plus the
/// `decodeTextEdits` response decode. Both run in every host gate.
final class LSPTextEditApplierTests: XCTestCase {

    private func edit(_ sl: Int, _ sc: Int, _ el: Int, _ ec: Int, _ text: String) -> LSPTextEdit {
        LSPTextEdit(
            range: LSPRange(
                start: LSPPosition(line: sl, character: sc),
                end: LSPPosition(line: el, character: ec)),
            newText: text)
    }

    // MARK: - apply

    func test_emptyEdits_returnsTextUnchanged() {
        XCTAssertEqual(LSPTextEditApplier.apply([], to: "abc", encoding: .utf16), "abc")
    }

    func test_singleReplacement() {
        // "let  x=1" → fix the double space.
        let out = LSPTextEditApplier.apply(
            [edit(0, 3, 0, 5, " ")], to: "let  x=1", encoding: .utf16)
        XCTAssertEqual(out, "let x=1")
    }

    func test_insertion_zeroLengthRange() {
        let out = LSPTextEditApplier.apply(
            [edit(0, 5, 0, 5, " ")], to: "let x=1", encoding: .utf16)
        XCTAssertEqual(out, "let x =1")
    }

    func test_multipleEdits_applyAgainstOriginalOffsets() {
        // Two edits on one line: both ranges are ORIGINAL-document
        // coordinates. Applying naively front-to-back would shift the
        // second range; reverse-order application must not.
        // "a=1;b=2" → "a = 1;b = 2"
        let out = LSPTextEditApplier.apply(
            [edit(0, 1, 0, 2, " = "), edit(0, 5, 0, 6, " = ")],
            to: "a=1;b=2", encoding: .utf16)
        XCTAssertEqual(out, "a = 1;b = 2")
    }

    func test_multilineEdit_collapsesLines() {
        let out = LSPTextEditApplier.apply(
            [edit(0, 3, 1, 0, " ")], to: "let\nx = 1\n", encoding: .utf16)
        XCTAssertEqual(out, "let x = 1\n")
    }

    func test_wholeDocumentReplace() {
        // The common server shape: ONE edit spanning the whole document.
        let original = "func f( ){\nreturn 1}\n"
        let formatted = "func f() {\n    return 1\n}\n"
        let out = LSPTextEditApplier.apply(
            [edit(0, 0, 2, 0, formatted)], to: original, encoding: .utf16)
        XCTAssertEqual(out, formatted)
    }

    func test_nonASCII_utf16Offsets() {
        // "🙂" is 2 UTF-16 units; an edit after it must land correctly.
        // Replace "=1" (chars 3..5 in UTF-16: 🙂=2 + 'x'=1) with " = 2".
        let out = LSPTextEditApplier.apply(
            [edit(0, 3, 0, 5, " = 2")], to: "🙂x=1", encoding: .utf16)
        XCTAssertEqual(out, "🙂x = 2")
    }

    func test_outOfRangePositions_clampToDocument() {
        // Line 99 doesn't exist → clamps to end; end<start → empty range.
        let out = LSPTextEditApplier.apply(
            [edit(99, 0, 99, 10, "!")], to: "abc", encoding: .utf16)
        XCTAssertEqual(out, "abc!")
    }

    func test_overlappingEdits_offenderDroppedNotCorrupting() {
        // Spec forbids overlap; a buggy server sending one must not
        // corrupt the document. The second (earlier-start, overlapping)
        // edit is dropped.
        let out = LSPTextEditApplier.apply(
            [edit(0, 2, 0, 6, "XYZ"), edit(0, 4, 0, 8, "!!")],
            to: "0123456789", encoding: .utf16)
        // Reverse order: (4..8 → "!!") applies first → "0123!!89";
        // then (2..6) overlaps the already-applied span → dropped.
        XCTAssertEqual(out, "0123!!89")
    }

    // MARK: - decodeTextEdits

    private func decode(_ json: String) -> [LSPTextEdit] {
        LSPClient.decodeTextEdits(Data(json.utf8))
    }

    func test_decode_nullAndEmpty() {
        XCTAssertEqual(decode("null"), [])
        XCTAssertEqual(decode("[]"), [])
        XCTAssertEqual(decode("not json at all"), [])
    }

    func test_decode_wellFormedEdits() {
        let json = #"""
        [{"range":{"start":{"line":0,"character":3},"end":{"line":0,"character":5}},
          "newText":" "}]
        """#
        let edits = decode(json)
        XCTAssertEqual(edits, [edit(0, 3, 0, 5, " ")])
    }

    func test_decode_malformedEntryDropped_goodOnesKept() {
        let json = #"""
        [{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}},
          "newText":"A"},
         {"newText":"missing range"},
         {"range":{"start":{"line":1,"character":0},"end":{"line":1,"character":2}}}]
        """#
        XCTAssertEqual(decode(json), [edit(0, 0, 0, 1, "A")],
            "malformed entries must be dropped, not trapped (TSK-627)")
    }
}
