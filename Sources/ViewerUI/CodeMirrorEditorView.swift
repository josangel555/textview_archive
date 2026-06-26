import AppKit
import SwiftUI
import WebKit
import ViewerKit
import ViewerCore
import os

/// Production text editor: CodeMirror 6 hosted in a `WKWebView`.
///
/// Replaces the `NSTextView`-backed `EditorTextDisplayView` PoC.
/// Bundles a vendored CM6 build (`Resources/codemirror/`) and exposes
/// a small Swift-side API that matches the prior editor contract:
///
/// - Initial text injected on first load via `setText(...)`.
/// - Edits debounced inside JS (200 ms) then posted back to Swift via
///   `WKScriptMessageHandler`, which calls `onTextChange`.
/// - ⌘S inside the webview posts `save` (was `saveRequested`), which
///   calls `onSaveRequested` (DocumentModel routes that to `saveActiveEditor`).
/// - Menu Undo/Redo route to `webView.evaluateJavaScript("undo()/redo()")`
///   when the active tab is in `.editor` mode — see `MarkdownViewer/main.swift`.
///
/// Bridge protocol v1 (`docs/CM6_INTEGRATION_DESIGN_2026-05-23.md` §13):
/// every wire payload carries `{v: 1, type: ..., ...}`. All outbound
/// calls go through `window.cmDispatch({...})`. Inbound goes through
/// `CMBridgeCodec.decodeInbound`.
public struct CodeMirrorEditorView: NSViewRepresentable {
    public let text: String
    public let fontSize: CGFloat
    public let language: HighlightLanguage
    public let isDarkTheme: Bool
    /// TSK-641 (theme engine, editor surface): the resolved CM palette of
    /// the USER-SELECTED theme (`DocumentModel.activeThemeCMPalette`).
    /// nil = no theme selected → the appearance-keyed legacy pair
    /// (TSK-602 behavior, byte-identical).
    public let themePalette: [String: String]?
    /// TSK-259 slice 2: the user-selected monospace family for the editor
    /// (nil = the bundle default). Same preference as the source view.
    public let fontFamily: String?
    public let wordWrap: Bool
    public let readOnly: Bool
    public let lineNumbers: Bool
    public let indentation: CMIndentation
    /// Bumping this value any time you want the editor to imperatively
    /// jump to a particular (1-based) line. Pass `nil` (default) to do
    /// nothing. Compare-by-equality means stable tab redraws don't
    /// re-trigger the jump.
    public let gotoLineRequest: CMGotoLineRequest?
    /// One-shot insert-at-caret request (TSK-299). Same nonce semantics
    /// as `gotoLineRequest`.
    public let insertRequest: CMInsertRequest?
    /// One-shot imperative selection request (TSK-705 snippet tab-stops).
    /// Drives `setSelection` to walk the caret through snippet `$N` stops.
    public let selectRequest: CMSelectRequest?
    /// TSK-705: true while a snippet tab-stop session is live, so the CM6
    /// host's Tab keymap routes Tab / Shift-Tab to `onSnippetTab` instead of
    /// indenting. Driven by `EditorCoordinator.isSnippetSessionActive`.
    public let snippetSessionActive: Bool
    public let showInvisibles: Bool
    /// Vim mode (opt-in; owner-approved 2026-06-15). Drives the JS host's
    /// `vimCompartment` via `setVimMode`. Off by default.
    public let vimMode: Bool
    /// TSK-906: one-shot "refocus the editor" nonce. Incremented by
    /// `DocumentModel.dismissPalette()` so the editor re-takes first responder
    /// after the palette overlay tears down. Int-nonce semantics (0 = idle).
    public let editorFocusRequest: Int
    /// Phase 4 (v2): toggle the indent-guides decoration plugin.
    /// Pure visual cue; no language-pack dependency.
    public let indentGuides: Bool
    /// Phase 4 (v2): LSP-driven fold ranges (UTF-16 doc offsets).
    /// Empty clears the override and CM falls back to language-default
    /// fold heuristics. Array equality means stable redraws no-op.
    public let foldingRanges: [CMFoldRange]
    /// Phase 4 (v2): diff + blame gutter markers, one per line.
    public let gutterMarkers: [CMGutterMarker]
    /// Pending diagnostics to push to CM6. Empty array clears any
    /// previously-pushed set. Compared by value (Array equality), so a
    /// stable redraw with the same diagnostics is a no-op.
    public let diagnostics: [CMDiagnostic]
    /// Find-bar driver values. Whenever any of these change, the
    /// editor coordinator dispatches the right CM6 search command
    /// through the v1 bridge.
    public let findQuery: String
    public let findCaseSensitive: Bool
    public let findRegex: Bool
    public let findNextRequest: Int
    public let findPrevRequest: Int
    /// Replacement string for find-and-replace. Carried into CM's
    /// `SearchQuery.replace` via `setSearchQuery`; consumed by the
    /// `replaceNext` / `replaceAll` request nonces below.
    public let findReplacement: String
    public let replaceNextRequest: Int
    public let replaceAllRequest: Int
    /// Initial caret position to seed on first mount (restore-on-tab-
    /// switch). nil = leave at start. Bumped via `setSelection` so
    /// gotoLine and selection-restore use the same path.
    public let initialSelection: CMSelectionSeed?
    /// Perf P1-followup (TSK-1047): stable key for the app-level warm-editor
    /// cache (`WarmEditorWebViewCache`). When non-nil, `dismantleNSView` PARKS
    /// this pane's CM6 WebView under the key (keeping the loaded document, undo
    /// history, caret, and scroll alive) and `makeNSView` RE-ATTACHES a parked
    /// WebView for the same key INSTEAD of rebuilding — so a session/tab switch
    /// (which mints fresh `Tab.id`s and evicts from the `MountedPanesLRU`) doesn't
    /// reload CM6 at the top of the file (the editor-scroll-resets bug). Derived
    /// from the file path (stable across the switch — what the snapshot persists).
    /// nil ⇒ this pane opts OUT of the cache (the split pane / preview slot pass
    /// nil so they never share or resurrect a cached editor). A re-attach is
    /// gated on the parked CM6's text matching this pane's `text` (the live-state
    /// safety invariant — see `WarmEditorWebViewCache`).
    public let cacheKey: String?
    public let onTextChange: (String) -> Void
    public let onSaveRequested: () -> Void
    public let onCursorChange: ((CMCursorPosition) -> Void)?
    /// Vim mode changed (TSK-679) — "normal"/"insert"/"visual…" or "" when
    /// vim is off. Routed to the footer status-bar mode indicator.
    public let onVimModeChange: ((String) -> Void)?
    public let onScrollChange: ((CMScrollPosition) -> Void)?
    public let onFindResultChange: ((CMFindResult) -> Void)?
    /// JS posted a hover request. Handler receives `(line, character,
    /// replyId)`; resolve via `Coordinator.send(.hoverResponse(...))`
    /// when the LSP round-trip finishes. Pass `contents: ""` to
    /// dismiss without showing a popover.
    public let onHoverRequest: ((CMHoverRequest) -> Void)?
    /// JS posted a Cmd-click. Swift opens the target tab via
    /// `LSPPool.definition` → `DocumentController.openTab(...)`.
    /// Handler is fire-and-forget; no JS reply expected.
    public let onDefinitionRequest: ((CMPositionRequest) -> Void)?
    /// JS posted a contextmenu. Swift pops a native NSMenu at the
    /// screen point. Handler must dispatch the menu synchronously
    /// (NSMenu.popUp blocks until dismissal).
    public let onContextMenuRequest: ((CMContextMenuRequest) -> Void)?
    /// JS posted `editorBlurred`. Wired to nil to ignore; the editor
    /// always posts blur, but Swift opts into save-on-blur via setting.
    public let onBlur: (() -> Void)?
    /// JS posted `snippetTab` / `snippetShiftTab` (TSK-705): the user pressed
    /// Tab / Shift-Tab while a snippet session was active. `forward == true`
    /// for Tab (advance), false for Shift-Tab (retreat). Swift walks the
    /// session and pushes a `selectRequest` to land the caret on the next stop.
    public let onSnippetTab: ((_ forward: Bool) -> Void)?

