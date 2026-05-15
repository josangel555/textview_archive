import AppKit
import SwiftUI
import ViewerCore
import ViewerKit

/// Read-only monospaced source viewer backed by `NSTextView`. Hosted
/// via `NSViewControllerRepresentable` (NOT `NSViewRepresentable`)
/// because the latter triggers a macOS SwiftUI compositor pathology
/// where sibling SwiftUI views stop committing layer contents at the
/// WindowServer level (visible as: surrounding TabBar / ModeBar /
/// Sidebar / StatusBar go blank).
///
/// Community/production evidence converges on the controller-based
/// representable as the fix for this class of bug. CodeEditApp's
/// SourceEditor — the highest-fidelity SwiftUI code editor we could
/// find — uses exactly this pattern. The mechanism appears to be that
/// `NSViewControllerRepresentable` gives SwiftUI a child-controller
/// lifecycle boundary, isolating the AppKit subtree's layer commits
/// from SwiftUI's layout-pass scheduling (the underlying bug appears
/// to be that `NSScrollView`'s `tile()` triggers a SwiftUI layout pass
/// reentrantly; SwiftUI logs "being laid out reentrantly while
/// rendering its SwiftUI content. This is not supported and the
/// current layout pass will be skipped." — and the skip means
/// siblings miss their commit window).
///
/// References:
///   - vicegax.substack.com/p/nsviewrepresentable-breaks
///   - github.com/CodeEditApp/CodeEditSourceEditor SourceEditor.swift
///   - FB22270146 / github.com/feedback-assistant/reports/issues/776
///
/// Containment guard: `Tests/.../DiagnosticDumpTests` and
/// `Tests/.../VisualRegressionTests` together assert (a) the view tree
/// is shaped right and (b) sibling SwiftUI pixels actually compose.
public struct TextDisplayView: NSViewControllerRepresentable {
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

    public struct FindState: Equatable, Sendable {
        public let query: String
        public let caseSensitive: Bool
        public let nextNonce: Int
        public let prevNonce: Int
        public static let empty = FindState(
            query: "", caseSensitive: false, nextNonce: 0, prevNonce: 0
        )
        public init(query: String, caseSensitive: Bool, nextNonce: Int, prevNonce: Int) {
            self.query = query
            self.caseSensitive = caseSensitive
            self.nextNonce = nextNonce
            self.prevNonce = prevNonce
        }
    }

    public func makeNSViewController(context: Context) -> SourceTextController {
        SourceTextController(
            text: text, fontSize: fontSize, theme: theme, wordWrap: wordWrap
        )
    }

    public func updateNSViewController(_ controller: SourceTextController, context: Context) {
        controller.apply(
            text: text,
            fontSize: fontSize,
            theme: theme,
            runs: runs,
            wordWrap: wordWrap,
            findState: findState,
            onFindSummary: onFindSummary
        )
    }
}

/// Controller-shape host for the source view. Owns the
/// `NSScrollView + NSTextView + LineNumberRulerView` triple so SwiftUI
/// only sees a controller boundary (not a raw `NSView` subtree).
public final class SourceTextController: NSViewController {
    public let scrollView: NSScrollView
    public let textView: NSTextView

    private var lastAttrKey: AttrKey?
    private var lastWordWrap: Bool = false
    private var lastFindKey: FindKey?
    private var findMatches: [NSRange] = []
    private var currentMatchIndex: Int?
    private var lastNextNonce: Int = 0
    private var lastPrevNonce: Int = 0

    private struct AttrKey: Equatable {
        let text: String
        let fontSize: CGFloat
        let theme: SyntaxTheme.Name
        let runCount: Int
    }
    private struct FindKey: Equatable {
        let query: String
        let caseSensitive: Bool
        let textHash: Int
    }

