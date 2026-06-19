import Foundation

/// Detects and converts *tabular* clipboard payloads into a plain `[[String]]`
/// grid that the CSV/table viewer (`CSVTableView` / `CSVParser`) can consume.
///
/// This is the "is this clipboard payload a table, and if so what are its rows"
/// half of **Universal Paste** (epic TSK-958). It is a pure, dependency-free
/// helper — no `NSPasteboard`, no UI — so the whole detection + extraction path
/// is host-testable. The clipboard read + viewer hand-off live elsewhere; this
/// type only answers "given these bytes, give me the grid".
///
/// Two input shapes are supported, mirroring what a browser/spreadsheet puts on
/// the pasteboard when you copy a table:
///
///  * **HTML** — `public.html` flavour, an `<table>` with `<tr>` rows and
///    `<td>`/`<th>` cells. Cells routinely contain nested formatting
///    (`<b>`, `<a>`, `<span style=…>`, `<br>`), entity-encoded text
///    (`&amp;`, `&#39;`), and `colspan`/`rowspan` attributes.
///  * **TSV** — `public.utf8-tab-separated-values` flavour (or just tab-
///    delimited text), the lossy plain-text fallback the same copy produces.
///
/// Cell text is extracted by stripping inner markup, decoding HTML entities
/// (`TextTools.htmlDecode`), and collapsing runs of whitespace — the same
/// "rendered text" a human would see in the cell, not the raw markup.
///
/// **Not a security boundary.** Like `HTMLSanitizer`, this is a forgiving
/// tag-walker, not a DOM. It never executes anything and only ever produces
/// `String` cell values, so the residual surface is "weirdly-shaped grid",
/// which the downstream CSV view already tolerates (ragged rows, caps).
public enum ClipboardTableExtractor {

    /// Bounds guarding against degenerate input. The HTML walker is linear in
    /// the source length, but a pathological payload (millions of empty `<tr>`s)
    /// could still materialize an enormous grid; these cap the output the same
    /// way `CSVParser.Limits` caps the parsed table.
    public struct Limits: Sendable {
        /// Max rows extracted from a single `<table>`. Excess `<tr>`s are dropped.
        public var maxRows: Int
        /// Max cells per row. Excess `<td>`/`<th>` past this are dropped.
        public var maxCellsPerRow: Int
        /// Max characters kept per cell (after entity decode + whitespace
        /// collapse). A runaway cell is cut with a trailing "…".
        public var maxCellChars: Int

        public init(maxRows: Int = 1_000_000,
                    maxCellsPerRow: Int = 4096,
                    maxCellChars: Int = 64 * 1024) {
            self.maxRows = maxRows
            self.maxCellsPerRow = maxCellsPerRow
            self.maxCellChars = maxCellChars
        }
    }

    // MARK: - Detection

    /// Whether `html` contains an HTML `<table>` element. Case-insensitive,
    /// requires a real `<table` open tag with a word boundary after the name
    /// (so `<tablexyz>` / a bare "table" in prose does NOT match). Used to
    /// decide whether the HTML pasteboard flavour is worth extracting before
    /// falling back to the TSV / plain-text flavour.
    public static func detectTable(html: String) -> Bool {
        firstOpenTag(named: "table", in: html, from: html.startIndex) != nil
    }

    // MARK: - HTML → rows

    /// Extract the first `<table>`'s rows as a `[[String]]` grid. Each inner
    /// array is one `<tr>`; each element is one `<td>`/`<th>` cell's rendered
    /// text. Returns `[]` when there is no `<table>` (callers should gate on
    /// `detectTable` first, but this is independently safe).
    ///
    /// Semantics:
    ///  * Only the FIRST `<table>` is read (clipboard copies are a single
    ///    table; a nested table's cells fold into the outer cell's text).
    ///  * `<th>` and `<td>` are treated identically — both are cells. The
    ///    header row, if any, is just the first `<tr>`; this helper does not
    ///    distinguish it (the CSV viewer treats row 0 as the header).
    ///  * `colspan` / `rowspan` are **ignored** — a `colspan=3` cell yields a
    ///    single cell, leaving the row narrower than its spanned width. This is
    ///    "ignored-but-safe": no crash, no phantom cells; rows stay ragged and
    ///    the downstream parser pads/truncates against the header.
    ///  * Cell text is the concatenation of all text nodes inside the cell,
    ///    with nested tags stripped, entities decoded, and whitespace runs
    ///    collapsed to single spaces (then trimmed). A `<br>` becomes a space.
    public static func htmlTableToRows(_ html: String,
                                       limits: Limits = Limits()) -> [[String]] {
        guard let tableOpen = firstOpenTag(named: "table", in: html,
                                           from: html.startIndex)
        else { return [] }

        // The table body runs from just past the open tag to the matching
        // </table> (or end-of-string if the close is missing/malformed).
        let bodyStart = html.index(after: tableOpen.end)
        let bodyEnd = firstCloseTag(named: "table", in: html, from: bodyStart)
            .map(\.lowerBound) ?? html.endIndex
        guard bodyStart <= bodyEnd else { return [] }
        let body = html[bodyStart..<bodyEnd]

        var rows: [[String]] = []
        var i = body.startIndex
        while i < body.endIndex {
            guard let trOpen = firstOpenTag(named: "tr", in: body, from: i)
            else { break }
            let rowStart = body.index(after: trOpen.end)
            // A row ends at its </tr>, or at the START of the next <tr>
            // (unclosed row), or at the end of the table body — whichever
            // comes first.
            let closeTr = firstCloseTag(named: "tr", in: body, from: rowStart)
            let nextTr = firstOpenTag(named: "tr", in: body, from: rowStart)
            let rowEnd = [closeTr?.lowerBound, nextTr?.start]
                .compactMap { $0 }
                .min() ?? body.endIndex

            let cells = extractCells(in: body[rowStart..<rowEnd], limits: limits)
            if !cells.isEmpty {
                rows.append(cells)
                if rows.count >= limits.maxRows { break }
            }
            // Advance past whichever boundary we used: past </tr> if present,
            // else to the next row's `<tr>` start (rowEnd), making forward
            // progress in both branches.
            i = (closeTr.map(\.upperBound)).map { Swift.min($0, body.endIndex) }
                ?? rowEnd
            if i <= rowStart { i = body.index(after: rowStart) }   // guard
        }
        return rows
    }