    public init(
        text: String,
        fontSize: CGFloat = 13,
        language: HighlightLanguage = .markdown,
        isDarkTheme: Bool = false,
        themePalette: [String: String]? = nil,
        fontFamily: String? = nil,
        wordWrap: Bool = true,
        readOnly: Bool = false,
        lineNumbers: Bool = true,
        indentation: CMIndentation = .spaces(2),
        gotoLineRequest: CMGotoLineRequest? = nil,
        insertRequest: CMInsertRequest? = nil,
        selectRequest: CMSelectRequest? = nil,
        snippetSessionActive: Bool = false,
        showInvisibles: Bool = false,
        vimMode: Bool = false,
        editorFocusRequest: Int = 0,
        indentGuides: Bool = false,
        foldingRanges: [CMFoldRange] = [],
        gutterMarkers: [CMGutterMarker] = [],
        diagnostics: [CMDiagnostic] = [],
        findQuery: String = "",
        findCaseSensitive: Bool = false,
        findRegex: Bool = false,
        findNextRequest: Int = 0,
        findPrevRequest: Int = 0,
        findReplacement: String = "",
        replaceNextRequest: Int = 0,
        replaceAllRequest: Int = 0,
        initialSelection: CMSelectionSeed? = nil,
        cacheKey: String? = nil,
        onTextChange: @escaping (String) -> Void,
        onSaveRequested: @escaping () -> Void = {},
        onCursorChange: ((CMCursorPosition) -> Void)? = nil,
        onVimModeChange: ((String) -> Void)? = nil,
        onScrollChange: ((CMScrollPosition) -> Void)? = nil,
        onFindResultChange: ((CMFindResult) -> Void)? = nil,
        onHoverRequest: ((CMHoverRequest) -> Void)? = nil,
        onDefinitionRequest: ((CMPositionRequest) -> Void)? = nil,
        onContextMenuRequest: ((CMContextMenuRequest) -> Void)? = nil,
        onBlur: (() -> Void)? = nil,
        onSnippetTab: ((_ forward: Bool) -> Void)? = nil
    ) {
        self.text = text
        self.fontSize = fontSize
        self.language = language
        self.isDarkTheme = isDarkTheme
        self.themePalette = themePalette
        self.fontFamily = fontFamily
        self.wordWrap = wordWrap
        self.readOnly = readOnly
        self.lineNumbers = lineNumbers
        self.indentation = indentation
        self.gotoLineRequest = gotoLineRequest
        self.insertRequest = insertRequest
        self.selectRequest = selectRequest
        self.snippetSessionActive = snippetSessionActive
        self.showInvisibles = showInvisibles
        self.vimMode = vimMode
        self.editorFocusRequest = editorFocusRequest
        self.indentGuides = indentGuides
        self.foldingRanges = foldingRanges
        self.gutterMarkers = gutterMarkers
        self.diagnostics = diagnostics
        self.findQuery = findQuery
        self.findCaseSensitive = findCaseSensitive
        self.findRegex = findRegex
        self.findNextRequest = findNextRequest
        self.findPrevRequest = findPrevRequest
        self.findReplacement = findReplacement
        self.replaceNextRequest = replaceNextRequest
        self.replaceAllRequest = replaceAllRequest
        self.initialSelection = initialSelection
        self.cacheKey = cacheKey
        self.onTextChange = onTextChange
        self.onSaveRequested = onSaveRequested
        self.onCursorChange = onCursorChange
        self.onVimModeChange = onVimModeChange
        self.onScrollChange = onScrollChange
        self.onFindResultChange = onFindResultChange
        self.onHoverRequest = onHoverRequest
        self.onDefinitionRequest = onDefinitionRequest
        self.onContextMenuRequest = onContextMenuRequest
        self.onBlur = onBlur
        self.onSnippetTab = onSnippetTab
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeNSView(context: Context) -> WKWebView {
        // Record the cache key on the (fresh) coordinator so `dismantleNSView`
        // — which only receives the coordinator, not the view — knows where to
        // park this pane's WebView. Set even on the cache-MISS path below.
        context.coordinator.cacheKey = cacheKey
        // Perf P1-followup (TSK-1047): re-attach a parked CM6 WebView for this
        // file instead of building a fresh one — keeping its loaded document,
        // undo history, caret, and SCROLL position intact, so a session/tab
        // switch-back doesn't reload CM6 at the top of the file. The re-attach is
        // GATED on the parked CM6's text matching THIS pane's `text` (the
        // live-state safety invariant — never resurrect stale text / mask edits;
        // see `WarmEditorWebViewCache`). On a hit we re-point the message handler
        // + delegate at the fresh coordinator and adopt the parked CM6 state, so
        // `applyPendingState` re-syncs cheaply (its `lastSent*` mirrors are
        // adopted, so identical state is a no-op — no `setText`, no reload).
        if let key = cacheKey,
           let parked = WarmEditorWebViewCache.shared.retrieve(
                forKey: key, expectedText: text) {
            let webView = parked.webView
            // Re-point the script message handler from the parked coordinator to
            // the fresh one. The handler name is per-WebView; add the new one,
            // having removed the old in `dismantleNSView` (parking path).
            webView.configuration.userContentController.add(
                context.coordinator, name: "mdvEditor")
            context.coordinator.adoptState(from: parked.coordinator)
            context.coordinator.webView = webView
            webView.navigationDelegate = context.coordinator
            context.coordinator.bind(view: self)
            CodeMirrorEditorRegistry.shared.register(webView)
            // Flush any state that changed while parked (theme/font/wrap/etc.) —
            // adopted `lastSent*` mirrors make unchanged state a no-op.
            context.coordinator.applyPendingState()
            return webView
        }

        let config = WKWebViewConfiguration()
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs
        // Shared process pool keeps the WebContent process warm across
        // editor tab switches — same reasoning as MarkdownRenderedView.
        config.processPool = Self.sharedProcessPool
        config.userContentController.add(context.coordinator, name: "mdvEditor")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        webView.setAccessibilityIdentifier("mdv.editor.webView")
        // CM6 handles all keyboard / paste / scroll behaviors; WKWebView
        // should not steal file-URL drops the parent SwiftUI handles.
        webView.unregisterDraggedTypes()

        context.coordinator.webView = webView
        context.coordinator.bind(view: self)
        context.coordinator.loadHostHTML()
        // Register so the AppDelegate's Undo/Redo menu items can find
        // the active CM6 webview without walking the view hierarchy.
        CodeMirrorEditorRegistry.shared.register(webView)
        #if DEBUG
        MountProbe.webViewMakes += 1   // Fix#1 mount-count probe (TSK-108)
        #endif
        return webView
    }

    public func updateNSView(_ webView: WKWebView, context: Context) {
        // Keep the parking key current — the pane's file can change within one
        // representable lifecycle, and `dismantleNSView` parks under whatever
        // this resolves to.
        context.coordinator.cacheKey = cacheKey
        context.coordinator.bind(view: self)
        context.coordinator.applyPendingState()
    }

    public static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        // Detach the message handler so the coordinator no longer receives JS
        // callbacks. WKUserContentController holds a STRONG reference to the
        // handler, so this must happen on BOTH paths (park + teardown) — on the
        // park path the make path re-adds a handler for the fresh coordinator.
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "mdvEditor")
        CodeMirrorEditorRegistry.shared.unregister(webView)

        // Perf P1-followup (TSK-1047): instead of tearing the WebView down, PARK
        // it in the warm-editor cache keyed by file path so a returning editor
        // tab (after a session switch that minted a fresh `Tab.id`, or an LRU
        // eviction) re-attaches it with NO reload — keeping the loaded document,
        // undo history, caret, and scroll. We record the CM6's current text
        // (`coordinator.currentText`, kept in lock-step with the live doc via the
        // change/echo path) so the make path can REJECT a re-attach if the
        // model's text has since diverged (the live-state safety invariant — no
        // stale text, no masked edits). Only opt-out panes (nil key, e.g. the
        // split pane / preview slot) take the real teardown below.
        if let key = coordinator.cacheKey {
            // Sever the live delegate link so no stray nav callback lands on this
            // (about-to-be-released) coordinator while parked; the make path
            // installs a fresh delegate on re-attach.
            webView.navigationDelegate = nil
            let parkedCoordinator = coordinator
            let parkedText = coordinator.currentText
            coordinator.webView = nil
            WarmEditorWebViewCache.shared.stash(
                webView, coordinator: parkedCoordinator,
                text: parkedText, forKey: key)
            return
        }

