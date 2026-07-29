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
    /// PERF-02: line-start offsets in UTF-16 code units (NSRange unit).
    /// Precomputed in the single init scan so `utf16Offset(for:)` is
    /// O(intra-line) — it walks only the current line, not the whole
    /// prefix of the document. The prior `text.utf16.distance(from:
    /// startIndex, to: idx)` was O(offset-from-doc-start), so converting
    /// a batch of N diagnostics on a large file was O(N · docLength).
    private let lineStartUTF16: [Int]

    public init(text: String, encoding: LSPPositionEncoding) {
        self.text = text
        self.encoding = encoding
        var starts: [Int] = [0]
        var indexStarts: [String.Index] = [text.startIndex]
        var utf16Starts: [Int] = [0]
        var codeUnits = 0
        var utf16Units = 0
        var idx = text.startIndex
        while idx < text.endIndex {
            let ch = text[idx]
            codeUnits += Self.codeUnitCount(of: ch, in: encoding)
            utf16Units += ch.utf16.count
            let next = text.index(after: idx)
            if Self.isLineTerminator(ch) {
                starts.append(codeUnits)
                indexStarts.append(next)
                utf16Starts.append(utf16Units)
            }
            idx = next
        }
        self.lineStartCodeUnits = starts
        self.lineStartCharacterIndices = indexStarts
        self.lineStartUTF16 = utf16Starts
    }

    /// LSP line terminators: `\n`, `\r\n`, `\r` (the spec's three).
    ///
    /// THE CRLF BUG (audit THEME 2, fixed 2026-07-29): the scan compared
    /// `ch == "\n"`, but in Swift `\r\n` is ONE grapheme cluster and that
    /// Character does NOT equal `"\n"` — so a CRLF file recorded zero line
    /// starts and the whole document became line 0. Every LSP feature keyed by
    /// line — diagnostics, folds, goto, formatter edits — then landed at the
    /// wrong offsets (a formatter edit against "line 40" applied at line 0,
    /// corrupting the buffer). A lone `\r` (classic-Mac) had the same failure.
    ///
    /// Deliberately NOT `Character.isNewline`: that also matches U+2028/U+2029/
    /// U+000B/U+000C/U+0085, which LSP servers do not treat as line breaks —
    /// splitting on those would desync our line numbering from the server's.
    static func isLineTerminator(_ ch: Character) -> Bool {
        ch == "\n" || ch == "\r\n" || ch == "\r"
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
        // Binary-search the line-start array for the largest `i` with
        // `lineStartCharacterIndices[i] <= clamped`. The array is
        // strictly ascending (each entry is the index after a `\n`) so
        // a standard upper-bound search applies: find the first entry
        // strictly greater than `clamped`, then back up one. The array
        // always contains at least one element (startIndex), so the
        // result is well-defined.
        var lo = 0
        var hi = lineStartCharacterIndices.count // exclusive
        while lo < hi {
            let mid = lo &+ (hi &- lo) / 2
            if lineStartCharacterIndices[mid] <= clamped {
                lo = mid &+ 1
            } else {
                hi = mid
            }
        }
        let line = lo - 1 // lo is the first index > clamped; predecessor is the line
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
            // Same terminator set as the init scan — `== "\n"` here walked
            // PAST the end of a CRLF line into the next one.
            if Self.isLineTerminator(ch) { break }
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
    ///
    /// PERF-02: O(intra-line). We resolve the line's precomputed UTF-16
    /// base from `lineStartUTF16`, then walk only within that line to
    /// the target index counting UTF-16 units — instead of
    /// `text.utf16.distance(from: startIndex, to: idx)`, which rescans
    /// the entire prefix of the document on every call (O(offset)). For
    /// a batch of N ranges on a D-length document that turns
    /// O(N · D) into O(N · lineLength).
    public func utf16Offset(for position: LSPPosition) -> Int {
        guard position.line >= 0, position.line < lineStartCharacterIndices.count else {
            // Out-of-range line clamps to document end (matches
            // `stringIndex(for:)`), so its UTF-16 offset is the full
            // UTF-16 length. `lineStartUTF16.last` is the last line's
            // base; add the trailing line's units by walking from there.
            return utf16OffsetWalkingFromLine(
                lineStartCharacterIndices.count - 1, to: text.endIndex)
        }
        let lineStartIdx = lineStartCharacterIndices[position.line]
        let target = stringIndex(for: position)
        // Walk from the line start to the resolved index, counting
        // UTF-16 units. `stringIndex(for:)` never crosses the newline,
        // so this stays within the line.
        var units = lineStartUTF16[position.line]
        var idx = lineStartIdx
        while idx < target {
            units += text[idx].utf16.count
            idx = text.index(after: idx)
        }
        return units
    }

    /// Shared tail walk for the clamp-to-end path. `line` is a valid
    /// index into `lineStartUTF16`; walks from that line's start to
    /// `end` accumulating UTF-16 units onto the line's precomputed base.
    private func utf16OffsetWalkingFromLine(_ line: Int, to end: String.Index) -> Int {
        let safeLine = max(0, min(line, lineStartUTF16.count - 1))
        var units = lineStartUTF16[safeLine]
        var idx = lineStartCharacterIndices[safeLine]
        while idx < end {
            units += text[idx].utf16.count
            idx = text.index(after: idx)
        }
        return units
    }

    /// Convert an LSP range to an `NSRange` in UTF-16 code units —
    /// the unit NSTextView's selection APIs use.
    public func nsRange(for range: LSPRange) -> NSRange {
        let start = utf16Offset(for: range.start)
        let end = utf16Offset(for: range.end)
        return NSRange(location: start, length: max(0, end - start))
    }
}