    // MARK: - TSV → rows

    /// Parse tab-separated text into a `[[String]]` grid, honoring RFC-4180
    /// quoting via `CSVParser` (a quoted cell may contain embedded tabs /
    /// newlines, `""` escapes a literal quote). The returned grid is
    /// `[header] + rows` — i.e. the full table including the first row — so it
    /// composes with `htmlTableToRows`, which also returns every row.
    ///
    /// Empty input → `[]`.
    public static func tsvToRows(_ text: String,
                                 limits: Limits = Limits()) -> [[String]] {
        guard !text.isEmpty else { return [] }
        let parsed = CSVParser.parse(
            text,
            delimiter: "\t",
            limits: CSVParser.Limits(maxCellChars: limits.maxCellChars,
                                     maxCellsPerRow: limits.maxCellsPerRow)
        )
        guard !parsed.header.isEmpty || !parsed.rows.isEmpty else { return [] }
        var grid = [parsed.header]
        grid.append(contentsOf: parsed.rows)
        if grid.count > limits.maxRows {
            grid = Array(grid.prefix(limits.maxRows))
        }
        return grid
    }

    // MARK: - Cell extraction

    /// Pull every `<td>`/`<th>` cell's rendered text out of one row's inner
    /// HTML (the slice between `<tr>` and `</tr>`).
    private static func extractCells(in row: Substring,
                                     limits: Limits) -> [String] {
        var cells: [String] = []
        var i = row.startIndex
        while i < row.endIndex {
            // Find the next cell open tag (td or th), whichever starts first.
            let td = firstOpenTag(named: "td", in: row, from: i)
            let th = firstOpenTag(named: "th", in: row, from: i)
            let candidates = [td, th].compactMap { $0 }
            guard let cellOpen = candidates.min(by: { $0.start < $1.start })
            else { break }
            let name = (th != nil && (td == nil || th!.start < td!.start))
                ? "th" : "td"

            let contentStart = row.index(after: cellOpen.end)
            // The cell ends at its matching close, or at the START of the next
            // cell of either kind (unclosed cell), or end-of-row.
            let close = firstCloseTag(named: name, in: row, from: contentStart)
            let nextTd = firstOpenTag(named: "td", in: row, from: contentStart)
            let nextTh = firstOpenTag(named: "th", in: row, from: contentStart)
            let contentEnd = [close?.lowerBound, nextTd?.start, nextTh?.start]
                .compactMap { $0 }
                .min() ?? row.endIndex

            let text = renderedText(in: row[contentStart..<contentEnd],
                                    maxChars: limits.maxCellChars)
            cells.append(text)
            if cells.count >= limits.maxCellsPerRow { break }

            // Advance past </name> if present, else to the next cell's start
            // (contentEnd). Guard guarantees forward progress.
            i = (close.map(\.upperBound)).map { Swift.min($0, row.endIndex) }
                ?? contentEnd
            if i <= contentStart { i = row.index(after: contentStart) }
        }
        return cells
    }