        coordinator.webView = nil
        #if DEBUG
        MountProbe.webViewDismantles += 1   // Fix#1 mount-count probe (TSK-108)
        #endif
    }

    /// Shared across all editor instances (one process pool per app
    /// session). Without sharing, each new tab spawns a fresh
    /// WebContent process (~50 MB resident).
    private static let sharedProcessPool = WKProcessPool()

    // MARK: - Coordinator

    /// Bridges `WKScriptMessageHandler` callbacks back to the SwiftUI
    /// closures, and forwards Swift-side state into the JS editor via
    /// `window.cmDispatch({...})` (protocol v1).
    @MainActor
    public final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var webView: WKWebView?
        /// Perf P1-followup (TSK-1047): the warm-editor cache key (file path)
        /// this pane's WebView is parked under on `dismantleNSView`. Set from
        /// `CodeMirrorEditorView.cacheKey` in make/update. nil ⇒ this pane opts
        /// out of the cache (real teardown on dismantle).
        var cacheKey: String?
        /// Becomes `true` the first time the bundled host HTML finishes
        /// loading. Gates the navigation policy: the lone legitimate
        /// `file:` load is the one-shot `loadFileURL(codemirror.html)` (and
        /// its bootstrap subresources, `codemirror.css`/`codemirror.js`),
        /// which all arrive BEFORE `didFinish`. Any post-bootstrap
        /// top-level `.other` navigation to `file:`/`data:` can only be an
        /// in-page script escape (`window.location = 'file:///etc/passwd'`)
        /// and is cancelled — see `decide(..., didFinishFirstLoad:)`. The
        /// editor never reloads its host page, so unlike `MarkdownRenderedView`
        /// it needs no `expectingProgrammaticLoad` distinction.
        var didFinishFirstLoad: Bool = false
        var onTextChange: ((String) -> Void)?
        var onSaveRequested: (() -> Void)?
        var onCursorChange: ((CMCursorPosition) -> Void)?
        var onVimModeChange: ((String) -> Void)?
        var onScrollChange: ((CMScrollPosition) -> Void)?
        var onFindResultChange: ((CMFindResult) -> Void)?
        var onHoverRequest: ((CMHoverRequest) -> Void)?
        var onDefinitionRequest: ((CMPositionRequest) -> Void)?
        var onContextMenuRequest: ((CMContextMenuRequest) -> Void)?
        var onBlur: (() -> Void)?
        var onSnippetTab: ((Bool) -> Void)?

        /// Pending state we attempt to flush every `updateNSView`.
        /// Before the bundled HTML finishes loading, all
        /// evaluateJavaScript calls silently no-op (no JS context yet),
        /// so we cache the desired state and apply it once the JS posts
        /// `{type: "ready"}`.
        private var pendingText: String?
        private var pendingFontSize: CGFloat?
        private var pendingLanguage: HighlightLanguage?
        private var pendingDark: Bool?
        private var pendingThemePalette: [String: String]?
        private var pendingFontFamily: String??
        private var pendingWrap: Bool?
        private var pendingReadOnly: Bool?
        private var pendingLineNumbers: Bool?
        private var pendingIndentation: CMIndentation?
        private var pendingGotoLine: CMGotoLineRequest?
        private var pendingFocusRequest: Int = 0
        private var pendingInsert: CMInsertRequest?
        private var pendingSelect: CMSelectRequest?
        private var pendingSnippetActive: Bool = false
        private var pendingShowInvisibles: Bool?
        private var pendingVim: Bool?
        private var pendingIndentGuides: Bool?
        private var pendingFoldingRanges: [CMFoldRange]?
        private var pendingGutterMarkers: [CMGutterMarker]?
        private var pendingDiagnostics: [CMDiagnostic]?
        private var pendingFindQuery: String?
        private var pendingFindCaseSensitive: Bool = false
        private var pendingFindRegex: Bool = false
        private var pendingFindNextRequest: Int = 0
        private var pendingFindPrevRequest: Int = 0
        private var pendingFindReplacement: String = ""
        private var pendingReplaceNextRequest: Int = 0
        private var pendingReplaceAllRequest: Int = 0
        private var pendingInitialSelection: CMSelectionSeed?
        private var didApplyInitialSelection: Bool = false
        private var isReady = false
        /// TSK-1047: WebContent-termination recovery attempts (capped).
        private var wcTerminateCount = 0
        /// Mirrors what we last successfully pushed to JS. Lets us
        /// skip redundant `setText` round-trips when the model just
        /// republished the same string after a JS → Swift → JS hop.
        private var lastSentText: String?
        private var lastSentFontSize: CGFloat?
        private var lastSentLanguage: HighlightLanguage?
        private var lastSentDark: Bool?
        private var lastSentPalette: [String: String]?
        private var lastSentFontFamily: String??
        private var lastSentWrap: Bool?
        private var lastSentVim: Bool?
        private var lastSentReadOnly: Bool?
        private var lastSentLineNumbers: Bool?
        private var lastSentIndentation: CMIndentation?
        private var lastAppliedGotoLine: CMGotoLineRequest?
        private var lastAppliedFocusRequest: Int = 0
        private var lastAppliedInsert: CMInsertRequest?
        private var lastAppliedSelect: CMSelectRequest?
        private var lastSentSnippetActive: Bool?
        private var lastSentShowInvisibles: Bool?
        private var lastSentIndentGuides: Bool?
        private var lastSentFoldingRanges: [CMFoldRange]?
        private var lastSentGutterMarkers: [CMGutterMarker]?
        private var lastSentDiagnostics: [CMDiagnostic]?
        /// (query, case, regex) tuple last shipped — comparing skips
        /// the bridge call when the user clears + re-shows the same
        /// query.
        private var lastSentFindQuery: (String, Bool, Bool, String)?
        private var lastSentFindNextRequest: Int = 0
        private var lastSentFindPrevRequest: Int = 0
        private var lastSentReplaceNextRequest: Int = 0
        private var lastSentReplaceAllRequest: Int = 0

        private static let log = Logger(
            subsystem: "com.markdownviewer.MarkdownViewer",
            category: "CodeMirrorEditor"
        )

        /// Pull the latest closures + desired state out of the
        /// representable. Called from both `makeNSView` and every
        /// `updateNSView`.
        func bind(view: CodeMirrorEditorView) {
            self.onTextChange = view.onTextChange
            self.onSaveRequested = view.onSaveRequested
            self.onCursorChange = view.onCursorChange
            self.onVimModeChange = view.onVimModeChange
            self.onScrollChange = view.onScrollChange
            self.onFindResultChange = view.onFindResultChange
            self.onHoverRequest = view.onHoverRequest
            self.onDefinitionRequest = view.onDefinitionRequest
            self.onContextMenuRequest = view.onContextMenuRequest
            self.onBlur = view.onBlur
            self.onSnippetTab = view.onSnippetTab
            self.pendingText = view.text
            self.pendingFontSize = view.fontSize
            self.pendingLanguage = view.language
            self.pendingDark = view.isDarkTheme
            self.pendingThemePalette = view.themePalette
            self.pendingFontFamily = view.fontFamily
            self.pendingWrap = view.wordWrap
            self.pendingReadOnly = view.readOnly
            self.pendingLineNumbers = view.lineNumbers
            self.pendingIndentation = view.indentation
            self.pendingGotoLine = view.gotoLineRequest
            self.pendingFocusRequest = view.editorFocusRequest
            self.pendingInsert = view.insertRequest
            self.pendingSelect = view.selectRequest
            self.pendingSnippetActive = view.snippetSessionActive
            self.pendingShowInvisibles = view.showInvisibles
            self.pendingVim = view.vimMode
            self.pendingIndentGuides = view.indentGuides
            self.pendingFoldingRanges = view.foldingRanges
            self.pendingGutterMarkers = view.gutterMarkers
            self.pendingDiagnostics = view.diagnostics
            self.pendingFindQuery = view.findQuery
            self.pendingFindCaseSensitive = view.findCaseSensitive
            self.pendingFindRegex = view.findRegex
            self.pendingFindNextRequest = view.findNextRequest
            self.pendingFindPrevRequest = view.findPrevRequest
            self.pendingFindReplacement = view.findReplacement
            self.pendingReplaceNextRequest = view.replaceNextRequest
            self.pendingReplaceAllRequest = view.replaceAllRequest
            self.pendingInitialSelection = view.initialSelection
        }

        /// Perf P1-followup (TSK-1047): the text the live CM6 currently holds, as
        /// mirrored by `lastSentText`. CM6 is the source of truth for the doc;
        /// `lastSentText` is updated on every JS `change`/`incrementalChange`
        /// (echo-suppression) AND on every Swift→JS `setText`, so it tracks the
        /// live document. Used by `dismantleNSView` to record the parked text so a
        /// later re-attach can verify the model's text still matches (the
        /// live-state safety guard). nil before the first text settles ⇒ treated
        /// as empty, so a never-loaded editor can still be parked/retrieved.
        var currentText: String { lastSentText ?? "" }

        /// Perf P1-followup (TSK-1047): adopt the navigation/CM6-sync state from a
        /// PARKED coordinator onto this (fresh, SwiftUI-owned) one when a warm
        /// editor WebView is re-attached. Copies the `lastSent*` mirrors so
        /// `applyPendingState` sees the already-loaded CM6 as fully in-sync — no
        /// redundant `setText` (which would reset the caret/scroll we're trying to
        /// preserve), no theme/font/wrap re-dispatch for unchanged values. Also
        /// carries the readiness + one-shot-applied flags so post-load state pushes
        /// resume immediately and the once-per-mount selection seed doesn't re-fire
        /// against the live document.
        ///
        /// Deliberately NOT copied: the SwiftUI callback closures (`onTextChange`
        /// etc. — the new representable supplies its own via `bind`) and the
        /// per-tick request nonces (gotoLine/insert/select/find/focus — those
        /// resync from the model on the next `applyPendingState`, and resetting
        /// them to the parked values would wrongly suppress a request that arrives
        /// on re-attach).
        func adoptState(from parked: Coordinator) {
            isReady = parked.isReady
            didFinishFirstLoad = parked.didFinishFirstLoad
            didApplyInitialSelection = parked.didApplyInitialSelection
            lastSentText = parked.lastSentText
            lastSentFontSize = parked.lastSentFontSize
            lastSentLanguage = parked.lastSentLanguage
            lastSentDark = parked.lastSentDark
            lastSentPalette = parked.lastSentPalette
            lastSentFontFamily = parked.lastSentFontFamily
            lastSentWrap = parked.lastSentWrap
            lastSentVim = parked.lastSentVim
            lastSentReadOnly = parked.lastSentReadOnly
            lastSentLineNumbers = parked.lastSentLineNumbers
            lastSentIndentation = parked.lastSentIndentation
            lastSentSnippetActive = parked.lastSentSnippetActive
            lastSentShowInvisibles = parked.lastSentShowInvisibles
            lastSentIndentGuides = parked.lastSentIndentGuides
            lastSentFoldingRanges = parked.lastSentFoldingRanges
            lastSentGutterMarkers = parked.lastSentGutterMarkers
            lastSentDiagnostics = parked.lastSentDiagnostics
        }

        #if DEBUG
        /// Test seam (TSK-1047): set/read the live-text mirror + readiness so a
        /// host test can verify `currentText` and `adoptState` without driving a
        /// real CM6 JS round-trip. DEBUG-only — production sets these via the
        /// change/echo path and `applyPendingState`.
        func _test_setLastSentText(_ text: String?) { lastSentText = text }
        func _test_setReady(_ ready: Bool) { isReady = ready }
        var _test_isReady: Bool { isReady }
        var _test_didApplyInitialSelection: Bool {
            get { didApplyInitialSelection }
            set { didApplyInitialSelection = newValue }
        }
        #endif

        func loadHostHTML() {
            guard let webView = webView else { return }
            guard let htmlURL = Bundle.module.url(
                forResource: "codemirror", withExtension: "html"
            ) else {
                Self.log.error("codemirror.html missing from Resources bundle")
                return
            }
            // loadFileURL with a readAccessURL pointing at the parent
            // dir lets the page reference codemirror.css / codemirror.js
            // via relative URLs. The SwiftPM resource bundle flattens
            // subdirectories so all three live side-by-side in
            // Bundle.module.resourceURL.
            let baseDir = htmlURL.deletingLastPathComponent()
            LiveScrollProbe.navLog("load(\(htmlURL.lastPathComponent))")
            webView.loadFileURL(htmlURL, allowingReadAccessTo: baseDir)
        }

        /// Push every dirty piece of state into JS. Called on every
        /// `updateNSView` and once after `ready`. Each setter checks
        /// against `lastSent*` so over-calling is cheap.
        func applyPendingState() {
            guard isReady, let webView = webView else { return }
            // TSK-602: ship the SyntaxTheme palette so the editor colors
            // match the ViewOnly source view exactly. TSK-641 (editor
            // surface): a user-SELECTED theme's palette wins; nil falls
            // back to the appearance-keyed legacy pair. A palette change
            // alone (theme switch under the same appearance) must
            // re-dispatch, so the dedupe compares BOTH channels.
            if let dark = pendingDark {
                let wire = CMEditorThemeWire.payload(
                    dark: dark, themePalette: pendingThemePalette)
                if dark != lastSentDark || wire.palette != lastSentPalette {
                    lastSentDark = dark
                    lastSentPalette = wire.palette
                    dispatch(.setTheme(name: wire.name, palette: wire.palette),
                             webView: webView)
                }
            }
            if let lang = pendingLanguage, lang != lastSentLanguage {
                lastSentLanguage = lang
                dispatch(.setLanguage(jsLanguageName(for: lang)), webView: webView)
            }
            if let size = pendingFontSize, size != lastSentFontSize {
                lastSentFontSize = size
                // TSK-1151: send the EXACT size (Double, no Int rounding → matches
                // the AppKit View at fractional zoom) + the View's line-height
                // multiple (NSTextView default) so CM6 stops hardcoding 1.45. The
                // `px` fix takes effect immediately (the JS host already does
                // `px + "px"`); the JS reading `lineHeight` is the render tail.
                // `name: nil` uses the system monospace metric — the multiple is
                // ~font-independent for monospace; exact per-family is render-tail
                // polish.
                dispatch(
                    .setFontSize(
                        px: Double(size),
                        lineHeight: FontPreference.editorLineHeightMultiple(
                            name: nil, size: size)),
                    webView: webView)
            }
            // TSK-259: double-optional channel — `nil` (outer) = nothing
            // pending; `.some(nil)` = explicit "bundle default" must still
            // dispatch once so clearing the preference takes effect.
            if let family = pendingFontFamily, family != lastSentFontFamily {
                lastSentFontFamily = family
                dispatch(.setFontFamily(family), webView: webView)
            }
            if let wrap = pendingWrap, wrap != lastSentWrap {
                lastSentWrap = wrap
                dispatch(.setWordWrap(wrap), webView: webView)
            }
            if let vim = pendingVim, vim != lastSentVim {
                lastSentVim = vim
                dispatch(.setVimMode(vim), webView: webView)
            }
            if let ro = pendingReadOnly, ro != lastSentReadOnly {
                lastSentReadOnly = ro
                dispatch(.setReadOnly(ro), webView: webView)
            }
            if let ln = pendingLineNumbers, ln != lastSentLineNumbers {
                lastSentLineNumbers = ln
                dispatch(.setLineNumbers(ln), webView: webView)
            }
            if let indent = pendingIndentation, indent != lastSentIndentation {
                lastSentIndentation = indent
                dispatch(
                    .setIndentation(useTabs: indent.useTabs, size: indent.size),
                    webView: webView
                )
            }
            if let text = pendingText, text != lastSentText {
                lastSentText = text
                // Swift→JS text pushes are rare (the editor is the
                // source of truth; Swift normally only echo-suppresses
                // what it just received). When one does happen, we keep
                // the caret where it was (`preserveSelection: true`).
                //
                // NOTE: `resetHistory: false` means the JS side applies
                // the change with `Transaction.addToHistory.of(false)`,
                // so a Swift-driven rewrite is NOT a user-undoable step —
                // but it is also NOT cleared from history, and a prior
                // edit can still be un-done "through" it. Full undo
                // isolation for a true external (file-watcher) rewrite
                // would need `resetHistory: true`; that path isn't wired
                // yet (see UDC-2 buffer-refresh), so we don't claim it.
                dispatch(
                    .setText(text: text,
                             resetHistory: false,
                             preserveSelection: true),
                    webView: webView
                )
            }
            if let req = pendingGotoLine, req != lastAppliedGotoLine {
                lastAppliedGotoLine = req
                dispatch(
                    .gotoLine(line: req.line, column: req.column, select: req.select),
                    webView: webView
                )
            }
            if let req = pendingInsert, req != lastAppliedInsert {
                lastAppliedInsert = req
                dispatch(.insertAtCursor(text: req.text), webView: webView)
            }
            // TSK-705: imperative selection (snippet tab-stop walk). Nonce-
            // gated like insert so re-selecting the same range still fires.
            if let req = pendingSelect, req != lastAppliedSelect {
                lastAppliedSelect = req
                dispatch(
                    .setSelection(anchor: req.anchor, head: req.head, scroll: req.scroll),
                    webView: webView
                )
            }
            // TSK-705: tell the host whether a snippet session is live so its
            // Tab keymap routes to `snippetTab` instead of indenting.
            if lastSentSnippetActive != pendingSnippetActive {
                lastSentSnippetActive = pendingSnippetActive
                dispatch(.setSnippetSessionActive(pendingSnippetActive), webView: webView)
            }
            // TSK-906: refocus the editor after a palette dismiss (the overlay
            // left first responder nowhere). Nonce-gated so stable redraws don't
            // steal focus; initial 0 == 0 is a no-op on mount.
            if pendingFocusRequest != lastAppliedFocusRequest {
                lastAppliedFocusRequest = pendingFocusRequest
                webView.window?.makeFirstResponder(webView)
                dispatch(.focus, webView: webView)
            }
            // Initial selection: applied exactly once after the text
            // is in the editor — using `setSelection` (anchor/head)
            // because gotoLine clobbers any prior column.
            if let seed = pendingInitialSelection,
               !didApplyInitialSelection,
               lastSentText != nil {
                didApplyInitialSelection = true
                dispatch(
                    .setSelection(anchor: seed.anchor, head: seed.head, scroll: seed.scroll),
                    webView: webView
                )
            }
            if let inv = pendingShowInvisibles, inv != lastSentShowInvisibles {
                lastSentShowInvisibles = inv
                dispatch(.setShowInvisibles(inv), webView: webView)
            }
            if let guides = pendingIndentGuides, guides != lastSentIndentGuides {
                lastSentIndentGuides = guides
                dispatch(.setIndentGuides(guides), webView: webView)
            }
            if let folds = pendingFoldingRanges, folds != lastSentFoldingRanges {
                lastSentFoldingRanges = folds
                dispatch(.setFoldingRanges(folds), webView: webView)
            }
            if let markers = pendingGutterMarkers, markers != lastSentGutterMarkers {
                lastSentGutterMarkers = markers
                dispatch(.setGutterMarkers(markers), webView: webView)
            }
            if let diags = pendingDiagnostics, diags != lastSentDiagnostics {
                lastSentDiagnostics = diags
                dispatch(.setDiagnostics(diags), webView: webView)
            }
            // Find query: dispatch on any change to query/case/regex,
            // or any of the next/prev request nonces. We send the
            // setSearchQuery first so the subsequent findNext picks
            // up the new query.
            let curQuery = (pendingFindQuery ?? "", pendingFindCaseSensitive,
                            pendingFindRegex, pendingFindReplacement)
            if curQuery.0 != (lastSentFindQuery?.0 ?? "")
                || curQuery.1 != (lastSentFindQuery?.1 ?? false)
                || curQuery.2 != (lastSentFindQuery?.2 ?? false)
                || curQuery.3 != (lastSentFindQuery?.3 ?? "") {
                lastSentFindQuery = curQuery
                dispatch(
                    .setSearchQuery(
                        query: curQuery.0,
                        caseSensitive: curQuery.1,
                        regex: curQuery.2,
                        replace: curQuery.3
                    ),
                    webView: webView
                )
            }
            if pendingFindNextRequest != lastSentFindNextRequest {
                lastSentFindNextRequest = pendingFindNextRequest
                if !(pendingFindQuery ?? "").isEmpty {
                    dispatch(.findNext, webView: webView)
                }
            }
            if pendingFindPrevRequest != lastSentFindPrevRequest {
                lastSentFindPrevRequest = pendingFindPrevRequest
                if !(pendingFindQuery ?? "").isEmpty {
                    dispatch(.findPrev, webView: webView)
                }
            }
            // Replace commands. CM's `replaceNext` / `replaceAll` read the
            // active SearchQuery's `replace` field (kept current by the
            // setSearchQuery dispatch above), so we only need to fire the
            // command on a request-nonce bump.
            if pendingReplaceNextRequest != lastSentReplaceNextRequest {
                lastSentReplaceNextRequest = pendingReplaceNextRequest
                if !(pendingFindQuery ?? "").isEmpty {
                    dispatch(.replaceNext, webView: webView)
                }
            }
            if pendingReplaceAllRequest != lastSentReplaceAllRequest {
                lastSentReplaceAllRequest = pendingReplaceAllRequest
                if !(pendingFindQuery ?? "").isEmpty {
                    dispatch(.replaceAll, webView: webView)
                }
            }
        }

        /// Public entry for one-shot Swift→JS calls (e.g. menu actions).
        /// Routes through the v1 envelope.
        public func send(_ message: CMOutboundMessage) {
            guard let webView = webView else { return }
            dispatch(message, webView: webView)
        }

        // MARK: - JS bridge

        /// Encode one CMOutboundMessage as `window.cmDispatch({...JSON})`
        /// and ship via `evaluateJavaScript`. One IPC per message — the
        /// design doc allows batching here (§15.1) but the PoC stays
        /// per-message for clarity.
        private func dispatch(_ message: CMOutboundMessage, webView: WKWebView) {
            let json = CMBridgeCodec.encodeOutboundJSON(message)
            let script = "window.cmDispatch(\(json));"
            webView.evaluateJavaScript(script) { _, err in
                if let err = err {
                    Self.log.error("CM JS eval failed: \(err.localizedDescription)")
                }
            }
        }

        // MARK: - WKScriptMessageHandler

        public func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let inbound = CMBridgeCodec.decodeInbound(message.body) else {
                Self.log.debug("CM bridge ignored unparseable body")
                return
            }
            switch inbound {
            case .ready:
                isReady = true
                applyPendingState()
            case .change(let text, _, _):
                lastSentText = text  // echo-suppress: JS already has this
                onTextChange?(text)
            case .incrementalChange(let edits, _, let contentLength):
                // v2: apply edits to our mirror of the doc, then forward
                // as a normal text-change. This keeps the Swift-side
                // `EditorBuffer` semantics identical (`onTextChange`
                // still receives a full String), while saving the JS →
                // Swift IPC the cost of marshalling the entire doc on
                // every keystroke debounce window. The full-text fall-
                // back protects against drift if JS and Swift ever
                // disagree on doc length.
                let base = lastSentText ?? ""
                // Routed through the `.cmEdit` gate (TSK-649 A0 — the last
                // unconsumed adapter): Rust reducer when on, Swift
                // CMEditApplier otherwise; both signal "resync" as nil.
                if let applied = RustCMEditAdapter.apply(edits, to: base),
                   contentLength < 0 || applied.utf16.count == contentLength {
                    lastSentText = applied
                    onTextChange?(applied)
                } else {
                    // Drift: ask JS to ship a full text. We do this by
                    // explicitly requesting a full change emit; the
                    // editor's `flushChanges` will produce a v1
                    // `change` envelope with the canonical text.
                    Self.log.debug("CM incrementalChange drift; requesting full text")
                    if let webView = webView {
                        dispatch(.flushChanges, webView: webView)
                    }
                }
            case .save:
                onSaveRequested?()
            case .cursorPositionChanged(let line, let column, let head, let ranges):
                onCursorChange?(CMCursorPosition(
                    line: line, column: column, head: head, rangeCount: ranges
                ))
            case .scrollChanged(let top, let left, let from, let to):
                onScrollChange?(CMScrollPosition(
                    top: top, left: left,
                    viewportFromLine: from, viewportToLine: to
                ))
            case .findResultChanged(let matches, let current):
                onFindResultChange?(CMFindResult(matches: matches, current: current))
            case .selectionChanged, .findOpened, .findClosed,
                 .linkClicked, .requestReply:
                // Phase 1: accepted by the protocol but no Swift-side
                // consumer wired yet. Phase 2/3 hookup.
                break
            case .editorBlurred:
                onBlur?()
            case .snippetTab(let forward):
                // TSK-705: Tab / Shift-Tab inside a live snippet session.
                onSnippetTab?(forward)
            case .vimModeChanged(let mode):
                onVimModeChange?(mode)
            case .requestHover(_, let line, let character, let replyId):
                if let handler = onHoverRequest {
                    handler(CMHoverRequest(line: line, character: character, replyId: replyId))
                } else if let webView = webView {
                    // No handler wired — reply with empty so the JS-side
                    // hover promise resolves instead of timing out.
                    dispatch(.hoverResponse(replyId: replyId, contents: "", from: 0, to: 0),
                             webView: webView)
                }
            case .requestDefinition(_, let line, let character):
                onDefinitionRequest?(CMPositionRequest(line: line, character: character))
            case .contextMenuRequested(_, let line, let character,
                                       let sx, let sy, let sel, let hasSel):
                onContextMenuRequest?(CMContextMenuRequest(
                    line: line, character: character,
                    screenPoint: NSPoint(x: sx, y: sy),
                    selection: sel, hasSelection: hasSel
                ))
            case .errorOccurred(let phase, let message, _):
                Self.log.error("CM JS error in \(phase, privacy: .public): \(message, privacy: .public)")
            case .unknown(let type):
                Self.log.debug("CM bridge: unknown message type \(type, privacy: .public)")
            case .unsupportedVersion(let v):
                // The JS bundle posted an envelope newer than this
                // binary understands — the user is running an app build
                // older than the vendored Resources/codemirror/ payload
                // (or a dev hot-reload skew). Log actionably; drop the
                // message (we can't trust its field layout).
                Self.log.error(
                    "CM bridge: peer protocol v\(v, privacy: .public) > supported v\(CMProtocol.currentVersion, privacy: .public); update the app"
                )
            }
        }

        // MARK: - WKNavigationDelegate

        public func webView(
            _ webView: WKWebView,
            didFinish navigation: WKNavigation!
        ) {
            // From here on the host page is up. Any further top-level
            // `.other` navigation to file:/data: is an in-page script
            // escape, not the bootstrap load — see
            // `decide(..., didFinishFirstLoad:)`.
            LiveScrollProbe.navLog("finish")
            didFinishFirstLoad = true
        }

        // TSK-1047 diag delegates: capture the CM6 nav lifecycle so a loadFileURL
        // that never commits under the VM GUI lane is no longer silent.
        public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            LiveScrollProbe.navLog("start")
        }
        public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            LiveScrollProbe.navLog("commit")
        }
        public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            LiveScrollProbe.navLog("failProv:\((error as NSError).domain)#\((error as NSError).code)")
        }
        public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            LiveScrollProbe.navLog("fail:\((error as NSError).domain)#\((error as NSError).code)")
        }
        public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            // TSK-1047: the CM6 WebContent process died (observed under the VM GUI
            // lane right after the heavy bundle loads + initializes). Production
            // hardening — re-bootstrap the host page so the editor is never left
            // permanently blank after a WebContent crash, resetting the gates the
            // first load set (else decidePolicyFor would cancel the re-bootstrap
            // file: nav). Capped so a deterministic crash can't loop forever.
            wcTerminateCount += 1
            LiveScrollProbe.navLog("WC-TERMINATED#\(wcTerminateCount)")
            guard wcTerminateCount <= 3 else { return }
            isReady = false
            didFinishFirstLoad = false
            loadHostHTML()
        }

        public func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            let decision = Coordinator.decide(
                url: navigationAction.request.url,
                navigationType: navigationAction.navigationType,
                currentDocumentURL: webView.url,
                didFinishFirstLoad: didFinishFirstLoad
            )
            LiveScrollProbe.navLog("policy[\(navigationAction.navigationType.rawValue)]:\(navigationAction.request.url?.lastPathComponent ?? "nil")=\(decision)")
            switch decision {
            case .allow:
                decisionHandler(.allow)
            case .cancel:
                decisionHandler(.cancel)
            }
        }

        /// Decide what to do with an editor navigation. Pure function so it
        /// can be unit-tested without a live `WKWebView` (mirrors
        /// `MarkdownRenderedView.Coordinator.decide`). The editor is NOT a
        /// browser: the only navigation it ever legitimately performs is the
        /// one-shot `loadFileURL` of the bundled `codemirror.html` plus that
        /// page's relative `file:` subresources (`codemirror.css` /
        /// `codemirror.js`), all of which arrive as `.other` BEFORE the page
        /// reports `didFinish`. Policy:
        ///
        /// - `javascript:` / `vbscript:` are **cancelled for ANY navigation
        ///   type** — blocks `window.location = 'javascript:…'` style escapes
        ///   regardless of how they surface.
        /// - `data:` is **cancelled for ANY navigation type** — the editor
        ///   never loads `data:` (it bootstraps via `loadFileURL`, not
        ///   `loadHTMLString`), so any `data:` navigation is an injection
        ///   attempt.
        /// - Same-document `#fragment` navigation is allowed (in-page anchors
        ///   inside the host HTML).
        /// - `file:` is allowed ONLY during the bootstrap window
        ///   (`didFinishFirstLoad == false`). Once the first load completes,
        ///   a top-level `.other` to `file:` can only be in-page script
        ///   (`window.location = 'file:///etc/passwd'`) — cancel it.
        /// - Every other navigation (user-clicked links, any non-bootstrap
        ///   scheme) is cancelled: clicking a link inside the editor must not
        ///   navigate the WebView away from the host HTML.
        ///
        /// - Parameter didFinishFirstLoad: `false` until the bundled host
        ///   page has reported `didFinish`. Defaults to `false` so the
        ///   bootstrap `loadFileURL` + its subresources render; a `true`
        ///   value locks the editor down to same-document fragments only.
        public static func decide(
            url: URL?,
            navigationType: WKNavigationType,
            currentDocumentURL: URL?,
            didFinishFirstLoad: Bool = false
        ) -> LinkDecision {
            let scheme = url?.scheme?.lowercased() ?? ""
            // Defense-in-depth: dangerous schemes blocked for ANY nav type.
            // `data:` is unconditionally blocked here (unlike the markdown
            // renderer) because the editor bootstraps via `loadFileURL`, so
            // it never has a legitimate `data:` load to whitelist.
            if ["javascript", "vbscript", "data"].contains(scheme) {
                return .cancel
            }
            // Same-document #fragment navigation (in-page anchor) is safe.
            if let url, URLFragmentPolicy.isSameDocument(url, as: currentDocumentURL) {
                return .allow
            }
            // The bootstrap `loadFileURL` (and its relative file: subresources)
            // surface as `.other` BEFORE first load completes — allow them.
            // After first load, no top-level file: navigation is legitimate.
            if navigationType == .other, !didFinishFirstLoad, scheme == "file" {
                return .allow
            }
            // Anything else — user-clicked links, post-bootstrap file:, any
            // other scheme — is cancelled. The editor is not a browser.
            return .cancel
        }

    }

    /// Resolution of an editor navigation decision. Pure value so the
    /// `Coordinator.decide(...)` policy can be unit-tested without a live
    /// `WKWebView`. The editor never opens links externally (it is not a
    /// browser), so unlike `MarkdownRenderedView.LinkDecision` there is no
    /// `.openExternally` case — every off-host navigation is cancelled.
    public enum LinkDecision: Equatable, Sendable {
        case allow
        case cancel
    }
}

