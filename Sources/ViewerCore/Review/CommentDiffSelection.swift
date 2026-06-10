import Foundation

/// Pure, host-testable resolver for the "select multiple review comments and see
/// the combined diff of the regions they touch" flow (TSK-532) — i.e. "show me a
/// diff of everything I flagged". Distinct from `CumulativeDiffSelection`, which
/// spans multiple COMMITS; this spans multiple COMMENTS.
///
/// Given the selected `ReviewComment`s it groups their anchor line-ranges by
/// `(filePath, side)` and merges overlapping/adjacent ranges into the minimal
/// set of `Region`s a diff view should reveal/highlight. SwiftUI/AppKit-free —
/// the multi-select gesture + the region-scoped `DiffView` are the VM-gated UI.
///
/// `.old` and `.new` ranges are kept in SEPARATE regions on purpose: a comment
/// on old-side line 50 and one on new-side line 50 address different code
/// (pre- vs post-change line numbering), so merging them would be wrong.
public enum CommentDiffSelection {

    /// One file+side with the merged set of line ranges to show.
    public struct Region: Equatable, Sendable {
        public let filePath: String
        public let side: LineAnchor.Side
        /// Merged, sorted, non-overlapping 1-based inclusive line ranges (on `side`).
        public let ranges: [ClosedRange<Int>]
        public init(filePath: String, side: LineAnchor.Side, ranges: [ClosedRange<Int>]) {
            self.filePath = filePath
            self.side = side
            self.ranges = ranges
        }
    }

    private struct Key: Hashable {
        let filePath: String
        let side: LineAnchor.Side
    }

    /// Resolve the combined regions for `comments`. Empty input → `[]`. Regions
    /// are sorted by `(filePath, side.rawValue)`; ranges within a region are
    /// merged (overlapping OR touching ranges coalesce) and sorted by start.
    public static func regions(from comments: [ReviewComment]) -> [Region] {
        guard !comments.isEmpty else { return [] }

        var grouped: [Key: [ClosedRange<Int>]] = [:]
        for c in comments {
            let lo = Swift.min(c.anchor.startLine, c.anchor.endLine)
            let hi = Swift.max(c.anchor.startLine, c.anchor.endLine)
            grouped[Key(filePath: c.filePath, side: c.anchor.side), default: []].append(lo...hi)
        }

        return grouped
            .map { key, ranges in
                Region(filePath: key.filePath, side: key.side, ranges: merge(ranges))
            }
            .sorted { ($0.filePath, $0.side.rawValue) < ($1.filePath, $1.side.rawValue) }
    }

    /// Merge overlapping or adjacent (gap ≤ 1) inclusive ranges into the minimal
    /// covering set, sorted by lower bound.
    static func merge(_ ranges: [ClosedRange<Int>]) -> [ClosedRange<Int>] {
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        var out: [ClosedRange<Int>] = []
        for r in sorted {
            if let last = out.last, r.lowerBound <= last.upperBound + 1 {
                out[out.count - 1] = last.lowerBound...Swift.max(last.upperBound, r.upperBound)
            } else {
                out.append(r)
            }
        }
        return out
    }
}
