import AppKit
import SwiftUI
import WebKit
import ViewerKit
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
/// - ⌘S inside the webview posts `saveRequested`, which calls
///   `onSaveRequested` (DocumentModel routes that to `saveActiveEditor`).
/// - Menu Undo/Redo route to `webView.evaluateJavaScript("undo()/redo()")`
///   when the active tab is in `.editor` mode — see `MarkdownViewer/main.swift`.
///
/// **Why WKWebView, not NSTextView/TextKit 2:** see
/// `docs/TEXT_EDITOR_OPTIONS_2026-05-23.md`. MIT-licensed, small
/// (<1 MB minified), handles 10 MB markdown comfortably, free find +
/// undo + history + theming.
public struct CodeMirrorEditorView: NSViewRepresentable {
    public let text: String
    public let fontSize: CGFloat
    public let language: HighlightLanguage
    public let isDarkTheme: Bool
    public let onTextChange: (String) -> Void
    public let onSaveRequested: () -> Void

    public init(
        text: String,
        fontSize: CGFloat = 13,
        language: HighlightLanguage = .markdown,
        isDarkTheme: Bool = false,
        onTextChange: @escaping (String) -> Void,
        onSaveRequested: @escaping () -> Void = {}
    ) {
        self.text = text
        self.fontSize = fontSize
        self.language = language
        self.isDarkTheme = isDarkTheme
        self.onTextChange = onTextChange
        self.onSaveRequested = onSaveRequested
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
    /// `onTextChange` / `onSaveRequested` closures, and forwards
    /// Swift-side state (text, theme, font, language) into the JS
    /// editor via `evaluateJavaScript`.
    @MainActor
    public final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var webView: WKWebView?
        /// Captured from `updateNSView`. Held as closures so SwiftUI
        /// can swap them on each body re-eval without losing the latest
        /// reference. Same pattern as `EditorTextController`.
        var onTextChange: ((String) -> Void)?
        var onSaveRequested: (() -> Void)?

        /// Pending state we attempt to flush every `updateNSView`.
        /// Before the bundled HTML finishes loading, all
        /// evaluateJavaScript calls silently no-op (no JS context yet),
        /// so we cache the desired state and apply it once the JS posts
        /// `{type: "ready"}`.
        private var pendingText: String?
        private var pendingFontSize: CGFloat?
        private var pendingLanguage: HighlightLanguage?
        private var pendingDark: Bool?
        private var isReady = false
        /// Mirrors what we last successfully pushed to JS. Lets us
        /// skip redundant `setText` round-trips when the model just
        /// republished the same string after a JS → Swift → JS hop.
        private var lastSentText: String?
        private var lastSentFontSize: CGFloat?
        private var lastSentLanguage: HighlightLanguage?
        private var lastSentDark: Bool?

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
            self.pendingText = view.text
            self.pendingFontSize = view.fontSize
            self.pendingLanguage = view.language
            self.pendingDark = view.isDarkTheme
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
        /// `updateNSView` and once after `ready`. Each setter is a
        /// no-op on the JS side when the value hasn't actually changed,
        /// so over-calling is cheap.
        func applyPendingState() {
            guard isReady, let webView = webView else { return }
            if let dark = pendingDark, dark != lastSentDark {
                lastSentDark = dark
                evalJS("setTheme(\(jsString(dark ? "dark" : "light")))", webView: webView)
            }
            if let lang = pendingLanguage, lang != lastSentLanguage {
                lastSentLanguage = lang
                evalJS("setLanguage(\(jsString(jsLanguageName(for: lang))))", webView: webView)
            }
            if let size = pendingFontSize, size != lastSentFontSize {
                lastSentFontSize = size
                evalJS("setFontSize(\(Int(size.rounded())))", webView: webView)
            }
            if let text = pendingText, text != lastSentText {
                lastSentText = text
                evalJS("setText(\(jsString(text)))", webView: webView)
            }
        }

        // MARK: - JS bridge

        /// JSON-encode a string for safe inline-injection into JS source.
        /// We can't use bare string-interp because text may contain
        /// quotes, newlines, backslashes, or `</script>`. JSONSerialization
        /// emits a JS-legal string literal (with leading/trailing quotes).
        private func jsString(_ s: String) -> String {
            // JSONSerialization needs a top-level array/object, so wrap
            // and unwrap. Cheap enough for the sizes we deal with
            // (single-doc text, max ~10 MB).
            guard let data = try? JSONSerialization.data(
                withJSONObject: [s], options: [.fragmentsAllowed]
            ),
            let raw = String(data: data, encoding: .utf8),
            raw.count >= 2 else {
                return "\"\""
            }
            // Strip the wrapping `[` and `]`.
            return String(raw.dropFirst().dropLast())
        }

        private func evalJS(_ source: String, webView: WKWebView) {
            webView.evaluateJavaScript(source) { _, err in
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
            let action = CodeMirrorBridge.decode(message.body)
            switch action {
            case .ready:
                isReady = true
                applyPendingState()
            case .change(let text):
                lastSentText = text  // echo-suppress: JS already has this
                onTextChange?(text)
            case .saveRequested:
                onSaveRequested?()
            case .none:
                break
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

// MARK: - Pure-logic bridge

/// Decodes the JSON payloads CM6's bootstrap posts to the
/// `mdvEditor` `WKScriptMessageHandler`. Extracted as a value-typed
/// helper so the routing logic is testable without spinning up a
/// `WKWebView`.
public enum CodeMirrorBridge {
    public enum Action: Equatable {
        case ready
        case change(text: String)
        case saveRequested
    }

    /// Decode the `message.body` that arrives from JS. Accepts a
    /// `[String: Any]` dictionary (the shape WKWebKit hands us when
    /// JS calls `postMessage({...})`). Returns nil for anything not
    /// recognized — bridge stays forward-compatible if we add message
    /// types later.
    public static func decode(_ body: Any) -> Action? {
        guard let dict = body as? [String: Any],
              let type = dict["type"] as? String else { return nil }
        switch type {
        case "ready":
            return .ready
        case "change":
            // Missing text is treated as empty document — JS always
            // emits a string but we don't trust the wire format.
            let text = dict["text"] as? String ?? ""
            return .change(text: text)
        case "saveRequested":
            return .saveRequested
        default:
            return nil
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
