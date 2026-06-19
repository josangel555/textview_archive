import Foundation

/// TSK-910 — the data builder behind a *single, multi-line-selectable* hunk.
///
/// Today the diff viewer draws every hunk line as its own
/// `Text(...).textSelection(.enabled)` (`DiffView.lineRow`). SwiftUI text
/// selection is scoped to ONE `Text`, so a drag can never span sibling
/// `Text`s — only one line is ever selectable at a time (the reported bug).
///
/// The render fix is to collapse a hunk into ONE `Text` over an
/// `AttributedString`, which makes selection span every line in the hunk.
/// That render swap is VM-validated; the HOST-fixable, independently
/// shippable core is THIS builder: it renders a `UnifiedDiff.Hunk` into a
/// single `AttributedString` where each diff line is one attributed RUN
/// carrying its `UnifiedDiff.Line.Kind` (so the view maps kind → colour at
/// render time, keeping `ViewerCore` free of SwiftUI). Line geometry — the
/// character offset/length of every line within the joined string — is
/// exposed so the find-highlight mapper (`DiffFindRuns`) and the
/// per-hunk scroll-anchor mapping can re-home onto char-precise ranges.
///
/// The text shape round-trips the unified-diff line form: each line is
/// `<prefix char><content>` (matching `UnifiedDiff.Hunk.clipboardText`),
/// lines joined by `\n` with NO trailing newline (so the rendered `Text`
/// has no dangling blank row and a full-hunk selection copies clean diff
/// text). Pass `includePrefix: false` to omit the `+`/`-`/space gutter
/// character when the view renders it in a separate column instead.
public enum DiffHunkAttributedString {

    /// Custom attribute carrying the diff line kind of each run, so the
    /// SwiftUI render slice can colour runs (`.added` → green, etc.)
    /// without `ViewerCore` importing SwiftUI, and so host tests can
    /// assert the per-line classification directly off the runs.
    public enum DiffLineKindAttribute: AttributedStringKey {
        public typealias Value = UnifiedDiff.Line.Kind
        public static let name = "mdv.diffLineKind"
    }

    /// Character offset + length of one logical diff line within the
    /// built `AttributedString`, addressed in CHARACTER units (the
    /// `AttributedString.CharacterView` index space, NOT UTF-16).
    public struct LineSpan: Equatable, Sendable {
        public let lineIndex: Int      // index into `hunk.lines`
        public let start: Int          // character offset of the line start
        public let length: Int         // character count (prefix + content)
        public init(lineIndex: Int, start: Int, length: Int) {
            self.lineIndex = lineIndex; self.start = start; self.length = length
        }
        /// End offset (exclusive) — i.e. the offset of the first character
        /// past this line, which for non-final lines is the `\n` separator.
        public var end: Int { start + length }
    }

    /// The built artifact: the joined attributed text plus the per-line
    /// char spans the find / scroll-anchor mappers consume. Returned
    /// together because the spans are computed during the same single pass
    /// that assembles the string — recomputing them later would have to
    /// re-derive identical offsets.
    public struct Built: Sendable {
        public let attributed: AttributedString
        public let lineSpans: [LineSpan]
        public init(attributed: AttributedString, lineSpans: [LineSpan]) {
            self.attributed = attributed; self.lineSpans = lineSpans
        }
    }

    /// Build the single selectable `AttributedString` for a hunk, plus the
    /// char spans of each line. Each line becomes one run tagged with its
    /// `DiffLineKindAttribute`; lines are joined by `\n` with no trailing
    /// newline.
    public static func build(
        hunk: UnifiedDiff.Hunk, includePrefix: Bool = true
    ) -> Built {
        var attributed = AttributedString()
        var spans: [LineSpan] = []
        var charCount = 0  // running character offset into `attributed`

        for (i, line) in hunk.lines.enumerated() {
            if i > 0 {
                // Newline separator carries no kind attribute.
                attributed.append(AttributedString("\n"))
                charCount += 1
            }
            let prefix = includePrefix ? line.kind.diffPrefix : ""
            let lineText = prefix + line.content
            var run = AttributedString(lineText)
            run[DiffLineKindAttribute.self] = line.kind
            attributed.append(run)

            let len = lineText.count
            spans.append(LineSpan(lineIndex: i, start: charCount, length: len))
            charCount += len
        }

        return Built(attributed: attributed, lineSpans: spans)
    }

    /// Convenience: just the attributed string (when the caller doesn't
    /// need the spans). The `build(hunk:)` `Built` form is preferred when
    /// find or scroll-anchor mapping is involved.
    public static func attributedString(
        hunk: UnifiedDiff.Hunk, includePrefix: Bool = true
    ) -> AttributedString {
        build(hunk: hunk, includePrefix: includePrefix).attributed
    }
}
