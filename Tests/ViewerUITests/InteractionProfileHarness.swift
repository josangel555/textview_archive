import XCTest
import SwiftUI
import AppKit
@testable import ViewerUI
@testable import ViewerCore
import ViewerKit

/// HEADLESS PER-INTERACTION PROFILER (profiling-harness branch).
///
/// PURPOSE: the owner reports the WHOLE UI went laggy *per-interaction*
/// after the `b38ed03..0905416` batch — scrolling a 12KB Swift file,
/// sidebar hover highlight, expand/collapse, opening tool windows, basic
/// navigation. At IDLE the app is silent (only parked threads), so the
/// cost is main-thread work paid on each interaction: SwiftUI body
/// re-eval + the AppKit layout pass it schedules + any synchronous work
/// the mutation kicks off.
///
/// WHAT THIS MEASURES: it hosts the REAL `ContentView` (and, for
/// finer-grained rows, the REAL `SidebarView`) in an OFFSCREEN
/// `NSHostingView` at a realistic frame — the established T2' pattern
/// (`ToolPanelBoundingTests`, `ChromeLayoutGateTests`). Each interaction
/// is driven as a model/state mutation followed by a FORCED layout pass
/// (`host.layoutSubtreeIfNeeded()` after invalidating layout), and the
/// wall-time of [mutation -> body re-eval -> forced layout] is timed with
/// a monotonic clock, repeated for a stable median. A phys_footprint
/// delta around a loop of the interaction is also captured.
///
/// WHAT IT CANNOT SEE (LESSONS.md stage ④): the WindowServer compositor.
/// That is acceptable — the owner's symptoms are logic/layout latency
/// (every interaction stalls the main thread), not a GPU/compositor
/// stutter. An offscreen `NSHostingView.layoutSubtreeIfNeeded()` exercises
/// SwiftUI's `body` graph + AppKit Auto Layout, which is exactly the
/// per-interaction main-thread cost the report describes.
///
/// HOW TO RUN (self-skips otherwise — never runs in the merge gate):
///
///     MDV_PROFILE=1 swift test --filter \
///       ViewerUITests.InteractionProfileHarness/test_profileAllInteractions
///
/// It prints a RANKED table to stderr and writes a JSON artifact to
/// `$MDV_PROFILE_OUT` (default: a file under the temp dir, path logged).
///
/// To capture hot frames for the worst offender, run the dedicated
/// single-interaction loop under `sample`:
///
///     MDV_PROFILE=1 MDV_PROFILE_HAMMER=<rawName> MDV_PROFILE_HAMMER_SECS=8 \
///       swift test --filter \
///       ViewerUITests.InteractionProfileHarness/test_hammerOneInteraction &
///     sample <pid> 6 -file /tmp/mdv-prof.sample.txt
///     python3 scripts/lib/sample_flamegraph.py /tmp/mdv-prof.sample.txt \
///       /tmp/mdv-prof.svg "hammer <rawName>"
@MainActor
final class InteractionProfileHarness: HeadlessUITestCase {

    // MARK: - Gate

    /// The profiler is opt-in. Without `MDV_PROFILE=1` it self-skips so a
    /// bare `swift test` / the headless merge gate never pays its cost (it
    /// runs hundreds of forced layout passes) and never trips the tier
    /// observer. It is a `HeadlessUITestCase` — host-safe, no window opens.
    private var profilingEnabled: Bool {
        ProcessInfo.processInfo.environment["MDV_PROFILE"] == "1"
    }

    // MARK: - Fixture

    private var tmpDir: URL!
    private var folderRoot: URL!
    private var swiftFile: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "InteractionProfile-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        try makeFixtureTree()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// Build a realistic folder: several files + subdirs (so FILES has a
    /// real tree to flatten/hover/expand) and a ~12KB `.swift` file
    /// (matching the owner's case — the source view scroll target).
    private func makeFixtureTree() throws {
        folderRoot = tmpDir.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: folderRoot, withIntermediateDirectories: true)

