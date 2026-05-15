import AppKit
import SwiftUI
import ViewerCore
import ViewerKit

/// Read-only monospaced source viewer. Pure SwiftUI — no NSScrollView /
/// NSTextView. The previous NSScrollView+NSTextView implementation
/// triggered a macOS-14+ SwiftUI compositor pathology where the
/// surrounding TabBar / ModeBar / sidebar all stopped committing their
/// layer contents (visible as: window shows ONLY line numbers + text,
/// nothing else). The pure-SwiftUI path avoids the entire AppKit-bridge
/// problem.
///
/// Highlighting:
///   Caller passes `runs` (NSRange-keyed UTF-16 spans) + a `SyntaxTheme`.
///   We split runs per-line at construction time and build an
///   AttributedString per visible line. Lines with no overlapping runs
///   render as plain text in the theme's `defaultText` color.
public struct TextDisplayView: View {
    public let text: String
    public let fontSize: CGFloat
    public let language: HighlightLanguage
    public let runs: [HighlightRun]
    public let theme: SyntaxTheme

    public init(
        text: String,
        fontSize: CGFloat = 13,
        language: HighlightLanguage = .plainText,
        runs: [HighlightRun] = [],
        theme: SyntaxTheme = .xcodeLight
    ) {
        self.text = text
        self.fontSize = fontSize
        self.language = language
        self.runs = runs
        self.theme = theme
    }

    public var body: some View {
        let lines = Self.splitLines(text)
        let lineRuns = Self.distributeRuns(runs, across: lines)
        SourceTextScrollView(
            lines: lines,
            lineRuns: lineRuns,
            fontSize: fontSize,
            theme: theme
        )
    }

    /// Split into lines preserving empty ones (so line numbers count
    /// correctly through blank lines).
    static func splitLines(_ text: String) -> [LineSlice] {
        var out: [LineSlice] = []
        out.reserveCapacity(text.count / 40 + 4)
        let ns = text as NSString
        var start = 0
        let length = ns.length
        var i = 0
        while i < length {
            let c = ns.character(at: i)
            if c == 0x0A {  // \n
                out.append(LineSlice(range: NSRange(location: start, length: i - start),
                                     text: ns.substring(with: NSRange(location: start, length: i - start))))
                i += 1
                start = i
            } else {
                i += 1
            }
        }
        if start <= length {
            out.append(LineSlice(range: NSRange(location: start, length: length - start),
                                 text: ns.substring(with: NSRange(location: start, length: length - start))))
        }
        return out
    }

    /// For each line, the runs (with ranges *clipped + rebased* to that
    /// line's local 0-origin coordinates) that intersect it.
    static func distributeRuns(
        _ runs: [HighlightRun], across lines: [LineSlice]
    ) -> [[HighlightRun]] {
        guard !runs.isEmpty else {
            return Array(repeating: [], count: lines.count)
        }
        var out = Array(repeating: [HighlightRun](), count: lines.count)
        // Runs are produced left-to-right by the engine, but be defensive.
        let sorted = runs.sorted {
            $0.range.location < $1.range.location
        }
        var runIdx = 0
        for (lineIdx, line) in lines.enumerated() {
            let lineEnd = line.range.location + line.range.length
            while runIdx < sorted.count,
                  sorted[runIdx].range.location + sorted[runIdx].range.length <= line.range.location {
                runIdx += 1  // run sits entirely before this line
            }
            var j = runIdx
            while j < sorted.count, sorted[j].range.location < lineEnd {
                let r = sorted[j].range
                let lo = max(r.location, line.range.location)
                let hi = min(r.location + r.length, lineEnd)
                if hi > lo {
                    let local = NSRange(
                        location: lo - line.range.location,
                        length: hi - lo
                    )
                    out[lineIdx].append(HighlightRun(range: local, kind: sorted[j].kind))
                }
                j += 1
            }
        }
        return out
    }
}

struct LineSlice {
    let range: NSRange   // location/length into the full text (UTF-16 units)
    let text: String
}

private struct SourceTextScrollView: View {
    let lines: [LineSlice]
    let lineRuns: [[HighlightRun]]
    let fontSize: CGFloat
    let theme: SyntaxTheme
    private let gutterWidth: CGFloat = 44

    var body: some View {
        GeometryReader { geom in
            ScrollView([.horizontal, .vertical]) {
                HStack(alignment: .top, spacing: 0) {
                    gutter
                    contentColumn
                    Spacer(minLength: 0)
                }
                .frame(
                    minWidth: geom.size.width,
                    minHeight: geom.size.height,
                    alignment: .topLeading
                )
            }
        }
        .background(Color(nsColor: theme.background))
    }

    private var gutter: some View {
        VStack(alignment: .trailing, spacing: 0) {
            ForEach(lines.indices, id: \.self) { i in
                Text("\(i + 1)")
                    .font(.system(size: max(10, fontSize - 3), design: .monospaced))
                    .foregroundStyle(Color(nsColor: theme.gutterText))
                    .frame(width: gutterWidth - 6, alignment: .trailing)
                    .padding(.trailing, 6)
                    .frame(height: lineHeight)
            }
        }
        .background(Color(nsColor: theme.gutterBackground))
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 0.5)
        }
    }

    private var contentColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lines.indices, id: \.self) { i in
                Text(attributed(for: i))
                    .font(.system(size: fontSize, design: .monospaced))
                    .frame(height: lineHeight, alignment: .leading)
                    .padding(.leading, 8)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .textSelection(.enabled)
    }

    /// Build the per-line attributed string. Returns plain text colored
    /// by `theme.defaultText` when this line has no runs.
    private func attributed(for lineIdx: Int) -> AttributedString {
        let line = lines[lineIdx]
        var attr = AttributedString(line.text)
        attr.foregroundColor = Color(nsColor: theme.defaultText)
        let runs = lineRuns[lineIdx]
        if runs.isEmpty { return attr }
        let ns = line.text as NSString
        let len = ns.length
        for run in runs {
            let lo = max(0, run.range.location)
            let hi = min(len, run.range.location + run.range.length)
            guard lo < hi else { continue }
            // AttributedString indexing uses .characters view; convert
            // from UTF-16 offsets via String.utf16 → String.Index → AS.
            // Easier: rebuild via NSString → AttributedString slice.
            guard let loIdx = attr.utf16Index(at: lo),
                  let hiIdx = attr.utf16Index(at: hi) else { continue }
            attr[loIdx..<hiIdx].foregroundColor = Color(nsColor: theme.color(for: run.kind))
        }
        return attr
    }

    /// Tight, predictable per-line height — keeps gutter rows aligned
    /// with content rows without measuring text metrics.
    private var lineHeight: CGFloat {
        max(14, fontSize * 1.32)
    }
}

private extension AttributedString {
    /// Convert a UTF-16 offset within the underlying string into an
    /// AttributedString index, or nil if out of range.
    func utf16Index(at offset: Int) -> AttributedString.Index? {
        let str = String(characters)
        guard let u16 = str.utf16.index(
            str.utf16.startIndex,
            offsetBy: offset,
            limitedBy: str.utf16.endIndex
        ),
              let sidx = u16.samePosition(in: str) else {
            return nil
        }
        return AttributedString.Index(sidx, within: self)
    }
}
