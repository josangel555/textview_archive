import XCTest

/// TSK-1534 — the rendering-stack POLICY guard (TSK-1524): WKWebView is for
/// CONTENT surfaces only; app chrome (sidebars, toolbars, palettes, panels,
/// settings) stays native. This tooth makes the boundary greppable and RED
/// when anyone constructs a WKWebView outside the allowlisted content hosts —
/// chrome can never silently move into a webview, and a new content surface
/// must be added HERE (a deliberate, reviewed policy decision) to compile
/// into the suite green.
final class WebViewAllowlistTests: XCTestCase {

    /// The ONLY files allowed to construct a WKWebView. Each is a content
    /// surface (or its dedicated host) under the TSK-1524 policy.
    private static let allowlist: Set<String> = [
        "Sources/ViewerUI/CanvasWebViewHost.swift",        // canvas documents
        "Sources/ViewerUI/CodeMirrorEditorView.swift",     // the CM6 editor
        "Sources/ViewerUI/HTMLRenderedView.swift",         // html documents
        "Sources/ViewerUI/MarkdownRenderedView.swift",     // rendered markdown
        "Sources/ViewerUI/Walkthrough/WalkthroughMermaidWebView.swift", // walkthrough mermaid
    ]

    func test_webViewConstruction_onlyInAllowlistedContentHosts() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources")
        var offenders: [String] = []
        var seen: Set<String> = []

        let e = try XCTUnwrap(FileManager.default.enumerator(
            at: sources, includingPropertiesForKeys: nil))
        for case let url as URL in e where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            guard text.contains("WKWebView(") else { continue }
            let rel = "Sources" + url.path.replacingOccurrences(
                of: sources.path, with: "")
            seen.insert(rel)
            if !Self.allowlist.contains(rel) {
                offenders.append(rel)
            }
        }

        XCTAssertTrue(offenders.isEmpty,
            "WKWebView constructed OUTSIDE the content-surface allowlist "
            + "(TSK-1524 policy: chrome stays native): \(offenders.sorted()). "
            + "If this is a NEW content surface, add it to the allowlist "
            + "deliberately — with its real-render coverage (TSK-1539).")

        // Teeth the other way: a stale allowlist entry (file gone/renamed)
        // rots the guard — keep it exact.
        let stale = Self.allowlist.subtracting(seen)
        XCTAssertTrue(stale.isEmpty,
            "allowlist entries no longer construct a WKWebView (renamed/deleted?): \(stale.sorted())")
    }
}
