import Foundation

/// LSP-boundary position conversion.
///
/// LSP positions are `(line, character)` where `character` is a count
/// of code units in the negotiated encoding. The PoC's old
/// `positionForPoint` used a hand-rolled grapheme walk plus a UTF-16
/// re-walk; it was correct for ASCII but wrong for combining marks
/// and emoji whose grapheme count diverges from code-unit count.
///
/// This converter takes the buffer's String and computes positions
/// strictly in the negotiated encoding. It is intentionally small —
/// 100 lines, no dependencies — and covers the four cases that
/// actually arise:
///
///   1. NSTextView point → LSP position (for hover/goto)
///   2. Buffer character offset → LSP position
///   3. LSP position → buffer character offset (for jump-to-symbol)
///   4. LSP range → NSRange (for highlight overlays)
///
/// Tests live in `LSPPositionConverterTests`.
public struct LSPPositionConverter: Sendable {

    public let encoding: LSPPositionEncoding
    public let text: String

    /// Line-start offsets in the negotiated encoding's code units.
    /// Lazily computed once per document version; callers should
    /// reconstruct the converter when the text mutates. The viewer is
    /// read-only so this happens once per `didOpen`.
    private let lineStartCodeUnits: [Int]
    private let lineStartCharacterIndices: [String.Index]

    public init(text: String, encoding: LSPPositionEncoding) {
        self.text = text
        self.encoding = encoding
        var starts: [Int] = [0]
        var indexStarts: [String.Index] = [text.startIndex]
        var codeUnits = 0
        var idx = text.startIndex
        while idx < text.endIndex {
            let ch = text[idx]
            codeUnits += Self.codeUnitCount(of: ch, in: encoding)
            let next = text.index(after: idx)
            if ch == "\n" {
                starts.append(codeUnits)
                indexStarts.append(next)
            }
            idx = next
        }
        self.lineStartCodeUnits = starts
        self.lineStartCharacterIndices = indexStarts
    }

    private static func codeUnitCount(
        of ch: Character, in encoding: LSPPositionEncoding
    ) -> Int {
        switch encoding {
        case .utf8:  return ch.utf8.count
        case .utf16: return ch.utf16.count
        case .utf32: return ch.unicodeScalars.count
        }
    }

    // MARK: - Conversions

    /// Convert a String.Index (character offset) to an LSP `(line, char)`
    /// position in the negotiated encoding. Out-of-range indices clamp
    /// to the document end.
    public func lspPosition(for stringIndex: String.Index) -> LSPPosition {
        let clamped = min(stringIndex, text.endIndex)
        // Binary-search the line-start array to find the line number.
        var line = 0
        for i in (0..<lineStartCharacterIndices.count).reversed() {
            if lineStartCharacterIndices[i] <= clamped {
                line = i
                break
            }
        }
        let lineStart = lineStartCharacterIndices[line]
        // Count code units from line start to clamped index.
        var codeUnits = 0
        var idx = lineStart
        while idx < clamped {
            let ch = text[idx]
            // Newline never appears before clamped on the same line.
            codeUnits += Self.codeUnitCount(of: ch, in: encoding)
            idx = text.index(after: idx)
        }
        return LSPPosition(line: line, character: codeUnits)
    }

    /// Convert an LSP position to a String.Index. Clamps to end if
    /// the line / character is out of range (sourcekit-lsp occasionally
    /// returns positions past EOL in error responses).
    public func stringIndex(for position: LSPPosition) -> String.Index {
        guard position.line >= 0, position.line < lineStartCharacterIndices.count else {
            return text.endIndex
        }
        var idx = lineStartCharacterIndices[position.line]
        var remaining = position.character
        while remaining > 0 && idx < text.endIndex {
            let ch = text[idx]
            if ch == "\n" { break }
            let units = Self.codeUnitCount(of: ch, in: encoding)
            // S2-H: if the server position lands "inside" a multi-
            // code-unit grapheme (surrogate pair / emoji), consuming
            // the whole character would overshoot — we'd advance idx
            // PAST the character the position was meant to land in.
            // Clamp to the char boundary instead. LSP is undefined
            // for inside-grapheme positions; the most conservative
            // valid interpretation is "don't cross the boundary".
            if units > remaining { break }
            remaining -= units
            idx = text.index(after: idx)
        }
        return idx
    }

    /// Convert an LSP position to an NSRange-compatible UTF-16 offset
    /// (used by NSTextView selection APIs).
    public func utf16Offset(for position: LSPPosition) -> Int {
        let idx = stringIndex(for: position)
        return text.utf16.distance(from: text.startIndex, to: idx)
    }

    /// Convert an LSP range to an `NSRange` in UTF-16 code units —
    /// the unit NSTextView's selection APIs use.
    public func nsRange(for range: LSPRange) -> NSRange {
        let start = utf16Offset(for: range.start)
        let end = utf16Offset(for: range.end)
        return NSRange(location: start, length: max(0, end - start))
    }
}
