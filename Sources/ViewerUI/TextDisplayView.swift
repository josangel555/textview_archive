import AppKit
import SwiftUI
import ViewerCore
import ViewerKit

/// Read-only monospaced source viewer. Pure SwiftUI — no NSScrollView /
/// NSTextView.
///
/// History / important context: the previous NSScrollView+NSTextView
/// implementation triggered a macOS-14+ SwiftUI compositor pathology
/// where the surrounding TabBar / ModeBar / sidebar / status bar all
/// stopped committing their layer contents at the WindowServer level
/// (visible as: window goes blank or shows only the source text).
/// The bug was first fixed by the pure-SwiftUI rewrite (commit
/// `377044f`); the NSTextView re-introduction in `0e6cf1e` brought it
/// back; this file reverts to the pure-SwiftUI path. A proper fix that
/// also restores native drag-select + scroll-to-match needs different
/// AppKit containment (NSHostingController, not NSViewRepresentable)
/// — tracked as a follow-up.
///
/// Tradeoffs in the current pure-SwiftUI implementation:
///   - Drag-select works per-line (each `Text` is its own selection
///     scope). Can't drag-select across lines.
///   - Find matches are highlighted in-place (background tint on the
///     AttributedString), but we can't programmatically scroll a
///     SwiftUI ScrollView to a match offset, so the "next match" path
///     navigates via index but doesn't auto-jump the viewport. Wrap
///     this in NSHostingController and we get both.
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
    public let findState: FindState
    public let wordWrap: Bool
    public let onFindSummary: ((String) -> Void)?

    public init(
        text: String,
        fontSize: CGFloat = 13,
        language: HighlightLanguage = .plainText,
        runs: [HighlightRun] = [],
        theme: SyntaxTheme = .xcodeLight,
        findState: FindState = .empty,
        wordWrap: Bool = false,
        onFindSummary: ((String) -> Void)? = nil
    ) {
        self.text = text
        self.fontSize = fontSize
        self.language = language
        self.runs = runs
        self.theme = theme
        self.findState = findState
        self.wordWrap = wordWrap
        self.onFindSummary = onFindSummary
    }

    /// Find-bar state shared with ContentView/DocumentModel. Same shape
    /// as the (failed) NSTextView variant so the find bar wiring
    /// doesn't have to change when we re-introduce the AppKit path.
    public struct FindState: Equatable, Sendable {
        public let query: String
        public let caseSensitive: Bool
        public let nextNonce: Int
        public let prevNonce: Int
        public static let empty = FindState(
            query: "", caseSensitive: false, nextNonce: 0, prevNonce: 0
        )
        public init(query: String, caseSensitive: Bool,
                    nextNonce: Int, prevNonce: Int) {
            self.query = query
            self.caseSensitive = caseSensitive
            self.nextNonce = nextNonce
            self.prevNonce = prevNonce
        }
    }

    public var body: some View {
        let lines = Self.splitLines(text)
        let lineRuns = Self.distributeRuns(runs, across: lines)
        let matches = Self.findRanges(
            in: text,
            query: findState.query,
            caseSensitive: findState.caseSensitive
        )
        SourceTextScrollView(
            lines: lines,
            lineRuns: lineRuns,
            fontSize: fontSize,
            theme: theme,
            wordWrap: wordWrap,
            findMatches: matches
        )
        .onAppear {
            onFindSummary?(Self.summarize(matchCount: matches.count, current: matches.isEmpty ? nil : 0))
        }
        .onChange(of: matches.count) { _, new in
            onFindSummary?(Self.summarize(matchCount: new, current: new == 0 ? nil : 0))
        }
    }

    static func summarize(matchCount: Int, current: Int?) -> String {
        guard matchCount > 0, let i = current else { return "" }
        return "\(i + 1)/\(matchCount)"
    }

    static func findRanges(in haystack: String, query: String, caseSensitive: Bool) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        let ns = haystack as NSString
        let opts: NSString.CompareOptions = caseSensitive
            ? [.literal] : [.literal, .caseInsensitive]
        var out: [NSRange] = []
        var search = NSRange(location: 0, length: ns.length)
        while search.length > 0 {
            let r = ns.range(of: query, options: opts, range: search)
            if r.location == NSNotFound { break }
            out.append(r)
            let next = r.location + max(r.length, 1)
            if next >= ns.length { break }
            search = NSRange(location: next, length: ns.length - next)
        }
        return out
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
        let sorted = runs.sorted { $0.range.location < $1.range.location }
        var runIdx = 0
        for (lineIdx, line) in lines.enumerated() {
            let lineEnd = line.range.location + line.range.length
            while runIdx < sorted.count,
                  sorted[runIdx].range.location + sorted[runIdx].range.length <= line.range.location {
                runIdx += 1
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
    let wordWrap: Bool
    let findMatches: [NSRange]
    private let gutterWidth: CGFloat = 44

    var body: some View {
        GeometryReader { geom in
            ScrollView(wordWrap ? [.vertical] : [.horizontal, .vertical]) {
                HStack(alignment: .top, spacing: 0) {
                    gutter
                    contentColumn(viewportWidth: geom.size.width)
                    if !wordWrap { Spacer(minLength: 0) }
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

    private func contentColumn(viewportWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lines.indices, id: \.self) { i in
                Text(attributed(for: i))
                    .font(.system(size: fontSize, design: .monospaced))
                    .frame(
                        maxWidth: wordWrap ? viewportWidth - gutterWidth - 16 : nil,
                        alignment: .leading
                    )
                    .frame(minHeight: lineHeight, alignment: .leading)
                    .padding(.leading, 8)
                    .fixedSize(horizontal: !wordWrap, vertical: wordWrap)
            }
        }
        .textSelection(.enabled)
    }

    /// Per-line attributed text. Layers: theme.defaultText foreground;
    /// per-token foreground from runs; current-match purple background;
    /// other-match pink background. Find painting comes LAST so it
    /// reads over the syntax colors.
    private func attributed(for lineIdx: Int) -> AttributedString {
        let line = lines[lineIdx]
        var attr = AttributedString(line.text)
        attr.foregroundColor = Color(nsColor: theme.defaultText)
        let lineLen = (line.text as NSString).length
        let runs = lineRuns[lineIdx]
        for run in runs {
            let lo = max(0, run.range.location)
            let hi = min(lineLen, run.range.location + run.range.length)
            guard lo < hi else { continue }
            guard let loIdx = attr.utf16Index(at: lo),
                  let hiIdx = attr.utf16Index(at: hi) else { continue }
            attr[loIdx..<hiIdx].foregroundColor = Color(nsColor: theme.color(for: run.kind))
        }
        // Find-match background tint.
        let lineStart = line.range.location
        let lineEnd   = lineStart + lineLen
        for (i, m) in findMatches.enumerated() {
            let lo = max(m.location, lineStart) - lineStart
            let hi = min(m.location + m.length, lineEnd) - lineStart
            guard hi > lo else { continue }
            guard let loIdx = attr.utf16Index(at: lo),
                  let hiIdx = attr.utf16Index(at: hi) else { continue }
            let tint = (i == 0)
                ? NSColor.systemPurple.withAlphaComponent(0.55)
                : NSColor.systemPink.withAlphaComponent(0.30)
            attr[loIdx..<hiIdx].backgroundColor = Color(nsColor: tint)
        }
        return attr
    }

    private var lineHeight: CGFloat { max(14, fontSize * 1.32) }
}

private extension AttributedString {
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