    public init(text: String, fontSize: CGFloat, theme: SyntaxTheme, wordWrap: Bool) {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = !wordWrap
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = theme.background
        self.scrollView = scroll

        let tv = (scroll.documentView as? NSTextView) ?? NSTextView()
        tv.isEditable = false
        tv.isRichText = true
        tv.isSelectable = true
        tv.allowsUndo = false
        tv.drawsBackground = true
        tv.backgroundColor = theme.background
        tv.textContainerInset = NSSize(width: 10, height: 10)
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        self.textView = tv

        // No NSRulerView. Empirically (see SourceViewVisualRegressionTests),
        // attaching a `LineNumberRulerView` to the scroll view's
        // vertical ruler causes NSScrollView's `tile()` to reentrantly
        // invoke `NSLayoutManager.glyphRange(...)`, which in turn fires
        // during SwiftUI's commit phase. SwiftUI logs "NSHostingView is
        // being laid out reentrantly while rendering its SwiftUI
        // content. This is not supported and the current layout pass
        // will be skipped." That skip leaves both the NSTextView's
        // documentView AND the sibling SwiftUI views (TabBar / ModeBar)
        // un-composited. The status bar BELOW the source view survives
        // because its commit happens later in the pass.
        //
        // Diagnostic toggle preserved so a developer can verify the
        // regression test catches the bug class:
        //   MDV_ENABLE_BROKEN_RULER=1 ./MarkdownViewer …
        // (Don't ship a build with this set.)
        if ProcessInfo.processInfo.environment["MDV_ENABLE_BROKEN_RULER"] == "1" {
            let r = LineNumberRulerView(textView: tv)
            scroll.verticalRulerView = r
            scroll.hasVerticalRuler = true
            scroll.rulersVisible = true
        }
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func loadView() {
        // Use the scrollView directly as the controller's view —
        // matches CodeEditApp/CodeEditSourceEditor's pattern. An extra
        // container NSView between the controller and the scrollview
        // breaks the documentView's layout/clip-view sizing dance.
        self.view = scrollView
    }

    /// Apply a (text, runs, theme, wrap, findState) update from SwiftUI.
    /// Each piece is gated on a coordinator-style cache key so we don't
    /// re-walk the textStorage when nothing actually changed.
    public func apply(
        text: String,
        fontSize: CGFloat,
        theme: SyntaxTheme,
        runs: [HighlightRun],
        wordWrap: Bool,
        findState: TextDisplayView.FindState,
        onFindSummary: ((String) -> Void)?
    ) {
        scrollView.backgroundColor = theme.background
        textView.backgroundColor = theme.background

        if wordWrap != lastWordWrap {
            applyWrap(wordWrap)
            lastWordWrap = wordWrap
        }

        applyAttributedString(
            text: text, fontSize: fontSize, theme: theme, runs: runs
        )
        applyFindHighlights(
            text: text, findState: findState, onFindSummary: onFindSummary
        )

        // Force a redraw of the text view + its enclosing tree. Without
        // this, on first paint the text storage has content but the
        // glyph cache hasn't been built — visible as a blank scrollview
        // body with only the ruler showing line numbers. Equivalent
        // outcome with explicit setNeedsDisplay on the window's
        // contentView, but cheaper to localize to the text view.
        textView.needsDisplay = true
        textView.enclosingScrollView?.contentView.needsDisplay = true
    }

    /// Toggle horizontal scrolling vs viewport-width wrap. Two knobs
    /// have to agree: the scrollView's horizontal scroller and the
    /// textContainer's `widthTracksTextView` + size.
    private func applyWrap(_ wrap: Bool) {
        scrollView.hasHorizontalScroller = !wrap
        if wrap {
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            if let c = textView.textContainer {
                c.widthTracksTextView = true
                c.containerSize = NSSize(
                    width: scrollView.contentSize.width,
                    height: CGFloat.greatestFiniteMagnitude
                )
            }
        } else {
            textView.isHorizontallyResizable = true
            textView.autoresizingMask = [.width, .height]
            if let c = textView.textContainer {
                c.widthTracksTextView = false
                c.containerSize = NSSize(
                    width: CGFloat.greatestFiniteMagnitude,
                    height: CGFloat.greatestFiniteMagnitude
                )
            }
        }
    }

    private func applyAttributedString(
        text: String, fontSize: CGFloat, theme: SyntaxTheme, runs: [HighlightRun]
    ) {
        let key = AttrKey(
            text: text, fontSize: fontSize, theme: theme.name, runCount: runs.count
        )
        if key == lastAttrKey { return }
        let baseFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        if runs.isEmpty {
            // Fast path for plain text / unsupported language /
            // oversized files: no attributedString allocation.
            if textView.string != text {
                textView.string = text
            }
            if let storage = textView.textStorage {
                let full = NSRange(location: 0, length: storage.length)
                storage.beginEditing()
                storage.setAttributes(
                    [.font: baseFont, .foregroundColor: theme.defaultText],
                    range: full
                )
                storage.endEditing()
            }
        } else {
            let attr = Self.buildAttributed(
                text: text, runs: runs, theme: theme, baseFont: baseFont
            )
            textView.textStorage?.setAttributedString(attr)
        }
        lastAttrKey = key
    }

    private func applyFindHighlights(
        text: String,
        findState: TextDisplayView.FindState,
        onFindSummary: ((String) -> Void)?
    ) {
        guard let layoutManager = textView.layoutManager,
              let textStorage = textView.textStorage else { return }
        let full = NSRange(location: 0, length: textStorage.length)
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)

        let query = findState.query
        guard !query.isEmpty, textStorage.length > 0 else {
            findMatches = []
            currentMatchIndex = nil
            onFindSummary.map { cb in DispatchQueue.main.async { cb("") } }
            return
        }

        let cacheKey = FindKey(
            query: query,
            caseSensitive: findState.caseSensitive,
            textHash: text.hashValue
        )
        if cacheKey != lastFindKey {
            findMatches = Self.findRanges(
                in: text, query: query, caseSensitive: findState.caseSensitive
            )
            lastFindKey = cacheKey
            currentMatchIndex = findMatches.isEmpty ? nil : 0
            lastNextNonce = findState.nextNonce
            lastPrevNonce = findState.prevNonce
        }
        if !findMatches.isEmpty {
            if findState.nextNonce != lastNextNonce {
                lastNextNonce = findState.nextNonce
                currentMatchIndex =
                    ((currentMatchIndex ?? -1) + 1) % findMatches.count
            }
            if findState.prevNonce != lastPrevNonce {
                lastPrevNonce = findState.prevNonce
                let n = findMatches.count
                currentMatchIndex =
                    ((currentMatchIndex ?? 0) - 1 + n) % n
            }
        }
        for (i, r) in findMatches.enumerated() {
            let color = (i == currentMatchIndex)
                ? NSColor.systemPurple.withAlphaComponent(0.55)
                : NSColor.systemPink.withAlphaComponent(0.30)
            layoutManager.addTemporaryAttribute(
                .backgroundColor, value: color, forCharacterRange: r
            )
        }
        if let idx = currentMatchIndex, idx < findMatches.count {
            textView.scrollRangeToVisible(findMatches[idx])
        }
        if let cb = onFindSummary {
            let summary = TextDisplayView.summarize(
                matchCount: findMatches.count, current: currentMatchIndex
            )
            DispatchQueue.main.async { cb(summary) }
        }
    }

    private static func buildAttributed(
        text: String, runs: [HighlightRun], theme: SyntaxTheme, baseFont: NSFont
    ) -> NSAttributedString {
        let attr = NSMutableAttributedString(string: text)
        let full = NSRange(location: 0, length: (text as NSString).length)
        attr.addAttribute(.font, value: baseFont, range: full)
        attr.addAttribute(.foregroundColor, value: theme.defaultText, range: full)
        for run in runs {
            let lo = max(0, run.range.location)
            let hi = min(full.length, run.range.location + run.range.length)
            guard hi > lo else { continue }
            attr.addAttribute(
                .foregroundColor,
                value: theme.color(for: run.kind),
                range: NSRange(location: lo, length: hi - lo)
            )
        }
        return attr
    }

    private static func findRanges(in haystack: String, query: String, caseSensitive: Bool) -> [NSRange] {
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
}

extension TextDisplayView {
    public static func summarize(matchCount: Int, current: Int?) -> String {
        guard matchCount > 0, let i = current else { return "" }
        return "\(i + 1)/\(matchCount)"
    }
}
