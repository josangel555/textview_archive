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
/// Out of scope: scroll-region (DECSTBM) and wide-char (CJK / emoji)
/// column accounting. The alternate screen buffer (DEC private modes
/// 1049 / 1047 / 47, used by `top` / `vim` / `less`) and bounded
/// scrollback history ARE modelled — see `enterAltScreen` /
/// `exitAltScreen` and `scrollback`. Entering the alt screen preserves
/// the main grid + scrollback + cursor + pen and restores them on exit,
/// so a full-screen app never churns the user's scrollback (the cause of
/// the `top` "constant scroll" report).
public struct TerminalScreen: Sendable, Equatable {
    public private(set) var rows: Int
    public private(set) var cols: Int
    public private(set) var cells: [[TerminalCell]]
    public private(set) var cursor: TerminalCursor

    /// DEC scroll region (DECSTBM) margins — INCLUSIVE row indices
    /// [scrollTop, scrollBottom]; default = the whole screen. lineFeed / scroll
    /// / IL / DL operate within these margins. A sub-region (e.g. vim pinning
    /// its status line) scrolls only the body and never evicts to scrollback;
    /// only a full-screen scroll on the main buffer pushes lines to history.
    /// Reset to the full screen on resize. (TSK-735.)
    public private(set) var scrollTop: Int = 0
    public private(set) var scrollBottom: Int = 0

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

    /// True while the alternate screen buffer is active (DEC private modes
    /// 1049 / 1047 / 47 — `top` / `vim` / `less`). The alt buffer has NO
    /// scrollback and is discarded on exit; the saved main state is restored.
    public private(set) var inAltScreen: Bool = false

    /// Saved main-screen state, captured on `enterAltScreen` and restored on
    /// `exitAltScreen`. `nil` while on the main screen.
    private var savedMain: SavedBuffer?

