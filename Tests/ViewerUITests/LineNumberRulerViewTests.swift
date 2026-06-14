import XCTest
@testable import ViewerUI

/// Host tests for the line-number ruler's newline-offset scan (TSK-828). The
/// scan was rewritten from a per-UTF-16-unit `NSString.character(at:)` (an
/// ObjC message-send per char — a first-scroll hitch on big logs) to a single
/// pass over the Swift `utf16` view. These pin that the OFFSETS are unchanged
/// (the binary-search line lookups depend on them) — incl. an equivalence
/// check against the exact old NSString computation (teeth).
final class LineNumberRulerViewTests: XCTestCase {

    func test_offsets_basic() {
        // a \n b b \n \n c  → '\n' at UTF-16 indices 1, 4, 5
        XCTAssertEqual(LineNumberRulerView.newlineUTF16Offsets(in: "a\nbb\n\nc"), [1, 4, 5])
    }

    func test_offsets_noNewlines_andEmpty() {
        XCTAssertEqual(LineNumberRulerView.newlineUTF16Offsets(in: ""), [])
        XCTAssertEqual(LineNumberRulerView.newlineUTF16Offsets(in: "abc"), [])
    }

    func test_offsets_areUTF16_pastASurrogatePair() {
        // "😀" is one Character but TWO UTF-16 units (a surrogate pair), so the
        // '\n' after it sits at UTF-16 index 2, not 1 (Character index).
        XCTAssertEqual(LineNumberRulerView.newlineUTF16Offsets(in: "😀\nx"), [2])
        XCTAssertEqual(LineNumberRulerView.newlineUTF16Offsets(in: "a😀b\n"), [4])
    }

    func test_offsets_trailingAndLeadingNewlines() {
        XCTAssertEqual(LineNumberRulerView.newlineUTF16Offsets(in: "\nx\n"), [0, 2])
    }

    /// Equivalence to the EXACT previous implementation across a mixed corpus
    /// (ASCII, CRLF, emoji, CJK) — proves the rewrite is byte-for-byte the same
    /// offsets the binary search was tuned against.
    func test_offsets_matchOldNSStringScan() {
        let samples = [
            "", "no newlines here", "line1\nline2\nline3",
            "windows\r\nstyle\r\nlines", "emoji 😀 line\nnext 🚀 line\n",
            "CJK 日本語\n中文\n", "\n\n\nblank lines\n\n",
        ]
        for s in samples {
            let ns = s as NSString
            var expected: [Int] = []
            var i = 0
            while i < ns.length {
                if ns.character(at: i) == 0x0A { expected.append(i) }
                i += 1
            }
            XCTAssertEqual(LineNumberRulerView.newlineUTF16Offsets(in: s), expected,
                "fast scan must equal the old NSString scan for: \(s.debugDescription)")
        }
    }
}
