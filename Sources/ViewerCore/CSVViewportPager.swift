import Foundation

/// Decides which window of a `CSVRowWindowSource` to fetch for a given scroll
/// viewport (TSK-1139). Pure + host-testable — it factors the window-math out of
/// the (VM-only) SwiftUI scroll handler so the "which rows, refetch or not"
/// decision can be unit-tested without a live `ScrollView`.
///
/// The model: the view reports the visible row range; the pager returns the
/// window `[offset, offset+limit)` to pull (the visible range padded by a buffer
/// above/below) and whether a fetch is actually needed. The buffer is slack — a
/// small scroll that keeps the *visible* range inside the cached window does NOT
/// refetch, so the core is hit only when the viewport escapes the cache.
///
/// The CSVTableView consumes this: `onScrollGeometryChange` → `plan(...)` →
/// (if `needsFetch`) `CSVRowWindowSource.window(offset:limit:)` → cache + render.
/// That wiring is the render/VM tail; this decision is the host-validated core.
public struct CSVViewportPager: Equatable, Sendable {

    /// Rows fetched above and below the visible range as scroll slack. A larger
    /// buffer means fewer refetches (smoother fast scrolls) at the cost of a
    /// bigger window per pull. Clamped non-negative.
    public let bufferRows: Int

    public init(bufferRows: Int = 50) {
        self.bufferRows = max(0, bufferRows)
    }

    /// The covered span `[offset, offset+count)` of the currently-cached window.
    public struct CachedWindow: Equatable, Sendable {
        public let offset: Int
        public let count: Int
        public init(offset: Int, count: Int) {
            self.offset = offset
            self.count = count
        }
        /// The visible-row range the cache can satisfy.
        public var upperBound: Int { offset + count }
    }

    /// The pager's decision for one viewport.
    public struct Plan: Equatable, Sendable {
        /// Window offset to fetch (0-based into the surviving/filtered set).
        public let offset: Int
        /// Window length to fetch (0 ⇒ nothing to render there).
        public let limit: Int
        /// True when the core must be hit; false when the cache already covers
        /// the visible range (the view keeps its current rows).
        public let needsFetch: Bool
        public init(offset: Int, limit: Int, needsFetch: Bool) {
            self.offset = offset
            self.limit = limit
            self.needsFetch = needsFetch
        }
    }

    /// Plan the window for a viewport.
    ///
    /// - Parameters:
    ///   - filteredCount: rows surviving the active filter (the windowable set).
    ///   - firstVisibleRow: index (into the filtered set) of the first on-screen row.
    ///   - visibleRowCount: number of rows on screen.
    ///   - cached: the currently-cached window, or nil if none.
    /// - Returns: the window to fetch + whether a fetch is required. Degenerate
    ///   inputs (no rows / nothing visible) yield an empty no-fetch plan.
    public func plan(
        filteredCount: Int,
        firstVisibleRow: Int,
        visibleRowCount: Int,
        cached: CachedWindow?
    ) -> Plan {
        guard filteredCount > 0, visibleRowCount > 0 else {
            return Plan(offset: 0, limit: 0, needsFetch: false)
        }
        // Clamp the visible range into the surviving set (a filter may have
        // shrunk it below the last scroll position).
        let firstVisible = max(0, min(firstVisibleRow, filteredCount - 1))
        let lastVisible = min(filteredCount - 1, firstVisible + visibleRowCount - 1)

        // Cache hit: the cached window already spans the whole VISIBLE range
        // (the buffer is intentionally not required — it's the slack that lets
        // the user scroll within the cache before we re-pull).
        if let cached = cached,
           cached.offset <= firstVisible,
           cached.upperBound >= lastVisible + 1 {
            return Plan(offset: cached.offset, limit: cached.count, needsFetch: false)
        }

        // Miss: fetch the visible range padded by the buffer, clamped to bounds.
        let lower = max(0, firstVisible - bufferRows)
        let upper = min(filteredCount, lastVisible + 1 + bufferRows)
        return Plan(offset: lower, limit: upper - lower, needsFetch: true)
    }
}
