import Foundation

/// Minimal RFC 4180-ish CSV parser. Handles:
///   - comma / tab / semicolon / pipe delimiters (auto-detected)
///   - double-quoted fields with embedded delimiters / newlines
///   - escaped quotes inside quoted fields (`""`)
///   - CRLF or LF line endings
///   - trailing empty fields
///
/// Does NOT handle:
///   - per-column type inference (everything is String)
///   - locale-specific number / date parsing
///   - alternative quote characters (single quotes, etc.)
///   - BOM stripping (caller normalizes input encoding)
///
/// Output: `(header: [String], rows: [[String]])`. If the input is
/// header-less the first row is still treated as the header — the
/// table view shows it as bold and the user can hover to see "Row 1".
public enum CSVParser {

    public struct Result: Equatable, Sendable {
        public let delimiter: Character
        public let header: [String]
        public let rows: [[String]]
        /// `true` when one of the `Limits` caps fired and the table was
        /// truncated / a cell was clamped. UI can surface a "malformed
        /// or oversized CSV — showing a partial view" banner (PARSE-04).
        public let truncated: Bool
        public init(delimiter: Character, header: [String], rows: [[String]],
                    truncated: Bool = false) {
            self.delimiter = delimiter
            self.header = header
            self.rows = rows
            self.truncated = truncated
        }
    }

    /// Resource caps guarding against degenerate input (PARSE-04). An
    /// unterminated quote, or a "delimiter" that never appears, used to
    /// collapse a multi-MB file into a single unbounded field / single
    /// giant row. Each cap truncates-with-a-marker and flips
    /// `Result.truncated` rather than throwing, keeping the parser
    /// forgiving while bounding worst-case memory and the cells handed
    /// to the table view.
    public struct Limits: Sendable {
        /// Max characters in a single cell. A runaway quoted field is
        /// cut here and gets a trailing "…" marker.
        public var maxCellChars: Int
        /// Max cells in a single row. Excess cells past this are
        /// dropped (a no-delimiter line that's really a quoted blob
        /// can't blow this, but a pathological delimiter-per-char line
        /// can).
        public var maxCellsPerRow: Int
        /// Max total cells across the whole table. Hard ceiling on the
        /// materialized `[[String]]`. Sized to comfortably clear a
        /// legitimate file at the loader's `sourceViewMaxBytes` (a 64 MB
        /// many-column CSV runs into the low millions of cells) while
        /// still bounding a pathological delimiter-per-byte blob.
        public var maxTotalCells: Int
        /// Max scalars consumed from `text`. Coarse backstop on overall
        /// input size, independent of cell/row structure. This is the
        /// LAST line of defense — the loader's `sourceViewMaxBytes`
        /// (64 MB) already bounds what reaches the parser in production,
        /// and the per-cell / per-row / total-cell caps do the real work
        /// for the degenerate shapes PARSE-04 targets (unterminated
        /// quote → one unbounded field; no delimiter → one giant row).
        /// Set well above any realistically-loaded file so it only trips
        /// on truly unbounded input, never clipping a valid parse.
        public var maxInputScalars: Int

        public init(maxCellChars: Int = 64 * 1024,
                    maxCellsPerRow: Int = 4096,
                    maxTotalCells: Int = 32_000_000,
                    maxInputScalars: Int = 256 * 1024 * 1024) {
            self.maxCellChars = maxCellChars
            self.maxCellsPerRow = maxCellsPerRow
            self.maxTotalCells = maxTotalCells
            self.maxInputScalars = maxInputScalars
        }
    }

    /// Auto-detect delimiter by counting candidates in the first
    /// record. Tabs win when present (TSV is unambiguous); otherwise
    /// pick whichever produces the most fields.
    ///
    /// CORR-9: the count is now **quote-aware**. Candidate delimiters
    /// (and the record-terminating newline) inside a double-quoted
    /// field don't count. Previously a header like `"a,b,c";x;y`
    /// tallied three commas and zero semicolons and mis-detected `,`,
    /// shredding the first quoted cell. We also let a quoted field span
    /// the first physical line break (`"a\nb",c`) so the record
    /// boundary is the first *unquoted* newline, matching how `parse`
    /// actually tokenizes.
    public static func detectDelimiter(in text: String) -> Character {
        var tabs = 0, commas = 0, semis = 0, pipes = 0
        var inQuotes = false
        var iter = text.unicodeScalars.makeIterator()
        scan: while let c = iter.next() {
            if inQuotes {
                if c == "\"" {
                    // Peek for an escaped `""`; consume it as a literal.
                    if let n = iter.next() {
                        if n == "\"" { continue }   // "" -> stay in quotes
                        // Closing quote; reprocess `n` below.
                        inQuotes = false
                        if n == "\n" || n == "\r" { break scan }
                        switch n {
                        case "\t": tabs += 1
                        case ",":  commas += 1
                        case ";":  semis += 1
                        case "|":  pipes += 1
                        default: break
                        }
                    } else {
                        inQuotes = false
                    }
                }
                continue
            }
            switch c {
            case "\"": inQuotes = true
            case "\n", "\r": break scan   // end of first record
            case "\t": tabs += 1
            case ",":  commas += 1
            case ";":  semis += 1
            case "|":  pipes += 1
            default: break
            }
        }
        if tabs > 0 { return "\t" }
        let counts: [(Character, Int)] = [(",", commas), (";", semis), ("|", pipes)]
        return counts.max(by: { $0.1 < $1.1 })?.0 ?? ","
    }

