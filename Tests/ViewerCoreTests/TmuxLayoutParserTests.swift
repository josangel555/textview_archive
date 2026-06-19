import XCTest
@testable import ViewerCore

/// Headless coverage for the tmux layout-string parser (TSK-964/TSK-1018
/// slice b), which decodes a tmux layout string into the CANONICAL typed
/// `PaneNode` tree (`leaf(paneID:)` / `split(axis:children:weights:)`) — the
/// same `PaneNode` `TerminalPaneTree` lays out. Geometry (cell W×H,X,Y) is
/// distilled into split axis + proportional weights and the absolute
/// coordinates discarded. Grammar + worked example:
/// `docs/TMUX_CC_DESIGN_2026-06-18.md` §1.4.
final class TmuxLayoutParserTests: XCTestCase {

    private func p(_ n: Int) -> TmuxPaneID { TmuxPaneID(n) }

    // MARK: - Single leaf

    func test_singleLeaf() {
        // <checksum>,WxH,X,Y,id  → one pane (no split wrapping).
        XCTAssertEqual(TmuxLayoutParser.parse("9f2b,80x24,0,0,0"), .leaf(paneID: p(0)))
    }

    func test_singleLeaf_nonZeroGeometryAndId() {
        XCTAssertEqual(TmuxLayoutParser.parse("abcd,120x40,5,7,3"), .leaf(paneID: p(3)))
    }

    // MARK: - Horizontal split (two leaves) — `{ … }` = left-to-right

    func test_horizontalSplit_twoLeaves_evenGeometry_equalWeights() {
        // 88 | 89 cells ≈ even → nil weights (equal split), axis horizontal.
        let tree = TmuxLayoutParser.parse("bf3a,178x40,0,0{88x40,0,0,1,89x40,89,0,2}")
        XCTAssertEqual(tree, .split(axis: .horizontal, children: [
            .leaf(paneID: p(1)), .leaf(paneID: p(2)),
        ], weights: nil))
    }

    // MARK: - Vertical split — `[ … ]` = top-to-bottom

    func test_verticalSplit_twoLeaves_evenGeometry_equalWeights() {
        let tree = TmuxLayoutParser.parse("0001,89x40,89,0[89x20,89,0,2,89x19,89,21,3]")
        XCTAssertEqual(tree, .split(axis: .vertical, children: [
            .leaf(paneID: p(2)), .leaf(paneID: p(3)),
        ], weights: nil))
    }

    // MARK: - Geometry → proportional weights (UNEVEN splits)

    func test_horizontalSplit_unevenGeometry_yieldsProportionalWeights() {
        // 50 | 150 cells → shares 0.25 / 0.75 along the horizontal axis.
        let tree = TmuxLayoutParser.parse("0a0a,200x40,0,0{50x40,0,0,1,150x40,50,0,2}")
        guard case let .split(axis, children, weights) = tree else {
            return XCTFail("expected a split, got \(String(describing: tree))")
        }
        XCTAssertEqual(axis, .horizontal)
        XCTAssertEqual(children, [.leaf(paneID: p(1)), .leaf(paneID: p(2))])
        XCTAssertNotNil(weights)
        XCTAssertEqual(weights?[0] ?? -1, 0.25, accuracy: 1e-9)
        XCTAssertEqual(weights?[1] ?? -1, 0.75, accuracy: 1e-9)
    }

    func test_verticalSplit_unevenGeometry_yieldsProportionalWeights() {
        // 30 | 10 cells tall → shares 0.75 / 0.25 along the vertical axis.
        let tree = TmuxLayoutParser.parse("0b0b,80x40,0,0[80x30,0,0,5,80x10,0,30,6]")
        guard case let .split(axis, children, weights) = tree else {
            return XCTFail("expected a split, got \(String(describing: tree))")
        }
        XCTAssertEqual(axis, .vertical)
        XCTAssertEqual(children, [.leaf(paneID: p(5)), .leaf(paneID: p(6))])
        XCTAssertEqual(weights?[0] ?? -1, 0.75, accuracy: 1e-9)
        XCTAssertEqual(weights?[1] ?? -1, 0.25, accuracy: 1e-9)
    }

