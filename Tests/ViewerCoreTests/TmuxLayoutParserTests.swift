import XCTest
@testable import ViewerCore

/// Headless coverage for the tmux layout-string parser (TSK-964 slice b).
/// Grammar + worked example: `docs/TMUX_CC_DESIGN_2026-06-18.md` §1.4.
final class TmuxLayoutParserTests: XCTestCase {

    // MARK: - Single leaf

    func test_singleLeaf() {
        // <checksum>,WxH,X,Y,id  → one pane.
        let tree = TmuxLayoutParser.parse("9f2b,80x24,0,0,0")
        XCTAssertEqual(tree, .leaf(id: 0, w: 80, h: 24, x: 0, y: 0))
    }

    func test_singleLeaf_nonZeroGeometryAndId() {
        let tree = TmuxLayoutParser.parse("abcd,120x40,5,7,3")
        XCTAssertEqual(tree, .leaf(id: 3, w: 120, h: 40, x: 5, y: 7))
    }

    // MARK: - Horizontal split (two leaves)

    func test_horizontalSplit_twoLeaves() {
        // `{ … }` = left-to-right. Two panes side by side.
        let tree = TmuxLayoutParser.parse("bf3a,178x40,0,0{88x40,0,0,1,89x40,89,0,2}")
        XCTAssertEqual(tree, .hsplit([
            .leaf(id: 1, w: 88, h: 40, x: 0, y: 0),
            .leaf(id: 2, w: 89, h: 40, x: 89, y: 0),
        ]))
    }

    // MARK: - Vertical split

    func test_verticalSplit_twoLeaves() {
        // `[ … ]` = top-to-bottom.
        let tree = TmuxLayoutParser.parse("0001,89x40,89,0[89x20,89,0,2,89x19,89,21,3]")
        XCTAssertEqual(tree, .vsplit([
            .leaf(id: 2, w: 89, h: 20, x: 89, y: 0),
            .leaf(id: 3, w: 89, h: 19, x: 89, y: 21),
        ]))
    }

    // MARK: - Nested: leaf beside a vertical split  {a,[b,c]}

    func test_nested_leafBesideVerticalSplit_shape_ids_geometry() {
        // Top-level horizontal split: leaf `1` on the left; on the right a
        // vertical split of panes `2` over `3`.
        let tree = TmuxLayoutParser.parse(
            "00aa,178x40,0,0{88x40,0,0,1,89x40,89,0[89x20,89,0,2,89x19,89,21,3]}")

        // Tree shape: hsplit of [leaf, vsplit].
        guard case let .hsplit(top) = tree else {
            return XCTFail("expected top-level hsplit, got \(String(describing: tree))")
        }
        XCTAssertEqual(top.count, 2)

        // Left child: leaf 1 with its geometry.
        XCTAssertEqual(top[0], .leaf(id: 1, w: 88, h: 40, x: 0, y: 0))

        // Right child: a vertical split of leaves 2 over 3.
        guard case let .vsplit(right) = top[1] else {
            return XCTFail("expected right child to be a vsplit, got \(top[1])")
        }
        XCTAssertEqual(right, [
            .leaf(id: 2, w: 89, h: 20, x: 89, y: 0),
            .leaf(id: 3, w: 89, h: 19, x: 89, y: 21),
        ])
    }

    // MARK: - The worked example from the design doc §1.4 (exact tree)

    func test_designDocWorkedExample_exactTree() {
        let layout = "bf3a,178x40,0,0{88x40,0,0,1,89x40,89,0[89x20,89,0,2,89x19,89,21,3]}"
        let expected: PaneNode = .hsplit([
            .leaf(id: 1, w: 88, h: 40, x: 0, y: 0),
            .vsplit([
                .leaf(id: 2, w: 89, h: 20, x: 89, y: 0),
                .leaf(id: 3, w: 89, h: 19, x: 89, y: 21),
            ]),
        ])
        XCTAssertEqual(TmuxLayoutParser.parse(layout), expected)
    }

    // MARK: - Deeper nesting (split inside a split inside a split)

    func test_deepNesting() {
        // { leaf, [ leaf, { leaf, leaf } ] }
        let layout = "1234,200x50,0,0{100x50,0,0,1,100x50,100,0[100x25,100,0,2,100x25,100,26{50x25,100,26,3,50x25,150,26,4}]}"
        let expected: PaneNode = .hsplit([
            .leaf(id: 1, w: 100, h: 50, x: 0, y: 0),
            .vsplit([
                .leaf(id: 2, w: 100, h: 25, x: 100, y: 0),
                .hsplit([
                    .leaf(id: 3, w: 50, h: 25, x: 100, y: 26),
                    .leaf(id: 4, w: 50, h: 25, x: 150, y: 26),
                ]),
            ]),
        ])
        XCTAssertEqual(TmuxLayoutParser.parse(layout), expected)
    }

