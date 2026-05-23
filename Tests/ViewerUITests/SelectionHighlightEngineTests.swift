import XCTest
@testable import ViewerUI

/// Pure-logic coverage for `SelectionHighlightEngine`. Doesn't touch
/// AppKit / NSTextView — fast, runnable on the host.
final class SelectionHighlightEngineTests: XCTestCase {

    private func engine(
        maxBytes: Int = 5 * 1024 * 1024,
        maxLen: Int = 100,
        minLen: Int = 2,
        wordLike: Bool = true
    ) -> SelectionHighlightEngine {
        SelectionHighlightEngine(policy: .init(
            maxHaystackBytes: maxBytes,
            maxSelectionLength: maxLen,
            minSelectionLength: minLen,
            requireWordLike: wordLike
        ))
    }

    // MARK: - happy path

    func test_findsOtherOccurrencesAndExcludesActiveSelection() {
        let text = "foo bar foo baz foo"
        // Pick the middle "foo" — locations 8..10.
        let sel = NSRange(location: 8, length: 3)
        let out = engine().otherOccurrences(
            in: text, selection: sel, haystackByteCount: text.utf8.count
        )
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0], NSRange(location: 0,  length: 3))
        XCTAssertEqual(out[1], NSRange(location: 16, length: 3))
    }

    func test_returnsEmptyWhenNoOtherOccurrences() {
        let text = "unique selection only"
        let sel = NSRange(location: 7, length: 9) // "selection"
        let out = engine().otherOccurrences(
            in: text, selection: sel, haystackByteCount: text.utf8.count
        )
        XCTAssertTrue(out.isEmpty)
    }

    func test_caseSensitiveSearch_doesNotMatchDifferentCase() {
        let text = "Foo foo FOO"
        // Selection = "Foo" at 0..2.
        let sel = NSRange(location: 0, length: 3)
        let out = engine().otherOccurrences(
            in: text, selection: sel, haystackByteCount: text.utf8.count
        )
        XCTAssertTrue(out.isEmpty, "literal case-sensitive should skip 'foo' and 'FOO'")
    }

    // MARK: - policy: size cap

    func test_returnsEmpty_whenHaystackExceedsByteCap() {
        let text = "abcabcabc"
        let sel = NSRange(location: 0, length: 3)
        let out = engine(maxBytes: 4).otherOccurrences(
            in: text, selection: sel, haystackByteCount: text.utf8.count
        )
        XCTAssertTrue(out.isEmpty, ">cap byte count must short-circuit")
    }

    func test_returnsEmpty_at5MBExactlyOverCap() {
        // We don't allocate 5MB; we pass haystackByteCount directly.
        let text = "abcabcabc"
        let sel = NSRange(location: 0, length: 3)
        let out = engine().otherOccurrences(
            in: text, selection: sel,
            haystackByteCount: 5 * 1024 * 1024 + 1
        )
        XCTAssertTrue(out.isEmpty)
    }

    // MARK: - policy: selection length

    func test_returnsEmpty_whenSelectionTooShort() {
        let text = "aaaa"
        let sel = NSRange(location: 0, length: 1)
        let out = engine().otherOccurrences(
            in: text, selection: sel, haystackByteCount: text.utf8.count
        )
        XCTAssertTrue(out.isEmpty)
    }

    func test_returnsEmpty_whenSelectionTooLong() {
        let needle = String(repeating: "x", count: 101)
        let text = needle + " " + needle
        let sel = NSRange(location: 0, length: 101)
        let out = engine().otherOccurrences(
            in: text, selection: sel, haystackByteCount: text.utf8.count
        )
        XCTAssertTrue(out.isEmpty)
    }

    func test_acceptsSelection_atExactly100Chars() {
        let needle = String(repeating: "x", count: 100)
        let text = needle + " " + needle
        let sel = NSRange(location: 0, length: 100)
        let out = engine().otherOccurrences(
            in: text, selection: sel, haystackByteCount: text.utf8.count
        )
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0], NSRange(location: 101, length: 100))
    }

    // MARK: - policy: word-like

    func test_rejectsSelectionWithInternalWhitespace_whenWordLike() {
        let text = "foo bar foo bar"
        // "foo bar" at 0..6.
        let sel = NSRange(location: 0, length: 7)
        let out = engine().otherOccurrences(
            in: text, selection: sel, haystackByteCount: text.utf8.count
        )
        XCTAssertTrue(out.isEmpty)
    }

    func test_acceptsWhitespaceSelection_whenWordLikeDisabled() {
        let text = "foo bar foo bar"
        let sel = NSRange(location: 0, length: 7) // "foo bar"
        let out = engine(wordLike: false).otherOccurrences(
            in: text, selection: sel, haystackByteCount: text.utf8.count
        )
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0], NSRange(location: 8, length: 7))
    }

    // MARK: - guard: invalid ranges

    func test_returnsEmpty_forOutOfBoundsSelection() {
        let text = "small text"
        let sel = NSRange(location: 5, length: 999)
        let out = engine().otherOccurrences(
            in: text, selection: sel, haystackByteCount: text.utf8.count
        )
        XCTAssertTrue(out.isEmpty)
    }

    func test_handlesRepeatedAdjacentOccurrences() {
        let text = "abab abab abab"
        // Pick the second "abab" (positions 5..8).
        let sel = NSRange(location: 5, length: 4)
        let out = engine().otherOccurrences(
            in: text, selection: sel, haystackByteCount: text.utf8.count
        )
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].location, 0)
        XCTAssertEqual(out[1].location, 10)
    }
}
