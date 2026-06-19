import CoreGraphics
import Foundation

/// One row in the markdown overview / minimap (TSK-305). The overview is a
/// scaled "satellite map" of the active document drawn top-right, so the
/// reader can see document structure (where the headings are, where the dense
/// prose vs the whitespace gaps fall) at a glance and click to jump.
///
/// A segment is a contiguous block of source lines between consecutive
/// headings (the band that a heading "owns"), plus the body before the first
/// heading. Each segment carries:
///   - the heading that opens it (nil for the pre-first-heading lead-in),
///   - its 1-based start/end line span,
///   - a 0...1 `density` = fraction of non-blank lines in the span. Density is
///     what makes the overview read as a *minimap* rather than a bare TOC:
///     dense prose draws a fuller bar, sparse / whitespace-heavy regions draw
///     a thinner one.
public struct MarkdownOverviewSegment: Equatable, Sendable {
    /// The heading that opens this segment, or nil for the lead-in block
    /// (lines before the first heading). When non-nil, `startLine` equals the
    /// heading's line.
    public let heading: MarkdownHeading?
    /// 1-based first line of the segment (inclusive).
    public let startLine: Int
    /// 1-based last line of the segment (inclusive). For the final segment
    /// this is the document's last line.
    public let endLine: Int
    /// Fraction of non-blank lines in `[startLine, endLine]`, in `0...1`.
    /// A fully-blank span is 0; a span with no blank lines is 1.
    public let density: Double

    public init(heading: MarkdownHeading?, startLine: Int, endLine: Int, density: Double) {
        self.heading = heading
        self.startLine = startLine
        self.endLine = endLine
        self.density = density
    }

    /// Number of lines the segment spans (≥ 1 for any well-formed segment).
    public var lineCount: Int { max(0, endLine - startLine + 1) }
}

/// One drawable band in the overview canvas — a segment projected onto the
/// minimap's vertical extent. `y0`/`y1` are canvas-local points (top-anchored,
/// `y0 < y1`); the renderer fills `[y0, y1]` with an alpha derived from
/// `density` and tints heading bands by level.
public struct MarkdownOverviewBand: Equatable, Sendable {
    public let segment: MarkdownOverviewSegment
    public let y0: CGFloat
    public let y1: CGFloat

    public init(segment: MarkdownOverviewSegment, y0: CGFloat, y1: CGFloat) {
        self.segment = segment
        self.y0 = y0
        self.y1 = y1
    }

    public var height: CGFloat { max(0, y1 - y0) }
}

/// Pure, dependency-free model + geometry for the markdown overview minimap.
/// Separated from the SwiftUI view so the structure detection and the
/// line↔pixel projection are unit-testable without a Canvas (mirrors
/// `FindMinimapLayout` / `MarkdownOutline`).
public enum MarkdownOverview {

    /// Build the overview segments for a markdown document.
    ///
    /// Strategy: split the document at heading boundaries (`MarkdownOutline`).
    /// Each heading opens a segment that runs until the line *before* the next
    /// heading (or EOF). Lines before the first heading form a leading segment
    /// with `heading == nil`. A document with no headings yields a single
    /// lead-in segment spanning the whole file (so the overview still shows a
    /// density bar — it never collapses to empty for non-trivial text).
    ///
    /// - Parameter text: the full document source.
    /// - Returns: segments in document order. Empty only for empty / blank
    ///   input (no lines to map).
    public static func segments(in text: String) -> [MarkdownOverviewSegment] {
        let lines = splitLines(text)
        let total = lines.count
        guard total > 0 else { return [] }
        // Treat a wholly-blank document (empty, or only whitespace across all
        // lines) as having no overview — nothing meaningful to map.
        let anyContent = lines.contains {
            !$0.allSatisfy { $0 == " " || $0 == "\t" || $0 == "\r" }
        }
        guard anyContent else { return [] }

        let headings = MarkdownOutline.headings(in: text)

        // Boundary set: 1-based start lines of each segment, in ascending
        // order. Always begins at line 1 — either the lead-in (heading == nil)
        // or the first heading if it sits on line 1.
        var boundaries: [(line: Int, heading: MarkdownHeading?)] = []
        if (headings.first?.line ?? Int.max) > 1 {
            boundaries.append((1, nil))
        }
        for h in headings {
            // Skip a heading that wouldn't advance the boundary (duplicate /
            // out-of-order line) so spans never collapse to zero or invert.
            if let last = boundaries.last, h.line <= last.line { continue }
            boundaries.append((h.line, h))
        }
        // Defensive: if nothing landed, map the whole doc as one lead-in band.
        if boundaries.isEmpty { boundaries.append((1, nil)) }

        var out: [MarkdownOverviewSegment] = []
        out.reserveCapacity(boundaries.count)
        for (i, b) in boundaries.enumerated() {
            let start = min(max(1, b.line), total)
            let nextStart = (i + 1 < boundaries.count) ? boundaries[i + 1].line : total + 1
            let end = max(start, min(total, nextStart - 1))
            let density = blankDensity(lines: lines, startLine: start, endLine: end)
            out.append(MarkdownOverviewSegment(
                heading: b.heading, startLine: start, endLine: end, density: density))
        }
        return out
    }