        // A ~12KB Swift source file (the owner's scroll case).
        swiftFile = folderRoot.appendingPathComponent("Heavy.swift")
        try makeSwiftSource(approxBytes: 12_000).data(using: .utf8)!.write(to: swiftFile)

        // A spread of sibling files so the flat-visible row list is wide
        // (hover/select/scroll all walk it).
        for i in 0..<24 {
            let name = String(format: "file_%02d.swift", i)
            try "import Foundation\n// file \(i)\nstruct S\(i) {}\n"
                .data(using: .utf8)!
                .write(to: folderRoot.appendingPathComponent(name))
        }
        // A few subdirs with children (expand/collapse targets).
        for d in ["Sources", "Tests", "Docs"] {
            let dir = folderRoot.appendingPathComponent(d)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for j in 0..<8 {
                try "// \(d)/\(j)\n".data(using: .utf8)!
                    .write(to: dir.appendingPathComponent("\(d.lowercased())_\(j).swift"))
            }
        }
        // A nested subdir so a deep expand is exercised too.
        let nested = folderRoot.appendingPathComponent("Sources/Deep/Nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        for k in 0..<6 {
            try "// deep \(k)\n".data(using: .utf8)!
                .write(to: nested.appendingPathComponent("d\(k).swift"))
        }
    }

    /// Synthesize a Swift source ~`approxBytes` long with realistic line
    /// structure (functions, comments, nesting) so the source view has a
    /// few hundred lines to lay out / scroll.
    private func makeSwiftSource(approxBytes: Int) -> String {
        var s = "import Foundation\nimport AppKit\n\n"
        var i = 0
        while s.utf8.count < approxBytes {
            s += """
            /// Doc comment for member \(i) — describes a unit of work that
            /// does something moderately interesting with index \(i).
            func member\(i)(value: Int) -> Int {
                let scaled = value * \(i + 1)
                let adjusted = scaled &+ (value % \(i + 3))
                guard adjusted > 0 else { return 0 }
                return adjusted + member\(i)Helper(adjusted)
            }
            private func member\(i)Helper(_ x: Int) -> Int { x ^ \(i) }

            """
            i += 1
        }
        return s
    }

    // MARK: - Model + host construction

    /// A model opened on the fixture folder, with the 12KB Swift file as
    /// the current source document and a couple more tabs. `panelLayout`
    /// overrides are left at `.auto` (the realistic default) for the main
    /// catalog; specific interactions force panels `.shown` explicitly.
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
        // Open the 12KB Swift file in source mode (NSTextView path — keeps
        // this in the headless gate; no WKWebView).
        m.open(url: swiftFile)
        m.setCurrentViewMode(.source)
        return m
    }

    private func host(_ model: DocumentModel, size: CGSize) -> NSHostingView<ContentView> {
        let view = ContentView(model: model)
        let h = NSHostingView(rootView: view)
        h.frame = NSRect(origin: .zero, size: size)
        return h
    }

    /// Settle initial layout across a few passes — the sidebar measures
    /// its allotted height via a background GeometryReader -> @State, which
    /// schedules another pass; matching `ToolPanelBoundingTests.settle`.
    private func settle(_ host: NSView) {
        for _ in 0..<4 { host.layoutSubtreeIfNeeded() }
    }

    /// Force a fresh layout pass and return wall-time in milliseconds for
    /// [the mutation already applied by the caller -> body re-eval ->
    /// forced layout]. We invalidate the whole subtree's layout so SwiftUI
    /// is forced to re-evaluate bodies whose observed state changed and
    /// AppKit re-runs Auto Layout — the per-interaction cost the report
    /// describes. `needsLayout = true` on the host + every descendant is
    /// what makes the pass non-trivial (a no-op layout returns instantly).
    private func forcedLayout(_ host: NSView) {
        // Two invalidation modes:
        //   * deep (default): mark every descendant `needsLayout`, forcing
        //     a full re-layout. Inflates absolute ms (and equalizes rows
        //     toward the full-tree cost) but guarantees the pass is real.
        //   * shallow (MDV_PROFILE_SHALLOW=1): only mark the host root,
        //     letting SwiftUI's own dependency tracking decide what
        //     re-bodies — closer to a real interaction, so the DELTA
        //     between rows attributes cost to the MUTATION, not the floor.
        if ProcessInfo.processInfo.environment["MDV_PROFILE_SHALLOW"] == "1" {
            host.needsLayout = true
        } else {
            invalidateDeep(host)
        }
        host.layoutSubtreeIfNeeded()
    }

    private func invalidateDeep(_ v: NSView) {
        v.needsLayout = true
        for s in v.subviews { invalidateDeep(s) }
    }

    // MARK: - Interaction catalog

    /// One profilable interaction: a name, a category, and a closure that
    /// applies the state mutation. The harness times [closure +
    /// forcedLayout] and (optionally) measures the footprint delta.
    ///
    /// `prepare` runs ONCE before the timed loop (e.g. force panels shown,
    /// set up a tab set) and is NOT timed. `apply` runs every iteration.
    private struct Interaction {
        let name: String
        let category: String
        let prepare: ((DocumentModel, NSHostingView<ContentView>) -> Void)?
        let apply: (DocumentModel, NSHostingView<ContentView>, _ iteration: Int) -> Void
    }

    /// ~50 interactions spanning every surface the owner flagged. Each is
    /// a model/state mutation; the harness pairs it with a forced layout.
    private func catalog() -> [Interaction] {
        var out: [Interaction] = []
        func add(_ name: String, _ cat: String,
                 prepare: ((DocumentModel, NSHostingView<ContentView>) -> Void)? = nil,
                 _ apply: @escaping (DocumentModel, NSHostingView<ContentView>, Int) -> Void) {
            out.append(Interaction(name: name, category: cat, prepare: prepare, apply: apply))
        }

        // ---- Sidebar: hover (the explicitly-flagged laggy one) ----
        // FileRowView hover is local @State, but a hover *change* re-bodies
        // the row and the sidebar lays out. We can't poke the row's private
        // @State from here, so we drive the closest observable proxy that
        // forces the sidebar to re-body + re-layout: nudge selection across
        // adjacent rows (what the pointer "lands on") which is exactly the
        // hover->select path, plus bump the sidebar to republish.
        add("sidebar.hover.adjacentRows", "sidebar-hover") { m, _, i in
            let rows = m.sidebar.flatVisibleNodes()
            guard !rows.isEmpty else { return }
            let idx = i % rows.count
            m.sidebar.setSelected(rows[idx].url)
        }
        add("sidebar.hover.republishOnly", "sidebar-hover") { m, _, _ in
            // The cheapest sidebar republish — isolates "sidebar re-body +
            // layout" cost from any model work. fileDidChange bumps
            // recencyVersion (the per-row .onChange the batch added).
            m.sidebar.fileDidChange(self.swiftFile)
        }

        // ---- Sidebar: selection / navigation ----
        add("sidebar.selectNext", "sidebar-nav") { m, _, _ in m.sidebar.selectNext() }
        add("sidebar.selectPrev", "sidebar-nav") { m, _, _ in m.sidebar.selectPrevious() }
        add("sidebar.selectRow.cycle", "sidebar-nav") { m, _, i in
            let rows = m.sidebar.flatVisibleNodes()
            guard !rows.isEmpty else { return }
            m.sidebar.setSelected(rows[i % rows.count].url)
        }
        add("sidebar.walkUp", "sidebar-nav") { m, _, _ in m.sidebar.collapseOrFocusParent() }
        add("sidebar.walkDownInto", "sidebar-nav") { m, _, _ in m.sidebar.expandOrFocusFirstChild() }

        // ---- Sidebar: expand / collapse dirs ----
        let topDirs = ["Sources", "Tests", "Docs"].map { folderRoot.appendingPathComponent($0) }
        add("sidebar.toggleExpand.Sources", "sidebar-expand") { m, _, _ in
            m.sidebar.toggleExpansion(topDirs[0])
        }
        add("sidebar.toggleExpand.three", "sidebar-expand") { m, _, i in
            m.sidebar.toggleExpansion(topDirs[i % 3])
        }
        add("sidebar.expandDeepNested", "sidebar-expand",
            prepare: { m, _ in
                m.sidebar.toggleExpansion(self.folderRoot.appendingPathComponent("Sources"))
            }) { m, _, _ in
            m.sidebar.toggleExpansion(self.folderRoot.appendingPathComponent("Sources/Deep"))
        }

        // ---- Sidebar: file-list scroll (offset change proxy) ----
        // No public scroll-offset on SidebarModel; the realistic proxy for
        // "scroll the list" is moving selection far down the flat list,
        // which the list follows. Pair with forced layout.
        add("sidebar.scrollList.farRows", "sidebar-scroll") { m, _, i in
            let rows = m.sidebar.flatVisibleNodes()
            guard rows.count > 2 else { return }
            let target = (i * 7) % rows.count
            m.sidebar.setSelected(rows[target].url)
        }

        // ---- Tool windows: open each panel kind individually ----
        for kind in SidebarPanelKind.allCases where kind != .files {
            add("toolwindow.open.\(kind.rawValue)", "toolwindow-open",
                prepare: { m, _ in m.panelLayout.setOverride(kind, .hidden) }) { m, _, i in
                // Toggle shown/hidden each iteration so the layout actually
                // changes (a no-change set wouldn't re-body).
                m.panelLayout.setOverride(kind, i % 2 == 0 ? .shown : .hidden)
            }
        }

        // ---- Tool windows: open ALL at once / close all ----
        add("toolwindow.openAll", "toolwindow-bulk") { m, _, i in
            let on = i % 2 == 0
            for kind in SidebarPanelKind.allCases where kind != .files {
                m.panelLayout.setOverride(kind, on ? .shown : .hidden)
            }
        }
        add("toolwindow.closeAll", "toolwindow-bulk",
            prepare: { m, _ in
                for kind in SidebarPanelKind.allCases where kind != .files {
                    m.panelLayout.setOverride(kind, .shown)
                }
            }) { m, _, i in
            let on = i % 2 == 1
            for kind in SidebarPanelKind.allCases where kind != .files {
                m.panelLayout.setOverride(kind, on ? .shown : .hidden)
            }
        }

        // ---- Sidebar width resize (drag the divider) ----
        add("sidebar.resizeWidth", "resize") { m, _, i in
            m.sidebarWidth = (i % 2 == 0) ? 180 : 320
        }

        // ---- Window resize: change the host frame (narrow/wide/short/tall) ----
        let sizes: [CGSize] = [
            CGSize(width: 700, height: 500),   // narrow+short
            CGSize(width: 1400, height: 500),  // wide+short
            CGSize(width: 700, height: 1000),  // narrow+tall
            CGSize(width: 1400, height: 1000), // wide+tall
        ]
        add("window.resize.cycle4", "resize") { _, h, i in
            h.frame = NSRect(origin: .zero, size: sizes[i % sizes.count])
        }
        add("window.resize.narrowTall", "resize") { _, h, i in
            h.frame = NSRect(origin: .zero,
                             size: i % 2 == 0 ? CGSize(width: 600, height: 1100)
                                              : CGSize(width: 1100, height: 600))
        }

        // ---- Tabs: switch / open / close / many ----
        add("tab.openClose", "tabs") { m, _, i in
            if i % 2 == 0 { m.newTab() } else { m.closeCurrentTab() }
        }
        add("tab.switch.cycle", "tabs",
            prepare: { m, _ in
                // Build a handful of tabs to switch among.
                for i in 0..<6 {
                    m.open(url: self.folderRoot.appendingPathComponent(String(format: "file_%02d.swift", i)))
                }
            }) { m, _, i in
            let count = m.tabs.tabs.count
            guard count > 1 else { return }
            m.selectTab(at: i % count)
        }
        add("tab.manyTabs.open", "tabs") { m, _, i in
            m.open(url: self.folderRoot.appendingPathComponent(String(format: "file_%02d.swift", i % 24)))
        }

        // ---- Source view: scroll (offset change across the 12KB file) ----
        add("source.scroll.offset", "source-scroll") { m, _, i in
            let cur = m.sourceScrollState
            let off = CGFloat((i % 40)) * 80.0
            m.sourceScrollState = SourceScrollState(
                offsetY: off, viewportHeight: 600, lineHeight: cur.lineHeight,
                lineCount: max(cur.lineCount, 300), topInset: cur.topInset)
        }
        add("source.gotoLine", "source-scroll") { m, _, i in
            m.scrollSource(toLine: 1 + (i * 13) % 280)
        }

        // ---- Source view: caret move + text select ----
        add("source.caretMove", "source-caret") { m, _, i in
            m.sourceSelection = SourceSelection(line: 1 + (i % 280), column: 1 + (i % 40), length: 0)
        }
        add("source.textSelect", "source-caret") { m, _, i in
            m.sourceSelection = SourceSelection(line: 1 + (i % 280), column: 1, length: (i % 50) + 1)
        }

        // ---- Word-wrap toggle ----
        add("source.wordWrapToggle", "source-toggle") { m, _, i in
            m.sourceWordWrap = (i % 2 == 0)
        }
        add("source.invisiblesToggle", "source-toggle") { m, _, i in
            m.showInvisibleChars = (i % 2 == 0)
        }

        // ---- View mode cycle ----
        add("viewmode.toggle", "viewmode") { m, _, _ in m.toggleViewMode() }
        add("viewmode.cycleSourceFormattedHex", "viewmode") { m, _, i in
            let modes: [ViewMode] = [.source, .formatted, .hex]
            m.setCurrentViewMode(modes[i % modes.count])
        }

        // ---- Find-as-you-type (per-keystroke, source bar) ----
        add("find.sourceTypeahead", "find",
            prepare: { m, _ in m.showSourceFindBar() }) { m, _, i in
            let q = "member"
            let n = (i % q.count) + 1
            m.find.sourceQuery = String(q.prefix(n))
        }
        add("find.crossSearchTypeahead", "find",
            prepare: { m, _ in m.showCrossSearch() }) { m, _, i in
            let q = "struct"
            let n = (i % q.count) + 1
            m.crossSearchQuery = String(q.prefix(n))
        }

        // ---- Fold / unfold proxy (collapse/expand a dir = the fold UI) ----
        add("fold.toggleDir", "fold") { m, _, _ in
            m.sidebar.toggleExpansion(self.folderRoot.appendingPathComponent("Tests"))
        }

        // ---- Zoom (chrome+content rescale; touches every bar) ----
        add("zoom.inOut", "zoom") { m, _, i in
            if i % 2 == 0 { m.zoomIn() } else { m.zoomOut() }
        }

        // ---- Folder-stats slide-down ----
        add("folderStats.toggle", "misc") { m, _, i in
            m.folderStatsExpanded = (i % 2 == 0)
        }

        // ---- Palette / GoToPath overlays ----
        add("palette.toggle", "overlay") { m, _, i in
            if i % 2 == 0 { m.showPalette() } else { m.dismissPalette() }
        }
        add("goto.toggle", "overlay") { m, _, i in
            if i % 2 == 0 { m.showGoToPath() } else { m.dismissGoToPath() }
        }

        // ---- BASELINE: a forced layout with NO state change ----
        // The control: a forced layout pass on an unchanged tree. Tells us
        // the floor cost of `layoutSubtreeIfNeeded` on this composition;
        // every other row should be read RELATIVE to this.
        add("baseline.noChange", "baseline") { _, _, _ in }

        return out
    }

    // MARK: - Measurement primitives

    private func nowNanos() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    private func footprintBytes() -> Int64 {
        Int64(ProcessMemory.appFootprintBytes() ?? 0)
    }

    private struct Result {
        let name: String
        let category: String
        let medianMs: Double
        let p90Ms: Double
        let maxMs: Double
        let footprintDeltaKB: Int64
    }

    /// Time one interaction: run `prepare` once, then loop
    /// [apply -> forcedLayout] N times, recording per-iteration ms; take
    /// median / p90 / max. Footprint delta is measured around the loop.
    private func measure(_ ix: Interaction,
                         on model: DocumentModel,
                         host: NSHostingView<ContentView>,
                         iterations: Int) -> Result {
        ix.prepare?(model, host)
        settle(host)

        // Warm-up (excluded): first pass after prepare pays one-time costs.
        for w in 0..<3 { ix.apply(model, host, w); forcedLayout(host) }

        let footBefore = footprintBytes()
        var samples: [Double] = []
        samples.reserveCapacity(iterations)
        for i in 0..<iterations {
            let t0 = nowNanos()
            ix.apply(model, host, i)
            forcedLayout(host)
            let t1 = nowNanos()
            samples.append(Double(t1 - t0) / 1_000_000.0)
        }
        let footAfter = footprintBytes()

        samples.sort()
        func pct(_ p: Double) -> Double {
            guard !samples.isEmpty else { return 0 }
            let idx = min(samples.count - 1, Int(Double(samples.count) * p))
            return samples[idx]
        }
        return Result(
            name: ix.name,
            category: ix.category,
            medianMs: pct(0.5),
            p90Ms: pct(0.9),
            maxMs: samples.last ?? 0,
            footprintDeltaKB: (footAfter - footBefore) / 1024
        )
    }

    // MARK: - The profile run

    func test_profileAllInteractions() throws {
        try XCTSkipUnless(profilingEnabled,
            "InteractionProfileHarness is opt-in; set MDV_PROFILE=1 to run it.")

        let iterations = Int(ProcessInfo.processInfo.environment["MDV_PROFILE_ITERS"] ?? "") ?? 40
        let hostSize = CGSize(width: 1100, height: 760)

        var results: [Result] = []
        for ix in catalog() {
            // Fresh model + host per interaction so cross-interaction state
            // doesn't contaminate (e.g. a prior interaction leaving panels
            // open). This is the honest per-interaction cost.
            let model = makeModel()
            let h = host(model, size: hostSize)
            settle(h)
            let r = measure(ix, on: model, host: h, iterations: iterations)
            results.append(r)
            FileHandle.standardError.write(Data(
                "  profiled \(r.name): median \(fmt(r.medianMs))ms\n".utf8))
        }

        // Rank by median descending.
        let ranked = results.sorted { $0.medianMs > $1.medianMs }

        let baseline = results.first { $0.name == "baseline.noChange" }?.medianMs ?? 0

        printTable(ranked, baseline: baseline)
        try writeJSON(ranked, baseline: baseline, iterations: iterations, hostSize: hostSize)

        // The run itself never fails on a threshold — it's a measurement
        // tool, not a gate. (A future regression gate could assert a
        // ceiling on a specific row.) Sanity: we measured the whole catalog.
        XCTAssertGreaterThanOrEqual(results.count, 40,
            "expected ~44 interactions in the catalog, profiled \(results.count)")
    }

    /// A/B subset: profile only the interactions named in
    /// `MDV_PROFILE_SUBSET` (comma-separated). Fast enough to run twice
    /// (before/after a source revert) to attribute cost to a code change.
    func test_profileSubset() throws {
        try XCTSkipUnless(profilingEnabled,
            "InteractionProfileHarness is opt-in; set MDV_PROFILE=1 to run it.")
        let names = (ProcessInfo.processInfo.environment["MDV_PROFILE_SUBSET"] ?? "")
            .split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        try XCTSkipUnless(!names.isEmpty, "set MDV_PROFILE_SUBSET=a,b,c")
        let iterations = Int(ProcessInfo.processInfo.environment["MDV_PROFILE_ITERS"] ?? "") ?? 60
        let hostSize = CGSize(width: 1100, height: 760)
        let wanted = Set(names)
        var results: [Result] = []
        for ix in catalog() where wanted.contains(ix.name) {
            let model = makeModel()
            let h = host(model, size: hostSize)
            settle(h)
            results.append(measure(ix, on: model, host: h, iterations: iterations))
        }
        let baseline = results.first { $0.name == "baseline.noChange" }?.medianMs ?? 0
        printTable(results.sorted { $0.medianMs > $1.medianMs }, baseline: baseline)
    }

    /// Loop ONE interaction continuously for `MDV_PROFILE_HAMMER_SECS` so an
    /// external `sample <pid>` can capture its hot main-thread frames. Pick
    /// the interaction via `MDV_PROFILE_HAMMER=<name>`.
    func test_hammerOneInteraction() throws {
        try XCTSkipUnless(profilingEnabled,
            "InteractionProfileHarness is opt-in; set MDV_PROFILE=1 to run it.")
        guard let target = ProcessInfo.processInfo.environment["MDV_PROFILE_HAMMER"] else {
            throw XCTSkip("set MDV_PROFILE_HAMMER=<interaction name> to hammer one")
        }
        let secs = Double(ProcessInfo.processInfo.environment["MDV_PROFILE_HAMMER_SECS"] ?? "") ?? 8.0
        guard let ix = catalog().first(where: { $0.name == target }) else {
            XCTFail("no interaction named \(target)"); return
        }

        let model = makeModel()
        let h = host(model, size: CGSize(width: 1100, height: 760))
        settle(h)
        ix.prepare?(model, h)
        settle(h)

        FileHandle.standardError.write(Data(
            "HAMMER \(target) for \(secs)s — attach `sample <pid>` now (pid \(getpid()))\n".utf8))
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(secs * 1e9)
        var i = 0
        while DispatchTime.now().uptimeNanoseconds < deadline {
            ix.apply(model, h, i)
            forcedLayout(h)
            i += 1
        }
        FileHandle.standardError.write(Data("HAMMER done — \(i) iterations\n".utf8))
    }

    // MARK: - Output

    private func fmt(_ d: Double) -> String { String(format: "%.3f", d) }

    private func printTable(_ ranked: [Result], baseline: Double) {
        var lines: [String] = []
        lines.append("")
        lines.append("==== INTERACTION PROFILE (forced-layout cost; ranked by median) ====")
        lines.append(String(format: "baseline (no-change forced layout): %.3f ms", baseline))
        lines.append("")
        lines.append(String(format: "%-38@ %10@ %8@ %8@ %10@ %12@",
            "interaction" as NSString, "median" as NSString, "p90" as NSString,
            "max" as NSString, "×base" as NSString, "footΔ KB" as NSString))
        lines.append(String(repeating: "-", count: 92))
        for r in ranked {
            let mult = baseline > 0 ? r.medianMs / baseline : 0
            let flag = (r.medianMs > 5.0 && r.category != "baseline") ? "  <== PATHOLOGICAL" : ""
            lines.append(String(format: "%-38@ %9.3f %7.3f %7.3f %9.1f %11d%@",
                r.name as NSString, r.medianMs, r.p90Ms, r.maxMs, mult,
                r.footprintDeltaKB, flag as NSString))
        }
        lines.append(String(repeating: "=", count: 92))
        lines.append("")
        FileHandle.standardError.write(Data(lines.joined(separator: "\n").utf8))
    }

    private func writeJSON(_ ranked: [Result], baseline: Double,
                           iterations: Int, hostSize: CGSize) throws {
        let outPath = ProcessInfo.processInfo.environment["MDV_PROFILE_OUT"]
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("mdv-interaction-profile.json").path
        var rows: [[String: Any]] = []
        for r in ranked {
            rows.append([
                "name": r.name,
                "category": r.category,
                "median_ms": r.medianMs,
                "p90_ms": r.p90Ms,
                "max_ms": r.maxMs,
                "x_baseline": baseline > 0 ? r.medianMs / baseline : 0,
                "footprint_delta_kb": r.footprintDeltaKB,
                "pathological": r.medianMs > 5.0 && r.category != "baseline",
            ])
        }
        let doc: [String: Any] = [
            "baseline_ms": baseline,
            "iterations": iterations,
            "host_size": ["w": hostSize.width, "h": hostSize.height],
            "results": rows,
        ]
        let data = try JSONSerialization.data(
            withJSONObject: doc, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: outPath))
        FileHandle.standardError.write(Data("JSON artifact: \(outPath)\n".utf8))
    }
}
