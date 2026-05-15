import AppKit
import SwiftUI
import ViewerCore
import ViewerKit

/// Read-only source viewer backed by `NSTextView`. We previously had a
/// pure-SwiftUI implementation (split lines into individual `Text` views)
/// because the AppKit/SwiftUI bridge had a compositor bug on macOS 14
/// that hid sibling SwiftUI views around the text scroll. The pure-
/// SwiftUI version is missing things only NSTextView gives us:
///
///   - Drag-select across lines + clicking in empty space to extend
///     selection
///   - Native find-bar interop
///   - Word-by-word double-click selection
///   - Standard right-click services
///
/// We bring NSTextView back here, configured deliberately to avoid the
/// prior pathology (use the stock `NSTextView.scrollableTextView()`
/// factory; don't touch wantsLayer; let SwiftUI host us via a clean
/// NSViewRepresentable).
///
/// Highlighting:
///   Caller passes `runs` (NSRange-keyed UTF-16 spans) + a `SyntaxTheme`.
///   We build the `NSAttributedString` here and assign it to the text
///   storage. Repeated calls with the same (text, runs, theme) reuse
///   the attributed string via Coordinator caching.
public struct TextDisplayView: NSViewRepresentable {
    public let text: String
    public let fontSize: CGFloat
    public let language: HighlightLanguage
    public let runs: [HighlightRun]
    public let theme: SyntaxTheme
    public let findState: FindState
    /// Optional callback fired whenever match list or current index
    /// changes. Caller updates its find-bar UI with the new summary
    /// (e.g. `model.sourceFindMatchSummary = summary`).
    public let onFindSummary: ((String) -> Void)?

    public init(
        text: String,
        fontSize: CGFloat = 13,
        language: HighlightLanguage = .plainText,
        runs: [HighlightRun] = [],
        theme: SyntaxTheme = .xcodeLight,
        findState: FindState = .empty,
        onFindSummary: ((String) -> Void)? = nil
    ) {
        self.text = text
        self.fontSize = fontSize
        self.language = language
        self.runs = runs
        self.theme = theme
        self.findState = findState
        self.onFindSummary = onFindSummary
    }

    /// Subset of find-bar state the source view needs to render and
    /// navigate matches. Caller wires this up from DocumentModel.
    public struct FindState: Equatable, Sendable {
        public let query: String
        public let caseSensitive: Bool
        /// Monotonic nonces the model bumps when the user hits next /
        /// prev. The view advances its currentMatchIndex on change.
        public let nextNonce: Int
        public let prevNonce: Int

        public static let empty = FindState(
            query: "", caseSensitive: false, nextNonce: 0, prevNonce: 0
        )

        public init(
            query: String, caseSensitive: Bool,
            nextNonce: Int, prevNonce: Int
        ) {
            self.query = query
            self.caseSensitive = caseSensitive
            self.nextNonce = nextNonce
            self.prevNonce = prevNonce
        }
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = theme.background

        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }
        textView.isEditable = false
        textView.isRichText = true   // we install styled NSAttributedString
        textView.isSelectable = true
        textView.allowsUndo = false
        textView.drawsBackground = true
        textView.backgroundColor = theme.background
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        // No font here — the attributed string carries per-run fonts.

        let ruler = LineNumberRulerView(textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        // Seed contents on first appear.
        applyAttributedString(
            on: textView,
            ruler: ruler,
            coordinator: context.coordinator
        )
        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        scrollView.backgroundColor = theme.background
        textView.backgroundColor = theme.background

        applyAttributedString(
            on: textView,
            ruler: scrollView.verticalRulerView as? LineNumberRulerView,
            coordinator: context.coordinator
        )
        applyFindHighlights(on: textView, coordinator: context.coordinator)
    }

    /// Build the attributed text from (text, runs, theme, fontSize)
    /// and write it to the text view. Skips rebuilding if none of
    /// those inputs changed since last call.
    private func applyAttributedString(
        on textView: NSTextView,
        ruler: LineNumberRulerView?,
        coordinator: Coordinator
    ) {
        let key = Coordinator.AttrCacheKey(
            text: text, fontSize: fontSize, theme: theme.name, runCount: runs.count
        )
        if coordinator.lastAttrKey == key { return }
        let attr = Self.buildAttributed(
            text: text, runs: runs, theme: theme, fontSize: fontSize
        )
        textView.textStorage?.setAttributedString(attr)
        coordinator.lastAttrKey = key
        coordinator.lastText = text
        ruler?.invalidateLineCache()
    }

