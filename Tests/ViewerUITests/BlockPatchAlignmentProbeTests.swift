import WebKit
import XCTest
import AppKit
import SwiftUI
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// TSK-1183 slice-B PRE-FLIGHT — answers the DOM-patch ALIGNMENT crux. The isolated
/// BlockPatchApplyWebViewTests proved `applyBlockPatch` on a CLEAN `<body>`; this
/// proves the LIVE rendered MarkdownRenderedView body (with its real WKUserScripts —
/// find-runtime, mermaid, etc.) isn't polluted by INJECTED non-block children that
/// would shift the index-based patch and corrupt every doc. Green ⇒ slice B can patch
/// `document.body` directly; a non-block child in the sequence ⇒ the rewiring must
/// wrap the rendered blocks in a stable container. It also `print`s the live body's
/// element-child tag sequence so the actual structure is visible in the lane output.
/// `#192`-gated (the VM/nightly WebView lane).
@MainActor
final class BlockPatchAlignmentProbeTests: WebViewTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var hostedViews: [NSView] = []

    override func setUp() async throws {
        try WebViewTestTeardown.skipUnlessEnabled()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlockPatchAlignmentProbe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "BlockPatchAlignmentProbe-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        WebViewTestTeardown.teardown(hostedViews)
        hostedViews.removeAll()
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
        if let suiteName, let defaults { defaults.removePersistentDomain(forName: suiteName) }
    }

    private func makeModel() -> DocumentModel {
        DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmpDir.appendingPathComponent("history.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults))
    }

    private func host<V: View>(_ view: V) -> NSView {
        _ = NSApplication.shared
        let h = NSHostingView(rootView: view)
        h.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        h.layoutSubtreeIfNeeded()
        hostedViews.append(h)
        return h
    }

    private func allDescendants(of view: NSView) -> [NSView] {
        var r: [NSView] = [view]
        for s in view.subviews { r.append(contentsOf: allDescendants(of: s)) }
        return r
    }

    /// ASYNC wait (await Task.sleep, NOT RunLoop.run): the WKWebView mounts only
    /// after the off-main render fills the cache and republishes on the MAIN actor
    /// (TSK-611). A sync RunLoop.run here would BLOCK the main actor inside an async
    /// @MainActor test, so that republish never runs and the WebView never mounts.
    /// Task.sleep yields the main actor so the fill's continuation can land.
    private func waitForWebView(in host: NSView, timeout: TimeInterval = 20) async -> WKWebView? {
        let cls: AnyClass = NSClassFromString("WKWebView")!
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            host.layoutSubtreeIfNeeded()
            if let wv = allDescendants(of: host).first(where: { $0.isKind(of: cls) }) as? WKWebView {
                return wv
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    /// Completion-handler bridged (TSK-1047), retried until the page populates.
    private func evalStr(_ wv: WKWebView, _ js: String, timeout: TimeInterval = 8) async -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let v: String = await withCheckedContinuation { (c: CheckedContinuation<String, Never>) in
                wv.evaluateJavaScript(js) { value, _ in c.resume(returning: (value as? String) ?? "") }
            }
            if !v.isEmpty { return v }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return ""
    }

    func test_renderedBody_elementChildren_haveNoInjectedNonBlockPollution() async throws {
        let md = "# Title\n\nFirst paragraph.\n\nSecond paragraph.\n\n## Section\n\nThird paragraph.\n"
        let url = tmpDir.appendingPathComponent("doc.md")
        try md.write(to: url, atomically: true, encoding: .utf8)
        let model = makeModel()
        model.open(url: url)

        let host = host(ContentView(model: model))
        guard let wv = await waitForWebView(in: host) else {
            throw XCTSkip("no WKWebView mounted (rendered tab didn't realize)")
        }
        let tags = await evalStr(wv, """
        (function () {
          var b = document.body;
          if (!b || b.children.length === 0) return '';
          return Array.from(b.children).map(function (c) { return c.tagName.toLowerCase(); }).join(',');
        })()
        """)
        XCTAssertFalse(tags.isEmpty, "rendered body never populated")
        print("[TSK-1183 ALIGNMENT PROBE] live rendered body element-children: \(tags)")

        // The slice-B index-based patch targets document.body.children, so the body
        // must not contain INJECTED non-block children (script/style/link/meta) that
        // would shift the block indices relative to RenderedBlockDiff.splitBlocks.
        let pollutionTags: Set<String> = ["script", "style", "link", "meta"]
        let childTags = tags.split(separator: ",").map(String.init)
        let pollution = childTags.filter { pollutionTags.contains($0) }
        XCTAssertTrue(pollution.isEmpty,
            "live rendered body has injected non-block children \(pollution) — slice B must wrap blocks in a stable container; full sequence: \(tags)")
        // Sanity: the doc rendered into real blocks (not a spinner / error page).
        XCTAssertGreaterThanOrEqual(childTags.count, 4,
            "expected at least the doc's blocks; got \(childTags.count): \(tags)")
    }
}
