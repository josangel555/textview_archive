import XCTest
@testable import ViewerCore

final class FoldCommandsTests: XCTestCase {

    private let r1 = FoldRegion(startLine: 1, endLine: 10, kind: .function)
    private let r2 = FoldRegion(startLine: 3, endLine: 7,  kind: .object)
    private let r3 = FoldRegion(startLine: 4, endLine: 5,  kind: .array)
    private var state: FoldState {
        FoldState(regions: [r1, r2, r3], collapsed: [])
    }

    func testCollapseAtCaret_PicksSmallestEnclosing() {
        // Caret at line 5 → inside all three. Smallest = r3 (span 2).
        let s = FoldCommands.collapseAtCaret(in: state, originalLine: 5)
        XCTAssertEqual(s.collapsed, [r3])
    }

    func testCollapseAtCaret_Idempotent() {
        var s = state
        s.collapsed.insert(r3)
        let s2 = FoldCommands.collapseAtCaret(in: s, originalLine: 5)
        XCTAssertEqual(s2.collapsed, [r3], "expected idempotence")
    }

    func testCollapseAtCaret_NoOpWhenOutsideAllFolds() {
        let s = FoldCommands.collapseAtCaret(in: state, originalLine: 99)
        XCTAssertEqual(s.collapsed, [])
    }

    func testExpandAtCaret_RemovesSmallestCollapsed() {
        var s = state
        s.collapsed = [r1, r2, r3]
        let s2 = FoldCommands.expandAtCaret(in: s, originalLine: 5)
        XCTAssertEqual(s2.collapsed, [r1, r2])
    }

    func testExpandAtCaret_NoOpWhenNothingCollapsedThere() {
        var s = state
        s.collapsed = [r1]
        // Caret in line 5 — r1 contains it but is the smallest
        // collapsed one (only one), so it should be expanded.
        let s2 = FoldCommands.expandAtCaret(in: s, originalLine: 5)
        XCTAssertEqual(s2.collapsed, [])
    }

    func testCollapseAll_AndExpandAll() {
        let collapsed = FoldCommands.collapseAll(in: state)
        XCTAssertEqual(collapsed.collapsed, Set([r1, r2, r3]))
        let expanded = FoldCommands.expandAll(in: collapsed)
        XCTAssertEqual(expanded.collapsed, [])
    }

    func testToggle_OnFoldStartLine() {
        // r1 starts at line 1. Toggle picks largest by span (r1 if
        // multiple started there, but only r1 does).
        guard let s2 = FoldCommands.toggle(in: state, foldStartingAt: 1)
        else { return XCTFail("expected toggle to find fold at line 1") }
        XCTAssertEqual(s2.collapsed, [r1])
        // Toggle again → expand.
        guard let s3 = FoldCommands.toggle(in: s2, foldStartingAt: 1)
        else { return XCTFail("expected re-toggle to expand") }
        XCTAssertEqual(s3.collapsed, [])
    }

    func testToggle_ReturnsNilWhenNoFoldStarts() {
        XCTAssertNil(FoldCommands.toggle(in: state, foldStartingAt: 99))
    }

    func testUpdateRegions_DropsStaleCollapsed() {
        var s = state
        s.collapsed = [r1, r3]
        // r3 disappears after re-parse.
        s.updateRegions([r1, r2])
        XCTAssertEqual(s.collapsed, [r1])
        XCTAssertEqual(s.regions, [r1, r2])
    }
}
