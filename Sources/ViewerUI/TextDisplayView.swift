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
    /// TSK-259: the user-selected monospace family (nil = system).
    /// Resolution is fail-safe (FontPreference.resolvedFont).
    public let fontName: String?
    public let language: HighlightLanguage
    public let runs: [HighlightRun]
    public let theme: SyntaxTheme
    public let findState: FindState
    public let wordWrap: Bool
    public let showInvisibles: Bool
    /// True when the backing file loaded above the read-only soft
    /// watermark (`TextFile.isLargeReadOnly`). Threaded down so the
    /// controller skips per-interaction O(N) overlays (newline index,
    /// selection highlight) that would make a few-hundred-MB file
    /// unusable. Default false keeps every existing call site unchanged.
    public let isLargeReadOnly: Bool
    /// Scroll-to-line request. (`line: nil` = no-op; otherwise scroll
    /// to that 1-based line and place the caret there.) The nonce
    /// distinguishes repeat requests for the same line.
    public let scrollLineRequest: ScrollLineRequest
    public let onFindSummary: ((String) -> Void)?
    public let onScrollChange: ((SourceScrollState) -> Void)?
    /// Called whenever the textView's selectedRange changes. Caller
    /// typically uses this to update a cursor-position indicator
    /// (line:col) in the status bar.
    public let onSelectionChange: ((SourceSelection) -> Void)?
    /// Called whenever the find-match set changes. The argument is
    /// the list of 1-based document line numbers where matches exist,
    /// in document order, along with the active match's index into
    /// that list (nil when no current match). Consumed by the find
    /// minimap (see `FindMatchMinimapView`). Empty when the find bar
    /// is dismissed or no matches.
    public let onFindMatchesChange: ((FindMatchSet) -> Void)?

    public init(
        text: String,
        fontSize: CGFloat = 13,
        fontName: String? = nil,
        language: HighlightLanguage = .plainText,
        runs: [HighlightRun] = [],
        theme: SyntaxTheme = .xcodeLight,
        findState: FindState = .empty,
        wordWrap: Bool = false,
        showInvisibles: Bool = false,
        isLargeReadOnly: Bool = false,
        scrollLineRequest: ScrollLineRequest = .none,
        onFindSummary: ((String) -> Void)? = nil,
        onScrollChange: ((SourceScrollState) -> Void)? = nil,
        onSelectionChange: ((SourceSelection) -> Void)? = nil,
        onFindMatchesChange: ((FindMatchSet) -> Void)? = nil
    ) {
        self.text = text
        self.fontSize = fontSize
        self.fontName = fontName
        self.language = language
        self.runs = runs
        self.theme = theme
        self.findState = findState
        self.wordWrap = wordWrap
        self.showInvisibles = showInvisibles
        self.isLargeReadOnly = isLargeReadOnly
        self.scrollLineRequest = scrollLineRequest
        self.onFindSummary = onFindSummary
        self.onScrollChange = onScrollChange
        self.onSelectionChange = onSelectionChange
        self.onFindMatchesChange = onFindMatchesChange
    }

    /// Snapshot of the find-bar's match set published to the SwiftUI
    /// minimap. Lines are 1-based and in document order; duplicates
    /// per line are preserved (multiple matches on one line each get a
    /// tick).
    public struct FindMatchSet: Equatable, Sendable {
        public let lines: [Int]
        public let currentIndex: Int?
        public static let empty = FindMatchSet(lines: [], currentIndex: nil)
        public init(lines: [Int], currentIndex: Int?) {
            self.lines = lines
            self.currentIndex = currentIndex
        }
    }

    public struct ScrollLineRequest: Equatable, Sendable {
        public let line: Int?
        public let nonce: Int
        public static let none = ScrollLineRequest(line: nil, nonce: 0)
        public init(line: Int?, nonce: Int) {
            self.line = line
            self.nonce = nonce
        }
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

    /// RC-7 (memory-on-close): when SwiftUI discards the source-view
    /// representable (tab close, mode switch, content replaced), proactively
    /// release the heavy `NSTextStorage` / `NSLayoutManager` glyph store.
    ///
    /// For a multi-MB source file `NSLayoutManager` lays out the entire
    /// document into a glyph store that can dwarf the file (a 5 MB file →
    /// 100+ MB resident). ARC frees this when the controller deinits, but
    /// the dealloc can be deferred to a later autorelease-pool drain, and
    /// `NSTextView`'s teardown of its own layout managers is itself
    /// lazy. Doing it here, synchronously at the dismantle point, frees
    /// the buffer at the earliest deterministic moment so the pages are
    /// immediately available for reuse by the next large file (verified:
    /// repeated open/close of a 5 MB file plateaus rather than ratchets)
    /// and become reclaimable on memory pressure right away.
    public static func dismantleNSViewController(
        _ controller: SourceTextController, coordinator: ()
    ) {
        controller.teardownStorage()
    }

    public func updateNSViewController(_ controller: SourceTextController, context: Context) {
        controller.apply(
            text: text,
            fontSize: fontSize,
            fontName: fontName,
            theme: theme,
            runs: runs,
            wordWrap: wordWrap,
            showInvisibles: showInvisibles,
            scrollLineRequest: scrollLineRequest,
            findState: findState,
            isLargeReadOnly: isLargeReadOnly,
            onFindSummary: onFindSummary,
            onScrollChange: onScrollChange,
            onSelectionChange: onSelectionChange,
            onFindMatchesChange: onFindMatchesChange
        )
    }
}

