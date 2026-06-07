import Foundation

/// 0-based cursor position. `row` / `col` are clamped to the screen by
/// the screen's mutators; this is just the value pair.
public struct TerminalCursor: Sendable, Equatable {
    public var row: Int
    public var col: Int
    public init(row: Int = 0, col: Int = 0) {
        self.row = row
        self.col = col
    }
}

/// A fixed-size character grid with a cursor — the terminal "screen
/// buffer". PURE logic (no AppKit / no I/O): the `ANSIParser` drives it,
/// the view renders a snapshot of it. Headless-testable end to end.
///
/// Coordinate system is 0-based internally (row 0 = top line, col 0 =
/// left column). VT/ANSI escape sequences are 1-based; the parser does
/// the −1 conversion before calling in here.
///
/// Out of scope for v1: alternate screen buffer, scroll-region
/// (DECSTBM), wide-char column accounting, scrollback history. The grid
/// is exactly `rows × cols`; content scrolled off the top is discarded
/// (a real shell mostly works fine against this — `less`/`vim` that use
/// the alt-screen will be imperfect, which is the documented v1 gap).
public struct TerminalScreen: Sendable, Equatable {
    public private(set) var rows: Int
    public private(set) var cols: Int
    public private(set) var cells: [[TerminalCell]]
    public private(set) var cursor: TerminalCursor

    /// Lines that have scrolled off the top of the live grid, oldest
    /// first — the scrollback history the view can scroll up into.
    /// Bounded to `maxScrollback`; rows keep the width they had when
    /// evicted (the viewport normalizes them to the current `cols`).
    public private(set) var scrollback: [[TerminalCell]] = []

    /// Hard cap on retained scrollback lines (memory bound).
    public static let maxScrollback = 1000

    /// Overflow slack before trimming. `scrollUp` lets `scrollback` grow to
    /// `maxScrollback + scrollbackSlack` and then trims back to the cap in
    /// one batch, rather than `removeFirst(1)` per line (an
    /// O(maxScrollback) memmove on EVERY scrolled line — costly under bulk
    /// output). Count therefore oscillates in `[maxScrollback,
    /// maxScrollback + scrollbackSlack]`.
    public static let scrollbackSlack = 256

    /// The pen — current SGR attributes stamped onto written cells.
    public var pen: CellAttributes = .default

    public init(rows: Int, cols: Int) {
        let r = max(1, rows)
        let c = max(1, cols)
        self.rows = r
        self.cols = c
        self.cells = Array(
            repeating: Array(repeating: TerminalCell.blank, count: c),
            count: r
        )
        self.cursor = TerminalCursor()
    }

    // MARK: - Reads

    /// The plain text of the grid, one line per row, trailing blank
    /// cells trimmed per line. Used by tests + the accessibility path.
    public func plainText() -> String {
        cells.map { row -> String in
            var line = String(row.map(\.char))
            while line.hasSuffix(" ") { line.removeLast() }
            return line
        }.joined(separator: "\n")
    }

    public func line(_ r: Int) -> String {
        guard cells.indices.contains(r) else { return "" }
        var line = String(cells[r].map(\.char))
        while line.hasSuffix(" ") { line.removeLast() }
        return line
    }

    // MARK: - Resize

    /// Resize the grid to `newRows × newCols`, preserving as much
    /// existing content as fits (top-left anchored). The cursor is
    /// clamped into the new bounds. Pen attributes are preserved.
    public mutating func resize(rows newRows: Int, cols newCols: Int) {
        let r = max(1, newRows)
        let c = max(1, newCols)
        guard r != rows || c != cols else { return }
        var grid = Array(
            repeating: Array(repeating: TerminalCell.blank, count: c),
            count: r
        )
        for row in 0..<min(r, rows) {
            for col in 0..<min(c, cols) {
                grid[row][col] = cells[row][col]
            }
        }
        rows = r
        cols = c
        cells = grid
        cursor.row = min(cursor.row, r - 1)
        cursor.col = min(cursor.col, c - 1)
    }

    // MARK: - Cursor movement (all clamp to the grid)

    public mutating func moveCursor(row: Int, col: Int) {
        cursor.row = clampRow(row)
        cursor.col = clampCol(col)
    }

    public mutating func moveCursorRow(_ row: Int) { cursor.row = clampRow(row) }
    public mutating func moveCursorCol(_ col: Int) { cursor.col = clampCol(col) }

    public mutating func cursorUp(_ n: Int)    { cursor.row = clampRow(cursor.row - max(1, n)) }
    public mutating func cursorDown(_ n: Int)  { cursor.row = clampRow(cursor.row + max(1, n)) }
    public mutating func cursorForward(_ n: Int)  { cursor.col = clampCol(cursor.col + max(1, n)) }
    public mutating func cursorBackward(_ n: Int) { cursor.col = clampCol(cursor.col - max(1, n)) }

    /// Carriage return — col 0, same row.
    public mutating func carriageReturn() { cursor.col = 0 }

    /// Backspace — move left one column (no erase; that's a separate
    /// `\b \b` sequence the shell emits).
    public mutating func backspace() {
        if cursor.col > 0 { cursor.col -= 1 }
    }

    /// Horizontal tab — advance to the next 8-column tab stop, clamped
    /// to the last column.
    public mutating func tab() {
        let next = ((cursor.col / 8) + 1) * 8
        cursor.col = min(next, cols - 1)
    }

