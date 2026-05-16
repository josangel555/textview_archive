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
    public let showInvisibles: Bool
    public let onFindSummary: ((String) -> Void)?
    public let onScrollChange: ((SourceScrollState) -> Void)?
    /// Called whenever the textView's selectedRange changes. Caller
    /// typically uses this to update a cursor-position indicator
    /// (line:col) in the status bar.
    public let onSelectionChange: ((SourceSelection) -> Void)?

    public init(
        text: String,
        fontSize: CGFloat = 13,
        language: HighlightLanguage = .plainText,
        runs: [HighlightRun] = [],
        theme: SyntaxTheme = .xcodeLight,
        findState: FindState = .empty,
        wordWrap: Bool = false,
        showInvisibles: Bool = false,
        onFindSummary: ((String) -> Void)? = nil,
        onScrollChange: ((SourceScrollState) -> Void)? = nil,
        onSelectionChange: ((SourceSelection) -> Void)? = nil
    ) {
        self.text = text
        self.fontSize = fontSize
        self.language = language
        self.runs = runs
        self.theme = theme
        self.findState = findState
        self.wordWrap = wordWrap
        self.showInvisibles = showInvisibles
        self.onFindSummary = onFindSummary
        self.onScrollChange = onScrollChange
        self.onSelectionChange = onSelectionChange
    }

    public struct FindState: Equatable, Sendable {
        public let query: String
        public let caseSensitive: Bool
        public let isRegex: Bool
        public let nextNonce: Int
        public let prevNonce: Int
        public static let empty = FindState(
            query: "", caseSensitive: false, isRegex: false, nextNonce: 0, prevNonce: 0
        )
        public init(query: String, caseSensitive: Bool, isRegex: Bool = false,
                    nextNonce: Int, prevNonce: Int) {
            self.query = query
            self.caseSensitive = caseSensitive
            self.isRegex = isRegex
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
            showInvisibles: showInvisibles,
            findState: findState,
            onFindSummary: onFindSummary,
            onScrollChange: onScrollChange,
            onSelectionChange: onSelectionChange
        )
    }
}

/// Scroll state we publish from `SourceTextController` to whatever
/// SwiftUI view (e.g. `SourceGutterView`) wants to render along the
/// text's vertical axis. Computed AFTER NSScrollView's `tile()` via
/// the clipView's `boundsDidChangeNotification`, so the data is fresh
/// and reading it doesn't re-trigger the layout reentrancy that
/// blanked our siblings when `NSRulerView` was attached.
/// Cursor / selection telemetry the source view emits after each
/// selection change. line and column are 1-based, matching how every
/// editor surfaces them.
public struct SourceSelection: Equatable, Sendable {
    public let line: Int
    public let column: Int
    /// Length of the selection in UTF-16 units. 0 == caret only.
    public let length: Int

    public init(line: Int, column: Int, length: Int) {
        self.line = line
        self.column = column
        self.length = length
    }
    public static let zero = SourceSelection(line: 1, column: 1, length: 0)
}

public struct SourceScrollState: Equatable, Sendable {
    /// Topmost visible content offset, in points. Same coordinate
    /// space as the textView's documentView origin.
    public let offsetY: CGFloat
    /// Height the scroll view shows (the clipView's bounds.height).
    public let viewportHeight: CGFloat
    /// Per-line height assuming the current font; we hand this back so
    /// callers don't have to compute font metrics independently.
    public let lineHeight: CGFloat
    /// Total number of \n-terminated lines in the document.
    public let lineCount: Int
    /// Top inset the textContainerInset adds above the first line of
    /// text. Callers need this to align their first row to glyph row 1.
    public let topInset: CGFloat
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
    /// Subscribes to the clipView's bounds change (i.e. scroll events).
    /// Fired AFTER NSScrollView.tile() so reading from layoutManager
    /// here is safe — different from the broken NSRulerView path.
    /// `@unchecked Sendable` annotation is implicit via `nonisolated`
    /// usage in deinit; the values themselves are unused after we
    /// stop receiving notifications, so racing on dealloc is benign.
    nonisolated(unsafe) private var scrollObserver: NSObjectProtocol?
    nonisolated(unsafe) private var frameObserver: NSObjectProtocol?
    nonisolated(unsafe) private var selectionObserver: NSObjectProtocol?
    private var onScrollChange: ((SourceScrollState) -> Void)?
    private var onSelectionChange: ((SourceSelection) -> Void)?
    private var cachedFontSize: CGFloat = 13
    private var cachedLineCount: Int = 1
    private var lastPublishedScrollState: SourceScrollState?
    /// Dedupe for the find-summary + selection callbacks. Without
    /// these, every apply() call re-fires the callback even when the
    /// value is unchanged. The model side then republishes via
    /// @Published (which is value-blind) → SwiftUI re-renders →
    /// apply() called again → infinite publish loop. The symptom
    /// before this guard: ~5 MB/sec RSS growth in source mode at idle.
    private var lastFindSummary: String?
    private var lastPublishedSelection: SourceSelection?

    private struct AttrKey: Equatable {
        let text: String
        let fontSize: CGFloat
        let theme: SyntaxTheme.Name
        let runCount: Int
    }
    private struct FindKey: Equatable {
        let query: String
        let caseSensitive: Bool
        let isRegex: Bool
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