// MARK: - Public value types for the v1 bridge surface

/// Per-tab cursor position emitted by `cursorPositionChanged`. Lines
/// are 1-based (matches CM6's `doc.line(n)`), columns are 0-based
/// (matches CM6's `head - line.from`). `rangeCount` is the number of
/// concurrent cursors / selections (always ≥ 1).
public struct CMCursorPosition: Equatable, Sendable {
    public let line: Int
    public let column: Int
    public let head: Int
    public let rangeCount: Int
    public init(line: Int, column: Int, head: Int, rangeCount: Int) {
        self.line = line; self.column = column
        self.head = head; self.rangeCount = rangeCount
    }
}

/// Per-tab scroll position emitted by `scrollChanged`. Pixel values
/// are dependent on font + zoom; the viewport line range is what we
/// actually persist (resilient to wrap toggle).
public struct CMScrollPosition: Equatable, Sendable {
    public let top: Int
    public let left: Int
    public let viewportFromLine: Int
    public let viewportToLine: Int
    public init(top: Int, left: Int, viewportFromLine: Int, viewportToLine: Int) {
        self.top = top; self.left = left
        self.viewportFromLine = viewportFromLine
        self.viewportToLine = viewportToLine
    }
}

/// Find-bar readout. `matches` total, `current` is 1-based index of
/// the highlighted match (0 when nothing matched).
public struct CMFindResult: Equatable, Sendable {
    public let matches: Int
    public let current: Int
    public init(matches: Int, current: Int) {
        self.matches = matches; self.current = current
    }
}

