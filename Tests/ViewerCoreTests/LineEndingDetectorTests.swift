import XCTest
@testable import ViewerCore

/// Coverage for `LineEndingDetector` (TSK-509). The CRLF cases are the
/// load-bearing ones: a grapheme-view scan would miss the LF inside `\r\n`
/// and misclassify, so these pin the scalar-level logic.
final class LineEndingDetectorTests: XCTestCase {

    private func d(_ s: String) -> LineEnding { LineEndingDetector.detect(in: s) }

    func test_empty_andSingleLine_areNone() {
        XCTAssertEqual(d(""), .none)
        XCTAssertEqual(d("no breaks here"), .none)
    }

    func test_pureLF() {
        XCTAssertEqual(d("a\nb\nc"), .lf)
        XCTAssertEqual(d("a\nb\n"), .lf, "trailing newline doesn't change kind")
    }

    func test_pureCRLF() {
        XCTAssertEqual(d("a\r\nb\r\nc"), .crlf)
        XCTAssertEqual(d("a\r\nb\r\n"), .crlf)
    }

    func test_pureCR_classicMac() {
        XCTAssertEqual(d("a\rb\rc"), .cr)
    }

    func test_blankCRLFLine_isStillCRLF_notMixed() {
        // `\r\n\r\n` is two CRLF pairs (a blank line), NOT a CRLF + lone CR/LF.
        XCTAssertEqual(d("a\r\n\r\nb"), .crlf)
    }

    func test_mixed_crlfAndLf() {
        XCTAssertEqual(d("a\r\nb\nc"), .mixed)
    }

    func test_mixed_lfAndCr() {
        XCTAssertEqual(d("a\nb\rc"), .mixed)
    }

    func test_mixed_crlfAndCr() {
        // A CRLF pair plus a lone CR (the lone CR is followed by 'b', not LF).
        XCTAssertEqual(d("a\r\nb\rc"), .mixed)
    }

    func test_loneCRAtEnd_isCR() {
        XCTAssertEqual(d("a\r"), .cr)
    }

    func test_loneCRBeforeNonLF_isCR_notCRLF() {
        XCTAssertEqual(d("a\rb"), .cr)
    }

    // MARK: - sampleScalars bound (the StatusBar hot-path perf guard, TSK-510)

    func test_sampleBound_classifiesFromPrefixOnly() {
        // First 4 scalars are pure LF; a CR hidden past the bound is NOT seen.
        XCTAssertEqual(LineEndingDetector.detect(in: "a\nb\n" + String(repeating: "x", count: 100) + "\r",
                                                 sampleScalars: 4), .lf)
    }

    func test_sampleBound_zeroOrNegative_scansNothing() {
        XCTAssertEqual(LineEndingDetector.detect(in: "a\r\nb", sampleScalars: 0), .none)
    }

    func test_unbounded_matchesNilSample() {
        // The default (nil) and an over-large bound classify identically.
        let s = "a\r\nb\nc"
        XCTAssertEqual(LineEndingDetector.detect(in: s),
                       LineEndingDetector.detect(in: s, sampleScalars: 10_000))
    }

    func test_displayString_matchesRawValue() {
        XCTAssertEqual(LineEndingDetector.displayString(in: "a\r\nb"), "CRLF")
        XCTAssertEqual(LineEndingDetector.displayString(in: "a\nb"), "LF")
        XCTAssertEqual(LineEndingDetector.displayString(in: "abc"), "—")
    }
}
