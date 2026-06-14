import Foundation

/// Drives tab-stop cursor navigation for an inserted snippet (TSK-705, slice 5).
/// Given a parsed snippet and the document offset where its plain text landed,
/// it yields the ABSOLUTE caret targets (offset + selection length) for each tab
/// stop in visit order (`$1`, `$2`, …, `$0` last). Pure + host-testable; the CM6
/// Tab-key interception that drives `advance()`/`retreat()` and selects the
/// returned range is the editor/VM tail.
public struct SnippetSession: Equatable, Sendable {

    /// One tab stop in absolute document coordinates.
    public struct Stop: Equatable, Sendable {
        public let index: Int      // tab-stop number (0 = final cursor)
        public let offset: Int     // absolute UTF-16 offset in the document
        public let length: Int     // selection length (0 = empty placeholder)
        public init(index: Int, offset: Int, length: Int) {
            self.index = index; self.offset = offset; self.length = length
        }
    }

    public let stops: [Stop]
    /// Index into `stops`; equals `stops.count` once navigation is finished.
    public private(set) var cursor: Int

    /// Build a session for `snippet`'s plain text inserted at `baseOffset`.
    /// Returns nil when the snippet has no tab stops (nothing to navigate). When
    /// an index is repeated (a mirror), its FIRST occurrence is the target.
    public init?(snippet: ParsedSnippet, insertedAt baseOffset: Int) {
        let order = snippet.tabStopOrder
        guard !order.isEmpty else { return nil }
        var firstByIndex: [Int: (offset: Int, length: Int)] = [:]
        for s in snippet.stops() where firstByIndex[s.index] == nil {
            firstByIndex[s.index] = (s.offset, s.length)
        }
        self.stops = order.compactMap { idx in
            firstByIndex[idx].map {
                Stop(index: idx, offset: baseOffset + $0.offset, length: $0.length)
            }
        }
        self.cursor = 0
    }

    /// The stop the caret should be at now, or nil when finished.
    public var current: Stop? { stops.indices.contains(cursor) ? stops[cursor] : nil }

    /// True once the user has tabbed past the final stop.
    public var isFinished: Bool { cursor >= stops.count }

    /// Advance to the next stop; returns it (nil when finished). Clamped.
    @discardableResult
    public mutating func advance() -> Stop? {
        if cursor < stops.count { cursor += 1 }
        return current
    }

    /// Retreat to the previous stop; returns it (nil if already at the first).
    @discardableResult
    public mutating func retreat() -> Stop? {
        if cursor > 0 { cursor -= 1 }
        return current
    }
}