    /// Project the segments onto a vertical canvas of `canvasHeight` points.
    /// Each band's pixel height is proportional to its `lineCount` so the
    /// overview is a true scaled map of the document (a long section gets a
    /// taller band). The bands tile `[0, canvasHeight]` with no gaps.
    ///
    /// - Returns: bands in document order. Empty when there are no segments or
    ///   the canvas has no height.
    public static func bands(
        for segments: [MarkdownOverviewSegment],
        canvasHeight: CGFloat
    ) -> [MarkdownOverviewBand] {
        guard !segments.isEmpty, canvasHeight > 0 else { return [] }
        let totalLines = segments.reduce(0) { $0 + max(1, $1.lineCount) }
        guard totalLines > 0 else { return [] }

        var bands: [MarkdownOverviewBand] = []
        bands.reserveCapacity(segments.count)
        var cursorLine = 0
        for seg in segments {
            let lc = max(1, seg.lineCount)
            let y0 = CGFloat(cursorLine) / CGFloat(totalLines) * canvasHeight
            cursorLine += lc
            let y1 = CGFloat(cursorLine) / CGFloat(totalLines) * canvasHeight
            bands.append(MarkdownOverviewBand(
                segment: seg,
                y0: max(0, min(canvasHeight, y0)),
                y1: max(0, min(canvasHeight, y1))))
        }
        return bands
    }

    /// Click→line: given a y-coordinate (canvas-local points) on the overview,
    /// return the 1-based document line to scroll to. We map proportionally
    /// within the band the click landed in (so clicking the top of a section
    /// jumps to its start, the middle to its middle), giving a smooth
    /// scrollbar-like feel rather than snapping to band starts.
    ///
    /// - Returns: a 1-based line, clamped to the document; nil when there are
    ///   no bands.
    public static func line(
        atY clickY: CGFloat,
        bands: [MarkdownOverviewBand]
    ) -> Int? {
        guard let first = bands.first, let last = bands.last else { return nil }
        let lastLine = last.segment.endLine
        if clickY <= first.y0 { return first.segment.startLine }
        if clickY >= last.y1 { return lastLine }
        for band in bands {
            if clickY >= band.y0 && clickY <= band.y1 {
                let h = band.height
                guard h > 0 else { return band.segment.startLine }
                let frac = (clickY - band.y0) / h
                let span = band.segment.endLine - band.segment.startLine
                let line = band.segment.startLine + Int((frac * CGFloat(span)).rounded())
                return min(lastLine, max(1, line))
            }
        }
        // Between bands (rounding gap): fall back to the nearest band start.
        return first.segment.startLine
    }

    /// Project a 1-based document line onto a y-position in the overview (the
    /// inverse used to draw a "you are here" viewport marker). Returns nil when
    /// there are no bands.
    public static func y(
        forLine line: Int,
        bands: [MarkdownOverviewBand]
    ) -> CGFloat? {
        guard let first = bands.first, let last = bands.last else { return nil }
        let clamped = max(1, line)
        for band in bands {
            if clamped >= band.segment.startLine && clamped <= band.segment.endLine {
                let span = band.segment.endLine - band.segment.startLine
                guard span > 0 else { return band.y0 }
                let frac = CGFloat(clamped - band.segment.startLine) / CGFloat(span)
                return band.y0 + frac * band.height
            }
        }
        // Before line 1 → top; past EOF → bottom.
        if clamped < first.segment.startLine { return first.y0 }
        return last.y1
    }

    // MARK: - helpers

    /// Fraction of non-blank lines in the 1-based inclusive span. A line is
    /// "blank" if it contains only whitespace. Empty span → 0.
    static func blankDensity(lines: [String], startLine: Int, endLine: Int) -> Double {
        let lo = max(1, startLine)
        let hi = min(lines.count, endLine)
        guard hi >= lo else { return 0 }
        var nonBlank = 0
        for i in (lo - 1)...(hi - 1) {
            if !lines[i].allSatisfy({ $0 == " " || $0 == "\t" || $0 == "\r" }) {
                nonBlank += 1
            }
        }
        let count = hi - lo + 1
        return count > 0 ? Double(nonBlank) / Double(count) : 0
    }

    /// Split on the LF scalar (NOT `Character.split`, which collapses CRLF into
    /// a single grapheme and miscounts lines — the `MarkdownOutline` /
    /// `IndentDetector` trap). Mirrors `MarkdownOutline.headings`' splitter so
    /// line numbers line up exactly between the two.
    private static func splitLines(_ text: String) -> [String] {
        var rawLines: [String] = []
        var cur = String.UnicodeScalarView()
        for u in text.unicodeScalars {
            if u == "\n" {
                rawLines.append(String(cur))
                cur = String.UnicodeScalarView()
            } else {
                cur.append(u)
            }
        }
        rawLines.append(String(cur))
        return rawLines
    }
}
