import XCTest
import AppKit
import WebKit
@testable import ViewerCore
@testable import ViewerUI

/// TSK-602 — ViewOnly ↔ Editor highlight COLOR PARITY, end to end.
///
/// `SyntaxThemeCMPaletteTests` pins the Swift half (every TokenKind maps
/// to a `#RRGGBB`); `CodeMirrorBundleTests` greps the wiring strings.
/// Neither proves the editor actually PAINTS those hexes. This suite
/// closes that gap: it boots the REAL `codemirror.html` host in a bare
/// `WKWebView`, drives it through the production bridge encoding
/// (`window.cmDispatch(CMBridgeCodec.encodeOutboundJSON(...))` — the
/// exact string `Coordinator.dispatch` ships), then reads back
/// `getComputedStyle(span).color` for sampled token kinds and asserts
/// equality with `SyntaxTheme.cmPalette`'s hex values.
///
/// Token spans are located by TEXT CONTENT, never by class — lezer
/// highlight class names are build-hashed (`ͼ…`).
///
/// #192-gated (`MDV_RUN_WEBVIEW_TESTS=1`) like every in-process
/// live-WKWebView suite; runs in the VM/nightly WebView lane
/// (`scripts/test-in-vm.sh`, `.github/workflows/nightly-vm.yml`).
@MainActor
final class EditorThemeParityTests: XCTestCase {

