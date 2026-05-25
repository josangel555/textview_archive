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
    public let wordWrap: Bool
    public let readOnly: Bool
    public let lineNumbers: Bool
    public let indentation: CMIndentation
    /// Bumping this value any time you want the editor to imperatively
    /// jump to a particular (1-based) line. Pass `nil` (default) to do
    /// nothing. Compare-by-equality means stable tab redraws don't
    /// re-trigger the jump.
    public let gotoLineRequest: CMGotoLineRequest?
    /// "External rewrite" mode for the next `text` push — true means
    /// "don't make this undoable" (file-watcher rewrites). Defaults
    /// to false (user-typed setText keeps history). Per-bump semantics:
    /// the flag only takes effect when `text` itself changes.
    public let externalRewrite: Bool
    public let showInvisibles: Bool
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
    /// Initial caret position to seed on first mount (restore-on-tab-
    /// switch). nil = leave at start. Bumped via `setSelection` so
    /// gotoLine and selection-restore use the same path.
    public let initialSelection: CMSelectionSeed?
    public let onTextChange: (String) -> Void
    public let onSaveRequested: () -> Void
    public let onCursorChange: ((CMCursorPosition) -> Void)?
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

    public init(
        text: String,
        fontSize: CGFloat = 13,
        language: HighlightLanguage = .markdown,
        isDarkTheme: Bool = false,
        wordWrap: Bool = true,
        readOnly: Bool = false,
        lineNumbers: Bool = true,
        indentation: CMIndentation = .spaces(2),
        gotoLineRequest: CMGotoLineRequest? = nil,
        externalRewrite: Bool = false,
        showInvisibles: Bool = false,
        indentGuides: Bool = false,
        foldingRanges: [CMFoldRange] = [],
        gutterMarkers: [CMGutterMarker] = [],
        diagnostics: [CMDiagnostic] = [],
        findQuery: String = "",
        findCaseSensitive: Bool = false,
        findRegex: Bool = false,
        findNextRequest: Int = 0,
        findPrevRequest: Int = 0,
        initialSelection: CMSelectionSeed? = nil,
        onTextChange: @escaping (String) -> Void,
        onSaveRequested: @escaping () -> Void = {},
        onCursorChange: ((CMCursorPosition) -> Void)? = nil,
        onScrollChange: ((CMScrollPosition) -> Void)? = nil,
        onFindResultChange: ((CMFindResult) -> Void)? = nil,
        onHoverRequest: ((CMHoverRequest) -> Void)? = nil,
        onDefinitionRequest: ((CMPositionRequest) -> Void)? = nil,
        onContextMenuRequest: ((CMContextMenuRequest) -> Void)? = nil,
        onBlur: (() -> Void)? = nil
    ) {
        self.text = text
        self.fontSize = fontSize
        self.language = language
        self.isDarkTheme = isDarkTheme
        self.wordWrap = wordWrap
        self.readOnly = readOnly
        self.lineNumbers = lineNumbers
        self.indentation = indentation
        self.gotoLineRequest = gotoLineRequest
        self.externalRewrite = externalRewrite
        self.showInvisibles = showInvisibles
        self.indentGuides = indentGuides
        self.foldingRanges = foldingRanges
        self.gutterMarkers = gutterMarkers
        self.diagnostics = diagnostics
        self.findQuery = findQuery
        self.findCaseSensitive = findCaseSensitive
        self.findRegex = findRegex
        self.findNextRequest = findNextRequest
        self.findPrevRequest = findPrevRequest
        self.initialSelection = initialSelection
        self.onTextChange = onTextChange
        self.onSaveRequested = onSaveRequested
        self.onCursorChange = onCursorChange
        self.onScrollChange = onScrollChange
        self.onFindResultChange = onFindResultChange
        self.onHoverRequest = onHoverRequest
        self.onDefinitionRequest = onDefinitionRequest
        self.onContextMenuRequest = onContextMenuRequest
        self.onBlur = onBlur
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeNSView(context: Context) -> WKWebView {
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
        return webView
    }

    public func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.bind(view: self)
        context.coordinator.applyPendingState()
    }

    public static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        // Detach the message handler so the coordinator (and its
        // owned WKWebView) can deinit. Without this, WKUserContentController
        // keeps a strong reference and we leak the editor for the
        // process lifetime.
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "mdvEditor")
        CodeMirrorEditorRegistry.shared.unregister(webView)
        coordinator.webView = nil
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
        var onTextChange: ((String) -> Void)?
        var onSaveRequested: (() -> Void)?
        var onCursorChange: ((CMCursorPosition) -> Void)?
        var onScrollChange: ((CMScrollPosition) -> Void)?
        var onFindResultChange: ((CMFindResult) -> Void)?
        var onHoverRequest: ((CMHoverRequest) -> Void)?
        var onDefinitionRequest: ((CMPositionRequest) -> Void)?
        var onContextMenuRequest: ((CMContextMenuRequest) -> Void)?
        var onBlur: (() -> Void)?

        /// Pending state we attempt to flush every `updateNSView`.
        /// Before the bundled HTML finishes loading, all
        /// evaluateJavaScript calls silently no-op (no JS context yet),
        /// so we cache the desired state and apply it once the JS posts
        /// `{type: "ready"}`.
        private var pendingText: String?
        private var pendingFontSize: CGFloat?
        private var pendingLanguage: HighlightLanguage?
        private var pendingDark: Bool?
        private var pendingWrap: Bool?
        private var pendingReadOnly: Bool?
        private var pendingLineNumbers: Bool?
        private var pendingIndentation: CMIndentation?
        private var pendingGotoLine: CMGotoLineRequest?
        private var pendingExternalRewrite: Bool = false
        private var pendingShowInvisibles: Bool?
        private var pendingIndentGuides: Bool?
        private var pendingFoldingRanges: [CMFoldRange]?
        private var pendingGutterMarkers: [CMGutterMarker]?
        private var pendingDiagnostics: [CMDiagnostic]?
        private var pendingFindQuery: String?
        private var pendingFindCaseSensitive: Bool = false
        private var pendingFindRegex: Bool = false
        private var pendingFindNextRequest: Int = 0
        private var pendingFindPrevRequest: Int = 0
        private var pendingInitialSelection: CMSelectionSeed?
        private var didApplyInitialSelection: Bool = false
        private var isReady = false
        /// Mirrors what we last successfully pushed to JS. Lets us
        /// skip redundant `setText` round-trips when the model just
        /// republished the same string after a JS → Swift → JS hop.
        private var lastSentText: String?
        private var lastSentFontSize: CGFloat?
        private var lastSentLanguage: HighlightLanguage?
        private var lastSentDark: Bool?
        private var lastSentWrap: Bool?
        private var lastSentReadOnly: Bool?
        private var lastSentLineNumbers: Bool?
        private var lastSentIndentation: CMIndentation?
        private var lastAppliedGotoLine: CMGotoLineRequest?
        private var lastSentShowInvisibles: Bool?
        private var lastSentIndentGuides: Bool?
        private var lastSentFoldingRanges: [CMFoldRange]?
        private var lastSentGutterMarkers: [CMGutterMarker]?
        private var lastSentDiagnostics: [CMDiagnostic]?
        /// (query, case, regex) tuple last shipped — comparing skips
        /// the bridge call when the user clears + re-shows the same
        /// query.
        private var lastSentFindQuery: (String, Bool, Bool)?
        private var lastSentFindNextRequest: Int = 0
        private var lastSentFindPrevRequest: Int = 0

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
            self.onScrollChange = view.onScrollChange
            self.onFindResultChange = view.onFindResultChange
            self.onHoverRequest = view.onHoverRequest
            self.onDefinitionRequest = view.onDefinitionRequest
            self.onContextMenuRequest = view.onContextMenuRequest
            self.onBlur = view.onBlur
            self.pendingText = view.text
            self.pendingFontSize = view.fontSize
            self.pendingLanguage = view.language
            self.pendingDark = view.isDarkTheme
            self.pendingWrap = view.wordWrap
            self.pendingReadOnly = view.readOnly
            self.pendingLineNumbers = view.lineNumbers
            self.pendingIndentation = view.indentation
            self.pendingGotoLine = view.gotoLineRequest
            self.pendingExternalRewrite = view.externalRewrite
            self.pendingShowInvisibles = view.showInvisibles
            self.pendingIndentGuides = view.indentGuides
            self.pendingFoldingRanges = view.foldingRanges
            self.pendingGutterMarkers = view.gutterMarkers
            self.pendingDiagnostics = view.diagnostics
            self.pendingFindQuery = view.findQuery
            self.pendingFindCaseSensitive = view.findCaseSensitive
            self.pendingFindRegex = view.findRegex
            self.pendingFindNextRequest = view.findNextRequest
            self.pendingFindPrevRequest = view.findPrevRequest
            self.pendingInitialSelection = view.initialSelection
        }

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
            webView.loadFileURL(htmlURL, allowingReadAccessTo: baseDir)
        }

        /// Push every dirty piece of state into JS. Called on every
        /// `updateNSView` and once after `ready`. Each setter checks
        /// against `lastSent*` so over-calling is cheap.
        func applyPendingState() {
            guard isReady, let webView = webView else { return }
            if let dark = pendingDark, dark != lastSentDark {
                lastSentDark = dark
                dispatch(.setTheme(name: dark ? "dark" : "light"), webView: webView)
            }
            if let lang = pendingLanguage, lang != lastSentLanguage {
                lastSentLanguage = lang
                dispatch(.setLanguage(jsLanguageName(for: lang)), webView: webView)
            }
            if let size = pendingFontSize, size != lastSentFontSize {
                lastSentFontSize = size
                dispatch(.setFontSize(Int(size.rounded())), webView: webView)
            }
            if let wrap = pendingWrap, wrap != lastSentWrap {
                lastSentWrap = wrap
                dispatch(.setWordWrap(wrap), webView: webView)
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
                // External rewrites = file-watcher reload: don't pollute
                // the user's undo stack. User-typed setText (rare) gets
                // dispatch with history skipped too but Swift never
                // pushes back what it just received (echo-suppressed
                // above when text == lastEmitted).
                dispatch(
                    .setText(text: text,
                             resetHistory: false,
                             preserveSelection: !pendingExternalRewrite),
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
            let curQuery = (pendingFindQuery ?? "", pendingFindCaseSensitive, pendingFindRegex)
            if curQuery.0 != (lastSentFindQuery?.0 ?? "")
                || curQuery.1 != (lastSentFindQuery?.1 ?? false)
                || curQuery.2 != (lastSentFindQuery?.2 ?? false) {
                lastSentFindQuery = curQuery
                dispatch(
                    .setSearchQuery(
                        query: curQuery.0,
                        caseSensitive: curQuery.1,
                        regex: curQuery.2
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
                if let applied = CMEditApplier.apply(edits, to: base),
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
            }
        }

        // MARK: - WKNavigationDelegate

        public func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            // Only allow the initial file:// load of the bundle.
            // Reject everything else (link clicks inside the editor
            // would try to navigate the WebView away from the host
            // HTML).
            if navigationAction.navigationType == .other {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        }
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
        let key = NSApp.keyWindow
        if let inKey = entries.lazy.compactMap({ $0.value })
            .first(where: { $0.window === key }) {
            return inKey
        }
        return entries.last?.value
    }

    private func prune() {
        entries.removeAll { $0.value == nil }
    }
}

/// Map a `HighlightLanguage` to the short token CM6's `setLanguage`
/// recognizes (defined in `codemirror.html`). Languages CM6 doesn't
/// have an extension for fall through to plain text — still get
/// editing, undo, search, etc., just no syntax highlighting.
public func jsLanguageName(for lang: HighlightLanguage) -> String {
    switch lang {
    case .markdown:    return "markdown"
    case .javascript:  return "javascript"
    case .typescript:  return "typescript"
    case .python:      return "python"
    case .json:        return "json"
    default:           return "plain"
    }
}
