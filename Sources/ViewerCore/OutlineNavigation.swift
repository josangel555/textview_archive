import Foundation

/// TSK-1438 — the outline panel's NAVIGATION model: which heading the
/// viewport is currently inside (the highlight-on-scroll), keyboard
/// next/previous stepping, and the filter box — all pure over
/// `[MarkdownHeading]`, so the panel's behavior is host-pinned and the
/// SwiftUI list + scroll wiring is the render tail.
public enum OutlineNavigation {

    /// The index of the heading whose SECTION contains `topLine` — the last
    /// heading at or above the viewport top (binary search). `nil` when the
    /// viewport is above the first heading (the preamble).
    public static func currentHeadingIndex(
        topLine: Int, headings: [MarkdownHeading]
    ) -> Int? {
        guard !headings.isEmpty else { return nil }
        var lo = 0
        var hi = headings.count - 1
        var best: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if headings[mid].line <= topLine {
                best = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return best
    }

    /// Keyboard ↓: the next heading index. From `nil` (preamble) it enters
    /// at the first heading; at the last it stays (clamped, no wrap).
    public static func nextIndex(from current: Int?, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return 0 }
        return min(current + 1, count - 1)
    }

    /// Keyboard ↑: the previous heading index. At the first it stays; from
    /// `nil` it stays `nil` (nothing above the preamble).
    public static func previousIndex(from current: Int?, count: Int) -> Int? {
        guard count > 0, let current else { return nil }
        return max(current - 1, 0)
    }

    /// The filter box: headings whose title matches `query`
    /// (case/diacritic-insensitive substring), order preserved, each with
    /// its ORIGINAL index so a click still jumps to the right line. A
    /// blank query returns everything.
    public static func filter(
        _ query: String, headings: [MarkdownHeading]
    ) -> [(index: Int, heading: MarkdownHeading)] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = headings.enumerated().map { (index: $0.offset, heading: $0.element) }
        guard !q.isEmpty else { return all }
        func norm(_ s: String) -> String {
            s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        }
        let needle = norm(q)
        return all.filter { norm($0.heading.title).contains(needle) }
    }
}
