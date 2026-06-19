import XCTest
@testable import ViewerCore

/// Correctness pins for the editor line power-ops (TSK-675): `duplicateLines`
/// and `moveLines`. These are the host-testable FOUNDATION slice — the
/// keybinding wiring into the CM6 / Source editor is the render tail. Every
/// case asserts BOTH the rewritten text AND the re-select line range the editor
/// uses afterwards, plus the trailing-newline / last-line edge cases that trip
/// naive line splitters.
final class TextToolsLineOpsTests: XCTestCase {

    // MARK: editorLines (lossless split helper)

    func testEditorLines_distinguishesTrailingNewline() {
        let noTrail = TextTools.editorLines("a\nb\nc")
        XCTAssertEqual(noTrail.lines, ["a", "b", "c"])
        XCTAssertFalse(noTrail.hasTrailingNewline)

        let withTrail = TextTools.editorLines("a\nb\nc\n")
        XCTAssertEqual(withTrail.lines, ["a", "b", "c"])
        XCTAssertTrue(withTrail.hasTrailingNewline)
    }

    func testEditorLines_emptyDocIsSingleEmptyLine() {
        let r = TextTools.editorLines("")
        XCTAssertEqual(r.lines, [""])
        XCTAssertFalse(r.hasTrailingNewline)
    }

    func testEditorLines_blankLinesSurvive_andCRLFCounted() {
        // A blank middle line is preserved; \r\n is one separator.
        let r = TextTools.editorLines("a\r\n\r\nb")
        XCTAssertEqual(r.lines, ["a", "", "b"])
        XCTAssertFalse(r.hasTrailingNewline)
    }

    func testEditorLines_singleTrailingNewlineIsOneLine() {
        // "x\n" is ONE line that happens to be terminated, not two lines.
        let r = TextTools.editorLines("x\n")
        XCTAssertEqual(r.lines, ["x"])
        XCTAssertTrue(r.hasTrailingNewline)
    }

    // MARK: duplicateLines

    func testDuplicate_singleLine_insertsCopyBelow_selectsCopy() {
        let r = TextTools.duplicateLines("alpha\nbeta\ngamma", lineRange: 1...1)
        XCTAssertEqual(r.text, "alpha\nbeta\nbeta\ngamma")
        // Selection moves onto the freshly-inserted copy.
        XCTAssertEqual(r.lineRange, 2...2)
    }

    func testDuplicate_multiLineBlock_insertsExactCopyBelow_selectsCopy() {
        let r = TextTools.duplicateLines("one\ntwo\nthree\nfour", lineRange: 1...2)
        XCTAssertEqual(r.text, "one\ntwo\nthree\ntwo\nthree\nfour")
        XCTAssertEqual(r.lineRange, 3...4)
    }

    func testDuplicate_firstLine() {
        let r = TextTools.duplicateLines("a\nb\nc", lineRange: 0...0)
        XCTAssertEqual(r.text, "a\na\nb\nc")
        XCTAssertEqual(r.lineRange, 1...1)
    }

    func testDuplicate_preservesTrailingNewline() {
        let r = TextTools.duplicateLines("a\nb\n", lineRange: 0...0)
        XCTAssertEqual(r.text, "a\na\nb\n")
        XCTAssertEqual(r.lineRange, 1...1)
    }

    /// Last line WITHOUT a trailing newline: the original gains a `\n`
    /// terminator from the join, the copy stays unterminated. Never `bb`.
    func testDuplicate_lastLineNoTrailingNewline() {
        let r = TextTools.duplicateLines("a\nb", lineRange: 1...1)
        XCTAssertEqual(r.text, "a\nb\nb")
        XCTAssertEqual(r.lineRange, 2...2)
        XCTAssertFalse(r.text.hasSuffix("\n"), "must not invent a trailing newline")
    }

    /// An empty document is ONE empty line; duplicating it yields a blank second
    /// line (`"\n"`) with the copy selected — exactly what VS Code / Sublime do
    /// on an empty buffer. (Not a no-op: there IS a line to duplicate.)
    func testDuplicate_emptyDocDuplicatesTheBlankLine() {
        let r = TextTools.duplicateLines("", lineRange: 0...0)
        XCTAssertEqual(r.text, "\n")
        XCTAssertEqual(r.lineRange, 1...1)
    }

    func testDuplicate_outOfRangeIsClamped() {
        // upperBound past the end clamps to the last line.
        let r = TextTools.duplicateLines("a\nb", lineRange: 1...99)
        XCTAssertEqual(r.text, "a\nb\nb")
        XCTAssertEqual(r.lineRange, 2...2)
    }

    func testDuplicate_twoLineLeadingBlock() {
        let r = TextTools.duplicateLines("one\ntwo\nthree", lineRange: 0...1)
        XCTAssertEqual(r.text, "one\ntwo\none\ntwo\nthree")
        XCTAssertEqual(r.lineRange, 2...3)
    }

    func testDuplicate_blankLinePreserved() {
        let r = TextTools.duplicateLines("a\n\nb", lineRange: 1...1)
        XCTAssertEqual(r.text, "a\n\n\nb")
        XCTAssertEqual(r.lineRange, 2...2)
    }

