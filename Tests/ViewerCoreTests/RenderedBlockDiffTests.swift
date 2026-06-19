import XCTest
@testable import ViewerCore

/// TSK-838 — host tests for the rendered-markdown block diff layer.
///
/// These pin the invariant that drives the whole "persistent page + DOM patch"
/// win: editing one block yields ONE op against only that block (not a full
/// rebuild), and applying the computed patch list to the old block model
/// reproduces the new model byte-for-byte.
final class RenderedBlockDiffTests: XCTestCase {

    private let renderer = HTMLRenderer()

    /// Convenience: render markdown to its body and split into blocks.
    private func blocks(_ markdown: String) -> [RenderedBlockDiff.Block] {
        RenderedBlockDiff.splitBlocks(renderer.render(markdown))
    }

    // MARK: - Splitting

    func test_split_separatesTopLevelBlocks() {
        let bs = blocks("# Title\n\nFirst paragraph.\n\nSecond paragraph.")
        XCTAssertEqual(bs.count, 3, "got tags: \(bs.map(\.tag))")
        XCTAssertEqual(bs.map(\.tag), ["h1", "p", "p"])
        // Re-joining the blocks reproduces the body byte-for-byte.
        let rejoined = bs.map(\.html).joined()
        XCTAssertEqual(rejoined, renderer.render("# Title\n\nFirst paragraph.\n\nSecond paragraph."))
    }

    func test_split_handlesNestedBlocks_listIsOneBlock() {
        // A list (with nested <li>) is ONE top-level block, not one per item.
        let md = "- a\n- b\n- c"
        let bs = blocks(md)
        XCTAssertEqual(bs.count, 1)
        XCTAssertEqual(bs[0].tag, "ul")
        // Whatever the exact <li> shape, all three items live in the single
        // <ul> block, and re-joining reproduces the body byte-for-byte.
        XCTAssertEqual(bs[0].html.components(separatedBy: "<li").count - 1, 3,
                       "all three items in one block, got: \(bs[0].html)")
        XCTAssertEqual(bs.map(\.html).joined(), renderer.render(md))
    }

    func test_split_voidBlock_hr() {
        let bs = blocks("para\n\n---\n\nmore")
        XCTAssertEqual(bs.map(\.tag), ["p", "hr", "p"])
    }

    func test_split_table_isOneBlock() {
        let md = "| a | b |\n| - | - |\n| 1 | 2 |"
        let bs = blocks(md)
        XCTAssertEqual(bs.count, 1)
        XCTAssertEqual(bs[0].tag, "table")
        XCTAssertEqual(bs.map(\.html).joined(), renderer.render(md))
    }

    func test_split_attributeWithAngleBracket_doesNotSplitMidTag() {
        // A '>' inside a quoted attribute must not end the tag early. The
        // mermaid host carries escaped markup in data-mdv-src; a title with a
        // '>' is a simpler reproducer that stays in the Swift renderer's output.
        let body = "<p title=\"a &gt; b\"><a href=\"x\" title=\"1 > 2\">link</a></p>\n"
        let bs = RenderedBlockDiff.splitBlocks(body)
        XCTAssertEqual(bs.count, 1)
        XCTAssertEqual(bs[0].tag, "p")
        XCTAssertEqual(bs[0].html, body)
    }

    func test_split_emptyBody() {
        XCTAssertEqual(RenderedBlockDiff.splitBlocks(""), [])
    }

    // MARK: - Diff: the core "edit one block ⇒ one op" invariant

    func test_diff_editOneParagraph_yieldsSingleReplace() {
        let old = blocks("# Title\n\nFirst paragraph.\n\nSecond paragraph.")
        let new = blocks("# Title\n\nFirst paragraph EDITED.\n\nSecond paragraph.")
        let ops = RenderedBlockDiff.diff(old: old, new: new)
        XCTAssertEqual(ops.count, 1, "expected exactly one op, got: \(ops)")
        guard case .replace(let index, let block) = ops[0] else {
            return XCTFail("expected a replace, got: \(ops[0])")
        }
        XCTAssertEqual(index, 1, "the edited paragraph is at block index 1")
        XCTAssertTrue(block.html.contains("EDITED"))
        // Applying the patch reproduces the new model exactly.
        XCTAssertEqual(RenderedBlockDiff.apply(ops, to: old), new)
    }

    func test_diff_unchangedDocument_yieldsNoOps() {
        let old = blocks("# A\n\nbody\n\n- x\n- y")
        let new = blocks("# A\n\nbody\n\n- x\n- y")
        XCTAssertEqual(RenderedBlockDiff.diff(old: old, new: new), [])
    }

    func test_diff_insertParagraph_yieldsSingleInsert() {
        let old = blocks("first\n\nthird")
        let new = blocks("first\n\nsecond\n\nthird")
        let ops = RenderedBlockDiff.diff(old: old, new: new)
        XCTAssertEqual(ops.count, 1, "got: \(ops)")
        guard case .insert(let index, let block) = ops[0] else {
            return XCTFail("expected an insert, got: \(ops[0])")
        }
        XCTAssertEqual(index, 1)
        XCTAssertTrue(block.html.contains("second"))
        XCTAssertEqual(RenderedBlockDiff.apply(ops, to: old), new)
    }

    func test_diff_removeParagraph_yieldsSingleRemove() {
        let old = blocks("first\n\nsecond\n\nthird")
        let new = blocks("first\n\nthird")
        let ops = RenderedBlockDiff.diff(old: old, new: new)
        XCTAssertEqual(ops.count, 1, "got: \(ops)")
        guard case .remove(let index) = ops[0] else {
            return XCTFail("expected a remove, got: \(ops[0])")
        }
        XCTAssertEqual(index, 1)
        XCTAssertEqual(RenderedBlockDiff.apply(ops, to: old), new)
    }

