import Foundation

/// Pure, host-testable bidirectional mapping between a character position
/// in the rendered hex dump and the underlying byte buffer — at *nibble*
/// granularity so the editor can place the caret on the high or low nibble
/// of a hex byte, or on a single ASCII glyph.
///
/// The read-only viewer (`HexView.charIndexToByteOffset`) only needed
/// char → byte at byte granularity for click-to-highlight. Editing needs
/// more: which *nibble* of which byte a hex char hits, whether a char is
/// in the ASCII column, and the inverse (byte+nibble+column → char index)
/// so arrow / tab navigation and post-edit caret placement can target an
/// exact glyph. This type formalizes that math on top of `HexLayout`.
///
/// Layout recap (see `HexLayout.renderedRowLength`):
///   `OOOOOOOO␣␣HH␣HH␣…␣HH␣␣AAAA…\n`
///    └ 8 ──┘└2┘└── width*3-1 ─┘└2┘└ width ┘└1┘
/// Per-row character offsets come straight from `HexLayout.hexCharOffset`
/// / `HexLayout.asciiCharOffset`, so this stays in lock-step with the
/// builder and the highlight painter — one source of truth for addresses.
public enum HexCaretMap {

    /// Which column family a character position falls in, and the exact
    /// byte (+ nibble, for hex) it addresses.
    public enum Hit: Equatable, Sendable {
        /// A hex digit. `nibble` is 0 for the high nibble (left digit),
        /// 1 for the low nibble (right digit).
        case hex(byte: Int, nibble: Int)
        /// An ASCII glyph for `byte`.
        case ascii(byte: Int)
    }

    /// Map a character index in the rendered dump to a byte + column.
    ///
    /// - Parameters:
    ///   - charIndex: 0-based character offset into the rendered string.
    ///   - width: bytes per row.
    ///   - byteCount: number of bytes actually present (caps the result;
    ///     a position in a short final row's padding returns `nil`).
    ///   - headerCharCount: character length of the optional truncation
    ///     header (0 when not truncated). Positions inside the header
    ///     return `nil`.
    /// - Returns: the hit, or `nil` for separators / gutters / offset
    ///   column / padding / out-of-range positions.
    public static func hit(charIndex: Int,
                           width: Int,
                           byteCount: Int,
                           headerCharCount: Int) -> Hit? {
        guard width > 0, charIndex >= headerCharCount else { return nil }
        let rowLength = HexLayout.renderedRowLength(width: width)
        let rel = charIndex - headerCharCount
        let row = rel / rowLength
        let inRow = rel % rowLength

        let hexStart = HexLayout.hexCharOffset(inRowColumn: 0)
        // Last char of the hex block is the low nibble of the final
        // column; the trailing separator after it doesn't exist (the
        // builder emits `HH␣HH…HH` with no trailing space), so the hex
        // block spans [hexStart, hexStart + width*3 - 1).
        let hexBlockEnd = hexStart + width * 3 - 1
        let asciiStart = HexLayout.asciiCharOffset(inRowColumn: 0, width: width)
        let asciiEnd = asciiStart + width

        if inRow >= hexStart, inRow < hexBlockEnd {
            let within = inRow - hexStart          // 0-based into "HH␣HH␣…"
            let col = within / 3                   // 3 chars per byte: H H ␣
            let posInByte = within % 3             // 0 = high, 1 = low, 2 = sep
            guard posInByte != 2 else { return nil } // landed on a separator
            let byte = row * width + col
            guard byte < byteCount else { return nil }
            return .hex(byte: byte, nibble: posInByte)
        }
        if inRow >= asciiStart, inRow < asciiEnd {
            let col = inRow - asciiStart
            let byte = row * width + col
            guard byte < byteCount else { return nil }
            return .ascii(byte: byte)
        }
        return nil  // offset column, gutters, separators, newline, padding
    }

    /// Inverse of `hit`: the character index of the high (or `nibble`-th)
    /// hex digit for `byte`, accounting for the header.
    public static func hexCharIndex(byte: Int,
                                    nibble: Int = 0,
                                    width: Int,
                                    headerCharCount: Int) -> Int {
        precondition(width > 0)
        let row = HexLayout.row(forOffset: byte, width: width)
        let col = HexLayout.column(forOffset: byte, width: width)
        let rowStart = headerCharCount + row * HexLayout.renderedRowLength(width: width)
        return rowStart + HexLayout.hexCharOffset(inRowColumn: col) + min(max(nibble, 0), 1)
    }

    /// Inverse of `hit` for the ASCII column: char index of `byte`'s glyph.
    public static func asciiCharIndex(byte: Int,
                                      width: Int,
                                      headerCharCount: Int) -> Int {
        precondition(width > 0)
        let row = HexLayout.row(forOffset: byte, width: width)
        let col = HexLayout.column(forOffset: byte, width: width)
        let rowStart = headerCharCount + row * HexLayout.renderedRowLength(width: width)
        return rowStart + HexLayout.asciiCharOffset(inRowColumn: col, width: width)
    }

    /// Step a `(byte, nibble)` hex caret forward (`+1`) or backward (`-1`)
    /// by one *nibble*, rolling across byte and buffer boundaries. Clamped
    /// to `[0, byteCount)`; returns the same position at the ends rather
    /// than wrapping. `byteCount == 0` returns `nil` (nothing to edit).
    public static func advanceHex(byte: Int,
                                  nibble: Int,
                                  by delta: Int,
                                  byteCount: Int) -> (byte: Int, nibble: Int)? {
        guard byteCount > 0 else { return nil }
        // Flatten to a nibble index, step, clamp, re-expand.
        let flat = byte * 2 + min(max(nibble, 0), 1) + delta
        let maxFlat = byteCount * 2 - 1
        let clamped = min(max(flat, 0), maxFlat)
        return (byte: clamped / 2, nibble: clamped % 2)
    }

    /// Step an ASCII caret forward/backward by one byte, clamped.
    public static func advanceAscii(byte: Int,
                                    by delta: Int,
                                    byteCount: Int) -> Int? {
        guard byteCount > 0 else { return nil }
        return min(max(byte + delta, 0), byteCount - 1)
    }
}
