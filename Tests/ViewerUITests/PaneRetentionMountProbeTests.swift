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

        // Mounted set is full (4). Opening the 5th activates it and evicts the
        // LRU tail → exactly ONE controlled dismantle.
        MountProbe.reset()
        model.open(url: urls[4]); settle(host)
        // TSK-1274: the evicted pane's dismantleNSView is an ASYNC SwiftUI teardown
        // (a later re-body + NSView reconciliation), so the single fixed settle()
        // above can sample BEFORE it fires (the bug repro'd as got 0). Pump until the
        // dismantle lands (≤ ~6s), then drain two more cycles so an over-eager (>1)
        // teardown (the TSK-621 class) is still caught. If it STILL reads 0 here, the
        // dismantle genuinely never fires — a real retained-pane leak, not a timing
        // artifact — and this assertion correctly fails.
        var pumps = 0
        while MountProbe.webViewDismantles < 1 && pumps < 40 { settle(host); pumps += 1 }
        settle(host); settle(host)

        XCTAssertEqual(model.mountedPanes.count, 4, "mounted set exceeded capacity")
        // TSK-1274 discriminator: the evicting 5th open must MAKE exactly one new pane
        // (t4). If THIS passes (makes==1) but the dismantle below is 0, the ForEach
        // added the new child yet RETAINED the evicted one → a real teardown miss
        // (leak). If THIS also fails with makes==0, the ForEach didn't re-render in
        // the NSHostingView host at all → a harness limitation, not a product leak.
        XCTAssertEqual(MountProbe.webViewMakes, 1,
            "5th open should make exactly one new pane, got \(MountProbe.webViewMakes)")
        XCTAssertEqual(MountProbe.webViewDismantles, 1,
            "LRU overflow should dismantle exactly the one evicted tail pane, got \(MountProbe.webViewDismantles)")
    }
}