/// PERF-02: a tiny single-slot cache for `LSPPositionConverter`.
///
/// Building a converter is O(documentLength) (one pass to compute the
/// line-start arrays). Diagnostics pushes, fold-range requests, and
/// hover/goto translations all happen repeatedly against the *same*
/// unchanged buffer (the viewer is read-only between edits), so
/// rebuilding the converter on every request re-pays that O(D) scan
/// needlessly. Callers that translate against one document at a time
/// (the editor coordinator, the outline section) hold one of these and
/// call `converter(text:encoding:)`; a cache hit (same text identity +
/// encoding) returns the memoized converter for free.
///
/// Keyed by `(text byte-length, a cheap content hash, encoding)` rather
/// than the full string so the hit-check is O(1)-ish: we only fall back
/// to a full `==` when the cheap key matches. Not thread-safe by design
/// — instantiate one per isolation domain (e.g. a `@MainActor` field).
/// Single-slot is sufficient because a given consumer works one active
/// document at a time; a multi-entry LRU would add eviction policy for
/// no measured win at this access pattern.
public final class LSPPositionConverterCache {
    private var cachedKey: Key?
    private var cached: LSPPositionConverter?

    /// Number of times `converter(text:encoding:)` had to build a fresh
    /// converter (cache miss). A repeated call with unchanged inputs
    /// must NOT increment this. Exposed so callers / tests can confirm
    /// the O(documentLength) rebuild is actually being avoided
    /// (`LSPPositionConverter` is a value type, so instance identity
    /// can't be used to detect a hit).
    public private(set) var buildCount: Int = 0

    private struct Key: Equatable {
        let count: Int
        let hash: Int
        let encoding: LSPPositionEncoding
    }

    public init() {}

    /// Return a converter for `text`/`encoding`, reusing the cached one
    /// when the inputs are unchanged. On a key match we still confirm
    /// with a full `text == cached.text` comparison to rule out a hash
    /// collision before handing back a stale converter.
    public func converter(
        text: String, encoding: LSPPositionEncoding
    ) -> LSPPositionConverter {
        let key = Key(count: text.utf8.count, hash: text.hashValue, encoding: encoding)
        if key == cachedKey, let hit = cached, hit.text == text {
            return hit
        }
        let fresh = LSPPositionConverter(text: text, encoding: encoding)
        cachedKey = key
        cached = fresh
        buildCount += 1
        return fresh
    }

    /// Drop the memoized converter (e.g. when the document closes).
    public func invalidate() {
        cachedKey = nil
        cached = nil
    }
}