/// Indent style — tabs or N spaces. Both halves live in one value
/// because CM6's `indentUnit` + `tabSize` always need to agree.
public enum CMIndentation: Equatable, Hashable, Sendable {
    case tabs(width: Int)
    case spaces(Int)
    public var useTabs: Bool {
        if case .tabs = self { return true } else { return false }
    }
    public var size: Int {
        switch self {
        case .tabs(let w): return max(1, min(16, w))
        case .spaces(let n): return max(1, min(16, n))
        }
    }
}

/// Seed value used by `CodeMirrorEditorView` to restore a caret /
/// selection once the editor first reports `ready` and has the text in.
/// Anchor + head are CM6 doc offsets (UTF-16 code units). `scroll`
/// controls whether the editor centers the head on apply.
public struct CMSelectionSeed: Equatable, Sendable {
    public let anchor: Int
    public let head: Int
    public let scroll: Bool
    public init(anchor: Int, head: Int, scroll: Bool = true) {
        self.anchor = anchor; self.head = head; self.scroll = scroll
    }
}

/// JS posted a hover request. `line` is 1-based, `character` is 0-based
/// (matches LSP wire format). `replyId` opaque — pass it straight back
/// in `CMOutboundMessage.hoverResponse`.
public struct CMHoverRequest: Equatable, Sendable {
    public let line: Int
    public let character: Int
    public let replyId: String
    public init(line: Int, character: Int, replyId: String) {
        self.line = line; self.character = character; self.replyId = replyId
    }
}

