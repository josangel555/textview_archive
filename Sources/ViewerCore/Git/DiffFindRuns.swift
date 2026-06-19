import Foundation

/// TSK-910 — re-homes the diff find-highlight from per-LINE row tints onto
/// char-precise RANGES inside a hunk's single selectable `AttributedString`
/// (built by `DiffHunkAttributedString`).
///
/// The old render drew one `Text` per line and tinted the whole ROW for a
/// match (`DiffView.lineRow`'s overlay). When a hunk collapses into ONE
/// `Text` (so selection can span lines, the TSK-910 bug fix), the find
/// highlight has to become a set of background-colour RUNS over the joined
/// string instead. This mapper produces those runs:
///   - it locates every occurrence of the query within each matching line's
///     rendered text (prefix + content, matching the build),
///   - converts each occurrence to a character range in the hunk string's
///     coordinate space (via the `LineSpan`s from the same build),
///   - flags the run that is the CURRENT match so the view can paint it the
///     stronger "active" tint.
///
/// Pure + host-testable: no SwiftUI, no view. The render slice walks these
/// `(range, isCurrent)` pairs and sets `backgroundColor` on each.
public enum DiffFindRuns {

    /// One highlight run: a character range within the hunk's built
    /// `AttributedString` plus whether it is the currently-focused match.
    public struct Run: Equatable, Sendable {
        public let lineIndex: Int      // hunk-line index the match sits on
        public let start: Int          // char offset within the hunk string
        public let length: Int         // char length of the matched substring
        public let isCurrent: Bool     // the active (next/prev-selected) match
        public init(lineIndex: Int, start: Int, length: Int, isCurrent: Bool) {
            self.lineIndex = lineIndex; self.start = start
            self.length = length; self.isCurrent = isCurrent
        }
        public var end: Int { start + length }
    }

    /// Map every find match that lands in `hunkIndex` of `fileIndex` to
    /// char-precise highlight runs over the hunk's built string.
    ///
    /// - Parameters:
    ///   - matches: the full `DiffFind` match set (across all files/hunks).
    ///   - query:   the active find query (used to locate substrings;
    ///              matched the SAME way `DiffFind` matches — case-insensitive
    ///              literal). Empty/whitespace ⇒ no runs.
    ///   - hunk:    the hunk being rendered.
    ///   - fileIndex/hunkIndex: this hunk's tree coordinates, to select the
    ///              relevant subset of `matches`.
    ///   - spans:   the per-line char spans from `DiffHunkAttributedString.build`
    ///              for THIS hunk (must be built with the same `includePrefix`).
    ///   - current: the currently-focused match (or nil); flagged `isCurrent`.
    ///   - includePrefix: whether the built string included the +/-/space
    ///              prefix (offsets the substring search by one char).
    ///
    /// Returns runs in document order (line, then occurrence within line).
    public static func map(
        matches: [DiffFind.Match],
        query: String,
        hunk: UnifiedDiff.Hunk,
        fileIndex: Int,
        hunkIndex: Int,
        spans: [DiffHunkAttributedString.LineSpan],
        current: DiffFind.Match?,
        includePrefix: Bool = true
    ) -> [Run] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }

        // Index spans by line for O(1) lookup.
        var spanByLine: [Int: DiffHunkAttributedString.LineSpan] = [:]
        for s in spans { spanByLine[s.lineIndex] = s }

        var runs: [Run] = []
        for m in matches where m.file == fileIndex && m.hunk == hunkIndex {
            guard hunk.lines.indices.contains(m.line),
                  let span = spanByLine[m.line] else { continue }
            let line = hunk.lines[m.line]
            // The rendered line text == prefix + content (same as the build),
            // so substring offsets line up with the LineSpan coordinates.
            let prefixLen = includePrefix ? line.kind.diffPrefix.count : 0
            let haystack = line.content
            let isCurrent = (m == current)

            // Locate every (non-overlapping) case-insensitive occurrence of
            // the query within the line content.
            var searchStart = haystack.startIndex
            while searchStart < haystack.endIndex,
                  let r = haystack.range(
                      of: q, options: .caseInsensitive,
                      range: searchStart..<haystack.endIndex) {
                let occStart = haystack.distance(
                    from: haystack.startIndex, to: r.lowerBound)
                let occLen = haystack.distance(
                    from: r.lowerBound, to: r.upperBound)
                runs.append(Run(
                    lineIndex: m.line,
                    start: span.start + prefixLen + occStart,
                    length: occLen,
                    isCurrent: isCurrent))
                // Advance past this occurrence; guard zero-width (can't
                // happen for a non-empty q, but keep the loop total).
                searchStart = r.upperBound > r.lowerBound ? r.upperBound
                    : haystack.index(after: r.lowerBound)
            }
        }
        return runs
    }

    /// Coarser fallback: re-home each match to its WHOLE line span (the
    /// faithful port of the old full-row tint) rather than the matched
    /// substring. Useful when char-precise substring highlighting isn't
    /// wanted. Order is document order over the supplied matches.
    public static func wholeLineRuns(
        matches: [DiffFind.Match],
        fileIndex: Int,
        hunkIndex: Int,
        spans: [DiffHunkAttributedString.LineSpan],
        current: DiffFind.Match?
    ) -> [Run] {
        var spanByLine: [Int: DiffHunkAttributedString.LineSpan] = [:]
        for s in spans { spanByLine[s.lineIndex] = s }

        var runs: [Run] = []
        for m in matches where m.file == fileIndex && m.hunk == hunkIndex {
            guard let span = spanByLine[m.line] else { continue }
            runs.append(Run(
                lineIndex: m.line,
                start: span.start,
                length: span.length,
                isCurrent: m == current))
        }
        return runs
    }
}