/// PoC LSP entry point: callers can grab the underlying NSTextView
/// from a `SourceTextController` (e.g. via an `@State` ref captured in
/// `makeNSViewController`-adjacent code or a SwiftUI `Coordinator`)
/// and pass it to `LSPHoverAttachment.bind`. Kept as an extension so
/// the LSP wiring is fully opt-in and trivially deletable.
public extension SourceTextController {
    /// Exposed so the LSP attachment can install event monitors on
    /// the real text view. Returns the same object every call.
    var lspTextView: NSTextView { textView }
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

    /// 1-based source line currently at the top of the viewport (UX-K, #231),
    /// or `nil` when the geometry isn't usable yet (zero line height /
    /// zero-line document, e.g. the first-paint seed before `viewDidLoad`).
    ///
    /// `line = round((offsetY - topInset) / lineHeight) + 1`, clamped to
    /// `[1, lineCount]`. `round` (not `floor`) so a viewport sitting
    /// fractionally past a line's top maps back to that same line rather than
    /// drifting up by one each save/restore cycle.
    ///
    /// NB: restore reuses `scrollSource(toLine:)`, which *centers* the target
    /// line in the viewport (it has no top-align mode). So a reopened file
    /// lands with the previously-top line centered, not pinned to the top —
    /// an acceptable "near where you left off" approximation that avoids a
    /// parallel top-align scroll path. The captured value here is the true
    /// top-of-viewport line; the centering is purely a restore-side artifact.
    public var topVisibleLine: Int? {
        guard lineHeight > 0, lineCount > 0 else { return nil }
        let raw = Int(((offsetY - topInset) / lineHeight).rounded()) + 1
        return min(max(raw, 1), lineCount)
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
    /// TSK-736: whether the find-highlight temp-attrs are CURRENTLY painted on
    /// the layout manager for `lastFindKey`. Lets `applyFindHighlights` skip its
    /// O(document) remove-all + O(matches) repaint on an apply() where nothing
    /// find-related changed — a hover line-crossing re-bodies the source view →
    /// `updateNSViewController` → apply(), which on a big file with Find active
    /// was per-mouse-move temp-attr churn. Cleared when the text storage's
    /// CHARACTERS are replaced (that wipes layout-manager temp-attrs); set true
    /// after a repaint. The find wash is a fixed Palette colour (theme-
    /// independent), so an attribute-only repaint needs no find repaint.
    private var findHighlightsLive = false
    private var findMatches: [NSRange] = []
    private var currentMatchIndex: Int?
    private var lastNextNonce: Int = 0
    private var lastPrevNonce: Int = 0
    /// Tracks which `currentMatchIndex` we last scrolled to. Stops the
    /// recurring `scrollRangeToVisible` from yanking the viewport back
    /// to the current match on every redraw — that was breaking the
    /// "scroll past the highlight to see context" workflow.
    private var lastScrolledMatchIndex: Int?
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
    private var onFindMatchesChange: ((TextDisplayView.FindMatchSet) -> Void)?
    private var lastPublishedFindMatchSet: TextDisplayView.FindMatchSet?

    // MARK: - Selection-highlight ("highlight all instances of selection")

    /// Engine that decides whether the current selection qualifies for
    /// the "highlight all instances" treatment and, if so, finds all
    /// other occurrences. Pure value type — see SelectionHighlightEngine.swift.
    private let selectionHighlightEngine = SelectionHighlightEngine()
    /// Ranges currently painted by the selection-highlight pass.
    /// Tracked so the next pass can clear them without disturbing
    /// find / current-line backdrops elsewhere in the text.
    private var selectionHighlightRanges: [NSRange] = []
    /// Throttle: at most one selection-highlight recompute per
    /// `selectionHighlightThrottleSeconds`. Selection changes can fire
    /// at keypress cadence (arrow-key drag) — a full findRanges walk
    /// per change is wasteful on a multi-hundred-KB file.
    private static let selectionHighlightThrottleSeconds: TimeInterval = 0.15
    private var lastSelectionHighlightFireDate: Date?
    nonisolated(unsafe) private var pendingSelectionHighlightWork: DispatchWorkItem?
    /// UTF-8 byte count of the current text — cached on each apply()
    /// so the per-selection size-cap check is O(1) rather than
    /// O(text.utf8.count). Cleared (set to 0) when there's no text.
    private var cachedTextByteCount: Int = 0
    private var cachedFontSize: CGFloat = 13
    /// TSK-259: the family the last apply() used — gutter metrics must
    /// derive from the SAME font the body renders or lines misalign.
    private var cachedFontName: String?
    private var cachedLineCount: Int = 1
    /// When true, the file loaded above the read-only soft watermark
    /// (see `TextFile.isLargeReadOnly`). The source view then skips the
    /// O(N)-per-interaction overlays that would make a few-hundred-MB
    /// file unusable: the newline-offset index build (walks the whole
    /// UTF-16 storage to resolve line:col) and the selection-highlight
    /// pass. The plain-text fast path already runs because highlighting
    /// is auto-off above the 512 KiB cap, so `runs` is always empty here.
    private var isLargeReadOnly: Bool = false
    private var lastPublishedScrollState: SourceScrollState?
    /// Dedupe for the find-summary + selection callbacks. Without
    /// these, every apply() call re-fires the callback even when the
    /// value is unchanged. The model side then republishes via
    /// @Published (which is value-blind) → SwiftUI re-renders →
    /// apply() called again → infinite publish loop. The symptom
    /// before this guard: ~5 MB/sec RSS growth in source mode at idle.
    private var lastFindSummary: String?
    private var lastPublishedSelection: SourceSelection?
    /// Last theme passed to `apply()` — `applyCurrentLineHighlight`
    /// reads it asynchronously from the selection observer so we
    /// need it cached, not fetched out of the SwiftUI struct.
    private var currentTheme: SyntaxTheme = .xcodeLight

    /// Cheap content fingerprint: utf8 byte count + first + last byte.
    /// Avoids storing or hashing the full string in the cache key
    /// (Equatable on a 1 MB String was an O(N) compare per `apply()`).
    /// Collisions are theoretically possible (same length + same first
    /// & last byte but different middle) but produce only a no-op
    /// skip, never wrong output — the next genuine change will
    /// invalidate via length change.
    private struct ContentFingerprint: Equatable {
        let byteCount: Int
        let firstByte: UInt8
        let lastByte: UInt8
        init(_ text: String) {
            self.byteCount = text.utf8.count
            self.firstByte = text.utf8.first ?? 0
            self.lastByte  = text.utf8.last ?? 0
        }
    }
    private struct AttrKey: Equatable {
        let content: ContentFingerprint
        let fontSize: CGFloat
        let fontName: String?
        let theme: SyntaxTheme.Name
        let runCount: Int
    }
    private struct FindKey: Equatable {
        let query: String
        let caseSensitive: Bool
        let isRegex: Bool
        let content: ContentFingerprint
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
        // Defer off-screen layout. Without this NSLayoutManager builds
        // glyph runs for the entire textStorage on every setAttributedString,
        // which is the single biggest UI-thread cost for multi-hundred-KB
        // files. Safe to enable since our gutter is a SwiftUI sibling
        // (clipView-bounds-driven), not an NSRulerView that would force
        // contiguous layout to fill its visible range.
        tv.layoutManager?.allowsNonContiguousLayout = true
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
        // All three observers post on the `.main` OperationQueue, so the
        // callback always runs on the main thread. `MainActor.assumeIsolated`
        // asserts that contract so the @MainActor-isolated `publishX`
        // methods are callable. Required by Swift 6.3 strict concurrency.
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clip, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.publishScrollState() }
        }
        frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: clip, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.publishScrollState() }
        }
        selectionObserver = NotificationCenter.default.addObserver(
            forName: NSTextView.didChangeSelectionNotification,
            object: textView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.publishSelection() }
        }
    }

    deinit {
        if let o = scrollObserver    { NotificationCenter.default.removeObserver(o) }
        if let o = frameObserver     { NotificationCenter.default.removeObserver(o) }
        if let o = selectionObserver { NotificationCenter.default.removeObserver(o) }
        pendingSelectionHighlightWork?.cancel()
    }

    /// Release the heavy `NSTextStorage` / `NSLayoutManager` glyph store.
    /// Called from `dismantleNSViewController` on close so the buffer is
    /// freed at the earliest deterministic point (see that method's note).
    ///
    /// We empty the storage AND detach every layout manager: a populated
    /// `NSLayoutManager` keeps its glyph store until *it* deallocs, and
    /// `NSTextView` releases its layout managers lazily — detaching here
    /// forces the glyph store to drop now rather than at some later
    /// autorelease drain. Cancel any pending selection-highlight work too,
    /// so a queued closure can't resurrect attributes on a torn-down view.
    func teardownStorage() {
        pendingSelectionHighlightWork?.cancel()
        // CRITICAL: drop the notification observers BEFORE mutating storage.
        // `endEditing()` below flushes layout, which makes NSTextView clamp
        // its now-stale selection into the emptied storage and synchronously
        // post `didChangeSelectionNotification`. If `selectionObserver` is
        // still live, that fires `publishSelection()` → mutates the
        // @Published `sourceSelection` → SwiftUI `GraphHost.invalidate()`,
        // re-entering a graph mutation already in flight at dismantle time —
        // an exclusive-access trap (SIGABRT). `removeObserver` is idempotent
        // and we nil the handles so `deinit` doesn't double-remove.
        if let o = scrollObserver    { NotificationCenter.default.removeObserver(o); scrollObserver = nil }
        if let o = frameObserver     { NotificationCenter.default.removeObserver(o); frameObserver = nil }
        if let o = selectionObserver { NotificationCenter.default.removeObserver(o); selectionObserver = nil }
        if let storage = textView.textStorage {
            storage.beginEditing()
            storage.setAttributedString(NSAttributedString(string: ""))
            storage.endEditing()
            for lm in storage.layoutManagers {
                storage.removeLayoutManager(lm)
            }
        }
        lastAttrKey = nil
        lastFindKey = nil
        findMatches = []
        currentMatchIndex = nil
        newlineOffsets = nil
        newlineOffsetsFor = NSRange(location: 0, length: -1)
        selectionHighlightRanges.removeAll()
        lastCurrentLineRange = nil
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
            lineHeight: Self.lineHeight(forFontSize: cachedFontSize, fontName: cachedFontName),
            lineCount: cachedLineCount,
            topInset: topInset
        )
        if state == lastPublishedScrollState { return }
        lastPublishedScrollState = state
        cb(state)
    }

    /// Cached array of UTF-16 offsets where each newline starts in the
    /// current textStorage. Built lazily on first use after each
    /// content change; cleared in `applyAttributedString`. Lets
    /// `publishSelection` resolve (line, column) by binary search in
    /// O(log lines) instead of walking `0..<loc` calling
    /// `NSString.character(at:)` per character (which on a 1 MB file
    /// at a deep cursor was ~800K calls per arrow press).
    private var newlineOffsets: [Int]?
    private var newlineOffsetsFor: NSRange = NSRange(location: 0, length: -1)

    private func newlineOffsetsRefreshed() -> [Int] {
        guard let storage = textView.textStorage else { return [] }
        let length = storage.length
        if let cached = newlineOffsets,
           newlineOffsetsFor.length == length {
            return cached
        }
        let ns = storage.string as NSString
        var offsets: [Int] = []
        offsets.reserveCapacity(max(16, length / 80))
        var i = 0
        while i < length {
            if ns.character(at: i) == 0x0A {
                offsets.append(i)
            }
            i += 1
        }
        newlineOffsets = offsets
        newlineOffsetsFor = NSRange(location: 0, length: length)
        return offsets
    }

    /// Compute (line, column) from the textView's selectedRange and
    /// publish via the caller's callback IF it changed. The dedupe
    /// is what stops the apply→publish→re-render→apply→… loop.
    private func publishSelection() {
        // Re-apply the current-line backdrop on every selection move.
        // Cheap (single line range), debounced internally by range
        // equality below.
        applyCurrentLineHighlight()
        // Large read-only files skip the selection-highlight pass
        // entirely. The engine policy already bails above 5 MB
        // (`maxHaystackBytes`), but skipping the schedule avoids even
        // the throttle/work-item churn on a file that can never paint.
        if !isLargeReadOnly {
            // Selection-driven "highlight all instances of selection" —
            // throttled to ~150ms so per-keystroke caret drags don't fire
            // an O(text) find on every change. Bails for short / long /
            // multi-line selections and for huge files (see engine policy).
            scheduleSelectionHighlightRefresh()
        }

        guard let cb = onSelectionChange else { return }
        let sel = textView.selectedRange()
        let total = textView.textStorage?.length ?? 0
        let loc = min(sel.location, total)
        // Large read-only files skip the newline-offset index build.
        // That index walks the ENTIRE UTF-16 storage (`ns.character(at:)`
        // per char) to resolve a precise (line, column); on a few-
        // hundred-MB file the first build is multi-second and a single-
        // line minified blob degenerates it entirely. We still publish a
        // selection so the status bar updates, but with line:col = 0:0
        // sentinel meaning "not computed for a large file" — the caret
        // offset (length) is still accurate for selection-length needs.
        if isLargeReadOnly {
            let degraded = SourceSelection(line: 0, column: 0, length: sel.length)
            if degraded == lastPublishedSelection { return }
            lastPublishedSelection = degraded
            cb(degraded)
            return
        }
        let offsets = newlineOffsetsRefreshed()
        // Number of newlines BEFORE `loc` = the count of offsets < loc.
        // Binary search for the first offset >= loc; that index is also
        // the count of newlines preceding the cursor.
        var lo = 0
        var hi = offsets.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if offsets[mid] < loc { lo = mid + 1 } else { hi = mid }
        }
        let line = lo + 1
        let lineStart = lo == 0 ? 0 : offsets[lo - 1] + 1
        let new = SourceSelection(
            line: line,
            column: loc - lineStart + 1,
            length: sel.length
        )
        if new == lastPublishedSelection { return }
        lastPublishedSelection = new
        cb(new)
    }

    /// Last line range we painted a current-line backdrop over —
    /// remembered so the next selection move can clear it without
    /// blowing away find / temp attributes elsewhere in the text.
    private var lastCurrentLineRange: NSRange?

    /// Paint a faint full-line backdrop behind the caret. Makes it
    /// obvious which line `⌘⌥D` (bookmark current line) will operate
    /// on. Uses `.backgroundColor` temporary attribute on the layout
    /// manager — coexists with syntax highlighting (which uses real
    /// text-storage attributes) but does collide with find highlights
    /// (also temp attrs). Find takes priority — current-line backdrop
    /// rebuilds whenever selection changes or find clears.
    private func applyCurrentLineHighlight() {
        guard let lm = textView.layoutManager,
              let storage = textView.textStorage,
              storage.length >= 0 else { return }
        let sel = textView.selectedRange()
        let location = min(sel.location, max(0, storage.length))
        let lineRange = (textView.string as NSString)
            .lineRange(for: NSRange(location: location, length: 0))
        if lineRange == lastCurrentLineRange { return }
        if let prev = lastCurrentLineRange {
            lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: prev)
        }
        // Blend the theme's selected-line tint over the background.
        // Tuned for visibility — user feedback said the prior ~6%
        // wasn't obvious enough. 12% on dark themes, 8% on light:
        // dark backgrounds swallow contrast faster, so they need
        // more lift to read as a "current line" cue.
        let isDark = currentTheme.background.brightnessComponent < 0.5
        let backdrop = (isDark ? NSColor.white : NSColor.black)
            .withAlphaComponent(isDark ? 0.12 : 0.08)
        lm.addTemporaryAttribute(.backgroundColor, value: backdrop,
                                 forCharacterRange: lineRange)
        lastCurrentLineRange = lineRange
    }

    /// Schedule a selection-highlight refresh, throttled to fire at
    /// most once per `selectionHighlightThrottleSeconds`. Multiple
    /// rapid selection changes coalesce — only the last selection's
    /// occurrences get painted, which is what the user expects.
    private func scheduleSelectionHighlightRefresh() {
        pendingSelectionHighlightWork?.cancel()
        let now = Date()
        let throttle = Self.selectionHighlightThrottleSeconds
        let elapsed = lastSelectionHighlightFireDate.map { now.timeIntervalSince($0) } ?? .infinity
        let delay = max(0, throttle - elapsed)
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshSelectionHighlight()
            }
        }
        pendingSelectionHighlightWork = work
        if delay <= 0 {
            DispatchQueue.main.async(execute: work)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    /// Compute + paint the selection-highlight ranges via the layout
    /// manager's temporary attributes. Coexists with current-line
    /// backdrop and find highlights (all three are temp attrs); the
    /// per-pass clear is scoped to the previously-painted ranges so
    /// the other layers are preserved.
    ///
    /// Color choice: translucent yellow on light themes, translucent
    /// amber on dark themes. Low-contrast on purpose — the active
    /// selection itself (OS-drawn) should remain the visually loudest
    /// signal; the secondary occurrences are an ambient cue.
    private func refreshSelectionHighlight() {
        lastSelectionHighlightFireDate = Date()
        guard let lm = textView.layoutManager,
              let storage = textView.textStorage else { return }
        let text = textView.string
        let selection = textView.selectedRange()

        // Clear last pass's highlights first — bounded by the count of
        // matches we painted, not the full textStorage length.
        for r in selectionHighlightRanges {
            let clamped = NSRange(
                location: min(r.location, storage.length),
                length: min(r.length, max(0, storage.length - r.location))
            )
            if clamped.length > 0 {
                lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: clamped)
            }
        }
        selectionHighlightRanges.removeAll(keepingCapacity: true)

        let matches = selectionHighlightEngine.otherOccurrences(
            in: text,
            selection: selection,
            haystackByteCount: cachedTextByteCount
        )
        if matches.isEmpty {
            // Restore the current-line backdrop in case we just wiped
            // it (we shouldn't have — clears are scoped — but cheap).
            return
        }

        let isDark = currentTheme.background.brightnessComponent < 0.5
        let tint = (isDark
            ? NSColor(calibratedRed: 1.0, green: 0.84, blue: 0.30, alpha: 1)
            : NSColor(calibratedRed: 1.0, green: 0.92, blue: 0.40, alpha: 1))
            .withAlphaComponent(isDark ? 0.35 : 0.45)

        for r in matches {
            let clamped = NSRange(
                location: min(r.location, storage.length),
                length: min(r.length, max(0, storage.length - r.location))
            )
            if clamped.length > 0 {
                lm.addTemporaryAttribute(
                    .backgroundColor, value: tint,
                    forCharacterRange: clamped
                )
                selectionHighlightRanges.append(clamped)
            }
        }
    }

    /// Clear any painted selection-highlight ranges. Used by text /
    /// theme / find changes that re-wipe temporary background attrs.
    private func clearSelectionHighlight() {
        guard let lm = textView.layoutManager,
              !selectionHighlightRanges.isEmpty else {
            selectionHighlightRanges.removeAll(keepingCapacity: true)
            return
        }
        for r in selectionHighlightRanges {
            lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: r)
        }
        selectionHighlightRanges.removeAll(keepingCapacity: true)
    }

    /// Match NSTextView's effective line height for the default
    /// monospaced font. The factor 1.20 holds for SF Mono / Menlo /
    /// Monaco across the size range we use; if it ever drifts we'd
    /// see misalignment in the gutter.
    static func lineHeight(forFontSize size: CGFloat, fontName: String? = nil) -> CGFloat {
        // TSK-259: metrics come from the RESOLVED font — the doc comment
        // above warns exactly about gutter drift if these diverge.
        let font = FontPreference.resolvedFont(name: fontName, size: size)
        // boundingRectForFont gives the maximal glyph box; NSTextView's
        // layout manager uses a slightly tighter line height.
        return ceil(font.ascender - font.descender + font.leading)
    }

    /// Apply a (text, runs, theme, wrap, findState) update from SwiftUI.
    /// Each piece is gated on a coordinator-style cache key so we don't
    /// re-walk the textStorage when nothing actually changed.
    /// Most recently honored scroll-to-line nonce. Pair with the
    /// publisher's `sourceScrollLineNonce`: when they differ, we run
    /// the scroll + select; otherwise we skip.
    private var lastScrollLineNonce: Int = 0

    public func apply(
        text: String,
        fontSize: CGFloat,
        fontName: String? = nil,
        theme: SyntaxTheme,
        runs: [HighlightRun],
        wordWrap: Bool,
        showInvisibles: Bool,
        scrollLineRequest: TextDisplayView.ScrollLineRequest,
        findState: TextDisplayView.FindState,
        isLargeReadOnly: Bool = false,
        onFindSummary: ((String) -> Void)?,
        onScrollChange: ((SourceScrollState) -> Void)?,
        onSelectionChange: ((SourceSelection) -> Void)?,
        onFindMatchesChange: ((TextDisplayView.FindMatchSet) -> Void)? = nil
    ) {
        let applyToken = PerfSignpost.begin(.render, "SourceTextController.apply")
        defer { PerfSignpost.end(applyToken) }
        self.onScrollChange = onScrollChange
        self.onSelectionChange = onSelectionChange
        self.onFindMatchesChange = onFindMatchesChange
        self.isLargeReadOnly = isLargeReadOnly
        self.cachedFontSize = fontSize
        self.cachedFontName = fontName
        self.currentTheme = theme
        // Refresh cached byte count for the selection-highlight
        // engine's O(1) size check. utf8.count is O(N) but only walked
        // once per apply() (i.e. per text change), not per selection.
        self.cachedTextByteCount = text.utf8.count
        scrollView.backgroundColor = theme.background
        textView.backgroundColor = theme.background

        if wordWrap != lastWordWrap {
            applyWrap(wordWrap)
            lastWordWrap = wordWrap
        }
        // NSLayoutManager renders dots / arrows / pilcrows when this is
        // on, in its built-in faint grey (`tertiaryLabelColor`). There is
        // NO public API to override the marker color or substitute glyphs
        // here — doing so requires subclassing `NSLayoutManager` and
        // overriding `drawGlyphs(forGlyphRange:at:)`, which has
        // historically triggered the SwiftUI compositor bug in this
        // codebase (see LESSONS.md "Things to NOT do" + the compositor
        // section). So the read-only source view keeps the OS default
        // tone. The IntelliJ-style subtle-but-readable rendering (item I2)
        // lives in the editable path instead — CodeMirror 6's
        // show-invisibles ViewPlugin, styled via `.cm-invisible` in
        // `Resources/codemirror/codemirror.css`, which is fully
        // controllable and compositor-safe (WKWebView, no NSLayoutManager).
        textView.layoutManager?.showsInvisibleCharacters = showInvisibles

        applyAttributedString(
            text: text, fontSize: fontSize, fontName: fontName,
            theme: theme, runs: runs
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

        // Honor a scroll-to-line request if a new nonce arrived.
        // We apply AFTER attributed-string + wrap so layout is up to
        // date when we ask NSLayoutManager for the line's range.
        if scrollLineRequest.nonce != lastScrollLineNonce,
           let line = scrollLineRequest.line {
            lastScrollLineNonce = scrollLineRequest.nonce
            scroll(toLine: line)
        }
    }

    /// Scroll the text view so 1-based `line` is centered and select
    /// the entire line. Out-of-range targets are clamped silently.
    private func scroll(toLine line: Int) {
        let storage = textView.textStorage ?? NSTextStorage(string: textView.string)
        let nsText = storage.string as NSString
        let totalLength = nsText.length
        guard totalLength > 0 else { return }
        var lineNumber = 0
        var loc = 0
        var lineStart = 0
        var lineEnd = totalLength
        while loc <= totalLength {
            lineNumber += 1
            let r = nsText.lineRange(for: NSRange(location: loc, length: 0))
            if lineNumber == line {
                lineStart = r.location
                lineEnd = r.location + r.length
                break
            }
            if r.location + r.length >= totalLength {
                // Off the end — clamp to last line.
                lineStart = r.location
                lineEnd = r.location + r.length
                break
            }
            loc = r.location + r.length
        }
        // Exclude trailing newline from the selection so the visible
        // highlight doesn't span into the next row.
        var selEnd = lineEnd
        if selEnd > lineStart,
           nsText.character(at: selEnd - 1) == 0x0A {
            selEnd -= 1
        }
        let target = NSRange(location: lineStart, length: max(0, selEnd - lineStart))
        textView.setSelectedRange(target)
        textView.scrollRangeToVisible(target)
        // Re-center the target in the viewport when it would otherwise
        // sit at the edge. NSTextView.scrollRangeToVisible only ensures
        // visibility, not centering.
        if let lm = textView.layoutManager,
           let tc = textView.textContainer {
            let glyphRange = lm.glyphRange(forCharacterRange: target, actualCharacterRange: nil)
            let rect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
            let inset = textView.textContainerInset.height
            let viewportH = scrollView.contentView.bounds.height
            let targetY = max(0, rect.midY + inset - viewportH / 2)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        publishSelection()
        publishScrollState()
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
        text: String, fontSize: CGFloat, fontName: String?,
        theme: SyntaxTheme, runs: [HighlightRun]
    ) {
        // TSK-259: fontName is part of the repaint key — a family change
        // with identical text/size/theme must NOT serve the cached paint.
        let key = AttrKey(
            content: ContentFingerprint(text),
            fontSize: fontSize, fontName: fontName,
            theme: theme.name, runCount: runs.count
        )
        if key == lastAttrKey { return }
        let baseFont = FontPreference.resolvedFont(name: fontName, size: fontSize)

        // PERF (source-slow, 2026-06-01): in-place recolor on the
        // plain → highlighted transition.
        //
        // A source open paints TWICE: once with empty `runs` (cache cold →
        // plain text), then ~tokenize-latency later with the highlight runs.
        // The naive second paint did `setAttributedString(NSMutableAttr…)`
        // over the WHOLE document, which discards the textStorage AND the
        // glyph layout the first paint already built — a second full
        // O(document) layout on the main thread (the dominant "source takes
        // forever" cost on a few-hundred-KB file, esp. with word-wrap on).
        //
        // When ONLY the runs changed (byte-identical text — same content
        // fingerprint — same font + theme as the previous apply, and the
        // storage already holds that text), the glyphs are already laid out
        // correctly; only the foreground colors differ. Re-fix the colors as
        // addAttribute over the EXISTING storage inside one beginEditing/
        // endEditing batch. NSTextStorage keeps its layout (no
        // setAttributedString → no full re-layout); only the attribute-fix
        // pass runs, which is bounded by run count, not glyph count.
        if !runs.isEmpty,
           let prev = lastAttrKey,
           prev.content == key.content,
           prev.fontSize == fontSize,
           prev.theme == theme.name,
           let storage = textView.textStorage,
           storage.length == (text as NSString).length {
            let full = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            // Reset to base before painting runs so colors from a prior
            // highlighted state (e.g. a theme that left stale spans) don't
            // bleed through where the new runs don't cover.
            storage.addAttribute(.font, value: baseFont, range: full)
            storage.addAttribute(.foregroundColor, value: theme.defaultText, range: full)
            for run in runs {
                let lo = max(0, run.range.location)
                let hi = min(full.length, run.range.location + run.range.length)
                guard hi > lo else { continue }
                storage.addAttribute(
                    .foregroundColor,
                    value: theme.color(for: run.kind),
                    range: NSRange(location: lo, length: hi - lo)
                )
            }
            storage.endEditing()
            lastAttrKey = key
            // Text content is byte-identical, so the gutter line count and
            // the newline-offset cache are still valid — do NOT invalidate
            // them (that would force a needless O(N) rebuild on the next
            // selection move). The selection-highlight ranges are temporary
            // layout-manager attributes, untouched by addAttribute on the
            // storage; the find/selection passes that run right after this
            // in apply() refresh them anyway.
            return
        }

        if runs.isEmpty {
            // Fast path for plain text / unsupported language /
            // oversized files: no attributedString allocation.
            if textView.string != text {
                textView.string = text
                findHighlightsLive = false   // TSK-736: chars replaced → find temp-attrs wiped
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
            findHighlightsLive = false   // TSK-736: storage replaced → find temp-attrs wiped
        }
        lastAttrKey = key
        // Refresh line count for the gutter.
        cachedLineCount = Self.countLines(in: text)
        // Replacing the full attributed string drops every temporary
        // attribute the layout manager carried — including any
        // selection-highlight ranges we'd painted. Forget them so the
        // next refresh starts from a clean slate.
        selectionHighlightRanges.removeAll(keepingCapacity: true)
        // Invalidate the newline-offset binary-search cache used by
        // publishSelection. Cheap to rebuild on first selection move
        // after a content change.
        newlineOffsets = nil
        newlineOffsetsFor = NSRange(location: 0, length: -1)
    }

    /// Logical line count = `newlineCount + 1` for non-empty text (0 for empty).
    /// TSK-737: a trailing `\n` does NOT reduce the count — NSLayoutManager lays
    /// out an empty final line fragment after it, so a file ending in `\n` has
    /// one more line position than newlines. The old `-= 1` adjustment
    /// under-counted by one, which clamped the gutter's last row off (no number
    /// on the bottom line) and skewed the hover-highlight + pointer→line map
    /// (TSK-263) that read the same count. `static` (not `private`) for the
    /// pure-logic teeth test.
    static func countLines(in text: String) -> Int {
        if text.isEmpty { return 0 }
        var n = 1
        for b in text.utf8 where b == 0x0A { n += 1 }
        return n
    }

    private func applyFindHighlights(
        text: String,
        findState: TextDisplayView.FindState,
        onFindSummary: ((String) -> Void)?
    ) {
        guard let layoutManager = textView.layoutManager,
              let textStorage = textView.textStorage else { return }
        let query = findState.query

        // Early return when the find bar isn't active AND wasn't active
        // last apply() either. Without this guard, every scroll tick /
        // selection change / theme tick fired a full-range
        // removeTemporaryAttribute over the entire textStorage — for
        // multi-hundred-KB files that's a measurable per-tick cost
        // with zero observable effect.
        if query.isEmpty, lastFindKey == nil, findMatches.isEmpty {
            return
        }

        // TSK-736: if the find highlights are already painted for exactly this
        // query/case/regex/content (`lastFindKey`) and no next/prev navigation
        // happened, the layout manager already shows the correct wash — return
        // BEFORE the full-range remove-all + per-match repaint below. Those run
        // on EVERY apply(), and a mouse hover line-crossing re-bodies
        // SourceModeView → updateNSViewController → apply(), so on a big file
        // with Find active this was O(document)+O(matches) of temp-attr churn
        // per mouse move (the felt lag). `findHighlightsLive` is cleared
        // whenever the storage chars are replaced, so this can only fire when
        // the wash is genuinely still on screen.
        if !query.isEmpty, findHighlightsLive, lastFindKey == FindKey(
            query: query, caseSensitive: findState.caseSensitive,
            isRegex: findState.isRegex, content: ContentFingerprint(text)),
           findState.nextNonce == lastNextNonce,
           findState.prevNonce == lastPrevNonce {
            return
        }

        let full = NSRange(location: 0, length: textStorage.length)
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
        // Find apply just wiped every backgroundColor attribute,
        // including our current-line backdrop and selection-highlight
        // overlay. Drop both caches so the next selection move reapplies
        // them cleanly.
        lastCurrentLineRange = nil
        selectionHighlightRanges.removeAll(keepingCapacity: true)

        guard !query.isEmpty, textStorage.length > 0 else {
            findMatches = []
            currentMatchIndex = nil
            lastFindKey = nil
            findHighlightsLive = false   // remove-all above cleared the wash
            // Dedupe: only publish "" if we hadn't already.
            if let cb = onFindSummary, lastFindSummary != "" {
                lastFindSummary = ""
                DispatchQueue.main.async { cb("") }
            }
            publishFindMatchSet(text: text)
            return
        }

        let cacheKey = FindKey(
            query: query,
            caseSensitive: findState.caseSensitive,
            isRegex: findState.isRegex,
            content: ContentFingerprint(text)
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
            // G2: tuned bright-blue wash (Palette) for both states —
            // legible on light + dark, current match at higher alpha.
            // Previously systemPurple/systemPink.
            let color = (i == currentMatchIndex)
                ? Palette.findHighlightCurrent
                : Palette.findHighlightInactive
            layoutManager.addTemporaryAttribute(
                .backgroundColor, value: color, forCharacterRange: r
            )
        }
        findHighlightsLive = true   // TSK-736: the wash is now painted for lastFindKey
        // Only auto-scroll when the active match actually changed
        // (new query, next/prev hit). Without this guard, every
        // `apply()` re-applied the highlight AND yanked the viewport
        // back to the match — so the user couldn't scroll past the
        // current hit to see surrounding context.
        if let idx = currentMatchIndex, idx < findMatches.count,
           idx != lastScrolledMatchIndex {
            lastScrolledMatchIndex = idx
            textView.scrollRangeToVisible(findMatches[idx])
        }
        if findMatches.isEmpty || currentMatchIndex == nil {
            lastScrolledMatchIndex = nil
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
        publishFindMatchSet(text: text)
    }

    /// Publish the current `findMatches` as a `FindMatchSet` of 1-based
    /// line numbers + the active match index. Consumed by the find
    /// minimap. Deduped by previous value so the SwiftUI subscriber
    /// only republishes when the set actually changes.
    ///
    /// Line resolution uses the shared `newlineOffsetsRefreshed`
    /// binary-search index (built lazily on first selection move
    /// after a content change), so the per-match line lookup is
    /// O(log lines) rather than O(loc).
    private func publishFindMatchSet(text: String) {
        guard let cb = onFindMatchesChange else { return }
        let lines: [Int]
        if findMatches.isEmpty {
            lines = []
        } else {
            let offsets = newlineOffsetsRefreshed()
            lines = findMatches.map { range in
                var lo = 0
                var hi = offsets.count
                let target = range.location
                while lo < hi {
                    let mid = (lo + hi) / 2
                    if offsets[mid] < target { lo = mid + 1 } else { hi = mid }
                }
                return lo + 1
            }
        }
        let set = TextDisplayView.FindMatchSet(
            lines: lines,
            currentIndex: currentMatchIndex
        )
        if set == lastPublishedFindMatchSet { return }
        lastPublishedFindMatchSet = set
        DispatchQueue.main.async { cb(set) }
    }

    private static func buildAttributed(
        text: String, runs: [HighlightRun], theme: SyntaxTheme, baseFont: NSFont
    ) -> NSAttributedString {
        let attr = NSMutableAttributedString(string: text)
        let full = NSRange(location: 0, length: attr.length)
        // beginEditing batches the N+2 attribute mutations into one
        // attribute-fixing pass at the end. Without it each addAttribute
        // does its own fix-up — for 10K+ highlight runs (typical for
        // 256 KB+ source) that's a measurable per-render cost.
        attr.beginEditing()
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
        attr.endEditing()
        return attr
    }

    /// Single-slot LRU cache for the most recently compiled regex.
    /// The find bar fires `findRanges` per keystroke; recompiling
    /// `NSRegularExpression` on every key is wasteful and shows up
    /// as latency on long patterns. One slot is enough — find
    /// queries are sticky.
    private static let regexCacheLock = NSLock()
    private static var lastRegexKey: String?
    private static var lastRegex: NSRegularExpression?
    /// Separate slot for the last KNOWN-INVALID pattern. Previously
    /// the negative cache stored `lastRegex = nil` in the same slot
    /// the positive cache used — so the `if lastRegexKey == key,
    /// let re = lastRegex` check fell through on the optional unwrap
    /// and we recompiled the invalid pattern on every keystroke.
    private static var lastFailedRegexKey: String?

    internal static func cachedRegex(pattern: String,
                                    caseSensitive: Bool) -> NSRegularExpression? {
        var opts: NSRegularExpression.Options = [.anchorsMatchLines]
        if !caseSensitive { opts.insert(.caseInsensitive) }
        let key = "\(caseSensitive ? "S" : "i"):\(pattern)"
        regexCacheLock.lock()
        defer { regexCacheLock.unlock() }
        if lastRegexKey == key, let re = lastRegex { return re }
        if lastFailedRegexKey == key { return nil }
        // SEC-003: ReDoS guard for the source-view find bar. The find
        // bar fires per keystroke against the full document, so a
        // catastrophic-backtracking pattern (e.g. `(a+)+$`) would peg
        // the main thread enumerating matches. Reject the known
        // exponential shapes before `NSRegularExpression` ever sees
        // them — the negative-cache slot stops us re-checking every
        // keystroke. `findRanges` treats a nil return as "no matches",
        // matching the existing invalid-pattern behaviour.
        if RegexComplexityGuard.reject(pattern) != nil {
            lastFailedRegexKey = key
            return nil
        }
        guard let re = try? NSRegularExpression(pattern: pattern, options: opts)
        else {
            lastFailedRegexKey = key
            return nil
        }
        lastRegexKey = key
        lastRegex = re
        lastFailedRegexKey = nil
        return re
    }

    /// Pure substring/regex search over `haystack`. Exposed internal so
    /// `@testable import ViewerUI` can exercise edge cases directly
    /// without spinning up an NSTextView.
    internal static func findRanges(in haystack: String, query: String, caseSensitive: Bool,
                                    isRegex: Bool = false) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        if isRegex {
            // Bad regex (unbalanced parens etc.) silently yields zero
            // matches — let the find bar show the "no matches" state
            // instead of crashing.
            guard let re = cachedRegex(pattern: query, caseSensitive: caseSensitive)
            else { return [] }
            let full = NSRange(location: 0, length: (haystack as NSString).length)
            // SEC-006: defense-in-depth wall-clock deadline on top of
            // the compile-time `reject` in `cachedRegex`. A pattern that
            // passes the shape check but backtracks polynomially can
            // still stall the main thread mid-enumeration over a large
            // document; cap it so the find bar degrades to a partial
            // result set instead of a frozen window.
            let result = RegexComplexityGuard.boundedMatches(
                re, in: haystack, range: full)
            return result.matches.map(\.range)
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
