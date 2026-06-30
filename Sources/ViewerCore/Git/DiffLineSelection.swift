import Foundation

/// A contiguous selection of diff LINES within a file's flattened line list
/// (the hunks' lines concatenated in render order, `@@` banners excluded),
/// addressed by a flat 0-based index.
///
/// TSK-910: the diff viewer renders each line as its own `Text` (for the
/// per-line gutter + ±colour), which defeats SwiftUI's cross-line
/// `.textSelection` — so a user could only ever select one line. Selection +
/// copy is therefore modelled here over the rows (the view drives `anchor`
/// on click and `focus` on shift-click / drag), and the copy text is built
/// from the model — independent of SwiftUI's text-selection limits.
public struct DiffLineSelection: Equatable, Sendable {
    /// The row the selection was started from (a plain click).
    public var anchor: Int
    /// The row the selection currently extends to (a shift-click / drag).
    public var focus: Int

    public init(anchor: Int, focus: Int) {
        self.anchor = anchor
        self.focus = focus
    }

    /// A single-row selection (a plain click).
    public init(_ index: Int) { self.init(anchor: index, focus: index) }

    /// The inclusive low…high range, order-independent (the anchor may sit
    /// below or above the focus depending on drag direction).
    public var range: ClosedRange<Int> {
        Swift.min(anchor, focus)...Swift.max(anchor, focus)
    }

    /// Whether the row at `index` falls within the selection (for row highlight).
    public func contains(_ index: Int) -> Bool { range.contains(index) }

    /// The number of selected rows.
    public var count: Int { range.count }
}

public extension UnifiedDiff.File {
    /// The file's lines flattened across its hunks, in render order (banners
    /// excluded). The flat index is the shared address the selection model and
    /// the per-row gesture use.
    var flatLines: [UnifiedDiff.Line] { hunks.flatMap(\.lines) }

    /// The selected lines as unified-diff text — the per-line prefix (` `/`+`/`-`/`\`)
    /// plus content, one line each — for the clipboard. Mirrors the per-hunk /
    /// per-file `clipboardText` line shape (TSK-594) so a partial selection still
    /// pastes as a readable diff fragment. The range is clamped to the available
    /// rows; an empty file or an out-of-range selection yields "".
    func selectedClipboardText(_ selection: DiffLineSelection) -> String {
        let lines = flatLines
        guard !lines.isEmpty else { return "" }
        let lo = Swift.max(0, selection.range.lowerBound)
        let hi = Swift.min(lines.count - 1, selection.range.upperBound)
        guard lo <= hi else { return "" }
        return lines[lo...hi].map { $0.kind.diffPrefix + $0.content }.joined(separator: "\n")
    }
}
