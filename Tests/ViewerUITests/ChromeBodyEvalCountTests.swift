import XCTest
import SwiftUI
import AppKit
@testable import ViewerUI
@testable import ViewerCore
import ViewerKit

/// TSK-615 — chrome re-evaluation WIDTH, pinned by body-eval COUNTS.
///
/// The distributed-re-eval residual has no single hot frame; the cost is
/// how many chrome subtrees re-body per model republish. Wall-clock can't
/// rank that headlessly (noisy), counts can: every top-level chrome view's
/// `body` ticks `BodyProbe` (DEBUG-only), this suite hosts the REAL
/// `ContentView` offscreen (the `InteractionProfileHarness` T2' pattern —
/// text files only, no WKWebView, host-safe), fires one interaction of
/// each kind, pumps the runloop so SwiftUI's scheduled render runs, and
/// asserts per-view bounds. The ZERO bounds are the teeth: a future
/// widening — a chrome view re-bodying on a republish it used to skip —
/// fails here with the offending view named.
@MainActor
final class ChromeBodyEvalCountTests: HeadlessUITestCase {

    private var tmpDir: URL!
    private var folderRoot: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var host: NSHostingView<ContentView>!

    override func setUp() async throws {
        suiteName = "ChromeBodyEval-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName)
        folderRoot = tmpDir.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: folderRoot, withIntermediateDirectories: true)
        for i in 0..<6 {
            try "line one\nline two\nfile \(i)\n"
                .write(to: folderRoot.appendingPathComponent("file_\(i).txt"),
                       atomically: true, encoding: .utf8)
        }
        BodyProbe.reset()
        BodyProbe.enabled = false
    }

    override func tearDown() async throws {
        BodyProbe.enabled = false
        BodyProbe.reset()
        host = nil
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
        if let suiteName, let defaults {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    /// Model on the fixture folder with 3 warm text tabs (source mode —
    /// NSTextView path, keeps this suite in the bare headless gate).
    private func makeModel() -> DocumentModel {
        let m = DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmpDir.appendingPathComponent("history.json")),
            goToPathHistory: GoToPathHistoryStore(
                storeURL: tmpDir.appendingPathComponent("goto.json")),
            bookmarks: BookmarksStore(storeURL: tmpDir.appendingPathComponent("bookmarks.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults)
        )
        m.sidebar.setRoot(folderRoot)
        m.sidebar.isVisible = true
        for i in 0..<3 {
            m.open(url: folderRoot.appendingPathComponent("file_\(i).txt"))
            // TSK-1588: .txt now defaults to the EDITOR lens, whose chrome
            // graph (editor-assist chips etc.) these re-body pins were never
            // written for. Pin the fixture to the read-only Source lens so
            // the suite keeps guarding the SOURCE-mode chrome contract
            // verbatim; the editor-lens chrome-eval budget is a separate,
            // unpinned surface (follow-up noted on TSK-1588).
            m.setCurrentViewMode(.source)
        }
        return m
    }

    private func makeHost(_ model: DocumentModel) {
        host = NSHostingView(rootView: ContentView(model: model))
        host.frame = NSRect(x: 0, y: 0, width: 1100, height: 760)
        for _ in 0..<4 { host.layoutSubtreeIfNeeded() }
        pump()
    }

    /// Service the main queue so SwiftUI's scheduled re-render actually
    /// runs (the `WebViewTestTeardown.pumpMainQueue` pattern) — body
    /// re-evals after a mutation happen here, not inside the mutation.
    private func pump() {
        for _ in 0..<6 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        host?.layoutSubtreeIfNeeded()
    }

    /// Pump until the chrome tree stops re-bodying (quiescent), so no setup /
    /// async-settle residual leaks into the measured window under machine load
    /// (TSK-1328 — the parallel-gate flake: a stray initial-render body landed in
    /// the window when the fixed pre-measure `pump()` was too short under load).
    /// Uses the probe itself to detect quiescence; bounded, so a genuinely
    /// never-quiescent tree still falls through and is caught by the real assert.
    ///
    /// Quiescence requires TWO consecutive empty pumps, not one (TSK-1328 follow-up): under
    /// the 18-worker gate a slow async residual can land just AFTER a single empty pump, so a
    /// one-empty break declared false quiescence and the residual leaked into the measured
    /// window (the recurring `StatusBar=1 ContentView=1` find-typeahead flake). Two empty
    /// pumps in a row means the tree was idle across a full pump cycle. Iteration bound
    /// doubled (24) so a genuinely slow settle still completes before the bound.
    private func settle() {
        BodyProbe.enabled = true
        var consecutiveEmpty = 0
        for _ in 0..<24 {
            BodyProbe.reset()
            pump()
            if BodyProbe.counts.isEmpty {
                consecutiveEmpty += 1
                if consecutiveEmpty >= 2 { break }   // idle across two full pumps → quiescent
            } else {
                consecutiveEmpty = 0
            }
        }
        BodyProbe.enabled = false
        BodyProbe.reset()
    }

    /// Run `mutation`, pump, and return the per-view body-eval counts for
    /// just that window.
    private func evals(after mutation: () -> Void) -> [String: Int] {
        settle()                  // drain setup/async residual to quiescence (TSK-1328)
        BodyProbe.reset()
        BodyProbe.enabled = true
        mutation()
        pump()
        BodyProbe.enabled = false
        return BodyProbe.counts
    }

    /// Like `evals(after:)` but RETRIES to clear a TRANSIENT coincidental body that lands in the
    /// measured window under gate load (TSK-1328 residual — settle() drains BEFORE the window, but
    /// a slow async body can still fire DURING the mutation+pump). The measured action's own effect
    /// is deterministic, so a GENUINE re-body of a `zeroViews` chrome view shows on EVERY attempt
    /// (the returned counts still catch it); transient noise clears on a clean attempt. The
    /// mutation MUST vary per attempt (e.g. a changing query) so each attempt is a real
    /// re-measurement, not a no-op. This is the robust fix after the 2-consecutive-empty settle()
    /// still flaked under the heavier (rebundle) gate.
    private func evalsExpectingZero(zeroViews: [String], attempts: Int = 4,
                                    mutation: (Int) -> Void) -> [String: Int] {
        var last: [String: Int] = [:]
        for i in 0..<attempts {
            last = evals(after: { mutation(i) })
            if zeroViews.allSatisfy({ (last[$0] ?? 0) == 0 }) { return last }  // clean — no noise
        }
        return last  // exhausted: a real regression persists across attempts → the assert catches it
    }

    private func describeCounts(_ c: [String: Int]) -> String {
        c.isEmpty ? "(none)" :
            c.sorted { $0.value > $1.value }
                .map { "\($0.key)=\($0.value)" }.joined(separator: " ")
    }

    /// Always emit the measured width to stderr — the suite is the
    /// TSK-615 measurement artifact, not just a gate.
    private func dump(_ label: String, _ c: [String: Int]) {
        FileHandle.standardError.write(Data(
            "  [body-evals] \(label): \(describeCounts(c))\n".utf8))
    }

    // MARK: - Control

    /// Pumping an unchanged tree must not re-body anything — proves the
    /// probe window isn't polluted by the harness itself.
    func test_noMutation_reBodiesNothing() throws {
        let model = makeModel()
        makeHost(model)
        let counts = evals(after: {})
        dump("noMutation", counts)
        XCTAssertTrue(counts.isEmpty,
            "idle pump must not re-body chrome; got \(describeCounts(counts))")
    }

    // MARK: - Probe liveness (the wide-by-design interaction)

    /// Zoom rescales every bar — ALL mounted chrome must re-body. This is
    /// by design (uiSize-driven layout) and doubles as probe liveness: if
    /// the probe stops ticking, this fails before the zero-bounds below
    /// turn into false greens.
    func test_zoomChange_reBodiesAllChrome() throws {
        let model = makeModel()
        makeHost(model)
        let counts = evals(after: { model.zoomIn() })
        dump("zoomIn", counts)
        for view in ["ContentView", "TabBar", "StatusBar",
                     "ContentToolbar", "BottomAttributesBar", "SidebarView"] {
            XCTAssertGreaterThanOrEqual(counts[view] ?? 0, 1,
                "\(view) must re-body on zoom (uiSize layout); "
                + "got \(describeCounts(counts))")
        }
    }

    // MARK: - Width pins per republish kind

    /// Warm same-mode tab switch: the chrome strip legitimately re-bodies
    /// (title, breadcrumb, selection), but each view must re-body a
    /// BOUNDED number of times — re-eval storms (N bodies per switch)
    /// are the TSK-615 class.
    func test_warmTabSwitch_chromeReEvalIsBounded() throws {
        let model = makeModel()
        makeHost(model)
        model.selectTab(at: 0)
        pump()
        let counts = evals(after: { model.selectTab(at: 1) })
        dump("warmTabSwitch", counts)
        for (view, bound) in ["ContentView": 4, "TabBar": 4, "StatusBar": 4,
                              "ContentToolbar": 4, "BottomAttributesBar": 4,
                              "SidebarView": 4] {
            XCTAssertLessThanOrEqual(counts[view] ?? 0, bound,
                "\(view) re-bodied \(counts[view] ?? 0)× on one warm tab "
                + "switch (bound \(bound)); counts: \(describeCounts(counts))")
        }
    }

    /// Find-coordinator typeahead (per-keystroke path): the REPUB-1 split
    /// moved find state off DocumentModel precisely so chrome does NOT
    /// re-body per keystroke. Pin the width at zero for every chrome view
    /// that doesn't observe FindCoordinator.
    func test_findTypeahead_doesNotReBodyChromeStrip() throws {
        let model = makeModel()
        makeHost(model)
        model.showSourceFindBar()
        pump()
        let zeroViews = ["TabBar", "StatusBar", "ContentToolbar",
                         "BottomAttributesBar", "SidebarView"]
        // A varying query per attempt → each is a real find keystroke; transient
        // coincidental bodies clear, a genuine per-keystroke re-body persists.
        let counts = evalsExpectingZero(zeroViews: zeroViews) { i in
            model.find.sourceQuery = "needle\(i)"
        }
        dump("findTypeahead", counts)
        for view in zeroViews {
            XCTAssertEqual(counts[view] ?? 0, 0,
                "\(view) must NOT re-body on a find keystroke (FindCoordinator "
                + "is split off DocumentModel); counts: \(describeCounts(counts))")
        }
    }

    /// Sidebar-only republish (recency tick): the forwarding chain into
    /// DocumentModel was removed (SidebarRepublishInvariantTests pins the
    /// publisher side) — this pins the VIEW side: the content/chrome strip
    /// must not re-body when only the sidebar republishes.
    func test_sidebarRecencyTick_doesNotReBodyContentChrome() throws {
        let model = makeModel()
        makeHost(model)
        let file = folderRoot.appendingPathComponent("file_0.txt")
        let counts = evals(after: { model.sidebar.fileDidChange(file) })
        dump("sidebarRecencyTick", counts)
        for view in ["TabBar", "StatusBar", "ContentToolbar",
                     "BottomAttributesBar"] {
            XCTAssertEqual(counts[view] ?? 0, 0,
                "\(view) must NOT re-body on a sidebar-only republish "
                + "(forwarding was removed); counts: \(describeCounts(counts))")
        }
    }

    // MARK: - Split open/close MUST re-body ContentView (TSK-921/922 root cause)

    /// THE BUG (owner: "works when you switch tabs, but if you stay in the tab
    /// nothing happens"): `splitURL` is `@Published` on `tabCoordinator`, so
    /// `openInSplit` fires ONLY `tabCoordinator.objectWillChange` — NOT
    /// `DocumentModel.objectWillChange` (PERF #1; pinned by
    /// `TabRepublishInvariantTests`). `ContentView` GATES the split pane on
    /// `splitURL`, so it MUST observe `tabCoordinator` directly or its body
    /// never re-evaluates on open → the pane doesn't appear until an unrelated
    /// `model`-republishing event (a tab switch) forces a re-body.
    ///
    /// TEETH: this is the direct host pin for the fix. Revert the
    /// `@ObservedObject var tabCoordinator` on `ContentView` (so the split gate
    /// is driven only by `model`) and `openInSplit` produces ZERO ContentView
    /// re-bodies → this fails with `ContentView=0`. With the fix, the
    /// coordinator observation re-bodies ContentView so the pane is created
    /// synchronously.
    func test_openInSplit_reBodiesContentView() throws {
        let model = makeModel()
        makeHost(model)
        let file = folderRoot.appendingPathComponent("file_3.txt")
        let counts = evals(after: { model.openInSplit(file) })
        dump("openInSplit", counts)
        XCTAssertNotNil(model.splitURL, "openInSplit pinned the split file")
        XCTAssertGreaterThanOrEqual(counts["ContentView"] ?? 0, 1,
            "ContentView must re-body on openInSplit so the split pane appears "
            + "WITHOUT a tab switch (it observes tabCoordinator directly); "
            + "counts: \(describeCounts(counts))")
    }

    /// CLOSE re-body — the owner's "even worse" half. `closeSplit` sets
    /// `splitURL = nil` (again coordinator-only), so ContentView must re-body
    /// to TEAR DOWN the pane. Verified separately from open (distinct path).
    func test_closeSplit_reBodiesContentView() throws {
        let model = makeModel()
        makeHost(model)
        let file = folderRoot.appendingPathComponent("file_3.txt")
        model.openInSplit(file)
        pump()
        XCTAssertNotNil(model.splitURL)
        let counts = evals(after: { model.closeSplit() })
        dump("closeSplit", counts)
        XCTAssertNil(model.splitURL, "closeSplit cleared the split file")
        XCTAssertGreaterThanOrEqual(counts["ContentView"] ?? 0, 1,
            "ContentView must re-body on closeSplit so the split pane disappears "
            + "WITHOUT a tab switch; counts: \(describeCounts(counts))")
    }

    /// Panel-layout-only republish (tool-window toggle): panelLayout is
    /// its own observable; the bottom/status chrome must not re-body when
    /// a shoulder panel toggles.
    func test_panelToggle_doesNotReBodyBottomChrome() throws {
        let model = makeModel()
        makeHost(model)
        let kind = SidebarPanelKind.allCases.first { $0 != .files }!
        let counts = evals(after: { model.panelLayout.setOverride(kind, .shown) })
        dump("panelToggle", counts)
        for view in ["TabBar", "StatusBar", "BottomAttributesBar",
                     "ContentToolbar"] {
            XCTAssertEqual(counts[view] ?? 0, 0,
                "\(view) must NOT re-body on a panelLayout-only republish; "
                + "counts: \(describeCounts(counts))")
        }
    }
}
