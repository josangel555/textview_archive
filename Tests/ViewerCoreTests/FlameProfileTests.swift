import XCTest
import CoreGraphics
@testable import ViewerCore

/// Pins the flame-profile foundation (TSK-715): folded-stacks parsing into a
/// merged self/total call tree, hot-frame ranking, the flame-chart geometry
/// layout, and the profile/memory diff. Pure logic → host-tested.
final class FlameProfileTests: XCTestCase {

    // Convenience: find a direct child of root by name.
    private func child(_ p: FlameProfile, _ name: String) -> FlameProfile.Frame? {
        p.root.children.first { $0.name == name }
    }

    // MARK: parseFolded

    func test_singleStack_buildsLinearTree_withSelfAtLeaf() {
        let p = FlameProfile.parseFolded("main;work;inner 10")
        XCTAssertEqual(p.totalWeight, 10)
        XCTAssertEqual(p.malformedLineCount, 0)
        XCTAssertFalse(p.isEmpty)

        let main = child(p, "main")!
        XCTAssertEqual(main.total, 10)
        XCTAssertEqual(main.selfWeight, 0)          // all time flowed into work
        let work = main.children.first { $0.name == "work" }!
        XCTAssertEqual(work.total, 10)
        XCTAssertEqual(work.selfWeight, 0)
        let inner = work.children.first { $0.name == "inner" }!
        XCTAssertEqual(inner.total, 10)
        XCTAssertEqual(inner.selfWeight, 10)        // leaf gets the self time
        XCTAssertTrue(inner.children.isEmpty)
    }

    func test_pathID_isRootToLeafJoin() {
        let p = FlameProfile.parseFolded("main;work;inner 10")
        let inner = child(p, "main")!.children[0].children[0]
        XCTAssertEqual(inner.id, "main;work;inner")
        XCTAssertEqual(child(p, "main")!.id, "main")
    }

    func test_mergesSiblingsAndAccumulatesDuplicateStacks() {
        // main->a appears twice (folds), main->b once.
        let text = """
        main;a 3
        main;a 2
        main;b 5
        """
        let p = FlameProfile.parseFolded(text)
        XCTAssertEqual(p.totalWeight, 10)
        let main = child(p, "main")!
        XCTAssertEqual(main.total, 10)
        XCTAssertEqual(main.selfWeight, 0)
        XCTAssertEqual(main.children.count, 2)
        // Sorted by total desc: b(5) before a(5)? a=5,b=5 tie → name asc → a,b.
        let a = main.children.first { $0.name == "a" }!
        let b = main.children.first { $0.name == "b" }!
        XCTAssertEqual(a.total, 5)                   // 3 + 2 folded
        XCTAssertEqual(b.total, 5)
        XCTAssertEqual(a.selfWeight, 5)
        XCTAssertEqual(b.selfWeight, 5)
    }

    func test_selfWeight_whenFrameIsBothLeafAndHasChildren() {
        // "main" sampled directly (self) AND as a caller of "deep".
        let text = """
        main 4
        main;deep 6
        """
        let p = FlameProfile.parseFolded(text)
        let main = child(p, "main")!
        XCTAssertEqual(main.total, 10)
        XCTAssertEqual(main.selfWeight, 4)          // 10 total − 6 in child
        XCTAssertEqual(main.children.first!.total, 6)
    }

    func test_childrenSortedByTotalDescendingThenName() {
        let text = """
        r;small 1
        r;big 9
        r;mid 5
        """
        let p = FlameProfile.parseFolded(text)
        let r = child(p, "r")!
        XCTAssertEqual(r.children.map(\.name), ["big", "mid", "small"])
    }

    func test_ignoresBlankAndCommentLines() {
        let text = """
        # a comment
        main;x 3

           # indented comment
        main;y 7
        """
        let p = FlameProfile.parseFolded(text)
        XCTAssertEqual(p.totalWeight, 10)
        XCTAssertEqual(p.malformedLineCount, 0)
        XCTAssertEqual(child(p, "main")!.children.count, 2)
    }

    func test_malformedLines_countedAndSkipped() {
        let text = """
        valid;stack 5
        no_count_here
        bad;count xyz
        zero;weight 0
        neg;weight -4
        """
        let p = FlameProfile.parseFolded(text)
        XCTAssertEqual(p.totalWeight, 5)
        XCTAssertEqual(p.malformedLineCount, 4)
    }

