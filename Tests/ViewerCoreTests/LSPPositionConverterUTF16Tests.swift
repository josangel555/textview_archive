import XCTest
@testable import ViewerCore

/// PERF-02 coverage for `LSPPositionConverter.utf16Offset(for:)` and the
/// `LSPPositionConverterCache`.
///
/// `utf16Offset` was rewritten to be O(intra-line): it resolves the
/// line's precomputed UTF-16 base from `lineStartUTF16` and walks only
/// within the line, instead of `text.utf16.distance(from: startIndex,
/// to: idx)` which rescanned the whole document prefix per call. These
/// tests pin the *correctness* of the rewrite (the perf win is exercised
/// by the consumers; the contract is that the offset is identical to the
/// brute-force walk for every encoding + Unicode shape).
final class LSPPositionConverterUTF16Tests: XCTestCase {

    // MARK: - utf16Offset agrees with brute-force distance

    /// Brute-force oracle: the pre-rewrite implementation.
    private func oracleUTF16Offset(
        _ c: LSPPositionConverter, _ pos: LSPPosition
    ) -> Int {
        let idx = c.stringIndex(for: pos)
        return c.text.utf16.distance(from: c.text.startIndex, to: idx)
    }

    func test_utf16Offset_matchesOracle_acrossEncodingsAndUnicode() {
        // The converter's *encoding* drives `stringIndex(for:)` (how an
        // LSP character count maps to a String.Index), but the RESULT is
        // always a UTF-16 offset. Verify the fast path equals the oracle
        // for every encoding the server might negotiate.
        let texts = [
            "abc\ndefgh\nij",
            "let x = \"🚀\"\nlet y = 1\n",
            "e\u{0301}llo\nworld",           // combining mark on line 0
            "🚀🚀🚀\nplain\n🌍 end",          // emoji-heavy
            "",
            "\n\n\n",                        // empty lines
            "no trailing newline",
        ]
        for text in texts {
            for encoding in [LSPPositionEncoding.utf16, .utf8, .utf32] {
                let c = LSPPositionConverter(text: text, encoding: encoding)
                let lineCount = text.reduce(1) { $0 + ($1 == "\n" ? 1 : 0) }
                for line in 0..<(lineCount + 1) { // +1 to probe out-of-range line
                    for character in [0, 1, 2, 3, 5, 50] {
                        let pos = LSPPosition(line: line, character: character)
                        XCTAssertEqual(
                            c.utf16Offset(for: pos),
                            oracleUTF16Offset(c, pos),
                            "encoding=\(encoding) line=\(line) char=\(character) text=\(text.debugDescription)"
                        )
                    }
                }
            }
        }
    }

    func test_utf16Offset_outOfRangeLine_clampsToDocEnd() {
        let text = "abc\ndef"
        let c = LSPPositionConverter(text: text, encoding: .utf16)
        let off = c.utf16Offset(for: LSPPosition(line: 99, character: 0))
        XCTAssertEqual(off, text.utf16.count,
            "an out-of-range line must clamp to the document's UTF-16 length")
    }

    func test_nsRange_unchanged_afterRewrite() {
        // Re-assert the existing nsRange contract still holds (the
        // rewrite is internal to utf16Offset, nsRange composes two).
        let text = "abc\ndefgh"
        let c = LSPPositionConverter(text: text, encoding: .utf16)
        let nsr = c.nsRange(for: LSPRange(
            start: LSPPosition(line: 1, character: 1),
            end:   LSPPosition(line: 1, character: 4)))
        XCTAssertEqual(nsr.location, 5)
        XCTAssertEqual(nsr.length, 3)
    }

    // MARK: - Cache

    func test_cache_avoidsRebuild_onHit() {
        let cache = LSPPositionConverterCache()
        let text = "hello\nworld"
        _ = cache.converter(text: text, encoding: .utf16)
        XCTAssertEqual(cache.buildCount, 1, "first call is a miss → one build")
        _ = cache.converter(text: text, encoding: .utf16)
        _ = cache.converter(text: text, encoding: .utf16)
        XCTAssertEqual(cache.buildCount, 1,
            "repeated calls with unchanged (text, encoding) must reuse the converter")
    }

    func test_cache_missesOnTextChange() {
        let cache = LSPPositionConverterCache()
        _ = cache.converter(text: "v1", encoding: .utf16)
        _ = cache.converter(text: "v2", encoding: .utf16)
        XCTAssertEqual(cache.buildCount, 2, "changed text must rebuild the converter")
    }

    func test_cache_missesOnEncodingChange() {
        let cache = LSPPositionConverterCache()
        _ = cache.converter(text: "same", encoding: .utf16)
        _ = cache.converter(text: "same", encoding: .utf8)
        XCTAssertEqual(cache.buildCount, 2, "changed encoding must rebuild the converter")
    }

    func test_cache_invalidate_forcesRebuild() {
        let cache = LSPPositionConverterCache()
        _ = cache.converter(text: "x", encoding: .utf16)
        cache.invalidate()
        _ = cache.converter(text: "x", encoding: .utf16)
        XCTAssertEqual(cache.buildCount, 2, "invalidate() must drop the memoized converter")
    }

    func test_cache_producesCorrectConverter() {
        // A cache hit must be a converter built from the right text.
        let cache = LSPPositionConverterCache()
        let text = "abc\ndefgh"
        _ = cache.converter(text: text, encoding: .utf16) // prime
        let hit = cache.converter(text: text, encoding: .utf16)
        XCTAssertEqual(hit.text, text)
        let nsr = hit.nsRange(for: LSPRange(
            start: LSPPosition(line: 1, character: 1),
            end:   LSPPosition(line: 1, character: 4)))
        XCTAssertEqual(nsr, NSRange(location: 5, length: 3))
    }
}
