import Foundation

/// Pure-logic, host-testable builder for the HEX viewer's text dump.
///
/// The HEX view renders the entire byte buffer as one pre-built string,
/// then attributes it once with a monospace font and pushes the
/// resulting `NSAttributedString` into an `NSTextView`'s `textStorage`.
/// For multi-MB files (cap is 4 MB) the row count climbs into the
/// hundreds of thousands — building that string on the main thread
/// stalls the app for hundreds of ms during the first render and on
/// every width-picker change.
///
/// `HexDumpBuilder` splits the work two ways:
///
/// * **Chunked.** `build(file:width:rowsPerChunk:onChunk:)` emits the
///   dump as a sequence of plain-`String` chunks via the callback —
///   header first (if any), then `rowsPerChunk` rows per chunk until
///   the buffer is exhausted. The UI layer can drive this from a
///   detached task and stream each chunk into `textStorage` via
///   `replaceCharacters` wrapped in `beginEditing`/`endEditing`,
///   keeping the main thread responsive.
///
/// * **All-at-once.** `buildAll(file:width:)` collapses the chunks into
///   a single string. Used by the synchronous one-shot path for tiny
///   files and by tests that want the canonical output.
///
/// The chunk math is in `chunkPlan(byteCount:width:rowsPerChunk:)` so
/// host tests can pin "the i-th chunk starts at byte X / row Y" without
/// instantiating an `NSTextView`.
///
/// Implementation note: `rowsPerChunk` is exposed mostly for tests.
/// Production callers should use `defaultRowsPerChunk`, tuned so each
/// chunk's character count stays in the 100–500 KB band — large enough
/// that per-chunk dispatch overhead doesn't dominate, small enough that
/// the main-thread `beginEditing/endEditing` window per chunk stays
/// well under a frame budget.
public enum HexDumpBuilder {

    /// Default rows-per-chunk. Picked so that at width=16 each chunk is
    /// ~300 KB of text (4096 × ~73 chars), which is well below the
    /// O(MB) main-thread cost of the synchronous build and gives the
    /// scroller a smooth incremental fill.
    public static let defaultRowsPerChunk: Int = 4096

    /// Result of a chunking plan — just the counts and the optional
    /// header. The text isn't materialized; that's done lazily by
    /// `build(...)` or `buildAll(...)`.
    public struct Plan: Equatable, Sendable {
        public let header: String
        public let headerCharCount: Int
        public let rowCount: Int
        public let rowsPerChunk: Int
        public let chunkCount: Int
        public let perRowChars: Int

        public init(header: String,
                    headerCharCount: Int,
                    rowCount: Int,
                    rowsPerChunk: Int,
                    chunkCount: Int,
                    perRowChars: Int) {
            self.header = header
            self.headerCharCount = headerCharCount
            self.rowCount = rowCount
            self.rowsPerChunk = rowsPerChunk
            self.chunkCount = chunkCount
            self.perRowChars = perRowChars
        }

        /// Row index where the i-th *body* chunk starts (zero-based).
        /// Bounds-checked; out-of-range returns `nil`.
        public func chunkStartRow(_ i: Int) -> Int? {
            guard i >= 0, i < chunkCount else { return nil }
            return i * rowsPerChunk
        }

        /// Number of rows in the i-th body chunk. The last chunk may
        /// be short. Out-of-range returns `nil`.
        public func chunkRowCount(_ i: Int) -> Int? {
            guard i >= 0, i < chunkCount else { return nil }
            let start = i * rowsPerChunk
            return min(rowsPerChunk, rowCount - start)
        }

        /// Byte offset where the i-th body chunk starts.
        public func chunkStartByte(_ i: Int, width: Int) -> Int? {
            guard let row = chunkStartRow(i) else { return nil }
            return row * width
        }
    }

    /// Build a chunking plan without materializing any text. Used by
    /// tests and by the streaming `build(...)` entry point.
    ///
    /// - Parameters:
    ///   - byteCount: byte count to dump (post-truncation).
    ///   - totalByteCount: pre-truncation file size, used in the
    ///     "Showing first N of M bytes" header.
    ///   - isTruncated: whether to emit the header.
    ///   - width: bytes per row.
    ///   - rowsPerChunk: chunk size in rows. Clamped to `>= 1`.
    public static func plan(byteCount: Int,
                            totalByteCount: Int,
                            isTruncated: Bool,
                            width: Int,
                            rowsPerChunk: Int = defaultRowsPerChunk) -> Plan {
        precondition(width > 0, "width must be > 0")
        let safeRowsPerChunk = max(1, rowsPerChunk)
        let rowCount = HexLayout.rowCount(byteCount: byteCount, width: width)
        let perRowChars = HexLayout.renderedRowLength(width: width)
        let header: String
        let headerCharCount: Int
        if isTruncated {
            let s = "Showing first \(byteCount) of \(totalByteCount) bytes\n\n"
            header = s
            headerCharCount = s.count
        } else {
            header = ""
            headerCharCount = 0
        }
        let chunkCount: Int = rowCount == 0
            ? 0
            : (rowCount + safeRowsPerChunk - 1) / safeRowsPerChunk
        return Plan(header: header,
                    headerCharCount: headerCharCount,
                    rowCount: rowCount,
                    rowsPerChunk: safeRowsPerChunk,
                    chunkCount: chunkCount,
                    perRowChars: perRowChars)
    }