    func test_emptyFrameSegments_areDropped() {
        // Leading/trailing/double semicolons produce empty frames → dropped.
        let p = FlameProfile.parseFolded(";main;;work; 8")
        XCTAssertEqual(p.totalWeight, 8)
        XCTAssertEqual(p.malformedLineCount, 0)
        let main = child(p, "main")!
        XCTAssertEqual(main.name, "main")
        XCTAssertEqual(main.children.map(\.name), ["work"])
    }

    func test_frameNameWithSpaces_countIsLastToken() {
        // C++-style signature with spaces; count is the final token.
        let p = FlameProfile.parseFolded("std::vector<int>::push_back(int const&) 12")
        XCTAssertEqual(p.totalWeight, 12)
        XCTAssertEqual(p.malformedLineCount, 0)
        XCTAssertEqual(p.root.children.first!.name,
                       "std::vector<int>::push_back(int const&)")
    }

    func test_emptyInput_isEmptyProfile() {
        let p = FlameProfile.parseFolded("")
        XCTAssertTrue(p.isEmpty)
        XCTAssertEqual(p.totalWeight, 0)
        XCTAssertEqual(p.malformedLineCount, 0)
    }

    func test_frameCountAndMaxDepth() {
        let text = """
        a;b;c 1
        a;d 1
        """
        let p = FlameProfile.parseFolded(text)
        // root + a + b + c + d = 5
        XCTAssertEqual(p.root.frameCount, 5)
        // root(0) a(1) b(2) c(3) → maxDepth from root = 3
        XCTAssertEqual(p.root.maxDepth, 3)
    }

    // MARK: hotFrames

    func test_hotFrames_mergeSelfAcrossPaths_rankedDescending() {
        // "leaf" is a leaf under two callers → self merges to 3+4=7.
        let text = """
        a;leaf 3
        b;leaf 4
        a;other 2
        """
        let p = FlameProfile.parseFolded(text)
        let hot = p.hotFrames()
        XCTAssertEqual(hot.first?.name, "leaf")
        XCTAssertEqual(hot.first?.selfWeight, 7)
        // "other" self = 2. "a"/"b" have 0 self (pure callers) → excluded.
        XCTAssertEqual(hot.map(\.name), ["leaf", "other"])
    }

    func test_hotFrames_respectsLimit() {
        let text = "x;p 5\nx;q 3\nx;r 1"
        let p = FlameProfile.parseFolded(text)
        XCTAssertEqual(p.hotFrames(limit: 2).map(\.name), ["p", "q"])
        XCTAssertEqual(p.hotFrames(limit: 0).count, 0)
    }

    // MARK: FlameLayout

    private let bounds = CGRect(x: 0, y: 0, width: 100, height: 90)

    func test_layout_emptyOrZeroBounds_noCells() {
        let p = FlameProfile.parseFolded("a 1")
        XCTAssertTrue(FlameLayout.lay(p, in: .zero).isEmpty)
        XCTAssertTrue(FlameLayout.lay(FlameProfile.parseFolded(""), in: bounds).isEmpty)
    }

    func test_layout_widthProportionalToTotal_rootChildrenSpanFullWidth() {
        // root total = 10; a=6, b=4.
        let p = FlameProfile.parseFolded("a 6\nb 4")
        let cells = FlameLayout.lay(p, in: bounds, rowHeight: 18)
        XCTAssertEqual(cells.count, 2)
        let a = cells.first { $0.frame.name == "a" }!
        let b = cells.first { $0.frame.name == "b" }!
        XCTAssertEqual(a.depth, 0)
        XCTAssertEqual(b.depth, 0)
        XCTAssertEqual(a.rect.width, 60, accuracy: 0.001)
        XCTAssertEqual(b.rect.width, 40, accuracy: 0.001)
        // Full-width span, no overlap (b starts where a ends).
        XCTAssertEqual(a.rect.minX, 0, accuracy: 0.001)
        XCTAssertEqual(a.rect.maxX, b.rect.minX, accuracy: 0.001)
        XCTAssertEqual(b.rect.maxX, bounds.maxX, accuracy: 0.001)
    }

