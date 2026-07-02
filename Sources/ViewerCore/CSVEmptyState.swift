import Foundation

/// The CSV table's empty-state message (production-grade polish, 2026-07-02
/// usability audit): the table body previously rendered a blank void for an
/// empty file or a filter that matched nothing — no message. This is the pure,
/// host-testable decision of WHICH message to show; `nil` = render the table.
public enum CSVEmptyState {
    /// - `total`: rows in the parsed file.
    /// - `shown`: rows after filter/sort (what the table would render).
    /// - `filterActive`: a filter is narrowing the view (shown < total, or a
    ///   query is set) — distinguishes "filtered to nothing" from "empty file".
    /// Returns the message to display in place of the grid, or `nil` to render rows.
    public static func message(total: Int, shown: Int, filterActive: Bool) -> String? {
        if total == 0 {
            return "This file has no rows."
        }
        if shown == 0 {
            return filterActive
                ? "No rows match the current filter."
                : "No rows to display."
        }
        return nil
    }
}
