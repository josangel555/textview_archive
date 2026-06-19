import Foundation

/// TSK-704 — side-by-side markdown editor + live preview, foundation slice.
///
/// The side-by-side feature needs a **scroll-sync model**: when the user scrolls
/// (or moves the caret) in the editor, the preview should follow to the matching
/// rendered region, and vice-versa. The two surfaces measure position in
/// different units — the editor in **source line numbers**, the preview in
/// **rendered DOM blocks** — so something has to translate between them.
///
/// This file is that translator: a pure, no-UI value type that, given the
/// markdown source, computes a bidirectional map between **source line** and
/// **rendered top-level block ordinal**. The UI tail (the synced split + the
/// WKWebView scroll bridge) consumes this map; the map itself is host-testable.
///
/// ## Why ordinal alignment (not source positions)
///
/// `HTMLRenderer` does NOT emit `sourcepos`/`data-source-line` attributes, so we
/// can't read a block's origin line off the rendered HTML. Instead we parse the
/// **source** into its own top-level blocks (one per heading / paragraph /
/// fenced-code / list / table / blockquote / thematic-break run, separated by
/// blank lines — the same block grain `RenderedBlockDiff.splitBlocks` produces
/// from the rendered side) and align the two lists **positionally**: the N-th
/// source block corresponds to the N-th rendered block. Both the source parser
/// here and the renderer walk the document in order and emit one top-level block
/// per logical construct, so the ordinals line up for the common document. Where
/// the counts diverge (e.g. a source construct the renderer folds away), the map
/// clamps to the shorter list rather than mis-pairing — a graceful v1 degrade,
/// not a correctness claim of 1:1 for every exotic input.
///
/// ## Inverse property
///
/// `block(forLine:)` then `line(forBlock:)` returns the block's **first source
/// line** (canonical representative), so the round-trip is stable: any line
/// inside block K maps to K, and K maps back to its start line, which maps to K
/// again. `line(forBlock:)` then `block(forLine:)` is the identity on valid
/// block indices. Out-of-range inputs clamp to the nearest valid block/line.
public struct MarkdownPreviewMap: Equatable, Sendable {

    /// One top-level source block and the rendered-block ordinal it maps to.
    public struct Entry: Equatable, Sendable {
        /// 1-based first source line of the block (the line the editor scrolls
        /// to when the preview anchors on this block).
        public let startLine: Int
        /// 1-based last source line of the block (inclusive). A line in
        /// `startLine...endLine` resolves to this block's `blockIndex`.
        public let endLine: Int
        /// 0-based ordinal of the matching rendered block (index into the
        /// `RenderedBlockDiff.splitBlocks` / preview DOM block list).
        public let blockIndex: Int

        public init(startLine: Int, endLine: Int, blockIndex: Int) {
            self.startLine = startLine
            self.endLine = endLine
            self.blockIndex = blockIndex
        }
    }

    /// Source-block → rendered-block entries, in ascending `startLine` /
    /// `blockIndex` order (they advance together).
    public let entries: [Entry]
    /// Total source line count (for clamping line queries).
    public let lineCount: Int
    /// Total rendered block count (for clamping block queries).
    public let blockCount: Int

    public init(entries: [Entry], lineCount: Int, blockCount: Int) {
        self.entries = entries
        self.lineCount = lineCount
        self.blockCount = blockCount
    }

    /// Build the map from markdown `source` and the rendered `blockCount`
    /// (`RenderedBlockDiff.splitBlocks(renderer.render(source)).count`). Passing
    /// the rendered count lets the map cap the ordinal alignment to what the
    /// preview actually shows; pass `nil` to align purely on the parsed source
    /// blocks (every source block gets a sequential ordinal).
    public static func build(source: String, renderedBlockCount: Int? = nil) -> MarkdownPreviewMap {
        let lines = splitLines(source)
        let lineCount = max(1, lines.count)
        let sourceBlocks = sourceBlockRanges(lines)
        // Align positionally; cap at the rendered count so we never point the
        // preview at a block index that doesn't exist.
        let cap = renderedBlockCount ?? sourceBlocks.count
        var entries: [Entry] = []
        var idx = 0
        for range in sourceBlocks {
            guard idx < cap else { break }
            entries.append(Entry(startLine: range.start, endLine: range.end, blockIndex: idx))
            idx += 1
        }
        let blockCount = renderedBlockCount ?? sourceBlocks.count
        return MarkdownPreviewMap(entries: entries, lineCount: lineCount, blockCount: blockCount)
    }