    func test_diff_appendToEnd_yieldsSingleInsertAtEnd() {
        let old = blocks("one\n\ntwo")
        let new = blocks("one\n\ntwo\n\nthree")
        let ops = RenderedBlockDiff.diff(old: old, new: new)
        XCTAssertEqual(ops.count, 1)
        guard case .insert(let index, _) = ops[0] else {
            return XCTFail("expected an insert, got: \(ops[0])")
        }
        XCTAssertEqual(index, 2)
        XCTAssertEqual(RenderedBlockDiff.apply(ops, to: old), new)
    }

    func test_diff_editFirstOfMany_touchesOnlyThatBlock() {
        // A 6-block doc, edit only block 0. The whole point of the feature:
        // the other 5 blocks must NOT be touched.
        let oldMD = "# H\n\np1\n\np2\n\np3\n\np4\n\np5"
        let newMD = "# H EDITED\n\np1\n\np2\n\np3\n\np4\n\np5"
        let old = blocks(oldMD)
        let new = blocks(newMD)
        XCTAssertEqual(old.count, 6)
        let ops = RenderedBlockDiff.diff(old: old, new: new)
        XCTAssertEqual(ops.count, 1, "only one block changed, got: \(ops)")
        if case .replace(let index, _) = ops[0] {
            XCTAssertEqual(index, 0)
        } else {
            XCTFail("expected a replace at 0, got: \(ops[0])")
        }
        XCTAssertEqual(RenderedBlockDiff.apply(ops, to: old), new)
    }

    // MARK: - apply(diff(old,new), to: old) == new — the round-trip contract

    func test_applyDiff_roundTrips_acrossVariousEdits() {
        let cases: [(String, String)] = [
            // (old markdown, new markdown)
            ("a\n\nb\n\nc", "a\n\nb\n\nc"),                       // identical
            ("a\n\nb\n\nc", "a\n\nB\n\nc"),                       // edit middle
            ("a\n\nb\n\nc", "a\n\nc"),                            // remove middle
            ("a\n\nc", "a\n\nb\n\nc"),                            // insert middle
            ("a\n\nb\n\nc", "x\n\ny\n\nz"),                       // full rebuild
            ("a\n\nb\n\nc\n\nd", "d\n\nc\n\nb\n\na"),             // reorder
            ("# H\n\n- x\n- y\n\np", "# H2\n\n- x\n- y\n- z\n\np"), // heading + list edits
            ("", "new content"),                                  // empty → content
            ("old content", ""),                                  // content → empty
            ("para\n\n---\n\npara2", "para\n\n---\n\npara2 EDITED"), // with hr
        ]
        for (oldMD, newMD) in cases {
            let old = blocks(oldMD)
            let new = blocks(newMD)
            let ops = RenderedBlockDiff.diff(old: old, new: new)
            let applied = RenderedBlockDiff.apply(ops, to: old)
            XCTAssertEqual(
                applied, new,
                "round-trip failed for old=<\(oldMD)> new=<\(newMD)>; ops=\(ops)"
            )
            // And re-joining the applied blocks reproduces the new body.
            XCTAssertEqual(
                applied.map(\.html).joined(),
                new.map(\.html).joined(),
                "rejoined body mismatch for old=<\(oldMD)> new=<\(newMD)>"
            )
        }
    }

    func test_diff_isMinimal_reorderDoesNotRebuildEveryBlock() {
        // Moving the last block to the front should NOT produce N replaces —
        // the LCS keeps the common run, so it's a small remove+insert (or
        // insert+remove), never "replace all".
        let old = blocks("a\n\nb\n\nc\n\nd")
        let new = blocks("d\n\na\n\nb\n\nc")
        let ops = RenderedBlockDiff.diff(old: old, new: new)
        XCTAssertLessThan(ops.count, old.count, "diff should be smaller than a full rebuild, got: \(ops)")
        XCTAssertEqual(RenderedBlockDiff.apply(ops, to: old), new)
    }

    // MARK: - Stable content hashing

    func test_contentHash_equalForIdenticalHTML_differsOnEdit() {
        let a = RenderedBlockDiff.Block(tag: "p", html: "<p>same</p>\n")
        let b = RenderedBlockDiff.Block(tag: "p", html: "<p>same</p>\n")
        let c = RenderedBlockDiff.Block(tag: "p", html: "<p>changed</p>\n")
        XCTAssertEqual(a.contentHash, b.contentHash)
        XCTAssertNotEqual(a.contentHash, c.contentHash)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    // MARK: - End-to-end against the real renderer

    func test_realRender_largeDoc_singleEditIsCheap() {
        // Build a 50-paragraph doc; edit one paragraph in the middle; assert
        // the patch set is exactly one op — the regression guard for the
        // "2-9s reload storm on every keystroke" the feature kills.
        let paras = (0..<50).map { "Paragraph number \($0) with some prose." }
        let oldMD = paras.joined(separator: "\n\n")
        var editedParas = paras
        editedParas[25] = "Paragraph number 25 with EDITED prose."
        let newMD = editedParas.joined(separator: "\n\n")

        let old = blocks(oldMD)
        let new = blocks(newMD)
        XCTAssertEqual(old.count, 50)
        let ops = RenderedBlockDiff.diff(old: old, new: new)
        XCTAssertEqual(ops.count, 1, "a single edit in a 50-block doc must be one op, got \(ops.count)")
        if case .replace(let index, _) = ops[0] {
            XCTAssertEqual(index, 25)
        } else {
            XCTFail("expected a replace, got: \(ops[0])")
        }
        XCTAssertEqual(RenderedBlockDiff.apply(ops, to: old), new)
    }
}
