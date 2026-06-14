import XCTest
@testable import ViewerCore

/// Teeth for `DocumentStats.compute` (TSK-675 word-count panel): char/word/line
/// counts, CRLF-aware line counting, and grapheme-correct character counts.
final class DocumentStatsTests: XCTestCase {

    func test_basicSentence() {
        let s = DocumentStats.compute("hello world")
        XCTAssertEqual(s.characters, 11)
        XCTAssertEqual(s.charactersNoWhitespace, 10)
        XCTAssertEqual(s.words, 2)
        XCTAssertEqual(s.lines, 1)
    }

    func test_empty_allZero() {
        let s = DocumentStats.compute("")
        XCTAssertEqual(s, DocumentStats(characters: 0, charactersNoWhitespace: 0, words: 0, lines: 0))
    }

    func test_lineCounting_trailingNewlineNotDoubleCounted() {
        XCTAssertEqual(DocumentStats.compute("a\nb").lines, 2)
        XCTAssertEqual(DocumentStats.compute("a\nb\n").lines, 2, "trailing newline doesn't add an empty line")
        XCTAssertEqual(DocumentStats.compute("a\n\nb").lines, 3, "a genuine blank line counts")
        XCTAssertEqual(DocumentStats.compute("single").lines, 1)
    }

    func test_lineCounting_CRLF_isOneBreak() {
        XCTAssertEqual(DocumentStats.compute("a\r\nb\r\nc").lines, 3)
    }

    func test_words_collapseRuns() {
        let s = DocumentStats.compute("  one   two\tthree\nfour  ")
        XCTAssertEqual(s.words, 4, "runs of whitespace separate, not multiply, words")
    }

    func test_graphemeCharacters_multibyte() {
        // "café 🌟" = c,a,f,é,space,🌟 = 6 graphemes; 5 non-whitespace; 2 words.
        let s = DocumentStats.compute("café 🌟")
        XCTAssertEqual(s.characters, 6)
        XCTAssertEqual(s.charactersNoWhitespace, 5)
        XCTAssertEqual(s.words, 2)
    }

    func test_summary_format() {
        XCTAssertEqual(DocumentStats.compute("a b\nc").summary, "2 lines · 3 words · 5 characters")
    }
}
