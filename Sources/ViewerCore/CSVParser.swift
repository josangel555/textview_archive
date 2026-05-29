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
        public init(delimiter: Character, header: [String], rows: [[String]]) {
            self.delimiter = delimiter
            self.header = header
            self.rows = rows
        }
    }

    /// Auto-detect delimiter by counting candidates in the first
    /// non-empty line. Tabs win when present (TSV is unambiguous);
    /// otherwise pick whichever produces the most fields.
    public static func detectDelimiter(in text: String) -> Character {
        let firstLine = text.split(separator: "\n", maxSplits: 1,
                                    omittingEmptySubsequences: true)
            .first.map(String.init) ?? ""
        if firstLine.contains("\t") { return "\t" }
        let counts: [(Character, Int)] = [",", ";", "|"].map { d in
            (d, firstLine.filter { $0 == d }.count)
        }
        return counts.max(by: { $0.1 < $1.1 })?.0 ?? ","
    }

    /// Parse `text` using auto-detected delimiter. Forgiving: malformed
    /// rows produce best-effort fields rather than throwing.
    public static func parse(_ text: String) -> Result {
        let delim = detectDelimiter(in: text)
        return parse(text, delimiter: delim)
    }

    public static func parse(_ text: String, delimiter delim: Character) -> Result {
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
        var row: [String] = []
        var inQuotes = false

        var iter = text.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar? = nil

        @inline(__always) func nextScalar() -> Unicode.Scalar? {
            if let p = pending { pending = nil; return p }
            return iter.next()
        }

        while let c = nextScalar() {
            if inQuotes {
                if c == quoteScalar {
                    // Peek one scalar to distinguish `""` (escaped
                    // quote → emit a literal `"`) from a closing
                    // quote. Re-stash the lookahead if it's not a
                    // quote so the outer loop processes it.
                    let peek = iter.next()
                    if peek == quoteScalar {
                        field.append("\"")
                    } else {
                        inQuotes = false
                        pending = peek
                    }
                } else {
                    field.unicodeScalars.append(c)
                }
                continue
            }
            // Outside quotes.
            if c == quoteScalar, field.isEmpty {
                inQuotes = true
                continue
            }
            if c == delimScalar {
                row.append(field)
                field = ""
                continue
            }
            if c == lfScalar {
                row.append(field)
                field = ""
                rows.append(row)
                row = []
                continue
            }
            if c == crScalar {
                // Treat CR as a line terminator too (Mac classic) but
                // swallow a following LF to avoid an empty row on
                // CRLF input. If the peeked scalar isn't LF, stash
                // it for the next iteration.
                row.append(field)
                field = ""
                rows.append(row)
                row = []
                let peek = iter.next()
                if peek != lfScalar {
                    pending = peek
                }
                continue
            }
            field.unicodeScalars.append(c)
        }
        // Flush trailing field / row.
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        // Drop terminal all-empty row that a trailing newline causes.
        if let last = rows.last, last.count == 1, last[0].isEmpty {
            rows.removeLast()
        }
        guard !rows.isEmpty else {
            return Result(delimiter: delim, header: [], rows: [])
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
        return Result(delimiter: delim, header: header, rows: Array(body))
    }
}
