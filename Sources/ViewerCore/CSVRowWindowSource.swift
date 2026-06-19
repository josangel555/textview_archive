import Foundation
import RustCore

/// A windowed (paged) data source for the CSV table view, backed by the Rust
/// core's stateful `CsvSession` (TSK-668).
///
/// Today the CSV grid materializes EVERY row into a Swift `[[String]]` and lets
/// `LazyVStack` virtualize the render. That keeps the whole body resident even
/// when only ~30 rows are on screen — for a multi-million-row CSV that is the
/// dominant cost. The Rust core already serves the windowing primitives
/// (`snapshotWindow(offset:limit:)` pages the *surviving* set in O(window);
/// `filteredCount()` sizes the scrollbar without projecting a single row), so
/// this type is the host-side seam the scroll-driven view requests windows
/// from. The actual scroll → fetch → render wiring is the VM tail.
///
/// What this exposes, all keyed to the CURRENT filter:
///   - `totalRowCount`        — the table total (unfiltered), for "N rows".
///   - `filteredRowCount()`   — the surviving (post-filter) count, the size of
///                              the windowable set, for scrollbar geometry.
///   - `header`               — column titles, cached from the open.
///   - `window(offset:limit:)`— rows `[offset, offset+limit)` of the surviving
///                              set, paired with their ABSOLUTE source-row ids
///                              so the consumer keeps a stable index → row map
///                              (selection, copy-row, "go to row N" all need the
///                              original id, not the post-filter position).
///
/// Fail-safe by construction: a `CSVRowWindowSource` only exists when the Rust
/// core opened the session successfully. If `open` throws (gate off in spirit,
/// bridge fault, bad UTF-8, an unknown future status), the caller keeps the
/// incumbent full-materialize Swift path — paging degrades to today's behavior
/// rather than blanking the table. This mirrors `RustCSVAdapter`'s seam.
public final class CSVRowWindowSource {

    /// One paged window of the surviving set. `absoluteIndices[i]` is the
    /// original (unfiltered) source-row id of `rows[i]`, so the consumer can map
    /// a visible position back to the underlying table row regardless of how the
    /// active filter renumbered things.
    public struct Window: Equatable, Sendable {
        /// The requested offset into the surviving set (clamped to its end).
        public let offset: Int
        /// The window's rows, in surviving-set order.
        public let rows: [[String]]
        /// Absolute (unfiltered) source-row id per row in `rows`. Same count as
        /// `rows`. Stable across re-pulls of the same offset under the same
        /// filter.
        public let absoluteIndices: [Int]
        /// The table total (unfiltered) the core reported with this window.
        public let totalRows: Int

        public init(offset: Int, rows: [[String]],
                    absoluteIndices: [Int], totalRows: Int) {
            self.offset = offset
            self.rows = rows
            self.absoluteIndices = absoluteIndices
            self.totalRows = totalRows
        }

        /// An empty window at `offset` (scrolled past the surviving end). Not an
        /// error — the consumer simply has no rows to render there.
        public static func empty(offset: Int, totalRows: Int) -> Window {
            Window(offset: offset, rows: [], absoluteIndices: [], totalRows: totalRows)
        }
    }

    private let session: CsvSession
    /// Column titles, captured once at open from a zero-width probe window so a
    /// header read never has to project rows.
    public let header: [String]
    /// The unfiltered table total. Stable for the lifetime of the source (the
    /// session's body never changes; only the filter does), so it is cached at
    /// open rather than re-probed.
    public let totalRowCount: Int

    /// Open a windowed source over `text`, routing through the Rust core.
    ///
    /// - Throws: any `CsvSession` open/bridge error. The caller treats a throw
    ///   as "windowing unavailable, fall back to the full-materialize path".
    public init(text: String) throws {
        let session = try CsvSession(bytes: [UInt8](text.utf8))
        self.session = session
        // A zero-row probe is the cheapest way to read header + total without
        // projecting any body rows: `snapshotWindow(limit: 0)` clamps to an
        // empty window but still carries `header` and `totalRows`.
        let probe = try session.snapshotWindow(offset: 0, limit: 0)
        self.header = probe.header
        self.totalRowCount = Int(probe.totalRows)
    }

    /// Apply (or clear) the active filter. Subsequent `window(_:)` /
    /// `filteredRowCount()` calls page the new surviving set. Idempotent in the
    /// core (re-setting the same query is a no-op), so a redundant call is cheap.
    ///
    /// - Throws: a bridge error if the session handle is dead.
    public func setFilter(_ query: String, scope: FilterScope = .all) throws {
        try session.setFilter(query, scope: scope)
    }

    /// The number of rows surviving the current filter — the size of the
    /// windowable set. Cheap: the core counts cached indices and projects no
    /// rows. Use this to size the scrollbar / "M / N rows" label.
    public func filteredRowCount() throws -> Int {
        try session.filteredCount()
    }

    /// Fetch the window `[offset, offset+limit)` of the surviving set.
    ///
    /// `offset` past the surviving end yields an empty window (valid — the
    /// consumer scrolled past the last row). A non-positive `limit` yields an
    /// empty window without touching the core. Negative `offset` is clamped to 0.
    ///
    /// - Returns: the paged rows + their absolute source-row ids + table total.
    /// - Throws: a bridge error if the session handle is dead.
    public func window(offset: Int, limit: Int) throws -> Window {
        let clampedOffset = max(0, offset)
        guard limit > 0 else {
            return .empty(offset: clampedOffset, totalRows: totalRowCount)
        }
        let snap = try session.snapshotWindow(offset: clampedOffset, limit: limit)
        return Window(
            offset: clampedOffset,
            rows: snap.rows,
            absoluteIndices: snap.indices.map(Int.init),
            totalRows: Int(snap.totalRows)
        )
    }

    /// Convenience: fetch the window covering `range` of the surviving set.
    /// An empty or reversed range yields an empty window without a core call.
    public func window(in range: Range<Int>) throws -> Window {
        guard range.lowerBound < range.upperBound else {
            return .empty(offset: max(0, range.lowerBound), totalRows: totalRowCount)
        }
        return try window(offset: range.lowerBound, limit: range.count)
    }
}
