import Foundation

// MARK: - HunkContextCapture
//
// v2 §3.1/§3.3: pure functions that turn a parsed `UnifiedDiff.Hunk` + an
// anchor (side + line range) into the FROZEN `HunkContext` stored on a
// `ReviewComment`. This is the snapshot that makes the export self-contained.
//
// Two landmines this must get right (§9):
//   1. `UnifiedDiff.Line.Kind` has 4 cases (.context/.added/.removed/
//      .noNewline); `DiffLine.Kind` has only 3. The `\ No newline at end of
//      file` marker carries no line numbers and isn't reviewable code — it
//      is DROPPED before windowing, so it can never occupy a context slot or
//      trap the mapper.
//   2. pre/post context is "UP TO 3, clipped to the hunk" — never fabricate
//      lines past a hunk edge. An off-by-one here bakes wrong context into
//      the export PERMANENTLY (the snapshot is frozen at creation).

public enum HunkContextCapture {

    /// Number of context lines captured on each side of the anchor.
    public static let contextRadius = 3

    /// Map a `UnifiedDiff.Line` to the storage `DiffLine`. Returns `nil` for
    /// `.noNewline` — those are dropped (no line numbers, not reviewable).
    public static func mapLine(_ line: UnifiedDiff.Line) -> DiffLine? {
        let kind: DiffLine.Kind
        switch line.kind {
        case .context:   kind = .context
        case .added:     kind = .added
        case .removed:   kind = .removed
        case .noNewline: return nil   // §3.3: drop the "\ No newline" marker
        }
        return DiffLine(
            kind: kind,
            oldLineNo: line.oldLineNo,
            newLineNo: line.newLineNo,
            content: line.content
        )
    }

    /// The line number a given line presents on the requested anchor side.
    /// `.context` lines exist on both sides; we use the side that was
    /// clicked, matching the exporter's `anchored`-flag convention
    /// (`.context → newLineNo ?? oldLineNo`, see ReviewExporter §line 399).
    private static func lineNumber(
        of line: UnifiedDiff.Line, on side: LineAnchor.Side
    ) -> Int? {
        switch side {
        case .old:     return line.oldLineNo
        case .new:     return line.newLineNo
        case .context: return line.newLineNo ?? line.oldLineNo
        }
    }

    /// Capture the frozen `HunkContext` for an anchor inside a single hunk.
    ///
    /// Algorithm:
    ///   1. Drop `.noNewline` lines (so windowing never lands on a marker).
    ///   2. Find the contiguous span of lines whose number on `side` falls
    ///      within `range` — those are the `anchoredLines`.
    ///   3. Take up to `contextRadius` reviewable lines immediately before
    ///      (preLines) and after (postLines) that span, clipped to the hunk.
    ///
    /// Returns `nil` if no line in the hunk matches the anchor on `side`
    /// (caller passed a range outside this hunk — a programming error, but
    /// we return nil rather than fabricate a bogus snapshot).
    public static func capture(
        hunk: UnifiedDiff.Hunk,
        side: LineAnchor.Side,
        range: ClosedRange<Int>
    ) -> HunkContext? {
        // (1) Drop `.noNewline`; everything below windows over reviewable
        // lines only.
        let reviewable: [DiffLine] = hunk.lines.compactMap(mapLine)
        guard !reviewable.isEmpty else { return nil }

        // (2) Indices of lines whose number on the anchored side is in range.
        // We map back onto the *reviewable* array (post-drop indices) by
        // re-deriving the side line-number from the mapped DiffLine.
        func sideLineNo(_ d: DiffLine) -> Int? {
            switch side {
            case .old:     return d.oldLineNo
            case .new:     return d.newLineNo
            case .context: return d.newLineNo ?? d.oldLineNo
            }
        }

        let anchoredIdx = reviewable.indices.filter { i in
            guard let n = sideLineNo(reviewable[i]) else { return false }
            return range.contains(n)
        }
        guard let first = anchoredIdx.first, let last = anchoredIdx.last else {
            return nil   // anchor doesn't intersect this hunk
        }

        // The anchored span is contiguous between the first and last match —
        // include any interior lines (e.g. an added line between two context
        // lines whose number isn't itself in `range` but sits inside the
        // selected block) so the captured block is visually continuous.
        let anchored = Array(reviewable[first...last])

        // (3) Up to `contextRadius` lines before / after, clipped to bounds.
        let preStart = max(0, first - contextRadius)
        let pre = first > preStart ? Array(reviewable[preStart..<first]) : []

        let postEnd = min(reviewable.count, last + 1 + contextRadius)
        let post = (last + 1) < postEnd ? Array(reviewable[(last + 1)..<postEnd]) : []

        return HunkContext(
            hunkHeader: hunkHeaderString(hunk),
            preLines: pre,
            anchoredLines: anchored,
            postLines: post
        )
    }

    /// Reconstruct the canonical `@@ -a,b +c,d @@ tail` header string from a
    /// parsed hunk. `DiffParser` keeps only the *tail* (the context after the
    /// second `@@`) in `Hunk.header`, dropping the coordinate prefix — but
    /// the frozen `HunkContext.hunkHeader` is meant to be the full, verbatim
    /// header (what `DiffView` displays). Rebuild it from the coordinates.
    ///
    /// Count omitted == 1 in unified-diff convention; we emit the explicit
    /// count (git itself emits the count even when 1 for multi-line hunks,
    /// and an explicit count is unambiguous for the agent).
    public static func hunkHeaderString(_ hunk: UnifiedDiff.Hunk) -> String {
        let coords = "@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@"
        let tail = hunk.header.trimmingCharacters(in: .whitespaces)
        return tail.isEmpty ? coords : "\(coords) \(tail)"
    }
}
