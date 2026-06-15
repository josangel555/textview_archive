import Foundation

/// Sorts CSV rows by a column for the table view (TSK-925). A pure CONSUMER of
/// parsed rows (not a change to the Rust-ported CSV parser), so it's
/// migration-safe and fully host-testable.
public enum CsvSort {

    /// Rows sorted by `column` (0-based). Type-aware: if every non-empty cell in
    /// that column parses as a number, the column sorts NUMERICALLY; otherwise
    /// case-insensitive string order. Empty cells always sort LAST (direction-
    /// independent). Stable — equal cells keep their original relative order.
    /// A short row (missing the column) is treated as an empty cell. `column`
    /// out of range returns the rows unchanged.
    public static func sorted(rows: [[String]], column: Int, ascending: Bool) -> [[String]] {
        guard column >= 0 else { return rows }

        func cell(_ row: [String]) -> String {
            (column < row.count ? row[column] : "").trimmingCharacters(in: .whitespaces)
        }

        let numeric = rows.allSatisfy { r in
            let c = cell(r)
            return c.isEmpty || Double(c) != nil
        }

        return rows.enumerated()
            .sorted { a, b in
                let ca = cell(a.element), cb = cell(b.element)
                // Empties last, regardless of direction.
                if ca.isEmpty != cb.isEmpty { return cb.isEmpty }
                if ca.isEmpty && cb.isEmpty { return a.offset < b.offset }
                let ascendingOrder: Bool
                if numeric, let na = Double(ca), let nb = Double(cb) {
                    if na == nb { return a.offset < b.offset }   // stable
                    ascendingOrder = na < nb
                } else {
                    let cmp = ca.localizedCaseInsensitiveCompare(cb)
                    if cmp == .orderedSame { return a.offset < b.offset }   // stable
                    ascendingOrder = cmp == .orderedAscending
                }
                return ascending ? ascendingOrder : !ascendingOrder
            }
            .map(\.element)
    }

    /// Sort state after tapping column `tapped`: tapping the ACTIVE column flips
    /// direction; tapping any other column sorts it ascending. Pins the
    /// header-click toggle behavior (the render is the VM tail).
    public static func nextState(
        current: (column: Int, ascending: Bool)?, tapped: Int
    ) -> (column: Int, ascending: Bool) {
        if let cur = current, cur.column == tapped { return (tapped, !cur.ascending) }
        return (tapped, true)
    }
}
