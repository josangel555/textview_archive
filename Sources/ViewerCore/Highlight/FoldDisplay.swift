import Foundation

/// Builds the *displayed* text + a parallel `FoldLineMap` from a
/// canonical source string and a `FoldState`.
///
/// The output text replaces each collapsed region's body (everything
/// after its `startLine`'s leading content, up to and including its
/// `endLine`'s last character) with a single ellipsis marker `{…}`.
/// The marker character sequence is fixed; the source view layer is
/// responsible for swapping the marker for an `NSTextAttachment` (or
/// applying `.tertiaryLabelColor`) when it renders.
///
/// Why a String marker rather than emitting the attachment here:
/// `NSTextAttachment` is AppKit-only; this type lives in ViewerCore so
/// it stays UI-framework-neutral and trivially testable.
public enum FoldDisplay {

    /// Marker that gets inserted at the end of every collapsed fold's
    /// start line. The source-view layer can locate these by string
    /// search if it needs to convert them to attachments. Chosen so the
    /// substring never appears in normal source code (HORIZONTAL
    /// ELLIPSIS U+2026, surrounded by braces).
    public static let ellipsisMarker: String = "{\u{2026}}"

    /// Result of a build pass.
    public struct Result: Equatable {
        public let displayedText: String
        public let lineMap: FoldLineMap
        /// 1-based displayed-line numbers that carry an ellipsis marker.
        /// Useful for the source-view layer to apply attribute styling
        /// (`.tertiaryLabelColor`) and click-to-expand hit testing.
        public let ellipsisDisplayedLines: [Int]
    }

    /// Build the displayed text + line map.
    ///
    /// Performance: one pass over `text` splitting on `\n`, plus one
    /// O(N+R) pass to build the map. Allocations: one `[Substring]`
    /// (line slices) and the output `String` (≤ length of canonical).
    /// For a 100K-line file this completes in low-single-digit ms.
    ///
    /// Behavior:
    /// - If `state.collapsed.isEmpty`, returns the canonical text +
    ///   identity line map. Cheap fast path — production hits this
    ///   on every keystroke when nothing is folded.
    /// - Overlapping / nested collapsed folds: a line is hidden if any
    ///   collapsed region hides it. The ellipsis appears at the start
    ///   line of the outermost active fold to avoid double-ellipsis.
    public static func build(text: String, state: FoldState) -> Result {
        // Fast path: nothing collapsed.
        if state.collapsed.isEmpty {
            let lines = splitLines(text)
            let map = FoldLineMap.identity(lineCount: lines.count)
            return Result(
                displayedText: text,
                lineMap: map,
                ellipsisDisplayedLines: []
            )
        }

        let lines = splitLines(text)
        let total = lines.count

        // Determine which lines are hidden + which lines carry the
        // ellipsis. Outermost fold carries — innermost folds are
        // entirely inside the outer's hidden range, so their start
        // line is itself hidden.
        var hidden = [Bool](repeating: false, count: total + 2)
        // ellipsisStart[i] = true if line i is the start of a collapsed
        // fold whose start line is NOT itself hidden by a larger fold.
        var ellipsisStart = [Bool](repeating: false, count: total + 2)

        // Sort outer (larger span) first so when we mark hidden lines
        // for nested folds, the outer's hidden range subsumes inner
        // starts cleanly.
        let folds = state.collapsed.sorted { a, b in
            if a.lineCount != b.lineCount { return a.lineCount > b.lineCount }
            return a.startLine < b.startLine
        }
        for r in folds {
            let from = max(1, r.startLine + 1)
            let to   = min(total, r.endLine)
            guard from <= to else { continue }
            for i in from...to { hidden[i] = true }
        }
        for r in folds {
            // Mark the carrier ellipsis only if the start line itself
            // is visible.
            if r.startLine >= 1, r.startLine <= total, !hidden[r.startLine] {
                ellipsisStart[r.startLine] = true
            }
        }

        // Compose displayed text + record displayed-line per original.
        var out: [String] = []
        out.reserveCapacity(total)
        var d2o: [Int] = [0]
        var o2d = [Int](repeating: 0, count: total + 1)
        var ellipsisLines: [Int] = []

        for i in 1...total {
            if hidden[i] { continue }
            let displayedIdx = d2o.count   // 1-based after append
            if ellipsisStart[i] {
                // Append marker; preserve any trailing whitespace the
                // user has on the fold-start line for stable rendering.
                out.append(String(lines[i - 1]) + " " + ellipsisMarker)
                ellipsisLines.append(displayedIdx)
            } else {
                out.append(String(lines[i - 1]))
            }
            d2o.append(i)
            o2d[i] = displayedIdx
        }
        // Backfill o2d for hidden lines to the displayed line of the
        // *innermost* fold's startLine (matches FoldLineMap semantics).
        // Innermost = shortest span; process shortest LAST so inner
        // wins.
        let innerFirst = state.collapsed.sorted {
            if $0.lineCount != $1.lineCount { return $0.lineCount > $1.lineCount }
            return $0.startLine < $1.startLine
        }
        for r in innerFirst {
            let from = max(1, r.startLine + 1)
            let to   = min(total, r.endLine)
            guard from <= to, r.startLine >= 1, r.startLine <= total else { continue }
            // r.startLine might itself be hidden by a larger fold;
            // walk up to the visible carrier in that case.
            var carrierDisplayed = o2d[r.startLine]
            if carrierDisplayed == 0 {
                // Find the displayed line of whichever bigger fold
                // hides r.startLine — its o2d entry was set above.
                // Fall back to last displayed line.
                carrierDisplayed = max(1, d2o.count - 1)
            }
            for i in from...to {
                o2d[i] = carrierDisplayed
            }
        }

        let displayedText = out.joined(separator: "\n")
        let map = FoldLineMap(
            displayedToOriginal: d2o,
            originalToDisplayed: o2d,
            originalLineCount: total,
            displayedLineCount: out.count
        )
        return Result(
            displayedText: displayedText,
            lineMap: map,
            ellipsisDisplayedLines: ellipsisLines
        )
    }

    /// Split on `\n` and return `Substring`s. Preserves a trailing
    /// empty line if `text` ends with `\n`, matching how NSTextView
    /// counts lines (a file with a final newline has N+1 lines, one
    /// of which is empty).
    private static func splitLines(_ text: String) -> [Substring] {
        var lines: [Substring] = []
        lines.reserveCapacity(64)
        var start = text.startIndex
        for i in text.indices {
            if text[i] == "\n" {
                lines.append(text[start..<i])
                start = text.index(after: i)
            }
        }
        // Trailing chunk (may be empty if text ends with \n).
        lines.append(text[start..<text.endIndex])
        return lines
    }
}