    // MARK: - Queries

    /// The rendered-block ordinal a given 1-based editor `line` maps to.
    ///
    /// A line inside a block's range resolves to that block. A line in the
    /// blank gap BETWEEN two blocks resolves to the FOLLOWING block (the user
    /// scrolling past a paragraph wants the preview anchored on what comes
    /// next). A line before the first block or past the last clamps to the
    /// first/last block. Returns `nil` only when there are no blocks at all.
    public func block(forLine line: Int) -> Int? {
        guard let first = entries.first, let last = entries.last else { return nil }
        let clamped = min(max(line, 1), max(lineCount, 1))
        if clamped <= first.startLine { return first.blockIndex }
        if clamped >= last.startLine {
            // Past the last block's start: still the last block (it owns the
            // tail of the document).
            if clamped > last.endLine { return last.blockIndex }
        }
        for (i, e) in entries.enumerated() {
            if clamped >= e.startLine && clamped <= e.endLine {
                return e.blockIndex
            }
            // In the gap before this block (after the previous block's end):
            // anchor on this (the following) block.
            if clamped < e.startLine {
                return e.blockIndex
            }
            _ = i
        }
        return last.blockIndex
    }

    /// The 1-based source line a given 0-based rendered `block` ordinal maps to
    /// — the block's FIRST source line (canonical representative for the inverse
    /// round-trip). Out-of-range ordinals clamp to the first/last block.
    /// Returns `nil` only when there are no blocks.
    public func line(forBlock block: Int) -> Int? {
        guard let first = entries.first, let last = entries.last else { return nil }
        if block <= first.blockIndex { return first.startLine }
        if block >= last.blockIndex { return last.startLine }
        for e in entries where e.blockIndex == block {
            return e.startLine
        }
        // No exact ordinal match (a gap in the alignment): clamp to the nearest
        // lower block's start line.
        var best = first
        for e in entries where e.blockIndex <= block { best = e }
        return best.startLine
    }

    // MARK: - Source block parsing

    /// 1-based inclusive line range of one top-level source block.
    struct SourceRange: Equatable {
        let start: Int
        let end: Int
    }

    /// Split `source` into its UnicodeScalar-LF-delimited lines (NOT
    /// `Character.split`, which folds a `\r\n` grapheme into a single Character
    /// and would miscount — the `IndentDetector` / `MarkdownOutline` trap). A
    /// CRLF line ends with a lone `\r` scalar, which the block scanner trims.
    static func splitLines(_ source: String) -> [String] {
        var out: [String] = []
        var cur = String.UnicodeScalarView()
        for u in source.unicodeScalars {
            if u == "\n" { out.append(String(cur)); cur = String.UnicodeScalarView() }
            else { cur.append(u) }
        }
        out.append(String(cur))
        return out
    }

