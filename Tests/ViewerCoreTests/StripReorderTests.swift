import CoreGraphics
import Foundation
import Testing
import ViewerCore

/// Geometry behind drag-to-reorder on both tab strips (file tabs and
/// session pills). Pure logic — the SwiftUI layer only supplies the
/// pointer x and the measured item frames, so everything that decides
/// WHERE a dragged tab lands is pinned here on the host.
@Suite("StripReorder — drag-to-reorder geometry")
struct StripReorderTests {

    /// Four 100pt items laid out end to end: midpoints at 50/150/250/350.
    private static let frames: [StripReorder.ItemFrame] = (0..<4).map { i in
        StripReorder.ItemFrame(id: ids[i],
                               minX: CGFloat(i) * 100,
                               maxX: CGFloat(i) * 100 + 100)
    }
    private static let ids: [UUID] = (0..<4).map { _ in UUID() }

    // MARK: insertionGap ----------------------------------------------

    @Test("pointer x maps to the gap whose midpoints it has passed",
          arguments: [
            (CGFloat(-500), 0),   // dragged far off the left edge → first gap
            (0, 0),
            (49, 0),
            (50, 1),              // exactly on a midpoint counts as passed
            (149, 1),
            (151, 2),
            (250, 3),
            (399, 4),
            (5_000, 4),           // far off the right edge → last gap
          ])
    func insertionGap(pointerX: CGFloat, expected: Int) {
        #expect(StripReorder.insertionGap(pointerX: pointerX,
                                          frames: Self.frames) == expected)
    }

    @Test("an empty strip has exactly one gap")
    func insertionGapEmpty() {
        #expect(StripReorder.insertionGap(pointerX: 123, frames: []) == 0)
    }

    // MARK: isNoOp -----------------------------------------------------

    /// BOTH gaps bordering the dragged item leave it where it started.
    /// Missing the `source + 1` case would fire a model mutation and
    /// flash an insertion caret for a drag that moves nothing.
    @Test("both gaps bordering the dragged item are no-ops",
          arguments: [(1, 1, true), (1, 2, true),
                      (1, 0, false), (1, 3, false),
                      (0, 0, true), (0, 1, true), (0, 2, false)])
    func isNoOp(source: Int, gap: Int, expected: Bool) {
        #expect(StripReorder.isNoOp(source: source, gap: gap) == expected)
    }

    // MARK: caretX -----------------------------------------------------

    @Test("the caret sits on the leading edge of the gap",
          arguments: [(0, CGFloat(0)), (1, 100), (3, 300), (4, 400)])
    func caretX(gap: Int, expected: CGFloat) {
        #expect(StripReorder.caretX(gap: gap, frames: Self.frames) == expected)
    }

    @Test("clamps rather than crashing on an out-of-range gap")
    func caretXClamps() {
        #expect(StripReorder.caretX(gap: -3, frames: Self.frames) == 0)
        #expect(StripReorder.caretX(gap: 99, frames: Self.frames) == 400)
        #expect(StripReorder.caretX(gap: 0, frames: []) == nil)
    }

    // MARK: resolveMove — the strip can change under a drag -------------

    @Test("a drop is resolved against the CURRENT order, not the start index")
    func resolveMoveUsesLiveOrder() {
        let ids = Self.ids
        // The dragged item (originally index 0) is now at index 2 because
        // two tabs opened to its left mid-drag.
        let live = [UUID(), UUID(), ids[0], ids[1]]
        let move = StripReorder.resolveMove(itemID: ids[0], ids: live, gap: 4)
        #expect(move?.source == 2)
        #expect(move?.destination == 4)
    }

    /// The whole point: a stale index would move somebody else's tab.
    @Test("a dragged item closed mid-drag cancels the move")
    func resolveMoveDroppedItem() {
        #expect(StripReorder.resolveMove(itemID: UUID(),
                                         ids: [UUID(), UUID()], gap: 1) == nil)
    }

    @Test("the gap is clamped to the live item count")
    func resolveMoveClampsGap() {
        let ids = [UUID(), UUID(), UUID()]
        // Frames were snapshotted when the strip was longer.
        #expect(StripReorder.resolveMove(itemID: ids[0], ids: ids, gap: 9)?.destination == 3)
        #expect(StripReorder.resolveMove(itemID: ids[2], ids: ids, gap: -4)?.destination == 0)
    }

    @Test("a resolved no-op is filtered out")
    func resolveMoveNoOp() {
        let ids = [UUID(), UUID(), UUID()]
        #expect(StripReorder.resolveMove(itemID: ids[1], ids: ids, gap: 1) == nil)
        #expect(StripReorder.resolveMove(itemID: ids[1], ids: ids, gap: 2) == nil)
    }

    // MARK: composition with the real tab model ------------------------

    private func tabs(_ names: [String]) -> TabsState {
        TabsState(tabs: names.map { Tab(url: URL(fileURLWithPath: "/\($0)")) })
    }

    /// The contract that actually matters end to end: the gap the caret
    /// was drawn at is the same gap handed to `TabsState.move`, so the
    /// tab lands exactly where the user saw the indicator.
    @Test("dragging the first tab past the third lands it where the caret showed")
    func dragRightwardMatchesTheCaret() {
        var state = tabs(["a", "b", "c", "d"])
        let moved = state.tabs[0].id
        // Pointer sits just past item 2's midpoint (250) → gap 3.
        let gap = StripReorder.insertionGap(pointerX: 260, frames: Self.frames)
        #expect(gap == 3)
        #expect(!StripReorder.isNoOp(source: 0, gap: gap))
        state.move(from: 0, to: gap)
        #expect(state.tabs.map { $0.url!.lastPathComponent } == ["b", "c", "a", "d"])
        #expect(state.tabs.firstIndex { $0.id == moved } == 2)
    }

    @Test("dragging the last tab to the front lands it where the caret showed")
    func dragLeftwardMatchesTheCaret() {
        var state = tabs(["a", "b", "c", "d"])
        let moved = state.tabs[3].id
        let gap = StripReorder.insertionGap(pointerX: 10, frames: Self.frames)
        #expect(gap == 0)
        state.move(from: 3, to: gap)
        #expect(state.tabs.map { $0.url!.lastPathComponent } == ["d", "a", "b", "c"])
        #expect(state.tabs.firstIndex { $0.id == moved } == 0)
    }

    /// Reordering must carry the selection with the dragged tab — losing
    /// it would silently switch the visible document mid-drag.
    @Test("the dragged tab keeps the selection")
    func selectionFollowsTheDraggedTab() {
        var state = tabs(["a", "b", "c", "d"])
        state.select(at: 0)
        let moved = state.tabs[0].id
        state.move(from: 0, to: 3)
        #expect(state.selectedIndex == 2)
        #expect(state.selected?.id == moved)
    }

    /// Dragging a tab you are NOT in must leave you in the tab you were in —
    /// its index may shift, but the selected DOCUMENT must not change.
    /// (Owner 2026-07-28: "I want to remain in the same tab.")
    @Test("reordering another tab never changes which document is selected")
    func selectionStaysPutWhenDraggingAnotherTab() {
        for gap in [0, 1, 2, 3, 4] {
            var state = tabs(["a", "b", "c", "d"])
            state.select(at: 1)                       // user is in "b"
            let current = state.selected?.id
            guard !StripReorder.isNoOp(source: 3, gap: gap) else { continue }
            state.move(from: 3, to: gap)              // drag "d" somewhere
            #expect(state.selected?.id == current)
            #expect(state.selected?.url?.lastPathComponent == "b")
        }
    }

    /// A drop back onto the dragged tab's own slot must not disturb the
    /// selection either.
    @Test("a no-op drop leaves the strip and selection untouched")
    func noOpDropChangesNothing() {
        var state = tabs(["a", "b", "c", "d"])
        state.select(at: 2)
        let before = state.tabs.map(\.id)
        for gap in [1, 2] where StripReorder.isNoOp(source: 1, gap: gap) {
            state.move(from: 1, to: gap)
        }
        #expect(state.tabs.map(\.id) == before)
        #expect(state.selectedIndex == 2)
    }
}
