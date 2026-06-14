import Foundation

/// Pure logic for "sticky scroll" (TSK-719): given a document's fold regions and
/// the editor's top-visible line, compute the chain of enclosing scope headers
/// to PIN at the top of the viewport (outermost → innermost), VS Code-style.
///
/// Host-testable: takes plain values (fold regions + a line number + the
/// document text), returns plain values. The pinned bar that renders these is
/// the VM-only render tail.
public enum StickyScrollHeaders {

    /// One header to pin: the 1-based source line of an enclosing region, its
    /// trimmed text (what the bar shows), and the fold kind (for an icon/style).
    public struct Header: Equatable, Sendable {
        public let line: Int            // 1-based start line of the region
        public let text: String         // trimmed source-line text
        public let kind: FoldRegion.Kind

        public init(line: Int, text: String, kind: FoldRegion.Kind) {
            self.line = line
            self.text = text
            self.kind = kind
        }
    }

    /// Fold kinds that name a scope worth pinning — a function/type/heading/
    /// element line answers "where am I". A brace-pair object/array, a comment,
    /// a multi-line string, or a markdown code fence does not, so they're
    /// excluded (pinning them is noise).
    public static let headerKinds: Set<FoldRegion.Kind> = [
        .function, .type, .heading, .element,
    ]

    /// The enclosing regions to pin for `viewportTopLine`, outermost → innermost.
    ///
    /// A region qualifies when (a) its kind is a scope header, (b) it CONTAINS
    /// the top line, and (c) its own header line has scrolled ABOVE the viewport
    /// (`startLine < viewportTopLine`) — a header still on screen needs no pin.
    /// Ordering: all qualifiers contain the top line, so the smallest `startLine`
    /// is the outermost; ties break by the larger span (more enclosing). On
    /// overflow past `maxDepth` the OUTERMOST are kept (the file→type→method
    /// breadcrumb is the useful context).
    public static func pinnedRegions(
        foldRegions: [FoldRegion],
        viewportTopLine: Int,
        kinds: Set<FoldRegion.Kind> = headerKinds,
        maxDepth: Int = 5
    ) -> [FoldRegion] {
        guard viewportTopLine > 0, maxDepth > 0 else { return [] }
        let enclosing = foldRegions.filter { r in
            kinds.contains(r.kind)
                && r.startLine < viewportTopLine
                && viewportTopLine <= r.endLine
        }
        let ordered = enclosing.sorted { a, b in
            a.startLine != b.startLine ? a.startLine < b.startLine
                                       : a.endLine > b.endLine
        }
        return ordered.count > maxDepth ? Array(ordered.prefix(maxDepth)) : ordered
    }

    /// `pinnedRegions` resolved to renderable `Header`s by pulling each region's
    /// start-line text out of `documentText`. A region whose start line is out
    /// of range (text changed under a stale fold set) is dropped rather than
    /// crashing. Extraction is a single bounded pass over the needed lines, not
    /// a full `split` per call.
    public static func headers(
        foldRegions: [FoldRegion],
        viewportTopLine: Int,
        documentText: String,
        kinds: Set<FoldRegion.Kind> = headerKinds,
        maxDepth: Int = 5
    ) -> [Header] {
        let regions = pinnedRegions(
            foldRegions: foldRegions, viewportTopLine: viewportTopLine,
            kinds: kinds, maxDepth: maxDepth)
        guard !regions.isEmpty else { return [] }
        let wanted = Set(regions.map(\.startLine))
        let byLine = lineText(for: wanted, in: documentText)
        return regions.compactMap { r in
            guard let raw = byLine[r.startLine] else { return nil }
            return Header(line: r.startLine,
                          text: raw.trimmingCharacters(in: .whitespaces),
                          kind: r.kind)
        }
    }

    /// Extract the text of specific 1-based line numbers from `text` in ONE
    /// pass, collecting only the requested lines (avoids materializing every
    /// line of a large document on each scroll tick). Uses `Character.isNewline`
    /// as the line separator — which correctly treats a `\r\n` as a SINGLE
    /// grapheme cluster (Swift merges CRLF into one `Character`, so a naive
    /// `== "\n"` scan would never fire), plus lone `\r` and Unicode line
    /// separators — so the captured line text carries no carriage return.
    static func lineText(for lines: Set<Int>, in text: String) -> [Int: String] {
        guard !lines.isEmpty, let maxLine = lines.max(), maxLine > 0 else { return [:] }
        var out: [Int: String] = [:]
        var current = 1
        var start = text.startIndex
        var i = text.startIndex
        while i < text.endIndex {
            if text[i].isNewline {
                if lines.contains(current) {
                    out[current] = String(text[start..<i])
                }
                current += 1
                if current > maxLine { return out }  // past the last wanted line
                start = text.index(after: i)
            }
            i = text.index(after: i)
        }
        // Final line (no trailing newline).
        if current <= maxLine, lines.contains(current) {
            out[current] = String(text[start..<text.endIndex])
        }
        return out
    }
}