    /// Line feed — move down one row, scrolling the whole grid up by one
    /// when already on the last row. Column is unchanged (Unix terminals
    /// in cooked mode rely on the driver translating `\n`→`\r\n`; the PTY
    /// does that for us, but we still keep col here so a bare `\n` in
    /// raw output behaves like index/IND).
    public mutating func lineFeed() {
        if cursor.row >= rows - 1 {
            scrollUp(1)
        } else {
            cursor.row += 1
        }
    }

    // MARK: - Writing

    /// Write a single printable character at the cursor, advancing the
    /// cursor. At the right edge we wrap to the start of the next line
    /// (scrolling if on the last row) — standard auto-wrap behaviour.
    public mutating func write(_ ch: Character) {
        if cursor.col >= cols {
            cursor.col = 0
            lineFeed()
        }
        cells[cursor.row][cursor.col] = TerminalCell(char: ch, attributes: pen)
        cursor.col += 1
    }

    // MARK: - Erase

    /// `ESC[2J` — clear the entire screen to blanks. Cursor is left where
    /// it is (callers that want home issue a separate CUP).
    public mutating func eraseScreen() {
        for r in 0..<rows {
            for c in 0..<cols { cells[r][c] = .blank }
        }
    }

    /// `ESC[0J` — erase from the cursor to the end of the screen.
    public mutating func eraseScreenFromCursor() {
        eraseLineFromCursor()
        for r in (cursor.row + 1)..<rows {
            for c in 0..<cols { cells[r][c] = .blank }
        }
    }

    /// `ESC[1J` — erase from the start of the screen to the cursor.
    public mutating func eraseScreenToCursor() {
        for r in 0..<cursor.row {
            for c in 0..<cols { cells[r][c] = .blank }
        }
        eraseLineToCursor()
    }

    /// `ESC[K` / `ESC[0K` — erase from the cursor to the end of the line.
    public mutating func eraseLineFromCursor() {
        guard cells.indices.contains(cursor.row) else { return }
        for c in cursor.col..<cols { cells[cursor.row][c] = .blank }
    }

    /// `ESC[1K` — erase from the start of the line to the cursor.
    public mutating func eraseLineToCursor() {
        guard cells.indices.contains(cursor.row) else { return }
        for c in 0...min(cursor.col, cols - 1) { cells[cursor.row][c] = .blank }
    }

    /// `ESC[2K` — erase the whole line the cursor is on.
    public mutating func eraseLine() {
        guard cells.indices.contains(cursor.row) else { return }
        for c in 0..<cols { cells[cursor.row][c] = .blank }
    }

    // MARK: - Scrolling

    /// Scroll the entire grid up by `n` lines: top `n` lines fall off
    /// (into `scrollback`), `n` blank lines appear at the bottom. The
    /// cursor row stays put (used by `lineFeed` on the last row).
    public mutating func scrollUp(_ n: Int) {
        let count = min(max(0, n), rows)
        guard count > 0 else { return }
        // Retain the evicted top lines as scrollback. Trim in BATCHES (only
        // once the buffer overflows the cap by `scrollbackSlack`) — a
        // per-line `removeFirst(1)` is an O(maxScrollback) memmove on every
        // scrolled line, which dominates under bulk output (build logs,
        // `cat`). Batching amortizes it to ~O(maxScrollback / slack)/line.
        scrollback.append(contentsOf: cells[0..<count])
        if scrollback.count > Self.maxScrollback + Self.scrollbackSlack {
            scrollback.removeFirst(scrollback.count - Self.maxScrollback)
        }
        cells.removeFirst(count)
        cells.append(contentsOf: Array(
            repeating: Array(repeating: TerminalCell.blank, count: cols),
            count: count
        ))
    }

    // MARK: - Scrollback viewport

    /// The `rows` display lines (each exactly `cols` cells) for a viewport
    /// scrolled up `offset` lines from the live bottom. `offset` 0 → the
    /// live grid; it is clamped to `0...scrollback.count`. Scrollback rows
    /// are normalized (padded/truncated) to the current `cols` so the view
    /// can render a uniform grid regardless of the width they were evicted
    /// at.
    public func visibleLines(scrollOffset offset: Int) -> [[TerminalCell]] {
        let o = min(max(0, offset), scrollback.count)
        if o == 0 { return cells }
        var out: [[TerminalCell]] = []
        out.reserveCapacity(rows)
        // Combined index space: [scrollback…] then [live grid…]. The
        // bottom-anchored window of height `rows` begins `o` lines up.
        let start = scrollback.count - o
        for i in start..<(start + rows) {
            if i < scrollback.count {
                out.append(normalizedRow(scrollback[i]))
            } else {
                out.append(cells[i - scrollback.count])
            }
        }
        return out
    }

    private func normalizedRow(_ row: [TerminalCell]) -> [TerminalCell] {
        if row.count == cols { return row }
        if row.count > cols { return Array(row[0..<cols]) }
        return row + Array(repeating: .blank, count: cols - row.count)
    }

    /// Scroll the entire grid down by `n` lines: bottom `n` lines fall
    /// off, `n` blank lines appear at the top.
    public mutating func scrollDown(_ n: Int) {
        let count = min(max(0, n), rows)
        guard count > 0 else { return }
        cells.removeLast(count)
        cells.insert(contentsOf: Array(
            repeating: Array(repeating: TerminalCell.blank, count: cols),
            count: count
        ), at: 0)
    }

    // MARK: - Helpers

    private func clampRow(_ r: Int) -> Int { min(max(0, r), rows - 1) }
    private func clampCol(_ c: Int) -> Int { min(max(0, c), cols - 1) }
}
