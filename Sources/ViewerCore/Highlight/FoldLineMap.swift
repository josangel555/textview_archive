import Foundation

/// Bidirectional line-mapping between the canonical document and the
/// displayed (fold-collapsed) document. Both indexes are **1-based**;
/// passing 0 is allowed and clamped to 1 to match `NSTextView`
/// behavior on empty selections.
///
/// Storage shape:
/// - `displayedToOriginal[d]` = original line number visible at
///   displayed line `d`. Length = total displayed line count + 1
///   (index 0 unused).
/// - `originalToDisplayed[o]` = displayed line number where original
///   line `o` is shown. For lines hidden inside a collapsed fold, this
///   resolves to the displayed line of the fold's *start* line — the
///   ellipsis carrier — so caret motion onto a hidden line lands on
///   the visible representative rather than disappearing.
///
/// Memory: two `[Int]` of length ~N. On a 100K-line file that's
/// ~1.6 MB total, well below the working-set cost of the document
/// itself. Recompute on every `FoldState` toggle (O(N) — measured
/// ~3 ms for 100K lines on M2).
public struct FoldLineMap: Sendable, Equatable {

    /// 1-indexed: `displayedToOriginal[1]` = original line on displayed
    /// line 1. `[0]` is a sentinel (unused; keeps math 1-based).
    public let displayedToOriginal: [Int]
    /// 1-indexed: `originalToDisplayed[1]` = displayed line on which
    /// original line 1 appears. For lines inside a collapsed fold,
    /// this returns the displayed line of the fold's *start* (i.e.
    /// the line that visually carries the ellipsis).
    public let originalToDisplayed: [Int]
    /// Total number of lines in the canonical document.
    public let originalLineCount: Int
    /// Total number of lines in the displayed (collapsed) document.
    public let displayedLineCount: Int

    public init(
        displayedToOriginal: [Int],
        originalToDisplayed: [Int],
        originalLineCount: Int,
        displayedLineCount: Int
    ) {
        self.displayedToOriginal = displayedToOriginal
        self.originalToDisplayed = originalToDisplayed
        self.originalLineCount  = originalLineCount
        self.displayedLineCount = displayedLineCount
    }

    /// Identity map for `lineCount` original lines (no folds collapsed).
    public static func identity(lineCount: Int) -> FoldLineMap {
        let count = max(0, lineCount)
        var d2o = [Int](repeating: 0, count: count + 1)
        var o2d = [Int](repeating: 0, count: count + 1)
        for i in 1...max(1, count) {
            d2o[i] = i
            o2d[i] = i
        }
        return FoldLineMap(
            displayedToOriginal: d2o,
            originalToDisplayed: o2d,
            originalLineCount: count,
            displayedLineCount: count
        )
    }

    /// Build the map from a canonical line count + a set of collapsed
    /// regions. Overlapping / nested collapsed regions are handled by
    /// computing a per-original-line `hidden` flag from a union of all
    /// hidden ranges (a line is hidden if **any** collapsed region
    /// hides it). O(N + R).
    ///
    /// "Hidden" lines = lines strictly *after* a fold's `startLine` and
    /// *up to* its `endLine`. The start line itself stays visible (it
    /// carries the ellipsis).
    public static func build(
        originalLineCount lineCount: Int,
        collapsed: Set<FoldRegion>
    ) -> FoldLineMap {
        let count = max(0, lineCount)
        guard count > 0 else { return identity(lineCount: 0) }
        guard !collapsed.isEmpty else { return identity(lineCount: count) }

        // Boolean per original line: is it hidden by any collapsed
        // fold? Use a single pass union — for each fold, mark lines
        // (startLine+1 ... endLine). Cheap (R small relative to N).
        var hidden = [Bool](repeating: false, count: count + 2)
        // For mapping hidden lines to their carrier (the fold-start
        // line they sit inside), record `carrier[i]` = startLine of
        // innermost fold hiding line i. Outer folds may hide more
        // lines; the innermost fold's startLine is the *visible* line
        // closest to `i` in the displayed buffer, which is the right
        // landing target.
        var carrier = [Int](repeating: 0, count: count + 2)
        // Sort folds by lineCount ASC so innermost (shortest) is
        // processed *last* and overwrites carrier for shared rows.
        let foldsOrdered = collapsed.sorted { a, b in
            // Outer (larger span) first, so inner overwrites.
            if a.lineCount != b.lineCount { return a.lineCount > b.lineCount }
            return a.startLine < b.startLine
        }
        for r in foldsOrdered {
            let from = max(1, r.startLine + 1)
            let to   = min(count, r.endLine)
            guard from <= to else { continue }
            for i in from...to {
                hidden[i] = true
                carrier[i] = r.startLine
            }
        }

        var d2o = [Int](repeating: 0, count: count + 1)
        d2o.reserveCapacity(count + 1)
        var o2d = [Int](repeating: 0, count: count + 1)

        var displayed = 0
        // For hidden lines we need to know the displayed line of
        // their carrier. Carrier startLines are themselves visible
        // (never hidden by their own fold — only inside-the-fold lines
        // are hidden). So we can compute o2d for hidden lines on the
        // fly using a running map of original→displayed for visible
        // lines.
        for i in 1...count {
            if !hidden[i] {
                displayed += 1
                if displayed < d2o.count {
                    d2o[displayed] = i
                } else {
                    d2o.append(i)
                }
                o2d[i] = displayed
            } else {
                // Carrier startLine is visible — its `o2d` was set
                // when we processed it on a previous iteration of
                // this loop (since startLine < i for hidden i).
                let cs = carrier[i]
                o2d[i] = (cs > 0 && cs < o2d.count) ? o2d[cs] : displayed
            }
        }

        // Trim d2o to actual displayed length + sentinel.
        d2o = Array(d2o.prefix(displayed + 1))

        return FoldLineMap(
            displayedToOriginal: d2o,
            originalToDisplayed: o2d,
            originalLineCount: count,
            displayedLineCount: displayed
        )
    }

    // MARK: Caret translation

    /// Translate an original-buffer line number into the displayed
    /// buffer. Clamped to `[1, displayedLineCount]`.
    @inlinable
    public func displayedLine(forOriginal original: Int) -> Int {
        let o = max(1, min(originalLineCount, original))
        guard o < originalToDisplayed.count else { return max(1, displayedLineCount) }
        let d = originalToDisplayed[o]
        return d > 0 ? d : 1
    }

    /// Translate a displayed-buffer line number into the canonical
    /// buffer. Clamped to `[1, originalLineCount]`.
    @inlinable
    public func originalLine(forDisplayed displayed: Int) -> Int {
        let d = max(1, min(displayedLineCount, displayed))
        guard d < displayedToOriginal.count else { return max(1, originalLineCount) }
        let o = displayedToOriginal[d]
        return o > 0 ? o : 1
    }

    /// True if original line `o` is hidden inside a currently-collapsed
    /// fold (i.e. the displayed buffer doesn't render it directly).
    @inlinable
    public func isHidden(originalLine o: Int) -> Bool {
        let line = max(1, min(originalLineCount, o))
        guard line < originalToDisplayed.count else { return false }
        // A hidden line maps to the displayed line of its carrier; the
        // carrier's original line ≠ the hidden line.
        let d = originalToDisplayed[line]
        guard d > 0, d < displayedToOriginal.count else { return false }
        return displayedToOriginal[d] != line
    }
}