    /// Captures the host's `ready` post. Non-isolated NSObject because
    /// `WKScriptMessageHandler` is a nonisolated protocol; WebKit calls
    /// it on the main thread, so the hop into MainActor state is safe.
    private final class BridgeRecorder: NSObject, WKScriptMessageHandler {
        var onReady: (@Sendable () -> Void)?
        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            if case .ready? = CMBridgeCodec.decodeInbound(message.body) {
                onReady?()
            }
        }
    }

    private var webView: WKWebView!
    private var recorder: BridgeRecorder!

    override func setUp() async throws {
        try WebViewTestTeardown.skipUnlessEnabled()  // #192
    }

    override func tearDown() async throws {
        if let webView {
            webView.configuration.userContentController
                .removeScriptMessageHandler(forName: "mdvEditor")
            WebViewTestTeardown.teardown([webView])  // #192
        }
        webView = nil
        recorder = nil
    }

    // MARK: - Harness

    /// JS fixture chosen so each sampled TokenKind has an unambiguous
    /// textContent needle: `const` (keyword), `"hi"` (string),
    /// `// note` (comment), `42` (number).
    private static let fixture = "const x = \"hi\"; // note\nconst y = 42;\n"

    /// Boot the production CM6 host exactly the way the Coordinator
    /// does: same handler name, same `loadFileURL` base-dir grant.
    private func makeEditor() async throws {
        let config = WKWebViewConfiguration()
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs
        recorder = BridgeRecorder()
        config.userContentController.add(recorder, name: "mdvEditor")
        webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            configuration: config)

        let htmlURL = try XCTUnwrap(
            CodeMirrorResources.hostHTMLURL,
            "codemirror.html missing from ViewerUI resources")
        let ready = expectation(description: "cm ready")
        ready.assertForOverFulfill = false
        recorder.onReady = { ready.fulfill() }
        webView.loadFileURL(
            htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
        await fulfillment(of: [ready], timeout: 15)
    }

    /// Ship one message through the PRODUCTION encoding — byte-identical
    /// to `Coordinator.dispatch`.
    private func dispatch(_ message: CMOutboundMessage) {
        let json = CMBridgeCodec.encodeOutboundJSON(message)
        webView.evaluateJavaScript("window.cmDispatch(\(json));") { _, err in
            if let err {
                XCTFail("cmDispatch eval failed: \(err.localizedDescription)")
            }
        }
    }

    private func evalString(_ script: String) async throws -> String? {
        let wv: WKWebView = webView
        return try await withCheckedThrowingContinuation { cont in
            wv.evaluateJavaScript(script) { result, error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume(returning: result as? String)
                }
            }
        }
    }

    /// Walk `.cm-content` spans, locate each sampled token by text
    /// content, return its computed color as `#RRGGBB` (uppercase, the
    /// `SyntaxTheme.cssHex` format). `background` reads the editor
    /// root's computed background (the palette's chrome half).
    private static let readbackJS = #"""
    (function () {
      function colorOf(pred) {
        const spans = document.querySelectorAll(".cm-content span");
        for (const s of spans) {
          if (pred(s.textContent || "")) return getComputedStyle(s).color;
        }
        return null;
      }
      function hex(c) {
        if (!c) return null;
        const m = c.match(/rgba?\((\d+)[,\s]+(\d+)[,\s]+(\d+)/);
        if (!m) return c;
        const h = (n) => Number(n).toString(16).padStart(2, "0").toUpperCase();
        return "#" + h(m[1]) + h(m[2]) + h(m[3]);
      }
      const editor = document.querySelector(".cm-editor");
      return JSON.stringify({
        keyword: hex(colorOf((t) => t.trim() === "const")),
        string: hex(colorOf((t) => t.includes("hi"))),
        comment: hex(colorOf((t) => t.includes("note"))),
        number: hex(colorOf((t) => t.trim() === "42")),
        background: editor
          ? hex(getComputedStyle(editor).backgroundColor) : null,
      });
    })()
    """#

    /// Poll until every sampled token has a painted color (highlight
    /// decoration + theme reconfigure are async-ish after dispatch).
    /// Returns the kind→hex map; fails the test on timeout with the
    /// partial map for diagnosis.
    private func readTokenColors(
        timeout: TimeInterval = 10
    ) async throws -> [String: String] {
        let deadline = Date().addingTimeInterval(timeout)
        var last: [String: String] = [:]
        while Date() < deadline {
            if let json = try await evalString(Self.readbackJS),
               let data = json.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data)
                   as? [String: Any] {
                last = obj.compactMapValues { $0 as? String }
                if last.count == 5 { return last }
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("token colors never fully painted; got \(last)")
        return last
    }

    // MARK: - Tests

    /// Light theme: every sampled token kind + the editor background
    /// must paint EXACTLY the SyntaxTheme hex shipped in the palette.
    func test_editorPaintsSyntaxThemePalette_light() async throws {
        try await makeEditor()
        let palette = SyntaxTheme.xcodeLight.cmPalette

        dispatch(.setLanguage("javascript"))
        dispatch(.setText(text: Self.fixture,
                          resetHistory: true, preserveSelection: false))
        dispatch(.setTheme(name: "light", palette: palette))

        let painted = try await readTokenColors()
        for kind in ["keyword", "string", "comment", "number", "background"] {
            XCTAssertEqual(
                painted[kind], palette[kind],
                "editor must paint SyntaxTheme's \(kind) hex exactly "
                + "(ViewOnly↔Editor parity); painted=\(painted)")
        }
    }

    /// Dark theme via RECONFIGURE: set light first, then dark — proves
    /// the theme compartment replaces (not appends) the palette, the
    /// production toggle path when the system appearance flips.
    func test_themeReconfigure_repaintsToDarkPalette() async throws {
        try await makeEditor()
        let light = SyntaxTheme.xcodeLight.cmPalette
        let dark = SyntaxTheme.xcodeDark.cmPalette
        // Sanity: the assertion below must be able to discriminate.
        XCTAssertNotEqual(light["keyword"], dark["keyword"])
        XCTAssertNotEqual(light["background"], dark["background"])

        dispatch(.setLanguage("javascript"))
        dispatch(.setText(text: Self.fixture,
                          resetHistory: true, preserveSelection: false))
        dispatch(.setTheme(name: "light", palette: light))
        _ = try await readTokenColors()

        dispatch(.setTheme(name: "dark", palette: dark))
        let deadline = Date().addingTimeInterval(10)
        var painted: [String: String] = [:]
        while Date() < deadline {
            painted = try await readTokenColors()
            if painted["keyword"] == dark["keyword"] { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        for kind in ["keyword", "string", "comment", "number", "background"] {
            XCTAssertEqual(
                painted[kind], dark[kind],
                "after reconfigure the editor must paint the DARK \(kind) "
                + "hex; painted=\(painted)")
        }
    }
}