    /// Stream the dump as plain-`String` chunks. The header (if any)
    /// is the first chunk; body chunks follow in row-order.
    ///
    /// The `onChunk` callback receives `(chunkIndex, chunk)`. Index 0
    /// is the header when `plan.headerCharCount > 0`, or the first
    /// body chunk otherwise. The callback can return `false` to abort
    /// further chunking — used by the UI layer to drop a stale build
    /// when the user changes width / file mid-render.
    ///
    /// The function is `nonisolated` and only reads `file.data`; safe
    /// to call from any actor / detached task.
    ///
    /// - Returns: the plan that was used. Useful for tests.
    @discardableResult
    public static func build(file: BinaryFile,
                             width: Int,
                             rowsPerChunk: Int = defaultRowsPerChunk,
                             onChunk: (_ index: Int, _ chunk: String) -> Bool)
        -> Plan
    {
        let p = plan(byteCount: file.byteCount,
                     totalByteCount: file.totalByteCount,
                     isTruncated: file.isTruncated,
                     width: width,
                     rowsPerChunk: rowsPerChunk)

        var idx = 0
        if p.headerCharCount > 0 {
            if !onChunk(idx, p.header) { return p }
            idx += 1
        }
        // Empty-body fast path: emit nothing more.
        guard p.rowCount > 0 else { return p }

        let bytes = file.data
        for chunkI in 0..<p.chunkCount {
            let startRow = chunkI * p.rowsPerChunk
            let endRow = min(startRow + p.rowsPerChunk, p.rowCount)
            let startByte = startRow * width
            let endByte = min(endRow * width, file.byteCount)
            let s = renderRows(bytes: bytes,
                               startByte: startByte,
                               endByte: endByte,
                               width: width,
                               rowsInChunk: endRow - startRow,
                               perRowChars: p.perRowChars)
            if !onChunk(idx, s) { return p }
            idx += 1
        }
        return p
    }

    /// Convenience: build the entire dump as a single string. Same
    /// output as concatenating every chunk from `build(...)`.
    public static func buildAll(file: BinaryFile, width: Int) -> String {
        var out = String()
        let p = plan(byteCount: file.byteCount,
                     totalByteCount: file.totalByteCount,
                     isTruncated: file.isTruncated,
                     width: width,
                     rowsPerChunk: defaultRowsPerChunk)
        let cap = p.headerCharCount + p.rowCount * p.perRowChars
        out.reserveCapacity(cap)
        build(file: file, width: width, rowsPerChunk: defaultRowsPerChunk) {
            _, chunk in
            out += chunk
            return true
        }
        return out
    }

    // MARK: - Row rendering

    private static let hexChars: [Character] = [
        "0","1","2","3","4","5","6","7",
        "8","9","a","b","c","d","e","f"
    ]

    /// Render `rowsInChunk` rows starting at byte `startByte`. Pure;
    /// no allocation other than the returned string.
    private static func renderRows(bytes: Data,
                                   startByte: Int,
                                   endByte: Int,
                                   width: Int,
                                   rowsInChunk: Int,
                                   perRowChars: Int) -> String {
        var s = String()
        s.reserveCapacity(rowsInChunk * perRowChars)

        var rowStart = startByte
        while rowStart < endByte {
            var off = rowStart
            var offBuf = [Character](repeating: "0", count: 8)
            for i in stride(from: 7, through: 0, by: -1) {
                offBuf[i] = hexChars[off & 0xF]
                off >>= 4
            }
            s += String(offBuf)
            s += "  "

            let rowEnd = min(rowStart + width, endByte)
            for i in 0..<width {
                let pos = rowStart + i
                if pos < rowEnd {
                    let b = bytes[pos]
                    s.append(hexChars[Int(b >> 4)])
                    s.append(hexChars[Int(b & 0xF)])
                } else {
                    s += "  "
                }
                if i != width - 1 { s.append(" ") }
            }
            s += "  "
            // Pad short final row so every row has the same character
            // length — lets the highlight code address bytes by
            // `(row * rowLength + col)` without per-row variable
            // lengths.
            for i in 0..<width {
                let pos = rowStart + i
                if pos < rowEnd {
                    let b = bytes[pos]
                    if (32...126).contains(b) {
                        s.append(Character(UnicodeScalar(b)))
                    } else {
                        s.append(".")
                    }
                } else {
                    s.append(" ")
                }
            }
            s.append("\n")
            rowStart += width
        }
        return s
    }
}
