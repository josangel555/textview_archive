import XCTest
@testable import ViewerCore

/// `LSPPositionConverter` — boundary-correctness for utf-8/16/32 and
/// for emoji / combining-mark grapheme drift. Pure-logic; no subprocess.
final class LSPPositionConverterTests: XCTestCase {

    func test_utf16_simple_ascii_line_offsets() {
        let text = "abc\ndef\nghi"
        let c = LSPPositionConverter(text: text, encoding: .utf16)
        // 'd' is line 1, char 0
        let idx = text.index(text.startIndex, offsetBy: 4) // after "abc\n"
        let pos = c.lspPosition(for: idx)
        XCTAssertEqual(pos.line, 1)
        XCTAssertEqual(pos.character, 0)
    }

    func test_utf16_emoji_counts_two_units() {
        let text = "let x = \"🚀\""
        let c = LSPPositionConverter(text: text, encoding: .utf16)
        let end = text.endIndex
        let pos = c.lspPosition(for: end)
        // 11 grapheme clusters (`l e t   x   =   " 🚀 "`), 12 UTF-16
        // code units (🚀 is a surrogate pair = 2 units).
        XCTAssertEqual(pos.line, 0)
        XCTAssertEqual(pos.character, 12)
    }

    func test_utf8_emoji_counts_four_bytes() {
        let text = "🚀"
        let c = LSPPositionConverter(text: text, encoding: .utf8)
        let pos = c.lspPosition(for: text.endIndex)
        XCTAssertEqual(pos.line, 0)
        XCTAssertEqual(pos.character, 4)
    }

    func test_utf32_emoji_counts_one_unit() {
        let text = "🚀"
        let c = LSPPositionConverter(text: text, encoding: .utf32)
        let pos = c.lspPosition(for: text.endIndex)
        XCTAssertEqual(pos.line, 0)
        XCTAssertEqual(pos.character, 1) // one scalar
    }

    func test_lsp_position_to_string_index_roundtrips() {
        let text = "line zero\nline one with 🚀 emoji\nline two"
        let c = LSPPositionConverter(text: text, encoding: .utf16)
        // Round-trip every grapheme index.
        var idx = text.startIndex
        while idx <= text.endIndex {
            let pos = c.lspPosition(for: idx)
            let back = c.stringIndex(for: pos)
            XCTAssertEqual(back, idx,
                "round-trip failed at \(text.distance(from: text.startIndex, to: idx))")
            if idx == text.endIndex { break }
            idx = text.index(after: idx)
        }
    }

    func test_clamps_out_of_range_position() {
        let text = "hello"
        let c = LSPPositionConverter(text: text, encoding: .utf16)
        // Past EOL clamps to end of line.
        let idx = c.stringIndex(for: LSPPosition(line: 0, character: 100))
        XCTAssertEqual(idx, text.endIndex)
        // Past EOF clamps to end of file.
        let idx2 = c.stringIndex(for: LSPPosition(line: 99, character: 0))
        XCTAssertEqual(idx2, text.endIndex)
    }

    func test_nsRange_for_lspRange() {
        let text = "abc\ndefgh"
        let c = LSPPositionConverter(text: text, encoding: .utf16)
        let range = LSPRange(
            start: LSPPosition(line: 1, character: 1),
            end:   LSPPosition(line: 1, character: 4))
        let nsr = c.nsRange(for: range)
        XCTAssertEqual(nsr.location, 5)  // "abc\n" + 'd'
        XCTAssertEqual(nsr.length, 3)    // "efg"
    }

    /// S2-H: an LSP position whose `character` lands "inside" a
    /// multi-code-unit grapheme (surrogate pair / emoji) used to
    /// overshoot — the loop consumed the whole char and advanced
    /// `idx` past it. After the fix the loop breaks at the boundary
    /// so the returned `idx` is at the grapheme's start.
    func test_insideGraphemeClampsToCharBoundary() {
        // "ab🚀cd" — UTF-16: a(1) b(1) 🚀(2 surrogate units) c(1) d(1)
        let text = "ab🚀cd"
        let c = LSPPositionConverter(text: text, encoding: .utf16)
        // Position character=3 lands INSIDE the surrogate pair (after
        // first unit). Pre-fix: idx advanced past 🚀 → pointed at 'c'.
        // Post-fix: idx stays at 🚀 start.
        let badPos = LSPPosition(line: 0, character: 3)
        let idx = c.stringIndex(for: badPos)
        // Distance from start should be 2 graphemes ("ab"), not 3.
        let dist = text.distance(from: text.startIndex, to: idx)
        XCTAssertEqual(
            dist, 2,
            "inside-grapheme LSP position must clamp to char boundary, not overshoot"
        )
    }

    func test_combining_marks_utf16() {
        // 'é' as base + combining acute = 2 unicode scalars, 2 UTF-16 units.
        // 'é' as precomposed = 1 scalar, 1 UTF-16 unit.
        let combining = "e\u{0301}"
        XCTAssertEqual(combining.count, 1) // grapheme count
        let c = LSPPositionConverter(text: combining, encoding: .utf16)
        let pos = c.lspPosition(for: combining.endIndex)
        XCTAssertEqual(pos.character, 2)
    }
}
