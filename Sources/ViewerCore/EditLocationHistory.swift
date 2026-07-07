import Foundation

/// TSK-1485 — per-file edit-location history: a bounded ring of the lines a
/// user edited, with jump-back / jump-forward navigation (the editor
/// equivalent of a browser's back/forward, but over EDIT sites). Pure and
/// host-tested; the ⌘⌥←/→ verbs + the scroll-to-line wiring are the render
/// tail, and the Codable form persists in the tab snapshot so jump-back
/// survives a session switch.
///
/// ## Coalescing
/// Consecutive edits within `coalesceRadius` lines collapse to ONE entry
/// (updated to the latest line) — typing a paragraph shouldn't leave 40
/// history stops one line apart. A jump target far from the last edit is a
/// new stop.
///
/// ## Navigation model
/// A cursor indexes into the ring. `recordEdit` truncates any forward
/// history (you edited somewhere new, so "forward" is gone — browser
/// semantics) and appends. `jumpBack`/`jumpForward` move the cursor without
/// mutating the ring, returning the line to scroll to.
public struct EditLocationHistory: Equatable, Codable, Sendable {
    public private(set) var lines: [Int]
    /// Index of the current position in `lines`; -1 when empty. A jump moves
    /// this; a new edit resets it to the appended entry.
    public private(set) var cursor: Int

    public let capacity: Int
    public let coalesceRadius: Int

    public init(capacity: Int = 50, coalesceRadius: Int = 2) {
        self.lines = []
        self.cursor = -1
        self.capacity = max(1, capacity)
        self.coalesceRadius = max(0, coalesceRadius)
    }

    // Codable: persist only the ring + cursor; capacity/radius are config.
    private enum CodingKeys: String, CodingKey { case lines, cursor }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.lines = (try? c.decode([Int].self, forKey: .lines)) ?? []
        self.cursor = (try? c.decode(Int.self, forKey: .cursor)) ?? (lines.isEmpty ? -1 : lines.count - 1)
        self.capacity = 50
        self.coalesceRadius = 2
        // Repair a persisted-but-out-of-range cursor.
        if lines.isEmpty { cursor = -1 }
        else { cursor = min(max(cursor, 0), lines.count - 1) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(lines, forKey: .lines)
        try c.encode(cursor, forKey: .cursor)
    }

    public var isEmpty: Bool { lines.isEmpty }

    /// Record an edit at `line` (1-based). Coalesces with the current entry
    /// if within `coalesceRadius`; otherwise truncates forward history and
    /// appends, evicting the oldest past capacity.
    public mutating func recordEdit(line: Int) {
        guard line >= 1 else { return }
        if cursor >= 0, abs(lines[cursor] - line) <= coalesceRadius {
            lines[cursor] = line   // same region → update in place
            // A coalesced edit still drops any forward history.
            if cursor < lines.count - 1 { lines.removeSubrange((cursor + 1)...) }
            return
        }
        // New region: drop forward history, append.
        if cursor < lines.count - 1 { lines.removeSubrange((cursor + 1)...) }
        lines.append(line)
        if lines.count > capacity {
            lines.removeFirst(lines.count - capacity)
        }
        cursor = lines.count - 1
    }

    /// Move to the previous edit site; returns its line, or nil at the start.
    public mutating func jumpBack() -> Int? {
        guard cursor > 0 else { return nil }
        cursor -= 1
        return lines[cursor]
    }

    /// Move to the next edit site; returns its line, or nil at the end.
    public mutating func jumpForward() -> Int? {
        guard cursor >= 0, cursor < lines.count - 1 else { return nil }
        cursor += 1
        return lines[cursor]
    }

    /// The line at the current cursor (nil when empty).
    public var current: Int? {
        guard cursor >= 0, cursor < lines.count else { return nil }
        return lines[cursor]
    }
}