    /// Strip all tags from `fragment`, decode HTML entities, collapse internal
    /// whitespace to single spaces, and trim — the text a human sees in the
    /// cell. `<br>` (and any other tag) becomes a whitespace boundary so
    /// "line1<br>line2" reads as "line1 line2".
    private static func renderedText(in fragment: Substring,
                                     maxChars: Int) -> String {
        var stripped = ""
        stripped.reserveCapacity(fragment.count)
        var i = fragment.startIndex
        while i < fragment.endIndex {
            if fragment[i] == "<", let end = tagEnd(in: fragment, from: i) {
                // Replace the tag with a space so adjacent text from different
                // inline elements doesn't run together (b</b><b>c → "b c"…
                // collapses back to "bc"? no: tags between letters become a
                // space, which the collapse below keeps only if it separates
                // non-space text). Use a space; the collapse handles dupes.
                stripped.append(" ")
                i = fragment.index(after: end)
            } else {
                stripped.append(fragment[i])
                i = fragment.index(after: i)
            }
        }
        let decoded = TextTools.htmlDecode(stripped)
        let collapsed = collapseWhitespace(decoded)
        if collapsed.count > maxChars {
            return String(collapsed.prefix(maxChars)) + "…"
        }
        return collapsed
    }

    /// Collapse runs of any whitespace (incl. newlines/tabs) to a single space
    /// and trim leading/trailing.
    private static func collapseWhitespace(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var lastWasSpace = false
        for ch in s {
            if ch == " " || ch == "\t" || ch == "\n" || ch == "\r"
                || ch.isWhitespace {
                if !lastWasSpace { out.append(" "); lastWasSpace = true }
            } else {
                out.append(ch)
                lastWasSpace = false
            }
        }
        // Trim the single leading/trailing space the collapse may have left.
        if out.hasPrefix(" ") { out.removeFirst() }
        if out.hasSuffix(" ") { out.removeLast() }
        return out
    }

    // MARK: - Tag scanning (quote-aware, mirrors HTMLSanitizer)

    /// Find the first `<name …>` open tag at or after `from` (case-insensitive,
    /// word-boundary after the name, quote-aware close-`>`). Returns BOTH the
    /// `<` start index and the closing `>` index — callers need `start` as a
    /// content boundary (where the previous cell/row ends) and `end` to advance
    /// past the open tag. `nil` if none.
    private static func firstOpenTag<S: StringProtocol>(
        named name: String, in source: S, from: S.Index
    ) -> (start: S.Index, end: S.Index)? where S.Index == String.Index {
        var i = from
        while i < source.endIndex {
            guard source[i] == "<" else { i = source.index(after: i); continue }
            if let end = matchOpenTag(named: name, in: source, at: i) {
                return (start: i, end: end)
            }
            i = source.index(after: i)
        }
        return nil
    }

    /// If a `<name …>` open tag starts exactly at `start`, return the index of
    /// its closing `>` (quote-aware); else `nil`.
    private static func matchOpenTag<S: StringProtocol>(
        named name: String, in source: S, at start: S.Index
    ) -> S.Index? where S.Index == String.Index {
        var i = source.index(after: start)   // skip '<'
        for ch in name {
            guard i < source.endIndex,
                  source[i].lowercased() == String(ch)
            else { return nil }
            i = source.index(after: i)
        }
        // Word boundary: next char must NOT continue an HTML name.
        if i < source.endIndex {
            let c = source[i]
            if c.isLetter || c.isNumber || c == "-" || c == "_" || c == ":" {
                return nil
            }
        }
        return tagEnd(in: source, from: start)
    }

    /// Find the first `</name …>` close tag at or after `from` (case-
    /// insensitive, quote-aware), returning the range covering `<` … `>`.
    private static func firstCloseTag<S: StringProtocol>(
        named name: String, in source: S, from: S.Index
    ) -> Range<S.Index>? where S.Index == String.Index {
        var i = from
        while i < source.endIndex {
            guard source[i] == "<" else { i = source.index(after: i); continue }
            var j = source.index(after: i)        // skip '<'
            guard j < source.endIndex, source[j] == "/" else {
                i = source.index(after: i); continue
            }
            j = source.index(after: j)            // skip '/'
            var matched = true
            for ch in name {
                guard j < source.endIndex,
                      source[j].lowercased() == String(ch)
                else { matched = false; break }
                j = source.index(after: j)
            }
            if matched, let end = tagEnd(in: source, from: i) {
                // Only whitespace allowed between the name and the `>`.
                var k = j, ok = true
                while k < end {
                    let c = source[k]
                    if !(c == " " || c == "\t" || c == "\n" || c == "\r") {
                        ok = false; break
                    }
                    k = source.index(after: k)
                }
                if ok { return i..<source.index(after: end) }
            }
            i = source.index(after: i)
        }
        return nil
    }

    /// Index of the `>` that closes the tag opened at `start`, skipping any `>`
    /// inside a `"…"`/`'…'` attribute value. `nil` if never closed.
    private static func tagEnd<S: StringProtocol>(
        in source: S, from start: S.Index
    ) -> S.Index? where S.Index == String.Index {
        var i = source.index(after: start)   // skip '<'
        var quote: Character? = nil
        while i < source.endIndex {
            let c = source[i]
            if let q = quote {
                if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == ">" {
                return i
            }
            i = source.index(after: i)
        }
        return nil
    }
}
