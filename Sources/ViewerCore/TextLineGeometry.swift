import Foundation

/// Pure line geometry over a text buffer, in 1-based UTF-16 coordinates — matching
/// `SourceSelection` (line/column 1-based; length in UTF-16 units, as the source
/// view publishes them from the NSTextView selectedRange).
///
/// TSK-942: to copy a selected SPAN as a line-RANGE agent reference, we need the
/// END line of a selection that starts at (startLine, startColumn) and runs for
/// `utf16Length` UTF-16 units. The source view only carries the start + length, so
/// the end line is derived here from the buffer text (host-testable, no view).
public enum TextLineGeometry {

    /// The 1-based line containing the END of the selection. A caret (length 0)
    /// returns `startLine`; everything is clamped to the buffer so a stale/oversized
    /// selection yields the last line rather than a crash.
    public static func endLine(
        in text: String, startLine: Int, startColumn: Int, utf16Length: Int
    ) -> Int {
        guard utf16Length > 0 else { return startLine }
        let u = Array(text.utf16)
        let newline = UInt16(10)  // '\n'

        // UTF-16 offset of the start of `startLine` (1-based): advance past the
        // (startLine - 1) preceding newlines.
        var offset = 0
        var line = 1
        while line < startLine, offset < u.count {
            if u[offset] == newline { line += 1 }
            offset += 1
        }

        let startOffset = min(offset + max(0, startColumn - 1), u.count)
        let endOffset = min(startOffset + utf16Length, u.count)

        // Count newlines spanned by [startOffset, endOffset).
        var endLine = startLine
        var i = startOffset
        while i < endOffset {
            if u[i] == newline { endLine += 1 }
            i += 1
        }
        return endLine
    }
}