    func test_layout_depthStacksUpwardFromBottom() {
        let p = FlameProfile.parseFolded("a;b 10")
        let cells = FlameLayout.lay(p, in: bounds, rowHeight: 18)
        let a = cells.first { $0.frame.name == "a" }!
        let b = cells.first { $0.frame.name == "b" }!
        XCTAssertEqual(a.depth, 0)
        XCTAssertEqual(b.depth, 1)
        // depth-0 row sits at the bottom; depth-1 directly above it.
        XCTAssertEqual(a.rect.maxY, bounds.maxY, accuracy: 0.001)
        XCTAssertEqual(b.rect.maxY, a.rect.minY, accuracy: 0.001)
        // A child never wider than its parent (b ⊆ a horizontally).
        XCTAssertGreaterThanOrEqual(b.rect.minX, a.rect.minX - 0.001)
        XCTAssertLessThanOrEqual(b.rect.maxX, a.rect.maxX + 0.001)
    }

    func test_layout_prunesThinCellsAndSubtree() {
        // tiny=1 of total 10000 over a 1000px canvas → 0.1px wide; pruned.
        let p = FlameProfile.parseFolded("big;deep 9999\ntiny;hidden 1")
        let kept = FlameLayout.lay(p, in: CGRect(x: 0, y: 0, width: 1000, height: 90),
                                   minCellWidth: 1)
        XCTAssertFalse(kept.contains { $0.frame.name == "tiny" })
        XCTAssertFalse(kept.contains { $0.frame.name == "hidden" }) // subtree pruned too
        XCTAssertTrue(kept.contains { $0.frame.name == "big" })
        // With no pruning, everything is present.
        let all = FlameLayout.lay(p, in: CGRect(x: 0, y: 0, width: 1000, height: 90),
                                  minCellWidth: 0)
        XCTAssertTrue(all.contains { $0.frame.name == "tiny" })
    }

    func test_layout_preOrder_parentBeforeChild() {
        let p = FlameProfile.parseFolded("a;b;c 10")
        let cells = FlameLayout.lay(p, in: bounds)
        let names = cells.map(\.frame.name)
        XCTAssertEqual(names, ["a", "b", "c"])
    }

    // MARK: diff

    func test_diff_perSymbolDelta_addedRemovedAndChanged() {
        // baseline: parse=10, render=5. after: parse=6 (shrank), render=5
        // (same), layout=8 (new). render=5 unchanged → delta 0.
        let base = FlameProfile.parseFolded("doc;parse 10\ndoc;render 5")
        let after = FlameProfile.parseFolded("doc;parse 6\ndoc;render 5\ndoc;layout 8")
        let d = base.diff(against: after)

        XCTAssertEqual(d.totalDelta, (6 + 5 + 8) - (10 + 5))   // 19 - 15 = 4
        let byName = Dictionary(uniqueKeysWithValues: d.rows.map { ($0.name, $0) })
        XCTAssertEqual(byName["parse"]?.delta, -4)
        XCTAssertTrue(byName["parse"]?.isRemoved == false)
        XCTAssertEqual(byName["layout"]?.delta, 8)
        XCTAssertTrue(byName["layout"]!.isAdded)
        XCTAssertEqual(byName["render"]?.delta, 0)
    }

    func test_diff_removedSymbol_flagged() {
        let base = FlameProfile.parseFolded("a;gone 7\na;keep 3")
        let after = FlameProfile.parseFolded("a;keep 3")
        let d = base.diff(against: after)
        let gone = d.rows.first { $0.name == "gone" }!
        XCTAssertTrue(gone.isRemoved)
        XCTAssertEqual(gone.delta, -7)
        XCTAssertEqual(d.totalDelta, -7)
    }

    func test_diff_rowsSortedByAbsDeltaDescending() {
        let base = FlameProfile.parseFolded("a;x 10\na;y 10\na;z 10")
        let after = FlameProfile.parseFolded("a;x 11\na;y 30\na;z 5")
        let d = base.diff(against: after)
        // deltas: y=+20, z=-5, x=+1 → abs order y,z,x.
        XCTAssertEqual(d.rows.map(\.name), ["y", "z", "x"])
        // changedRows excludes nothing here (all moved).
        XCTAssertEqual(d.changedRows.count, 3)
    }

    func test_diff_changedRows_excludesUnchanged() {
        let base = FlameProfile.parseFolded("a;same 5\na;moved 5")
        let after = FlameProfile.parseFolded("a;same 5\na;moved 9")
        let d = base.diff(against: after)
        XCTAssertEqual(d.changedRows.map(\.name), ["moved"])
    }
}