    func test_threeWayHorizontalSplit() {
        let tree = TmuxLayoutParser.parse(
            "00ff,150x40,0,0{50x40,0,0,1,50x40,50,0,2,50x40,100,0,3}")
        XCTAssertEqual(tree, .hsplit([
            .leaf(id: 1, w: 50, h: 40, x: 0, y: 0),
            .leaf(id: 2, w: 50, h: 40, x: 50, y: 0),
            .leaf(id: 3, w: 50, h: 40, x: 100, y: 0),
        ]))
    }

    // MARK: - Malformed → nil (no crash)

    func test_malformed_empty() {
        XCTAssertNil(TmuxLayoutParser.parse(""))
    }

    func test_malformed_checksumTooShort() {
        XCTAssertNil(TmuxLayoutParser.parse("9f2,80x24,0,0,0"))
    }

    func test_malformed_checksumTooLong() {
        // 5 hex digits → the 5th would have to be the comma; geometry then
        // starts mid-string and fails.
        XCTAssertNil(TmuxLayoutParser.parse("9f2bc,80x24,0,0,0"))
    }

    func test_malformed_checksumNonHex() {
        XCTAssertNil(TmuxLayoutParser.parse("9g2b,80x24,0,0,0"))
    }

    func test_malformed_noChecksumComma() {
        XCTAssertNil(TmuxLayoutParser.parse("9f2b80x24,0,0,0"))
    }

    func test_malformed_missingGeometry() {
        XCTAssertNil(TmuxLayoutParser.parse("9f2b,"))
        XCTAssertNil(TmuxLayoutParser.parse("9f2b,80x24"))
        XCTAssertNil(TmuxLayoutParser.parse("9f2b,80x24,0"))
        XCTAssertNil(TmuxLayoutParser.parse("9f2b,80x24,0,0")) // no suffix (id/group)
    }

    func test_malformed_missingXSeparator() {
        // `80-24` instead of `80x24`.
        XCTAssertNil(TmuxLayoutParser.parse("9f2b,80-24,0,0,0"))
    }

    func test_malformed_unbalancedBrace_missingClose() {
        XCTAssertNil(TmuxLayoutParser.parse("bf3a,178x40,0,0{88x40,0,0,1,89x40,89,0,2"))
    }

    func test_malformed_unbalancedBracket_missingClose() {
        XCTAssertNil(TmuxLayoutParser.parse("bf3a,178x40,0,0[88x40,0,0,1,89x40,89,0,2"))
    }

    func test_malformed_mismatchedBrackets() {
        // Opens with `{` but closes with `]`.
        XCTAssertNil(TmuxLayoutParser.parse("bf3a,178x40,0,0{88x40,0,0,1,89x40,89,0,2]"))
    }

    func test_malformed_emptyGroup() {
        XCTAssertNil(TmuxLayoutParser.parse("bf3a,178x40,0,0{}"))
        XCTAssertNil(TmuxLayoutParser.parse("bf3a,178x40,0,0[]"))
    }

    func test_malformed_trailingJunkAfterLeaf() {
        XCTAssertNil(TmuxLayoutParser.parse("9f2b,80x24,0,0,0xyz"))
    }

    func test_malformed_trailingJunkAfterGroup() {
        XCTAssertNil(TmuxLayoutParser.parse("bf3a,178x40,0,0{88x40,0,0,1,89x40,89,0,2}!"))
    }

    func test_malformed_trailingComma_inGroup() {
        XCTAssertNil(TmuxLayoutParser.parse("bf3a,178x40,0,0{88x40,0,0,1,}"))
    }

    func test_malformed_negativeGeometry() {
        // Leading '-' is not a digit → parseUInt fails.
        XCTAssertNil(TmuxLayoutParser.parse("9f2b,80x24,-1,0,0"))
    }

    func test_malformed_nonNumericPaneId() {
        XCTAssertNil(TmuxLayoutParser.parse("9f2b,80x24,0,0,a"))
    }

    func test_malformed_integerOverflow() {
        // A width that overflows Int → nil, not a trap.
        XCTAssertNil(TmuxLayoutParser.parse("9f2b,99999999999999999999x24,0,0,0"))
    }

    func test_malformed_doesNotCrashOnGarbage() {
        // Fuzz-ish smoke: a pile of pathological inputs must all return nil
        // without trapping.
        let garbage = [
            "{{{{{{", "[[[[[", "}]}]}]", ",,,,,",
            "ffff,", "0000,x", "0000,1x", "0000,1x1",
            "0000,1x1,", "0000,1x1,1", "0000,1x1,1,",
            "0000,1x1,1,1{", "0000,1x1,1,1[",
            String(repeating: "0000,1x1,1,1{", count: 50),
        ]
        for g in garbage {
            XCTAssertNil(TmuxLayoutParser.parse(g), "expected nil for \(g)")
        }
    }
}
