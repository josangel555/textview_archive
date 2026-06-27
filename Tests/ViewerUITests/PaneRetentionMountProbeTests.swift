import XCTest
import AppKit
import SwiftUI
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// Perf Fix#1 (TSK-108) VIEW-LAYER proof: hosts the real `ContentView` (with
/// real WKWebViews) and asserts that an A→B→A tab switch performs ZERO
/// additional WKWebView make/dismantle — i.e. the retained inactive pane is
/// NOT torn down + reloaded (the ~1s freeze this fix removes).
///
/// This complements `MountedPanesWiringTests` (the WKWebView-free model-side
/// retention-set guard on the bare gate). It needs real WebContent processes,
/// so it `#192`-gates itself out of the bare sweep and runs in the
/// `MDV_RUN_WEBVIEW_TESTS` / VM lane:
///   MDV_RUN_WEBVIEW_TESTS=1 swift test --filter PaneRetentionMountProbeTests
@MainActor
final class PaneRetentionMountProbeTests: WebViewTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var hostedViews: [NSView] = []

    override func setUp() async throws {
        try WebViewTestTeardown.skipUnlessEnabled()   // #192
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaneRetentionMountProbe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "PaneRetentionMountProbe-\(UUID().uuidString)"
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
            preferences: PreferencesStore(defaults: defaults)
        )
    }

    @discardableResult
    private func writeFile(_ name: String, _ contents: String) throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func host<V: View>(_ view: V) -> NSHostingView<V> {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        host.layoutSubtreeIfNeeded()
        hostedViews.append(host)
        return host
    }

    /// Pump the runloop so SwiftUI flushes the model republish into a re-body
    /// + NSView reconciliation, then force layout to realize representables.
    private func settle(_ host: NSView) {
        for _ in 0..<3 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
        }
    }

    func test_switchAtoBtoA_zeroAdditionalWebViewMounts() throws {
        let model = makeModel()
        // Two rendered-markdown tabs → each is a MarkdownRenderedView WKWebView.
        let a = try writeFile("a.md", "# Alpha\n\nFirst doc body.\n")
        let b = try writeFile("b.md", "# Bravo\n\nSecond doc body.\n")
        model.open(url: a)
        model.open(url: b)

        let host = host(ContentView(model: model))
        settle(host)
        // Visit both so each pane's WKWebView is realized once and retained.
        model.selectTab(at: 0); settle(host)
        model.selectTab(at: 1); settle(host)

        // Baseline established — now measure ONLY the A→B→A cycle.
        MountProbe.reset()
        model.selectTab(at: 0); settle(host)   // A
        model.selectTab(at: 1); settle(host)   // B
        model.selectTab(at: 0); settle(host)   // A

        XCTAssertEqual(MountProbe.webViewMakes, 0,
            "A→B→A remounted a WKWebView — retained pane was rebuilt (reload regression)")
        XCTAssertEqual(MountProbe.webViewDismantles, 0,
            "A→B→A tore down a retained WKWebView — it will reload on switch-back (the ~1s freeze)")
    }

    func test_lruOverflow_evictsExactlyTheTail() throws {
        let model = makeModel()
        // Capacity is 4. Open 5 rendered-markdown tabs, visiting each so all
        // get realized; the 5th activation must evict EXACTLY one pane.
        var urls: [URL] = []
        for i in 0..<5 { urls.append(try writeFile("f\(i).md", "# Doc \(i)\n\nbody \(i)\n")) }
        let host = host(ContentView(model: model))
        for u in urls.prefix(4) { model.open(url: u); settle(host) }

        // Mounted set is full (4). Opening the 5th activates it and evicts the LRU
        // tail. Post-TSK-1042 the evicted RENDERED pane is NOT hard-dismantled — its
        // dismantleNSView PARKS the WebView in the bounded WarmWebViewCache (capacity
        // 4) for no-reload re-attach, returning before the webViewDismantles probe.
        // So the eviction registers as exactly ONE STASH, not a dismantle. (TSK-1274:
        // the old dismantles==1 expectation predated TSK-1042 and was a false "leak"
        // — the warm cache is bounded, so retention is capped, not leaked.)
        MountProbe.reset()
        WarmWebViewCache.shared.resetProbes()
        model.open(url: urls[4]); settle(host)
        // The park is driven by the async ForEach re-body, so pump until it lands
        // (≤ ~6s) + drain two cycles to still catch an over-eager (>1) eviction.
        var pumps = 0
        while WarmWebViewCache.shared.stashes < 1 && pumps < 40 { settle(host); pumps += 1 }
        settle(host); settle(host)

        XCTAssertEqual(model.mountedPanes.count, 4, "mounted set exceeded capacity")
        // The evicting 5th open MAKES exactly one new pane (t4)…
        XCTAssertEqual(MountProbe.webViewMakes, 1,
            "5th open should make exactly one new pane, got \(MountProbe.webViewMakes)")
        // …and PARKS exactly the one evicted tail pane in the warm cache (not 0 =
        // under-evict, not >1 = the TSK-621 over-evict class).
        XCTAssertEqual(WarmWebViewCache.shared.stashes, 1,
            "LRU overflow should park exactly the one evicted tail pane, got \(WarmWebViewCache.shared.stashes)")
        // …and does NOT hard-dismantle it: a rendered pane under capacity parks. A
        // real dismantle only fires when the warm cache ALSO overflows (>8 panes).
        XCTAssertEqual(MountProbe.webViewDismantles, 0,
            "under capacity the eviction parks, not hard-dismantles, got \(MountProbe.webViewDismantles)")
    }
}