    /// Parse `text` using auto-detected delimiter. Forgiving: malformed
    /// rows produce best-effort fields rather than throwing.
    public static func parse(_ text: String, limits: Limits = Limits()) -> Result {
        let delim = detectDelimiter(in: text)
        return parse(text, delimiter: delim, limits: limits)
    }

    public static func parse(_ text: String, delimiter delim: Character,
                             limits: Limits = Limits()) -> Result {
        // Iterate Unicode scalars so `\r\n` decomposes into two
        // separate scalars (Swift's `Character` view collapses them
        // into one grapheme cluster, which broke CRLF parsing).
        //
        // Stream the scalar view directly via an iterator rather than
        // materializing `Array(text.unicodeScalars)` — for a 50 MB
        // CSV the array form holds ~200 MB of `Unicode.Scalar` (4 B
        // each) for the duration of the parse, doubling peak RSS.
        // We keep a single `pending` slot for the one-scalar lookahead
        // that escaped quotes and CRLF need.
        let delimScalar = delim.unicodeScalars.first!
        let quoteScalar: Unicode.Scalar = "\""
        let crScalar:    Unicode.Scalar = "\r"
        let lfScalar:    Unicode.Scalar = "\n"

        var rows: [[String]] = []
        var field = ""
        // Track the current field's scalar length explicitly: Swift's
        // `UnicodeScalarView` is not random-access and caches no length,
        // so `field.unicodeScalars.count` walks the whole UTF-8 buffer
        // each call — checking it per appended scalar made building an
        // N-scalar field O(N²). Mirrors the Rust port's `field_chars`.
        var fieldScalarCount = 0
        var row: [String] = []
        var inQuotes = false

        // PARSE-04 cap state.
        var truncated = false
        var totalCells = 0
        var scalarsConsumed = 0
        // Once a field hits the char cap we keep parsing structure but
        // stop appending to it (and mark truncated). Resets per field.
        var fieldCapped = false

        var iter = text.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar? = nil

        @inline(__always) func nextScalar() -> Unicode.Scalar? {
            if let p = pending { pending = nil; return p }
            return iter.next()
        }

        /// Append `c` to the current field, honoring the per-cell char
        /// cap (appends a single "…" marker once when first exceeded).
        @inline(__always) func appendToField(_ c: Unicode.Scalar) {
            if fieldScalarCount >= limits.maxCellChars {
                if !fieldCapped {
                    field.append("…")
                    fieldCapped = true
                    truncated = true
                }
                return
            }
            field.unicodeScalars.append(c)
            fieldScalarCount += 1
        }

        /// Push the current field into `row`, honoring the per-row cell
        /// cap. Resets field state.
        @inline(__always) func commitField() {
            if row.count < limits.maxCellsPerRow {
                row.append(field)
            } else {
                truncated = true
            }
            field = ""
            fieldScalarCount = 0
            fieldCapped = false
        }

        while let c = nextScalar() {
            // Overall input-size backstop (PARSE-04): independent of
            // cell/row structure, so an unterminated quote that turns
            // the whole file into one field can't run unbounded.
            scalarsConsumed += 1
            if scalarsConsumed > limits.maxInputScalars {
                truncated = true
                break
            }
            // Total-cell ceiling on the materialized table.
            if totalCells >= limits.maxTotalCells {
                truncated = true
                break
            }
            if inQuotes {
                if c == quoteScalar {
                    // Peek one scalar to distinguish `""` (escaped
                    // quote → emit a literal `"`) from a closing
                    // quote. Re-stash the lookahead if it's not a
                    // quote so the outer loop processes it.
                    let peek = iter.next()
                    if peek == quoteScalar {
                        appendToField("\"")
                    } else {
                        inQuotes = false
                        pending = peek
                    }
                } else {
                    appendToField(c)
                }
                continue
            }
            // Outside quotes.
            if c == quoteScalar, field.isEmpty {
                inQuotes = true
                continue
            }
            if c == delimScalar {
                commitField()
                totalCells += 1
                continue
            }
            if c == lfScalar {
                commitField()
                totalCells += 1
                rows.append(row)
                row = []
                continue
            }
            if c == crScalar {
                // Treat CR as a line terminator too (Mac classic) but
                // swallow a following LF to avoid an empty row on
                // CRLF input. If the peeked scalar isn't LF, stash
                // it for the next iteration.
                commitField()
                totalCells += 1
                rows.append(row)
                row = []
                let peek = iter.next()
                if peek != lfScalar {
                    pending = peek
                }
                continue
            }
            appendToField(c)
        }
        // Flush trailing field / row.
        if !field.isEmpty || !row.isEmpty {
            commitField()
            rows.append(row)
        }
        // Drop terminal all-empty row that a trailing newline causes.
        if let last = rows.last, last.count == 1, last[0].isEmpty {
            rows.removeLast()
        }
        guard !rows.isEmpty else {
            return Result(delimiter: delim, header: [], rows: [], truncated: truncated)
        }
        // Treat first row as header. Normalize column count both ways:
        // truncate long rows AND pad short rows with empty cells so
        // downstream consumers can index by header count without
        // hitting "ragged row" off-by-ones.
        let header = rows[0]
        let cols = header.count
        let body = rows.dropFirst().map { row -> [String] in
            if row.count == cols { return row }
            if row.count > cols { return Array(row.prefix(cols)) }
            return row + Array(repeating: "", count: cols - row.count)
        }
        return Result(delimiter: delim, header: header, rows: Array(body),
                      truncated: truncated)
    }
}
