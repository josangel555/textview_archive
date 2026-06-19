import Foundation

/// TSK-888 — bound how many match rows a single file renders in the global
/// search results. The results `LazyVStack` virtualizes *file* groups, but each
/// group renders ALL of its file's matches eagerly (each builds a highlighted
/// AttributedString), so a file with hundreds of matches makes that row — and
/// scrolling past it — janky. Cap the rows shown per file; surface the rest via
/// a "+N more — open file" affordance. Pure + host-testable.
public enum SearchResultCap {

    /// Default cap on match rows rendered per file.
    public static let perFileDefault = 50

    /// How many rows to render for a file with `total` matches.
    public static func visible(total: Int, cap: Int = perFileDefault) -> Int {
        max(0, min(cap, total))
    }

    /// How many matches are hidden by the cap (0 if within the cap).
    public static func overflow(total: Int, cap: Int = perFileDefault) -> Int {
        max(0, total - cap)
    }
}