    /// Partition the source `lines` into top-level block line ranges, the same
    /// grain the renderer emits: blank lines separate blocks, a fenced code
    /// block is one block (its inner blank lines don't split it), and a run of
    /// consecutive non-blank lines is one block (paragraph / list / table /
    /// blockquote). A thematic break (`---`/`***`/`___`) and an ATX heading are
    /// each their own single-line block. Setext underlines stay attached to the
    /// paragraph they convert (one block).
    ///
    /// This intentionally mirrors `MarkdownOutline`'s fence handling and the
    /// renderer's block grain rather than being a full CommonMark block parser:
    /// the goal is line↔block ordinal alignment for scroll-sync, not a second
    /// authoritative parse.
    static func sourceBlockRanges(_ lines: [String]) -> [SourceRange] {
        var ranges: [SourceRange] = []
        var i = 0
        let n = lines.count

        // Skip a leading YAML front-matter block so it doesn't become a phantom
        // first block (it renders to nothing).
        if let first = lines.first,
           first.trimmingCharacters(in: .whitespaces) == "---" {
            var k = 1
            while k < n {
                let t = lines[k].trimmingCharacters(in: .whitespaces)
                if t == "---" || t == "..." { i = k + 1; break }
                k += 1
            }
        }

        while i < n {
            let trimmed = trimLine(lines[i])
            // Skip blank separators between blocks.
            if trimmed.isEmpty { i += 1; continue }

            let blockStart = i

            // Fenced code block: consume through the closing fence (or EOF).
            if let (marker, len) = fenceRun(trimmed) {
                i += 1
                while i < n {
                    let t = trimLine(lines[i])
                    if let (m2, l2) = fenceRun(t), m2 == marker, l2 >= len {
                        i += 1
                        break
                    }
                    i += 1
                }
                ranges.append(SourceRange(start: blockStart + 1, end: i))
                continue
            }

            // ATX heading: its own single-line block.
            if isATXHeading(trimmed) {
                ranges.append(SourceRange(start: blockStart + 1, end: blockStart + 1))
                i += 1
                continue
            }

            // Thematic break: its own single-line block.
            if isThematicBreak(trimmed) {
                ranges.append(SourceRange(start: blockStart + 1, end: blockStart + 1))
                i += 1
                continue
            }

            // Otherwise: a run of consecutive non-blank lines (paragraph, list,
            // table, blockquote, setext heading+underline) terminated by a
            // blank line, a fence, or an ATX heading. NOTE: a thematic-break-
            // looking line (`---`/`***`/`___`) does NOT break the run here — a
            // `---` immediately after a paragraph line is a *setext underline*
            // (one block with the paragraph), which the renderer also treats as
            // a single block. A standalone thematic break is only reached at a
            // block START (handled by the branch above), where the preceding
            // blank line already terminated any paragraph.
            i += 1
            while i < n {
                let t = trimLine(lines[i])
                if t.isEmpty { break }
                if fenceRun(t) != nil { break }
                if isATXHeading(t) { break }
                i += 1
            }
            ranges.append(SourceRange(start: blockStart + 1, end: i))
        }
        return ranges
    }

    // MARK: - Line classification helpers (mirror MarkdownOutline)

    private static func trimLine(_ line: String) -> String {
        var s = line
        if s.hasSuffix("\r") { s.removeLast() }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// `=`/`~` fence run of ≥3 → (marker, length); else nil.
    private static func fenceRun(_ trimmed: String) -> (Character, Int)? {
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        let run = trimmed.prefix { $0 == first }
        guard run.count >= 3 else { return nil }
        return (first, run.count)
    }

    /// ATX heading: leading run of 1...6 `#`, then a space or end-of-line.
    private static func isATXHeading(_ trimmed: String) -> Bool {
        guard trimmed.first == "#" else { return false }
        let hashes = trimmed.prefix { $0 == "#" }
        let level = hashes.count
        guard level >= 1, level <= 6 else { return false }
        let after = trimmed.dropFirst(level)
        return after.isEmpty || after.first == " " || after.first == "\t"
    }

    /// Thematic break: a line of ≥3 of `-`, `*`, or `_` (CommonMark allows
    /// interspersed spaces). NOT a setext underline (those attach to a
    /// preceding paragraph, handled by the run-consuming branch).
    private static func isThematicBreak(_ trimmed: String) -> Bool {
        for marker: Character in ["-", "*", "_"] {
            let stripped = trimmed.filter { $0 != " " && $0 != "\t" }
            if stripped.count >= 3 && stripped.allSatisfy({ $0 == marker }) {
                return true
            }
        }
        return false
    }
}
