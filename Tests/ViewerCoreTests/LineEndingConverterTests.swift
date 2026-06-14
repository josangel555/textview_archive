import XCTest
@testable import ViewerCore

/// Teeth for `LineEndingConverter` (TSK-675, robust plain-text editing): the
/// write side of `LineEndingDetector`. Every break kind normalizes to the
/// target; non-break content + the no-trailing-newline shape are preserved; the
/// CRLF grapheme is split correctly (the recurring trap).
final class LineEndingConverterTests: XCTestCase {

    func test_mixed_toLF_normalizesEveryBreak() {
        let mixed = "a\r\nb\nc\rd"   // CRLF, LF, CR
        XCTAssertEqual(LineEndingConverter.convert(mixed, to: .lf), "a\nb\nc\nd")
        // ...and the detector now agrees it's pure LF.
        XCTAssertEqual(LineEndingDetector.detect(in: LineEndingConverter.convert(mixed, to: .lf)), .lf)
    }

    func test_lf_toCRLF() {
        XCTAssertEqual(LineEndingConverter.convert("a\nb\nc", to: .crlf), "a\r\nb\r\nc")
    }

    func test_crlf_toLF_doesNotDoubleCount() {
        // The CRLF pair becomes ONE LF, not two (the grapheme trap).
        XCTAssertEqual(LineEndingConverter.convert("a\r\nb", to: .lf), "a\nb")
    }

    func test_loneCR_toLF() {
        XCTAssertEqual(LineEndingConverter.convert("a\rb\rc", to: .lf), "a\nb\nc")
    }

    func test_idempotent_lfToLf_unchanged() {
        let s = "already\nunix\nstyle\n"
        XCTAssertEqual(LineEndingConverter.convert(s, to: .lf), s)
    }

    func test_noTrailingNewline_preserved() {
        // Conversion changes break bytes only — it never appends a terminator.
        XCTAssertEqual(LineEndingConverter.convert("no trailing break", to: .crlf), "no trailing break")
        XCTAssertEqual(LineEndingConverter.convert("ends with break\n", to: .crlf), "ends with break\r\n")
    }

    func test_empty_isEmpty() {
        XCTAssertEqual(LineEndingConverter.convert("", to: .crlf), "")
    }

    func test_contentScalarsPreserved() {
        // Non-break scalars (incl. multi-byte) pass through verbatim.
        let s = "café 🌟\nλ\r\nx"
        XCTAssertEqual(LineEndingConverter.convert(s, to: .lf), "café 🌟\nλ\nx")
    }

    func test_nonNormalizableTargets_passThrough() {
        let s = "a\r\nb"
        XCTAssertEqual(LineEndingConverter.convert(s, to: .mixed), s)
        XCTAssertEqual(LineEndingConverter.convert(s, to: .none), s)
    }
}