    // MARK: moveLines — down (+1)

    func testMoveDown_singleLine_swapsWithNext_selectionFollows() {
        let r = TextTools.moveLines("a\nb\nc", lineRange: 0...0, by: 1)
        XCTAssertEqual(r.text, "b\na\nc")
        XCTAssertEqual(r.lineRange, 1...1)
    }

    func testMoveDown_block_swapsPastTheLineBelow() {
        let r = TextTools.moveLines("one\ntwo\nthree\nfour", lineRange: 0...1, by: 1)
        XCTAssertEqual(r.text, "three\none\ntwo\nfour")
        XCTAssertEqual(r.lineRange, 1...2)
    }

    func testMoveDown_atBottomIsNoOp() {
        let r = TextTools.moveLines("a\nb\nc", lineRange: 2...2, by: 1)
        XCTAssertEqual(r.text, "a\nb\nc")
        XCTAssertEqual(r.lineRange, 2...2)
    }

    func testMoveDown_blockAtBottomIsNoOp() {
        let r = TextTools.moveLines("a\nb\nc", lineRange: 1...2, by: 1)
        XCTAssertEqual(r.text, "a\nb\nc")
        XCTAssertEqual(r.lineRange, 1...2)
    }

    // MARK: moveLines — up (-1)

    func testMoveUp_singleLine_swapsWithPrevious_selectionFollows() {
        let r = TextTools.moveLines("a\nb\nc", lineRange: 2...2, by: -1)
        XCTAssertEqual(r.text, "a\nc\nb")
        XCTAssertEqual(r.lineRange, 1...1)
    }

    func testMoveUp_block_swapsPastTheLineAbove() {
        let r = TextTools.moveLines("one\ntwo\nthree\nfour", lineRange: 2...3, by: -1)
        XCTAssertEqual(r.text, "one\nthree\nfour\ntwo")
        XCTAssertEqual(r.lineRange, 1...2)
    }

    func testMoveUp_atTopIsNoOp() {
        let r = TextTools.moveLines("a\nb\nc", lineRange: 0...0, by: -1)
        XCTAssertEqual(r.text, "a\nb\nc")
        XCTAssertEqual(r.lineRange, 0...0)
    }

    func testMoveUp_blockAtTopIsNoOp() {
        let r = TextTools.moveLines("a\nb\nc", lineRange: 0...1, by: -1)
        XCTAssertEqual(r.text, "a\nb\nc")
        XCTAssertEqual(r.lineRange, 0...1)
    }

    // MARK: moveLines — edge cases

    /// Moving the last unterminated line up keeps the trailing-newline state
    /// (still no trailing newline; the line that becomes last is unterminated).
    func testMoveUp_lastLineNoTrailingNewline_preservesNoTrailing() {
        let r = TextTools.moveLines("a\nb\nc", lineRange: 2...2, by: -1)
        XCTAssertEqual(r.text, "a\nc\nb")
        XCTAssertFalse(r.text.hasSuffix("\n"))
    }

    /// Moving up INTO the last slot from above when the file is newline-
    /// terminated keeps the terminator.
    func testMoveDown_preservesTrailingNewline() {
        let r = TextTools.moveLines("a\nb\nc\n", lineRange: 0...0, by: 1)
        XCTAssertEqual(r.text, "b\na\nc\n")
        XCTAssertEqual(r.lineRange, 1...1)
    }

    func testMove_zeroStepIsNoOp() {
        let r = TextTools.moveLines("a\nb\nc", lineRange: 1...1, by: 0)
        XCTAssertEqual(r.text, "a\nb\nc")
        XCTAssertEqual(r.lineRange, 1...1)
    }

    func testMove_emptyDocIsNoOp() {
        let r = TextTools.moveLines("", lineRange: 0...0, by: 1)
        XCTAssertEqual(r.text, "")
        XCTAssertEqual(r.lineRange, 0...0)
    }

    func testMove_outOfRangeClampsThenMoves() {
        // Range past the end clamps to last line, which is a no-op moving down.
        let r = TextTools.moveLines("a\nb\nc", lineRange: 5...9, by: 1)
        XCTAssertEqual(r.text, "a\nb\nc")
        XCTAssertEqual(r.lineRange, 2...2)
    }

    /// A move down by a multi-step `by` (>1) is honoured only as a single ±1
    /// step (the editor only ever asks ±1); guards against silent over-reach.
    func testMove_multiStepByTreatedAsSingleStep() {
        let r = TextTools.moveLines("a\nb\nc\nd", lineRange: 0...0, by: 5)
        XCTAssertEqual(r.text, "b\na\nc\nd")
        XCTAssertEqual(r.lineRange, 1...1)
    }

    // MARK: round-trip / inverse properties

    /// Move down then up restores the original (and selection) — an inverse pair.
    func testMove_downThenUp_isIdentity() {
        let original = "alpha\nbeta\ngamma\ndelta"
        let down = TextTools.moveLines(original, lineRange: 1...1, by: 1)
        let back = TextTools.moveLines(down.text, lineRange: down.lineRange, by: -1)
        XCTAssertEqual(back.text, original)
        XCTAssertEqual(back.lineRange, 1...1)
    }
}
