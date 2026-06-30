import Testing
@testable import ViewerCore

/// TSK-942 — the selection END-line geometry (1-based UTF-16, matching SourceSelection).
struct TextLineGeometryTests {

    @Test func caretReturnsStartLine() {
        #expect(TextLineGeometry.endLine(in: "a\nb\nc", startLine: 2, startColumn: 1, utf16Length: 0) == 2)
    }

    @Test func singleLineSelectionStaysOnStartLine() {
        // "abc def" — select "abc" (3 units) on line 1 → ends on line 1.
        #expect(TextLineGeometry.endLine(in: "abc def", startLine: 1, startColumn: 1, utf16Length: 3) == 1)
    }

    @Test func multiLineSelectionFromLineOne() {
        // "a\nb\nc": select "a\nb" (3 UTF-16 units) from line 1 → ends on line 2.
        #expect(TextLineGeometry.endLine(in: "a\nb\nc", startLine: 1, startColumn: 1, utf16Length: 3) == 2)
    }

    @Test func multiLineSelectionFromAMiddleLine() {
        // "a\nb\nc": from line 2 col 1, select "b\nc" (3 units) → ends on line 3.
        #expect(TextLineGeometry.endLine(in: "a\nb\nc", startLine: 2, startColumn: 1, utf16Length: 3) == 3)
    }

    @Test func midColumnStartCountsCorrectly() {
        // "hello\nworld": from line 1 col 3 ("llo\nwo" = 6 units) → ends on line 2.
        #expect(TextLineGeometry.endLine(in: "hello\nworld", startLine: 1, startColumn: 3, utf16Length: 6) == 2)
    }

    @Test func oversizedLengthClampsToLastLine() {
        // A stale/oversized selection clamps to the buffer's last line, no crash.
        #expect(TextLineGeometry.endLine(in: "a\nb\nc", startLine: 1, startColumn: 1, utf16Length: 9999) == 3)
    }

    @Test func spanAcrossManyLines() {
        let text = "L1\nL2\nL3\nL4\nL5"
        // From line 2 col 1, select "L2\nL3\nL4" (8 units) → ends on line 4.
        #expect(TextLineGeometry.endLine(in: text, startLine: 2, startColumn: 1, utf16Length: 8) == 4)
    }
}
