import Foundation

/// Profiles a parsed CSV (header + rows) into per-column counts and, for numeric
/// columns, min / max / mean — "CSV Summary" for the CSV viewer. A pure CONSUMER
/// of `CSVParser.parse` output (not a modification of the Rust-ported CSV
/// engine), so it's migration-safe and fully host-testable.
public enum CsvSummary {

    /// Per-column profile. `numericCount` is how many non-empty cells parsed as a
    /// number; `isNumeric` is true only when EVERY non-empty cell did (and there
    /// was at least one). `min`/`max`/`mean` are over the parsed numeric cells —
    /// nil when the column has none.
    public struct Column: Equatable, Sendable {
        public let name: String
        public let nonEmpty: Int
        public let empty: Int
        public let numericCount: Int
        public let isNumeric: Bool
        public let min: Double?
        public let max: Double?
        public let mean: Double?
    }

    public struct Summary: Equatable, Sendable {
        public let rowCount: Int        // data rows (header excluded)
        public let columnCount: Int
        public let columns: [Column]
    }

    public static func compute(header: [String], rows: [[String]]) -> Summary {
        let columnCount = Swift.max(header.count, rows.map(\.count).max() ?? 0)
        guard columnCount > 0 else { return Summary(rowCount: rows.count, columnCount: 0, columns: []) }

        var columns: [Column] = []
        columns.reserveCapacity(columnCount)
        for i in 0..<columnCount {
            let name = (i < header.count && !header[i].isEmpty) ? header[i] : "Column \(i + 1)"
            var nonEmpty = 0, empty = 0
            var nums: [Double] = []
            for row in rows {
                let cell = i < row.count ? row[i] : ""
                if cell.trimmingCharacters(in: .whitespaces).isEmpty {
                    empty += 1
                } else {
                    nonEmpty += 1
                    if let n = parseNumber(cell) { nums.append(n) }
                }
            }
            let isNumeric = nonEmpty > 0 && nums.count == nonEmpty
            let mn = nums.min(), mx = nums.max()
            let mean = nums.isEmpty ? nil : nums.reduce(0, +) / Double(nums.count)
            columns.append(Column(name: name, nonEmpty: nonEmpty, empty: empty,
                                  numericCount: nums.count, isNumeric: isNumeric,
                                  min: mn, max: mx, mean: mean))
        }
        return Summary(rowCount: rows.count, columnCount: columnCount, columns: columns)
    }

    /// A plain-text report for the menu alert.
    public static func report(header: [String], rows: [[String]]) -> String {
        let s = compute(header: header, rows: rows)
        var lines = ["Rows: \(s.rowCount)", "Columns: \(s.columnCount)", ""]
        for c in s.columns {
            let kind = c.isNumeric ? "numeric" : "text"
            var line = "• \(c.name) (\(kind)) — \(c.nonEmpty) value\(c.nonEmpty == 1 ? "" : "s"), \(c.empty) empty"
            if let mn = c.min, let mx = c.max, let mean = c.mean, c.numericCount > 0 {
                line += "; min \(num(mn)), max \(num(mx)), mean \(num(mean))"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - helpers

    /// Parse a cell as a number — trimmed; rejects thousands separators / currency
    /// (ambiguous with the delimiter), accepting only what `Double` accepts.
    static func parseNumber(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        return Double(t)
    }

    /// Render a Double compactly: integers without a decimal point, otherwise up
    /// to 4 significant decimals with trailing zeros trimmed.
    static func num(_ d: Double) -> String {
        if d.rounded() == d && abs(d) < 1e15 { return String(Int(d)) }
        var s = String(format: "%.4f", d)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}