/// JS posted a doc-position-only request (currently Cmd-click →
/// definition). Line + character match LSP coords.
public struct CMPositionRequest: Equatable, Sendable {
    public let line: Int
    public let character: Int
    public init(line: Int, character: Int) {
        self.line = line; self.character = character
    }
}

/// JS posted a contextmenu event. `screenPoint` is in WebKit screen
/// coordinates (origin top-left); convert to AppKit (origin bottom-
/// left) before passing to `NSMenu.popUp(positioning:at:in:)`.
public struct CMContextMenuRequest: Equatable, Sendable {
    public let line: Int
    public let character: Int
    public let screenPoint: NSPoint
    public let selection: String
    public let hasSelection: Bool
    public init(
        line: Int, character: Int, screenPoint: NSPoint,
        selection: String, hasSelection: Bool
    ) {
        self.line = line; self.character = character
        self.screenPoint = screenPoint
        self.selection = selection; self.hasSelection = hasSelection
    }
}

/// Imperative "jump to line" request — bumped (typically by replacing
/// the value with a fresh `id`) when the host wants the editor to scroll
/// + place the caret. `id` is just an opaque tag the host uses to make
/// each request distinct from the previous one; equality comparison on
/// the whole struct decides whether to fire.
public struct CMGotoLineRequest: Equatable, Sendable {
    public let id: UUID
    public let line: Int
    public let column: Int?
    public let select: Bool
    public init(id: UUID = UUID(), line: Int, column: Int? = nil, select: Bool = false) {
        self.id = id; self.line = line; self.column = column; self.select = select
    }
}