    private struct SavedBuffer: Sendable, Equatable {
        var cells: [[TerminalCell]]
        var cursor: TerminalCursor
        var scrollback: [[TerminalCell]]
        var pen: CellAttributes
    }

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
        self.scrollTop = 0
        self.scrollBottom = r - 1
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
        cells = Self.resizedGrid(cells, fromRows: rows, fromCols: cols, toRows: r, toCols: c)
        // Keep the saved (inactive) main buffer in sync so exiting the alt
        // screen after a resize restores at the CURRENT geometry, not the
        // stale pre-resize one.
        if var saved = savedMain {
            saved.cells = Self.resizedGrid(saved.cells, fromRows: rows, fromCols: cols,
                                           toRows: r, toCols: c)
            saved.cursor.row = min(saved.cursor.row, r - 1)
            saved.cursor.col = min(saved.cursor.col, c - 1)
            savedMain = saved
        }
        rows = r
        cols = c
        cursor.row = min(cursor.row, r - 1)
        cursor.col = min(cursor.col, c - 1)
        // DECSTBM is reset to the full screen on resize (standard).
        scrollTop = 0
        scrollBottom = r - 1
    }

    /// Top-left-anchored grid resize, preserving as much content as fits.
    private static func resizedGrid(_ grid: [[TerminalCell]],
                                    fromRows: Int, fromCols: Int,
                                    toRows: Int, toCols: Int) -> [[TerminalCell]] {
        var out = blankGrid(rows: toRows, cols: toCols)
        for row in 0..<min(toRows, fromRows) {
            for col in 0..<min(toCols, fromCols) {
                out[row][col] = grid[row][col]
            }
        }
        return out
    }

    private static func blankGrid(rows: Int, cols: Int) -> [[TerminalCell]] {
        Array(repeating: Array(repeating: TerminalCell.blank, count: cols), count: rows)
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
        if cursor.row == scrollBottom {
            scrollUp(1)   // scroll within the active region (TSK-735)
        } else if cursor.row < rows - 1 {
            cursor.row += 1
        }
        // At the last row but below the scroll region: stay put (no scroll).
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

    // MARK: - In-line editing (DCH / ICH / ECH / IL / DL)
    //
    // TSK-740: line editors (zsh/readline) and full-screen apps send these CSI
    // edits to mutate the grid in place; the parser used to parse-and-IGNORE
    // them, so a deleted char lingered on screen ("display doesn't match true
    // state"). Char ops act within the cursor's row; line ops from the cursor
    // row to the bottom (no scroll-region margins yet — that's TSK-735).

    /// `ESC[nP` (DCH) — delete `n` chars at the cursor; the rest of the line
    /// shifts left, blanks fill in at the right edge.
    public mutating func deleteChars(_ n: Int) {
        guard cells.indices.contains(cursor.row) else { return }
        let count = min(max(1, n), cols - cursor.col)
        guard count > 0 else { return }
        var row = cells[cursor.row]
        row.removeSubrange(cursor.col ..< (cursor.col + count))
        row.append(contentsOf: Array(repeating: .blank, count: count))
        cells[cursor.row] = row
    }

    /// `ESC[n@` (ICH) — insert `n` blanks at the cursor; the line shifts right,
    /// chars past the right edge fall off.
    public mutating func insertChars(_ n: Int) {
        guard cells.indices.contains(cursor.row) else { return }
        let count = min(max(1, n), cols - cursor.col)
        guard count > 0 else { return }
        var row = cells[cursor.row]
        row.insert(contentsOf: Array(repeating: .blank, count: count), at: cursor.col)
        row.removeLast(count)
        cells[cursor.row] = row
    }

    /// `ESC[nX` (ECH) — erase `n` chars at the cursor (blank in place, no shift).
    public mutating func eraseChars(_ n: Int) {
        guard cells.indices.contains(cursor.row) else { return }
        let end = min(cursor.col + max(1, n), cols)
        guard cursor.col < end else { return }
        for c in cursor.col ..< end { cells[cursor.row][c] = .blank }
    }

    /// `ESC[nL` (IL) — insert `n` blank lines at the cursor row; lines below
    /// shift down, lines pushed past the bottom are lost.
    public mutating func insertLines(_ n: Int) {
        guard cells.indices.contains(cursor.row),
              cursor.row >= scrollTop, cursor.row <= scrollBottom else { return }
        let bot = min(scrollBottom, rows - 1)
        let count = min(max(1, n), bot - cursor.row + 1)
        guard count > 0 else { return }
        cells.removeSubrange((bot - count + 1) ..< (bot + 1))
        cells.insert(contentsOf: Self.blankGrid(rows: count, cols: cols), at: cursor.row)
    }

    /// `ESC[nM` (DL) — delete `n` lines at the cursor row; lines below shift up,
    /// blanks fill in at the bottom of the scroll region. No-op outside it.
    public mutating func deleteLines(_ n: Int) {
        guard cells.indices.contains(cursor.row),
              cursor.row >= scrollTop, cursor.row <= scrollBottom else { return }
        let bot = min(scrollBottom, rows - 1)
        let count = min(max(1, n), bot - cursor.row + 1)
        guard count > 0 else { return }
        cells.removeSubrange(cursor.row ..< (cursor.row + count))
        cells.insert(contentsOf: Self.blankGrid(rows: count, cols: cols), at: bot - count + 1)
    }

    // MARK: - Scrolling

    /// Scroll the entire grid up by `n` lines: top `n` lines fall off
    /// (into `scrollback`), `n` blank lines appear at the bottom. The
    /// cursor row stays put (used by `lineFeed` on the last row).
    public mutating func scrollUp(_ n: Int) {
        let top = scrollTop
        let bot = min(scrollBottom, rows - 1)
        guard top <= bot else { return }
        let count = min(max(0, n), bot - top + 1)
        guard count > 0 else { return }
        // Only a FULL-screen scroll on the MAIN buffer evicts to scrollback
        // (normal output scrolling into history). A sub-region scroll (DECSTBM —
        // e.g. vim's body while the footer is pinned) or the alternate screen
        // (`top`/`vim`/`less`) discards the lines, never churning history.
        let fullScreen = (top == 0 && bot == rows - 1)
        if fullScreen && !inAltScreen {
            // Retain evicted top lines, trimming in BATCHES (a per-line
            // removeFirst is an O(maxScrollback) memmove that dominates bulk
            // output; batching amortizes it).
            scrollback.append(contentsOf: cells[top..<(top + count)])
            if scrollback.count > Self.maxScrollback + Self.scrollbackSlack {
                scrollback.removeFirst(scrollback.count - Self.maxScrollback)
            }
        }
        cells.removeSubrange(top..<(top + count))
        cells.insert(contentsOf: Self.blankGrid(rows: count, cols: cols), at: bot - count + 1)
    }

    // MARK: - Alternate screen buffer (DEC 1049 / 1047 / 47)

    /// Enter the alternate screen buffer. Saves the main grid, scrollback,
    /// cursor, and pen; swaps in a fresh blank buffer with no scrollback and
    /// homes the cursor. Idempotent (a second enter while already in alt is a
    /// no-op, so the saved main state is never clobbered). Driven by DECSET
    /// 1049h / 1047h / 47h from the parser.
    public mutating func enterAltScreen() {
        guard !inAltScreen else { return }
        savedMain = SavedBuffer(cells: cells, cursor: cursor,
                                scrollback: scrollback, pen: pen)
        inAltScreen = true
        cells = Self.blankGrid(rows: rows, cols: cols)
        scrollback = []
        cursor = TerminalCursor()
        pen = .default
        scrollTop = 0; scrollBottom = rows - 1   // fresh buffer → full region
    }

    /// Exit the alternate screen buffer, restoring the saved main grid,
    /// scrollback, cursor, and pen. Idempotent (no-op when not in alt). The
    /// restored cursor is clamped to the current geometry. Driven by DECRST
    /// 1049l / 1047l / 47l from the parser.
    public mutating func exitAltScreen() {
        guard inAltScreen, let saved = savedMain else { return }
        inAltScreen = false
        cells = saved.cells
        scrollback = saved.scrollback
        pen = saved.pen
        cursor = TerminalCursor(row: clampRow(saved.cursor.row),
                                col: clampCol(saved.cursor.col))
        savedMain = nil
        scrollTop = 0; scrollBottom = rows - 1   // app's region doesn't outlive it
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

    /// Scroll the active region [scrollTop, scrollBottom] DOWN by `n` lines:
    /// the bottom `n` rows of the region fall off, `n` blank lines appear at the
    /// top of the region. Reverse scroll never touches scrollback. (TSK-735.)
    public mutating func scrollDown(_ n: Int) {
        let top = scrollTop
        let bot = min(scrollBottom, rows - 1)
        guard top <= bot else { return }
        let count = min(max(0, n), bot - top + 1)
        guard count > 0 else { return }
        cells.removeSubrange((bot - count + 1) ..< (bot + 1))
        cells.insert(contentsOf: Self.blankGrid(rows: count, cols: cols), at: top)
    }

    /// `ESC[t;b r` (DECSTBM) — set the scroll region to INCLUSIVE 0-based rows
    /// [top, bottom]. A degenerate/inverted/whole-screen range resets to the
    /// full screen. Homes the cursor (DEC spec). (TSK-735.)
    public mutating func setScrollRegion(top: Int, bottom: Int) {
        let t = max(0, top)
        let b = min(bottom, rows - 1)
        if t < b {
            scrollTop = t
            scrollBottom = b
        } else {
            scrollTop = 0
            scrollBottom = rows - 1
        }
        cursor = TerminalCursor(row: 0, col: 0)
    }

    // MARK: - Helpers

    private func clampRow(_ r: Int) -> Int { min(max(0, r), rows - 1) }
    private func clampCol(_ c: Int) -> Int { min(max(0, c), cols - 1) }
}
