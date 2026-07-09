import Foundation
import Combine
import ViewerCore

/// TSK-1438 — the live Markdown outline panel's view-model: the binding layer
/// between the host-tested pure `OutlineNavigation` / `MarkdownOutline` and
/// the SwiftUI `MarkdownOutlineSection`. Holds the headings, the scroll-driven
/// current section, and the filter query; every transition delegates to the
/// pure engine so the behavior is host-testable without a window.
///
/// The SwiftUI section + its wiring into the sidebar is the render tail
/// (VM/AX-validated); this object's state machine is host-pinned.
@MainActor
public final class MarkdownOutlineModel: ObservableObject {

    /// The active document's headings (outline rows before filtering).
    @Published public private(set) var headings: [MarkdownHeading] = []

    /// The filter-box text. Rows are recomputed from this on read.
    @Published public var filterQuery: String = ""

    /// The heading whose section the viewport is currently inside — drives
    /// the highlight-follows-scroll behavior. `nil` = above the first
    /// heading (preamble) or an empty outline.
    @Published public private(set) var currentIndex: Int?

    public init() {}

    /// Whether the panel has anything to show.
    public var isEmpty: Bool { headings.isEmpty }

    /// Recompute the outline from the active source text. Clamps
    /// `currentIndex` into the new range (a shorter doc must not leave a
    /// stale out-of-bounds selection).
    public func rebuild(fromSource source: String) {
        headings = MarkdownOutline.headings(in: source)
        if let idx = currentIndex {
            currentIndex = headings.isEmpty ? nil : min(idx, headings.count - 1)
        }
    }

    /// The viewport top moved to `topLine` (1-based). Recompute the current
    /// section, but ONLY publish when it actually changed — a scroll tick
    /// that stays inside the same section must not fire `objectWillChange`
    /// and churn the list (the recurring-no-op-update guard).
    public func viewportChanged(topLine: Int) {
        let next = OutlineNavigation.currentHeadingIndex(topLine: topLine, headings: headings)
        if next != currentIndex { currentIndex = next }
    }

    /// The filtered rows to render, each carrying its ORIGINAL index so a
    /// click still resolves to the right heading/line.
    public var visibleRows: [(index: Int, heading: MarkdownHeading)] {
        OutlineNavigation.filter(filterQuery, headings: headings)
    }

    /// Keyboard ↓: advance the selection and return the 1-based line to
    /// scroll to (nil when there's nothing to move to).
    @discardableResult
    public func selectNext() -> Int? {
        guard let idx = OutlineNavigation.nextIndex(from: currentIndex, count: headings.count)
        else { return nil }
        currentIndex = idx
        return lineForIndex(idx)
    }

    /// Keyboard ↑: retreat the selection and return the line to scroll to.
    @discardableResult
    public func selectPrevious() -> Int? {
        guard let idx = OutlineNavigation.previousIndex(from: currentIndex, count: headings.count)
        else { return nil }
        currentIndex = idx
        return lineForIndex(idx)
    }

    /// Select the heading at `index` (a row click) and return its line.
    @discardableResult
    public func select(index: Int) -> Int? {
        guard headings.indices.contains(index) else { return nil }
        currentIndex = index
        return lineForIndex(index)
    }

    /// The 1-based source line for a heading index, or nil if out of range.
    public func lineForIndex(_ index: Int) -> Int? {
        headings.indices.contains(index) ? headings[index].line : nil
    }
}