/// One-shot "insert this text at the caret" request (TSK-299). Same
/// nonce pattern as `CMGotoLineRequest`: the host sets a fresh value
/// (new `id`) to fire; whole-struct equality decides whether to dispatch,
/// so inserting the SAME text twice in a row still fires both times.
public struct CMInsertRequest: Equatable, Sendable {
    public let id: UUID
    public let text: String
    public init(id: UUID = UUID(), text: String) {
        self.id = id; self.text = text
    }
}

/// One-shot "move the caret / select this range" request (TSK-705 snippet
/// tab-stops). Same nonce pattern as `CMInsertRequest`: the host sets a fresh
/// value (new `id`) to fire, so selecting the SAME range twice in a row still
/// fires both times. Unlike `initialSelection` (a once-per-mount seed) this is
/// an imperative push the editor applies on each distinct `id`, via the same
/// `setSelection` bridge command. `anchor`/`head` are CM6 doc offsets (UTF-16);
/// an empty range (`anchor == head`) is a bare caret.
public struct CMSelectRequest: Equatable, Sendable {
    public let id: UUID
    public let anchor: Int
    public let head: Int
    public let scroll: Bool
    public init(id: UUID = UUID(), anchor: Int, head: Int, scroll: Bool = true) {
        self.id = id; self.anchor = anchor; self.head = head; self.scroll = scroll
    }
}

// MARK: - Legacy bridge (kept for backwards-compatibility)

/// **Deprecated** — the original untyped bridge enum, retained so the
/// existing `CodeMirrorBundleTests` pass during Phase 1 rollout. New
/// code should use `CMBridgeCodec.decodeInbound` from ViewerCore.
///
/// The decode here adapts the v1 envelope back into the three legacy
/// action cases the rest of the app understands today.
public enum CodeMirrorBridge {
    public enum Action: Equatable {
        case ready
        case change(text: String)
        case saveRequested
    }

    public static func decode(_ body: Any) -> Action? {
        // Legacy callers — accept both the old flat `{type: "..."}`
        // envelope (no `v` field) and the v1 envelope.
        if let dict = body as? [String: Any],
           dict["v"] == nil,
           let type = dict["type"] as? String {
            switch type {
            case "ready": return .ready
            case "change": return .change(text: dict["text"] as? String ?? "")
            case "saveRequested": return .saveRequested
            default: return nil
            }
        }
        switch CMBridgeCodec.decodeInbound(body) {
        case .ready: return .ready
        case .change(let text, _, _): return .change(text: text)
        case .save: return .saveRequested
        default: return nil
        }
    }
}

/// Test-visible accessors for the vendored CM6 bundle resources.
/// Exposed because `Bundle.module` is per-module and tests in
/// `ViewerUITests` can't see ViewerUI's resource bundle directly.
/// Used by `CodeMirrorBundleTests` to assert the build artifacts
/// still ship in the SwiftPM bundle after each rebuild.
public enum CodeMirrorResources {
    public static var hostHTMLURL: URL? {
        Bundle.module.url(forResource: "codemirror", withExtension: "html")
    }
    public static var jsBundleURL: URL? {
        Bundle.module.url(forResource: "codemirror", withExtension: "js")
    }
    public static var hostCSSURL: URL? {
        Bundle.module.url(forResource: "codemirror", withExtension: "css")
    }
}

/// Tracks the currently-mounted CodeMirror webviews so the AppKit
/// menu (Edit → Undo / Redo) can route ⌘Z / ⇧⌘Z into JS without
/// walking the view hierarchy. The registry holds weak refs to keep
/// dismantle deterministic; `current` returns the topmost webview
/// attached to the key window (the only one the user can interact
/// with at any moment).
@MainActor
public final class CodeMirrorEditorRegistry {
    public static let shared = CodeMirrorEditorRegistry()
    /// Weak box because WKWebViews are owned by SwiftUI / AppKit and
    /// we don't want to keep them alive past dismantle.
    private final class Weak { weak var value: WKWebView?; init(_ v: WKWebView) { value = v } }
    private var entries: [Weak] = []

    public func register(_ webView: WKWebView) {
        prune()
        if entries.contains(where: { $0.value === webView }) { return }
        entries.append(Weak(webView))
    }

    public func unregister(_ webView: WKWebView) {
        entries.removeAll { $0.value === webView || $0.value == nil }
    }

    /// Returns the webview whose window is currently key, if any.
    /// Falls back to the most-recently-registered webview when no
    /// webview lives in the key window — covers menu-driven undo
    /// during the brief moment a sheet steals key.
    public func current() -> WKWebView? {
        prune()
        // `NSApp` is an implicitly-unwrapped global that is nil until an
        // `NSApplication` is created — i.e. in a headless unit-test process.
        // Treat it as an Optional and skip the key-window match when absent
        // (rather than `NSApp.keyWindow`, which traps on the nil unwrap) so a
        // model-layer fold/menu dispatch exercised by a host test is inert here
        // instead of crashing. Deliberately does NOT touch `NSApplication.shared`
        // (which would instantiate the app + open a WindowServer connection in
        // the headless gate).
        let app: NSApplication? = NSApp
        if let key = app?.keyWindow,
           let inKey = entries.lazy.compactMap({ $0.value })
            .first(where: { $0.window === key }) {
            return inKey
        }
        return entries.last?.value
    }

    private func prune() {
        entries.removeAll { $0.value == nil }
    }

    /// TSK-1047: all live registered editor WebViews — the probe iterates these to
    /// find the one with CM6 actually up (`current()` can return a blank/parked one).
    public var liveWebViews: [WKWebView] {
        prune()
        return entries.compactMap { $0.value }
    }
}

