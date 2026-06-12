import SwiftUI
import ViewerCore

// TSK-282 (mode A): fuzzy-narrow the VISIBLE file-nav rows as the user
// types, with matched-glyph highlighting. Pure core + shared highlighter;
// the view wiring lives in `SidebarView` (the design doc:
// docs/SIDEBAR_FUZZY_FILTER_DESIGN.md — mode B's global descendant cache
// is the deferred follow-up).

/// One ranked sidebar filter hit. `display` is what the row renders and
/// what `matchedIndices` index into: the filename in mode A (visible-rows
/// narrowing), the root-relative path in mode B (global find — TSK-666),
/// so deep matches show WHERE they are and rank by path-segment boundaries.
struct SidebarFilterMatch: Equatable, Identifiable {
    let url: URL
    let display: String
    /// Secondary context text (mode A: the parent directory name; mode B:
    /// empty — the relPath already carries the location).
    let secondary: String
    let isDirectory: Bool
    /// Character indices into `display` to bold (the matcher contract).
    let matchedIndices: [Int]
    var id: URL { url }
}

enum SidebarFilter {
    /// Render cap — never an unbounded match list (design rule 4).
    static let resultCap = 500

    /// Mode A: rank the VISIBLE rows against `query` through the ROUTED
    /// fuzzy engine (`RustFuzzyAdapter` — rust by default; §2.5: new
    /// consumers must not grow the Swift twin). Empty/whitespace query →
    /// `[]` (callers render the normal tree). Ranked, stable ties, capped.
    static func filter(
        _ rows: [SidebarModel.VisibleRow], query: String
    ) -> [SidebarFilterMatch] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let ranked = RustFuzzyAdapter.filterWithMatches(rows, query: q) { $0.node.name }
        return ranked.prefix(resultCap).map { row, match in
            SidebarFilterMatch(
                url: row.node.url,
                display: row.node.name,
                secondary: row.node.url.deletingLastPathComponent().lastPathComponent,
                isDirectory: row.node.isDirectory,
                matchedIndices: match.matchedIndices
            )
        }
    }

    /// Mode B (TSK-666): rank the GLOBAL descendant set — every file under
    /// the root regardless of expansion — by root-relative path. Same
    /// routed engine, same cap.
    static func filterGlobal(
        _ entries: [SidebarModel.DescendantEntry], query: String
    ) -> [SidebarFilterMatch] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let ranked = RustFuzzyAdapter.filterWithMatches(entries, query: q) { $0.relPath }
        return ranked.prefix(resultCap).map { entry, match in
            SidebarFilterMatch(
                url: entry.url,
                display: entry.relPath,
                secondary: "",
                isDirectory: entry.isDirectory,
                matchedIndices: match.matchedIndices
            )
        }
    }
}

/// Shared matched-glyph highlighter for fuzzy results — extracted from
/// `CommandPaletteView` (TSK-282) so the palette and the sidebar filter
/// render matches identically. ONE highlight path, per the design doc.
enum FuzzyHighlight {
    /// Build an AttributedString with matched characters bolded and
    /// accent-colored. Single forward pass — O(N). `matchedIndices` index
    /// into `text`'s Character positions (the FuzzyMatcher contract; the
    /// rust engine's scalar offsets agree on ASCII — the adapter documents
    /// the grapheme divergence).
    static func attributed(
        _ text: String,
        matchedIndices: [Int],
        size: CGFloat,
        regular: Color,
        highlight: Color
    ) -> AttributedString {
        var out = AttributedString(text)
        out.foregroundColor = regular
        let matchedSet = Set(matchedIndices)
        var charIndex = 0
        var cur = out.startIndex
        while cur < out.endIndex {
            let next = out.characters.index(after: cur)
            if matchedSet.contains(charIndex) {
                out[cur..<next].foregroundColor = highlight
                out[cur..<next].font = .system(size: size, weight: .semibold)
            }
            cur = next
            charIndex += 1
        }
        return out
    }
}
