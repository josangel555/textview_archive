import XCTest
@testable import ViewerCore

/// TSK-361 — the long-line soft-wrap policy that keeps a Jupyter `.ipynb` (or any
/// pathologically-long-line file) from hanging the source NSTextView on open.
/// Pure; host-safe.
final class SourceWrapPolicyTests: XCTestCase {

    // MARK: hasLongLine — threshold + line-break reset

    func test_shortLines_noLongLine() {
        // 2000 lines of 200 chars each — long file, but no single long line.
        let text = Array(repeating: String(repeating: "a", count: 200), count: 2000)
            .joined(separator: "\n")
        XCTAssertFalse(SourceWrapPolicy.hasLongLine(text))
    }

    func test_oneVeryLongLine_isDetected() {
        // A single 150k-char line (notebook base64 blob shape).
        let text = String(repeating: "x", count: 150_000)
        XCTAssertTrue(SourceWrapPolicy.hasLongLine(text))
    }

    func test_threshold_isInclusive() {
        XCTAssertTrue(SourceWrapPolicy.hasLongLine(String(repeating: "a", count: 10), threshold: 10),
                      "a line exactly `threshold` long trips the guard")
        XCTAssertFalse(SourceWrapPolicy.hasLongLine(String(repeating: "a", count: 9), threshold: 10),
                       "one short of `threshold` does not")
    }

    func test_lengthResetsAtLineBreaks() {
        // The same total characters, but split into short lines, is SAFE.
        let safe = Array(repeating: String(repeating: "a", count: 5), count: 100)
            .joined(separator: "\n")  // 100 lines × 5 chars
        XCTAssertFalse(SourceWrapPolicy.hasLongLine(safe, threshold: 20))
        // CRLF and classic-Mac CR both reset the line length.
        XCTAssertFalse(SourceWrapPolicy.hasLongLine("aaaaa\r\nbbbbb\rccccc", threshold: 8))
    }

    func test_longLineAfterShortLines_isDetected() {
        let text = "short\nshort\n" + String(repeating: "z", count: 50) + "\nshort"
        XCTAssertTrue(SourceWrapPolicy.hasLongLine(text, threshold: 40),
                      "a long line anywhere in the file is found")
    }

    func test_emptyAndZeroThreshold() {
        XCTAssertFalse(SourceWrapPolicy.hasLongLine(""))
        XCTAssertFalse(SourceWrapPolicy.hasLongLine("anything", threshold: 0),
                       "a non-positive threshold can't trip")
    }

    // MARK: effectiveWrap

    func test_effectiveWrap_userPrefHonored() {
        // User wrap ON ⇒ always wrap, even with short lines.
        XCTAssertTrue(SourceWrapPolicy.effectiveWrap(userWrap: true, text: "short"))
    }

    func test_effectiveWrap_forcedByLongLine_evenWhenPrefOff() {
        let longLine = String(repeating: "x", count: 120)
        XCTAssertTrue(
            SourceWrapPolicy.effectiveWrap(userWrap: false, text: longLine, threshold: 100),
            "a long line forces wrap even when the user pref is off (the hang guard)")
        XCTAssertFalse(
            SourceWrapPolicy.effectiveWrap(userWrap: false, text: "short", threshold: 100),
            "no long line + pref off ⇒ no wrap (unchanged behavior)")
    }
}