/// Map a `HighlightLanguage` to the short token CM6's `setLanguage`
/// recognizes (defined in `codemirror.html`'s `languageFor`). Languages
/// CM6 doesn't have an extension for fall through to plain text — still get
/// editing, undo, search, etc., just no syntax highlighting.
///
/// TSK-1135: expanded from ~6 languages to the full 22 the native engine
/// covers, via the CM6 Lezer + legacy-mode packs bundled into
/// `Resources/codemirror/codemirror.js`. Every non-"plain" token here MUST
/// have a matching `case "<token>":` in `codemirror.html`'s `languageFor`
/// switch — pinned by `CodeMirrorBundleTests.testEveryEmittedLanguageTokenIsHandledByHostHTML`.
/// This must stay in lock-step with `HighlightLanguage.editorHighlightable`
/// (pinned by `testJSLanguageNameAgreesWithEditorHighlightable`).
public func jsLanguageName(for lang: HighlightLanguage) -> String {
    switch lang {
    // Official Lezer packs.
    case .markdown:    return "markdown"
    case .javascript:  return "javascript"
    case .typescript:  return "typescript"
    // `.tsx` reuses the bundled JS pack's JSX+TS mode (the host's
    // `languageFor` handles `case "tsx"` → `javascript({ jsx, typescript })`).
    case .tsx:         return "tsx"
    case .python:      return "python"
    case .json:        return "json"
    case .rust:        return "rust"
    case .java:        return "java"
    // lang-cpp's Lezer grammar parses C as well as C++.
    case .c:           return "c"
    case .cpp:         return "cpp"
    case .sql:         return "sql"
    case .html:        return "html"
    case .css:         return "css"
    case .xml:         return "xml"
    case .go:          return "go"
    // @codemirror/legacy-modes stream parsers (no official Lezer pack).
    case .swift:       return "swift"
    case .kotlin:      return "kotlin"
    case .csharp:      return "csharp"
    case .lua:         return "lua"
    case .shell:       return "shell"
    case .yaml:        return "yaml"
    case .ruby:        return "ruby"
    // No CM6 pack bundled for plain text — basic editing only.
    case .plainText:   return "plain"
    }
}

/// TSK-894 (editor current-line highlight): the interaction state that
/// decides whether the CM6 editor paints its current-line highlight, and on
/// which line. Pure value type, host-testable without a WKWebView — it mirrors
/// the decision made by the custom active-line ViewPlugin in `codemirror.html`
/// so a regression of that JS logic fails on the host gate too.
///
/// The bug this models (two coupled symptoms):
///   (a) while drag-selecting, the current-line highlight must be SUPPRESSED
///       (it flickers / fights the selection otherwise); and
///   (b) after a drag ends, the highlight used to STICK on the last line and
///       stop following the caret — the state machine never transitioned out
///       of the drag/selection state.
///
/// Modeling the visibility explicitly (idle / hovering / dragging /
/// has-non-empty-selection) makes both transitions testable: the highlight is
/// hidden while `dragging` or while a non-empty selection exists, and on
/// drag-end with a collapsed caret it tracks the caret line again.
public struct CMCurrentLineHighlightState: Equatable, Sendable {

    /// What the pointer / selection is doing right now.
    public enum Phase: Equatable, Sendable {
        /// No interaction in flight — the caret is at rest.
        case idle
        /// Pointer is hovering (moving without a button held). Treated the
        /// same as `idle` for the line-highlight decision; kept distinct so
        /// the hover-tracking transition is explicit and testable.
        case hovering
        /// A mouse drag is in progress (button held, selection being swept).
        case dragging
    }

    /// The interaction phase.
    public var phase: Phase
    /// Whether the current selection is non-empty (any range covers ≥1 char,
    /// or there is more than one range — a rectangular / multi-cursor select).
    public var hasNonEmptySelection: Bool
    /// 1-based document line containing the selection head (the caret). Drives
    /// WHICH line is highlighted when the highlight is shown.
    public var caretLine: Int

    public init(phase: Phase = .idle, hasNonEmptySelection: Bool = false, caretLine: Int = 1) {
        self.phase = phase
        self.hasNonEmptySelection = hasNonEmptySelection
        self.caretLine = caretLine
    }

    /// The current-line highlight is shown ONLY when the user is at rest with a
    /// collapsed caret: not mid-drag, and no non-empty selection. This is the
    /// single source of truth both (a) suppress-during-drag and
    /// (b) clear-the-stuck-decoration are derived from.
    public var shouldShowCurrentLineHighlight: Bool {
        if phase == .dragging { return false }
        if hasNonEmptySelection { return false }
        return true
    }

    /// The line to highlight, or `nil` when nothing should be highlighted.
    /// Callers use `nil` to CLEAR the (possibly stuck) decoration so hover
    /// resumes tracking after a drag/selection collapses.
    public var highlightedLine: Int? {
        shouldShowCurrentLineHighlight ? caretLine : nil
    }

    // MARK: - Transitions (pure)

    /// Pointer pressed down to begin a drag-select. Enters `dragging`; the
    /// highlight is suppressed until the drag ends.
    public func beginningDrag() -> CMCurrentLineHighlightState {
        var next = self
        next.phase = .dragging
        return next
    }

    /// Drag released. Leaves `dragging`. If the resulting selection collapsed
    /// to a caret on `caretLine`, the highlight resumes there; if a non-empty
    /// selection remains it stays suppressed. This is the transition that fixes
    /// the "stuck on the last line" symptom — `dragging` is always exited.
    public func endingDrag(hasNonEmptySelection: Bool, caretLine: Int) -> CMCurrentLineHighlightState {
        CMCurrentLineHighlightState(
            phase: hasNonEmptySelection ? .idle : .hovering,
            hasNonEmptySelection: hasNonEmptySelection,
            caretLine: caretLine
        )
    }

    /// Selection changed without a drag (keyboard move, programmatic set,
    /// click). Stays out of `dragging`; refreshes the caret line + selection
    /// emptiness so the highlight follows the caret.
    public func selectionChanged(hasNonEmptySelection: Bool, caretLine: Int) -> CMCurrentLineHighlightState {
        var next = self
        // A non-drag selection change can never be `dragging` — a programmatic
        // or keyboard change is not a pointer sweep.
        if next.phase == .dragging { next.phase = .idle }
        next.hasNonEmptySelection = hasNonEmptySelection
        next.caretLine = caretLine
        return next
    }
}

/// TSK-890 (editor drag-select perf): the gate that decides whether the
/// expensive selection-match highlight scan should run for a given editor
/// update. Pure value type, host-testable without a WKWebView — it mirrors the
/// drag-gating logic the selection-match wrapper applies in `codemirror.html`.
///
/// THE PERF BUG it models: CM6's stock `highlightSelectionMatches` ViewPlugin
/// recomputes its decorations on EVERY `selectionSet` transaction. A mouse
/// drag-select fires one such transaction per mousemove, so the plugin runs a
/// viewport-wide occurrence scan (RegExpCursor over every visible line) on each
/// frame of the drag — unthrottled, on the WebView main thread, which is what
/// makes a drag feel sluggish on a large/wide document.
///
/// THE FIX (same drag-gating principle as TSK-894's active-line highlight):
/// suppress the selection-match scan while a drag is in flight, and recompute
/// exactly once when the drag ends. The match decorations are visually
/// irrelevant DURING the sweep anyway (the selection itself is what the user is
/// watching), so skipping the scan is invisible — it just removes the per-frame
/// cost. On drag-end the scan runs once against the final selection.
///
/// `shouldRunSelectionMatchScan` is the single source of truth: the scan runs
/// when NOT dragging. The transitions (`beginningDrag` / `endingDrag`) flip the
/// flag so a host test pins the behaviour even though the pixel/perf effect is
/// WebView-only.
public struct CMSelectionMatchHighlightGate: Equatable, Sendable {

    /// Whether a pointer drag-select is currently sweeping. While true, the
    /// selection-match viewport scan is suppressed.
    public var isDragging: Bool

    public init(isDragging: Bool = false) {
        self.isDragging = isDragging
    }

    /// The selection-match occurrence scan runs ONLY when no drag is in flight.
    /// During a drag the per-mousemove scan is the perf cost we are removing;
    /// the prior decoration set simply stays put until the drag ends.
    public var shouldRunSelectionMatchScan: Bool {
        !isDragging
    }

    // MARK: - Transitions (pure)

    /// Pointer pressed down — a drag-select may begin. Enters the suppressed
    /// state so the next mousemove-driven `selectionSet` updates don't re-scan.
    public func beginningDrag() -> CMSelectionMatchHighlightGate {
        CMSelectionMatchHighlightGate(isDragging: true)
    }

    /// Drag released (anywhere — a document-level mouseup ends it even off the
    /// editor). Leaves the suppressed state so the scan recomputes once against
    /// the final selection.
    public func endingDrag() -> CMSelectionMatchHighlightGate {
        CMSelectionMatchHighlightGate(isDragging: false)
    }
}

/// TSK-641 (editor surface): resolve what `setTheme` should carry for the
/// current appearance + selected theme. Pure — host-testable without a
/// WKWebView. A selected theme's palette wins; nil reproduces the TSK-602
/// appearance-keyed legacy pair byte-for-byte.
enum CMEditorThemeWire {
    static func payload(
        dark: Bool, themePalette: [String: String]?
    ) -> (name: String, palette: [String: String]) {
        let palette = themePalette
            ?? SyntaxTheme.named(dark ? .xcodeDark : .xcodeLight).cmPalette
        return (dark ? "dark" : "light", palette)
    }
}