    public override func viewDidLoad() {
        super.viewDidLoad()
        // Tell the clipView to post bounds-change notifications. Off by
        // default; without this our `boundsDidChange` observer is
        // silent. (Frame changes are separate; we observe both so
        // resize also updates the gutter.)
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clip, queue: .main
        ) { [weak self] _ in
            self?.publishScrollState()
        }
        frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: clip, queue: .main
        ) { [weak self] _ in
            self?.publishScrollState()
        }
        selectionObserver = NotificationCenter.default.addObserver(
            forName: NSTextView.didChangeSelectionNotification,
            object: textView, queue: .main
        ) { [weak self] _ in
            self?.publishSelection()
        }
    }

    deinit {
        if let o = scrollObserver    { NotificationCenter.default.removeObserver(o) }
        if let o = frameObserver     { NotificationCenter.default.removeObserver(o) }
        if let o = selectionObserver { NotificationCenter.default.removeObserver(o) }
    }

    /// Publish current scroll state to the SwiftUI gutter. Reads from
    /// layoutManager — safe to do here because we're in a notification
    /// handler (async, on .main runloop), not inside NSScrollView.tile.
    ///
    /// Dedupe identical publishes: SwiftUI republishing → re-layout →
    /// frame-changed → publish creates a feedback loop. Equatable
    /// guard breaks it.
    private func publishScrollState() {
        guard let cb = onScrollChange else { return }
        let clip = scrollView.contentView
        let offset = clip.bounds.origin.y
        let viewport = clip.bounds.size.height
        let topInset = textView.textContainerInset.height
        let state = SourceScrollState(
            offsetY: offset,
            viewportHeight: viewport,
            lineHeight: Self.lineHeight(forFontSize: cachedFontSize),
            lineCount: cachedLineCount,
            topInset: topInset
        )
        if state == lastPublishedScrollState { return }
        lastPublishedScrollState = state
        cb(state)
    }

    /// Compute (line, column) from the textView's selectedRange and
    /// publish via the caller's callback IF it changed. The dedupe
    /// is what stops the apply→publish→re-render→apply→… loop.
    private func publishSelection() {
        guard let cb = onSelectionChange else { return }
        let sel = textView.selectedRange()
        let str = textView.string as NSString
        let loc = min(sel.location, str.length)
        var line = 1
        var lineStart = 0
        for i in 0..<loc {
            if str.character(at: i) == 0x0A {
                line += 1
                lineStart = i + 1
            }
        }
        let new = SourceSelection(
            line: line,
            column: loc - lineStart + 1,
            length: sel.length
        )
        if new == lastPublishedSelection { return }
        lastPublishedSelection = new
        cb(new)
    }

    /// Match NSTextView's effective line height for the default
    /// monospaced font. The factor 1.20 holds for SF Mono / Menlo /
    /// Monaco across the size range we use; if it ever drifts we'd
    /// see misalignment in the gutter.
    static func lineHeight(forFontSize size: CGFloat) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        // boundingRectForFont gives the maximal glyph box; NSTextView's
        // layout manager uses a slightly tighter line height.
        return ceil(font.ascender - font.descender + font.leading)
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
        showInvisibles: Bool,
        findState: TextDisplayView.FindState,
        onFindSummary: ((String) -> Void)?,
        onScrollChange: ((SourceScrollState) -> Void)?,
        onSelectionChange: ((SourceSelection) -> Void)?
    ) {
        self.onScrollChange = onScrollChange
        self.onSelectionChange = onSelectionChange
        self.cachedFontSize = fontSize
        scrollView.backgroundColor = theme.background
        textView.backgroundColor = theme.background

        if wordWrap != lastWordWrap {
            applyWrap(wordWrap)
            lastWordWrap = wordWrap
        }
        // NSLayoutManager renders dots / arrows / pilcrows when this
        // is on. We tone the marker color down via the layout
        // manager's textStorage so the visualization doesn't fight
        // the text — Word's pilcrow is too loud for code-reading.
        textView.layoutManager?.showsInvisibleCharacters = showInvisibles

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

        // Initial publish so the gutter + status bar have baseline
        // state even before the user scrolls or moves the caret.
        publishScrollState()
        publishSelection()
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
        // Refresh line count for the gutter.
        cachedLineCount = Self.countLines(in: text)
    }

    private static func countLines(in text: String) -> Int {
        if text.isEmpty { return 0 }
        var n = 1
        for b in text.utf8 where b == 0x0A { n += 1 }
        if text.utf8.last == 0x0A { n -= 1 }
        return n
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
            // Dedupe: only publish "" if we hadn't already.
            if let cb = onFindSummary, lastFindSummary != "" {
                lastFindSummary = ""
                DispatchQueue.main.async { cb("") }
            }
            return
        }

        let cacheKey = FindKey(
            query: query,
            caseSensitive: findState.caseSensitive,
            isRegex: findState.isRegex,
            textHash: text.hashValue
        )
        if cacheKey != lastFindKey {
            findMatches = Self.findRanges(
                in: text, query: query, caseSensitive: findState.caseSensitive,
                isRegex: findState.isRegex
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
            if summary != lastFindSummary {
                lastFindSummary = summary
                DispatchQueue.main.async { cb(summary) }
            }
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

    private static func findRanges(in haystack: String, query: String, caseSensitive: Bool,
                                    isRegex: Bool = false) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        if isRegex {
            // Bad regex (unbalanced parens etc.) silently yields zero
            // matches — let the find bar show the "no matches" state
            // instead of crashing.
            var opts: NSRegularExpression.Options = [.anchorsMatchLines]
            if !caseSensitive { opts.insert(.caseInsensitive) }
            guard let re = try? NSRegularExpression(pattern: query, options: opts)
            else { return [] }
            let full = NSRange(location: 0, length: (haystack as NSString).length)
            return re.matches(in: haystack, options: [], range: full).map(\.range)
        }
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
