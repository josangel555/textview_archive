import Foundation

/// Row-filtering for `CSVParser.Result`. Pure value logic; testable
/// without UI. Three orthogonal criteria, applied conjunctively:
///
///   1. `globalQuery` — case-insensitive substring match.
///        - When `globalScope == .all`, matches against any column.
///        - When `globalScope == .column(i)`, only column `i`.
///   2. `perColumn[i]` — per-column expression supporting operator
///      prefixes (see `ColumnExpression`). Empty / nil = no filter
///      for that column. Multiple per-column filters AND together.
///
/// Performance: O(rows × cols × queries). One full sweep per call;
/// caller is responsible for debouncing (typical: SwiftUI body re-eval
/// is cheap if `parsed` is stable and `criteria` is `Equatable`).
public struct CSVFilter: Sendable, Equatable {

    public enum Scope: Sendable, Equatable {
        case all
        case column(Int)
    }

    public var globalQuery: String
    public var globalScope: Scope
    /// Column index → raw user-typed expression. Missing / empty values
    /// are skipped. Stored as `[Int: String]` (sparse) rather than
    /// `[String]` so column-count changes during the session don't
    /// scramble indices.
    public var perColumn: [Int: String]

    public init(globalQuery: String = "",
                globalScope: Scope = .all,
                perColumn: [Int: String] = [:]) {
        self.globalQuery = globalQuery
        self.globalScope = globalScope
        self.perColumn = perColumn
    }

    public var isEmpty: Bool {
        globalQuery.isEmpty && perColumn.values.allSatisfy { $0.isEmpty }
    }

    /// Apply filter to `result.rows`. Header is untouched. Returns the
    /// surviving row indices alongside the filtered rows so callers
    /// can preserve original line numbers if needed.
    public func apply(to result: CSVParser.Result) -> (indices: [Int], rows: [[String]]) {
        if isEmpty {
            return (Array(result.rows.indices), result.rows)
        }
        let colExprs: [(col: Int, expr: ColumnExpression)] = perColumn.compactMap { (col, raw) in
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            return (col, ColumnExpression.parse(trimmed))
        }
        let needle = globalQuery.lowercased()
        var indices: [Int] = []
        var rows: [[String]] = []
        for (i, row) in result.rows.enumerated() {
            if !needle.isEmpty {
                let matched: Bool
                switch globalScope {
                case .all:
                    matched = row.contains { $0.lowercased().contains(needle) }
                case .column(let c):
                    matched = c >= 0 && c < row.count
                        && row[c].lowercased().contains(needle)
                }
                if !matched { continue }
            }
            var passes = true
            for (col, expr) in colExprs {
                guard col >= 0, col < row.count else { passes = false; break }
                if !expr.matches(row[col]) { passes = false; break }
            }
            if passes {
                indices.append(i)
                rows.append(row)
            }
        }
        return (indices, rows)
    }
}

/// Per-column expression. Operator prefix is detected greedily on the
/// trimmed input. Operands are compared as `Double` when both sides
/// parse as numbers, else as case-insensitive strings. Substring (no
/// operator) is the default for the no-prefix case — matches the
/// global-query semantic so users don't need two mental models.
public enum ColumnExpression: Equatable, Sendable {
    case contains(String)
    case equals(String)
    case notEquals(String)
    case greaterThan(String)
    case greaterOrEqual(String)
    case lessThan(String)
    case lessOrEqual(String)

    public static func parse(_ raw: String) -> ColumnExpression {
        let s = raw.trimmingCharacters(in: .whitespaces)
        // Order matters: longer prefixes first (`>=` before `>`).
        if let v = strip(s, prefix: ">=") { return .greaterOrEqual(v) }
        if let v = strip(s, prefix: "<=") { return .lessOrEqual(v) }
        if let v = strip(s, prefix: "!=") { return .notEquals(v) }
        if let v = strip(s, prefix: ">")  { return .greaterThan(v) }
        if let v = strip(s, prefix: "<")  { return .lessThan(v) }
        if let v = strip(s, prefix: "=")  { return .equals(v) }
        return .contains(s)
    }

    private static func strip(_ s: String, prefix: String) -> String? {
        guard s.hasPrefix(prefix) else { return nil }
        return String(s.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespaces)
    }

    public func matches(_ cell: String) -> Bool {
        switch self {
        case .contains(let v):
            return cell.range(of: v, options: .caseInsensitive) != nil
        case .equals(let v):
            return numericCompare(cell, v) == .orderedSame
                || cell.compare(v, options: .caseInsensitive) == .orderedSame
        case .notEquals(let v):
            return !(numericCompare(cell, v) == .orderedSame
                || cell.compare(v, options: .caseInsensitive) == .orderedSame)
        case .greaterThan(let v):
            return numericOrLexical(cell, v) == .orderedDescending
        case .greaterOrEqual(let v):
            let r = numericOrLexical(cell, v)
            return r == .orderedDescending || r == .orderedSame
        case .lessThan(let v):
            return numericOrLexical(cell, v) == .orderedAscending
        case .lessOrEqual(let v):
            let r = numericOrLexical(cell, v)
            return r == .orderedAscending || r == .orderedSame
        }
    }

    /// Numeric compare when both operands parse as Double; falls back
    /// to case-insensitive string compare otherwise. Same precedence
    /// rule for equality and ordering operators so `=10` matches
    /// "10.0", "10", "  10" alike.
    private func numericOrLexical(_ a: String, _ b: String) -> ComparisonResult {
        if let na = Double(a.trimmingCharacters(in: .whitespaces)),
           let nb = Double(b.trimmingCharacters(in: .whitespaces)) {
            if na < nb { return .orderedAscending }
            if na > nb { return .orderedDescending }
            return .orderedSame
        }
        return a.compare(b, options: .caseInsensitive)
    }

    private func numericCompare(_ a: String, _ b: String) -> ComparisonResult {
        if let na = Double(a.trimmingCharacters(in: .whitespaces)),
           let nb = Double(b.trimmingCharacters(in: .whitespaces)) {
            if na < nb { return .orderedAscending }
            if na > nb { return .orderedDescending }
            return .orderedSame
        }
        // No numeric match → "not equal numerically"; caller handles
        // the string fallback for `.equals` / `.notEquals`.
        return .orderedDescending
    }
}