    func test_proportionalWeights_feedTerminalPaneTree_endToEnd() {
        // The whole point of weights: TerminalPaneTree must lay the 0.25/0.75
        // split out as a quarter / three-quarters of the bounds width.
        let tree = TmuxLayoutParser.parse("0a0a,200x40,0,0{50x40,0,0,1,150x40,50,0,2}")!
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let frames = TerminalPaneTree.frames(for: tree, in: bounds)
        XCTAssertEqual(frames[0].rect.width, 200, accuracy: 1e-6)   // 1/4 of 800
        XCTAssertEqual(frames[1].rect.width, 600, accuracy: 1e-6)   // 3/4 of 800
    }

    // MARK: - Nested: leaf beside a vertical split  {a,[b,c]}

    func test_nested_leafBesideVerticalSplit_shape_ids_axes() {
        let tree = TmuxLayoutParser.parse(
            "00aa,178x40,0,0{88x40,0,0,1,89x40,89,0[89x20,89,0,2,89x19,89,21,3]}")

        // Top level: a horizontal split of [leaf, vertical-split].
        guard case let .split(topAxis, top, _) = tree else {
            return XCTFail("expected top-level split, got \(String(describing: tree))")
        }
        XCTAssertEqual(topAxis, .horizontal)
        XCTAssertEqual(top.count, 2)
        XCTAssertEqual(top[0], .leaf(paneID: p(1)))

        // Right child: a vertical split of leaves 2 over 3.
        guard case let .split(rightAxis, right, _) = top[1] else {
            return XCTFail("expected right child to be a split, got \(top[1])")
        }
        XCTAssertEqual(rightAxis, .vertical)
        XCTAssertEqual(right, [.leaf(paneID: p(2)), .leaf(paneID: p(3))])
    }

    // MARK: - The worked example from the design doc §1.4 (exact tree)

    func test_designDocWorkedExample_exactTree() {
        let layout = "bf3a,178x40,0,0{88x40,0,0,1,89x40,89,0[89x20,89,0,2,89x19,89,21,3]}"
        let expected: PaneNode = .split(axis: .horizontal, children: [
            .leaf(paneID: p(1)),
            .split(axis: .vertical, children: [
                .leaf(paneID: p(2)), .leaf(paneID: p(3)),
            ], weights: nil),
        ], weights: nil)
        XCTAssertEqual(TmuxLayoutParser.parse(layout), expected)
    }

    // MARK: - Deeper nesting (split inside a split inside a split)

    func test_deepNesting() {
        // { leaf, [ leaf, { leaf, leaf } ] } — all geometry even → nil weights.
        let layout = "1234,200x50,0,0{100x50,0,0,1,100x50,100,0[100x25,100,0,2,100x25,100,26{50x25,100,26,3,50x25,150,26,4}]}"
        let expected: PaneNode = .split(axis: .horizontal, children: [
            .leaf(paneID: p(1)),
            .split(axis: .vertical, children: [
                .leaf(paneID: p(2)),
                .split(axis: .horizontal, children: [
                    .leaf(paneID: p(3)), .leaf(paneID: p(4)),
                ], weights: nil),
            ], weights: nil),
        ], weights: nil)
        XCTAssertEqual(TmuxLayoutParser.parse(layout), expected)
    }

    func test_threeWayHorizontalSplit() {
        let tree = TmuxLayoutParser.parse(
            "00ff,150x40,0,0{50x40,0,0,1,50x40,50,0,2,50x40,100,0,3}")
        XCTAssertEqual(tree, .split(axis: .horizontal, children: [
            .leaf(paneID: p(1)), .leaf(paneID: p(2)), .leaf(paneID: p(3)),
        ], weights: nil))
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
