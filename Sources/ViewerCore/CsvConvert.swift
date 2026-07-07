import Foundation

/// Converts parsed CSV (header + rows) to a Markdown table or a JSON array —
/// "Copy as Markdown Table / JSON" for the CSV viewer. A pure CONSUMER of
/// `CSVParser.parse` output (not a modification of the Rust-ported CSV engine),
/// so it's migration-safe and fully host-testable.
public enum CsvConvert {

    /// A GitHub-flavoured Markdown pipe table, columns padded to align. Cells
    /// have `|` escaped and embedded newlines collapsed to spaces (a table cell
    /// can't span lines). Empty input → "".
    public static func toMarkdownTable(header: [String], rows: [[String]]) -> String {
        let columns = Swift.max(header.count, rows.map(\.count).max() ?? 0)
        guard columns > 0 else { return "" }

        func cell(_ s: String) -> String {
            s.replacingOccurrences(of: "\r\n", with: " ")
             .replacingOccurrences(of: "\n", with: " ")
             .replacingOccurrences(of: "\r", with: " ")
             .replacingOccurrences(of: "|", with: "\\|")
        }
        func pad(_ row: [String]) -> [String] {
            var r = row.map(cell)
            while r.count < columns { r.append("") }
            return r
        }

        let head = pad(header)
        let body = rows.map(pad)
        var widths = [Int](repeating: 3, count: columns)   // min 3 for `---`
        for r in [head] + body {
            for (i, c) in r.enumerated() { widths[i] = Swift.max(widths[i], c.count) }
        }

        func line(_ cells: [String]) -> String {
            "| " + cells.enumerated().map { i, c in
                c + String(repeating: " ", count: widths[i] - c.count)
            }.joined(separator: " | ") + " |"
        }
        let separator = "| " + widths.map { String(repeating: "-", count: $0) }
            .joined(separator: " | ") + " |"

        return ([line(head), separator] + body.map(line)).joined(separator: "\n")
    }

    /// A pretty-printed JSON array of objects, one per row, keyed by the header
    /// (column ORDER preserved). All values are strings (CSV is untyped — keeping
    /// them as text is lossless; no leading-zero / precision surprises). A row
    /// shorter than the header gets "" for the missing columns; extra cells past
    /// the header are dropped. Empty header → "[]".
    public static func toJSON(header: [String], rows: [[String]]) -> String {
        guard !header.isEmpty else { return "[]" }
        let keys = header
        let objects = rows.map { row -> String in
            let pairs = keys.enumerated().map { i, key -> String in
                let value = i < row.count ? row[i] : ""
                return "    \(jsonEscape(key)): \(jsonEscape(value))"
            }
            return "  {\n" + pairs.joined(separator: ",\n") + "\n  }"
        }
        guard !objects.isEmpty else { return "[]" }
        return "[\n" + objects.joined(separator: ",\n") + "\n]"
    }

    /// A GitHub-flavoured pipe table is lossy for round-tripping (it collapses
    /// newlines, pads columns). This is the loss-LESS writer: RFC-4180 CSV, LF
    /// row separator (macOS-native; our parser accepts CRLF too), fields quoted
    /// only when they contain `,`/`"`/CR/LF with `"` doubled. Completes
    /// `CsvConvert`'s export set (it could already read CSV → md/json but not
    /// WRITE CSV — the natural "export a result grid" format). Rows shorter than
    /// the header are padded with empty cells; the column count is the max of the
    /// header width and the widest row. Empty input → "".
    ///
    /// TSK-1439: the SQLite browser exports query results through this.
    public static func toCSV(header: [String], rows: [[String]]) -> String {
        let columns = Swift.max(header.count, rows.map(\.count).max() ?? 0)
        guard columns > 0 else { return "" }
        func pad(_ row: [String]) -> [String] {
            var r = row
            while r.count < columns { r.append("") }
            return r
        }
        let all = ([header] + rows).map(pad)
        return all.map { $0.map(csvField).joined(separator: ",") }.joined(separator: "\n")
    }

    /// RFC-4180 field quoting: a field with a comma, a double-quote, or an
    /// embedded CR/LF is wrapped in double-quotes with each `"` doubled.
    private static func csvField(_ s: String) -> String {
        guard s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r") else {
            return s
        }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Minimal, correct JSON string literal (quoted + escaped).
    private static func jsonEscape(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 { out += String(format: "\\u%04x", u.value) }
                else { out.unicodeScalars.append(u) }
            }
        }
        out += "\""
        return out
    }
}
