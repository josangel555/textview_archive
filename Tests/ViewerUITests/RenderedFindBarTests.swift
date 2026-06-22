import XCTest
import AppKit
import SwiftUI
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// T2' view-tree tests for the Cmd+F find bar in markdown rendered view
/// (WKWebView).
///
/// We don't simulate the menu keystroke or run WKWebView's find() under
/// test (it requires a real navigation + DOM, and verifying its visible
/// highlight needs a pixel snapshot). What's left here, after the §3.2
/// split, is the part that genuinely needs a realized `NSHostingView`
/// tree: the find-bar overlay's presence/absence in the rendered-mode
/// view tree. These host `ContentView` in rendered mode → mint a live
/// `WKWebView`, so they keep the `#192` `MDV_RUN_WEBVIEW_TESTS` gate +
/// `WebViewTestTeardown` graph-quiesce.
///
/// The three model-state tests (show/dismiss toggle, dismiss-clears-query,
/// next/prev counters) moved to the UNGATED T1m `RenderedFindBarModelTests`
/// — they read `model.*` only and were paying the WebView-gate tax for
/// nothing.
@MainActor
final class RenderedFindBarTests: WebViewTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    /// #192: tracked so tearDown can dismantle embedded WKWebViews.
    private var hostedViews: [NSView] = []

    override func setUp() async throws {
        // #192: process-isolated — skipped in the bare sweep.
        try WebViewTestTeardown.skipUnlessEnabled()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RenderedFindBar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "RenderedFindBar-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        WebViewTestTeardown.teardown(hostedViews)  // #192
        hostedViews.removeAll()
        // tmpDir/defaults are nil when setUp early-skipped (#192 gate).
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
        if let suiteName, let defaults {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    private func makeModel() -> DocumentModel {
        DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmpDir.appendingPathComponent("h.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults)
        )
    }

    private func renderHost<V: View>(_ view: V, size: NSSize = NSSize(width: 1000, height: 700)) -> NSView {
        _ = NSApplication.shared
        let h = NSHostingView(rootView: view)
        h.frame = NSRect(origin: .zero, size: size)
        h.layoutSubtreeIfNeeded()
        hostedViews.append(h)  // #192: track for WebView teardown
        return h
    }

    private func descendants(of view: NSView) -> [NSView] {
        var out: [NSView] = [view]
        for s in view.subviews { out.append(contentsOf: descendants(of: s)) }
        return out
    }

    // MARK: View tree

    func test_findBar_renders_inMarkdownRenderedMode_whenShown() throws {
        // SwiftUI's `.accessibilityIdentifier` doesn't propagate to the
        // realized NSView's `accessibilityIdentifier()` reliably for
        // SwiftUI-native views — it's only exposed via the AX query API.
        // So we compare descendant counts: showing the bar must add
        // subviews (text field, buttons) to the rendered-mode tree.
        let model = makeModel()
        let url = tmpDir.appendingPathComponent("hello.md")
        try "# h\nbody\n".write(to: url, atomically: true, encoding: .utf8)
        model.open(url: url)

        let hiddenHost = renderHost(ContentView(model: model))
        let hiddenCount = descendants(of: hiddenHost).count

        model.showRenderedFindBar()
        let shownHost = renderHost(ContentView(model: model))
        let shownCount = descendants(of: shownHost).count

        XCTAssertGreaterThan(shownCount, hiddenCount + 3,
            "Showing the find bar should add ≥3 subviews to the rendered tree (got hidden=\(hiddenCount), shown=\(shownCount))")
    }

    func test_findBar_notPresent_inSourceMode() throws {
        // In source mode we use NSTextView's native find bar. The
        // SwiftUI MarkdownFindBar overlay should never be added even if
        // `isRenderedFindBarPresented` is true — the overlay only lives
        // inside the markdown rendered branch of ContentView.
        let model = makeModel()
        let url = tmpDir.appendingPathComponent("hello.md")
        try "# h\nbody\n".write(to: url, atomically: true, encoding: .utf8)
        model.open(url: url)
        model.toggleViewMode()  // → source

        let beforeShow = descendants(of: renderHost(ContentView(model: model))).count
        model.showRenderedFindBar()
        let afterShow = descendants(of: renderHost(ContentView(model: model))).count

        XCTAssertEqual(beforeShow, afterShow,
            "Toggling the rendered find bar state must not affect source mode's view tree. before=\(beforeShow), after=\(afterShow)")
    }
}