    /// Apply temporary highlight attributes for find matches and
    /// scroll the current match into view. Doesn't mutate textStorage's
    /// foreground colors — we use `setTemporaryAttributes` on the layout
    /// manager so the underlying highlight colors stay intact when the
    /// find query is cleared.
    private func applyFindHighlights(
        on textView: NSTextView,
        coordinator: Coordinator
    ) {
        guard let layoutManager = textView.layoutManager,
              let textStorage = textView.textStorage else { return }
        let full = NSRange(location: 0, length: textStorage.length)

        // Clear any prior find highlights every update; cheap.
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)

        let query = findState.query
        guard !query.isEmpty, textStorage.length > 0 else {
            coordinator.findMatches = []
            coordinator.currentMatchIndex = nil
            return
        }

        // Recompute matches only when query/case/text actually changed.
        let cacheKey = Coordinator.FindCacheKey(
            query: query,
            caseSensitive: findState.caseSensitive,
            textHash: text.hashValue
        )
        if coordinator.findCacheKey != cacheKey {
            coordinator.findMatches = Self.findRanges(
                in: textStorage.string,
                query: query,
                caseSensitive: findState.caseSensitive
            )
            coordinator.findCacheKey = cacheKey
            coordinator.currentMatchIndex = coordinator.findMatches.isEmpty ? nil : 0
            coordinator.lastNextNonce = findState.nextNonce
            coordinator.lastPrevNonce = findState.prevNonce
        }

        // Advance/regress match index when caller bumps a nonce.
        if !coordinator.findMatches.isEmpty {
            if findState.nextNonce != coordinator.lastNextNonce {
                coordinator.lastNextNonce = findState.nextNonce
                coordinator.currentMatchIndex =
                    ((coordinator.currentMatchIndex ?? -1) + 1) % coordinator.findMatches.count
            }
            if findState.prevNonce != coordinator.lastPrevNonce {
                coordinator.lastPrevNonce = findState.prevNonce
                let n = coordinator.findMatches.count
                coordinator.currentMatchIndex =
                    ((coordinator.currentMatchIndex ?? 0) - 1 + n) % n
            }
        }

        // Paint all matches in pink; current in purple.
        for (i, r) in coordinator.findMatches.enumerated() {
            let color = (i == coordinator.currentMatchIndex)
                ? NSColor.systemPurple.withAlphaComponent(0.55)
                : NSColor.systemPink.withAlphaComponent(0.30)
            layoutManager.addTemporaryAttribute(
                .backgroundColor, value: color, forCharacterRange: r
            )
        }

        // Scroll current match into view.
        if let idx = coordinator.currentMatchIndex,
           idx < coordinator.findMatches.count {
            textView.scrollRangeToVisible(coordinator.findMatches[idx])
        }

        // Publish summary back to caller. Hop to next runloop so we
        // don't mutate published state during a SwiftUI view-update.
        let summary = Self.summarize(
            matches: coordinator.findMatches,
            current: coordinator.currentMatchIndex
        )
        if let cb = onFindSummary {
            DispatchQueue.main.async { cb(summary) }
        }
    }

    static func findRanges(
        in haystack: String,
        query: String,
        caseSensitive: Bool
    ) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        let ns = haystack as NSString
        let full = NSRange(location: 0, length: ns.length)
        let opts: NSString.CompareOptions =
            caseSensitive ? [.literal] : [.literal, .caseInsensitive]
        var out: [NSRange] = []
        var search = full
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

    static func buildAttributed(
        text: String, runs: [HighlightRun], theme: SyntaxTheme, fontSize: CGFloat
    ) -> NSAttributedString {
        let attr = NSMutableAttributedString(string: text)
        let baseFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let full = NSRange(location: 0, length: (text as NSString).length)
        attr.addAttribute(.font, value: baseFont, range: full)
        attr.addAttribute(.foregroundColor, value: theme.defaultText, range: full)
        for run in runs {
            // Defensive: clip against text length so a stale-range run
            // (from a prior text) can't crash addAttribute.
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

    public final class Coordinator {
        struct AttrCacheKey: Equatable {
            let text: String
            let fontSize: CGFloat
            let theme: SyntaxTheme.Name
            let runCount: Int
        }
        struct FindCacheKey: Equatable {
            let query: String
            let caseSensitive: Bool
            let textHash: Int
        }
        var lastAttrKey: AttrCacheKey?
        var lastText: String = ""
        var findMatches: [NSRange] = []
        var currentMatchIndex: Int?
        var findCacheKey: FindCacheKey?
        var lastNextNonce: Int = 0
        var lastPrevNonce: Int = 0
    }

    /// Match-count summary the find bar can display.
    public static func summarize(
        matches: [NSRange], current: Int?
    ) -> String {
        if matches.isEmpty { return "" }
        let pos = (current ?? 0) + 1
        return "\(pos)/\(matches.count)"
    }
}
