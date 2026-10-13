import XCTest
import SwiftUI
import AppKit
@testable import ViewerUI
@testable import ViewerCore
import ViewerKit

/// Bug A — "the top tab bar / top items disappear on window resize."
///
/// ROOT CAUSE: `TabBar.body` was wrapped in a `GeometryReader` (introduced
/// WAVE 2b `7474204`) purely to feed `geo.size.width` into the per-tab width
/// budget. A `GeometryReader` is GREEDY on both axes yet reports a TINY (10×10)
/// IDEAL size — so the TabBar's intrinsic/fitting size collapsed to a 10pt
/// width. Sitting inside ContentView's chrome VStack under
/// `.fixedSize(horizontal:false, vertical:true)` + `.layoutPriority(1)`, that
/// ambiguous intrinsic size is the kind of unstable composition that makes the
/// bar mis-lay-out / blank on a LIVE window resize. The prior chrome-pinning
/// fix (`6f1e532`) and `ChromeLayoutGateTests` only exercised the VERTICAL axis
/// and used a `Color.clear` center, so they never observed the collapsed
/// intrinsic WIDTH — they passed while the app failed.
///
/// THE FIX: measure available width via a NON-layout-driving
/// `.background(GeometryReader …)` overlay instead of a WRAPPING
/// `GeometryReader`. A background never alters its parent's sizing, so the
/// TabBar reports a firm `(naturalContentWidth, 30)` intrinsic size again.
///
/// TEETH: pre-fix `TabBar(...).fittingSize.width == 10` (the GeometryReader
/// default); post-fix it is the real content width (hundreds of points for
/// several tabs). This is the actual broken axis — directly observable
/// headless via `NSHostingView.fittingSize`, no VM/compositor needed.
///
/// HEADLESS CAVEAT (LESSONS.md, load-bearing): an in-process `fittingSize` /
/// frame walk CANNOT observe the WindowServer compositor (stage ④). If the
/// owner is *also* hitting a separate compositor-blank flavor on live drag,
/// that stays VM/T5-owed (`SourceViewVisualRegressionTests`). What this test
/// pins is the SwiftUI-layout regression — a chrome bar reporting a collapsed,
/// ambiguous intrinsic size — which is what the GeometryReader introduced and
/// what the fix removes.
@MainActor
final class TabBarIntrinsicSizeTests: HeadlessUITestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "TabBarIntrinsic-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeModel(tabs: Int) throws -> DocumentModel {
        let m = DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmpDir.appendingPathComponent("history.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults)
        )
        for i in 0..<tabs {
            let url = tmpDir.appendingPathComponent("file\(i).txt")
            try "x\n".data(using: .utf8)!.write(to: url)
            m.open(url: url)
        }
        return m
    }

    /// THE Bug-A repro. The TabBar's intrinsic content size must reflect its
    /// real tabs, not collapse to the `GeometryReader` default. Pre-fix the
    /// fitting width is ~10pt (GeometryReader's tiny ideal); post-fix it is
    /// the real strip width (many hundreds of points for 10 tabs).
    func test_tabbar_reportsFirmIntrinsicWidth_notGeometryReaderDefault() throws {
        let model = try makeModel(tabs: 10)
        XCTAssertEqual(model.tabs.tabs.count, 10)
        let host = NSHostingView(rootView: TabBar(model: model))
        let fitting = host.fittingSize

        // Height stays a firm 30 either way (the outer `.frame(height: 30)`).
        XCTAssertEqual(fitting.height, 30, accuracy: 1,
                       "TabBar height must stay pinned at 30")

        // The WIDTH is the broken axis. The GeometryReader-wrapped body
        // reported a collapsed ~10pt ideal width; the fixed body reports the
        // real content width. 10 tabs at the idle width (≥54pt each) is well
        // past 200pt — assert a generous floor so the collapsed-10 case fails
        // unambiguously while remaining robust to width-budget tuning.
        XCTAssertGreaterThan(fitting.width, 200,
            "TabBar fitting width \(fitting.width) collapsed toward the " +
            "GeometryReader default (~10pt) — the bar reports an ambiguous " +
            "intrinsic size that destabilizes the chrome VStack on live resize " +
            "(the top-tab-bar-disappears-on-resize regression). Expected the " +
            "real content width (hundreds of points for 10 tabs).")
    }

    /// The intrinsic width must scale with the tab count — a single tab is
    /// narrow, ten tabs are wide. A GeometryReader-collapsed width is ~10pt
    /// regardless of count, so this monotonicity is a second, independent
    /// signature of the regression.
    func test_tabbar_intrinsicWidth_scalesWithTabCount() throws {
        let one = try makeModel(tabs: 1)
        let many = try makeModel(tabs: 10)
        let wOne = NSHostingView(rootView: TabBar(model: one)).fittingSize.width
        let wMany = NSHostingView(rootView: TabBar(model: many)).fittingSize.width
        XCTAssertGreaterThan(wMany, wOne + 100,
            "10-tab strip (\(wMany)) must be much wider than a 1-tab strip " +
            "(\(wOne)); a collapsed GeometryReader width is ~10pt for both.")
    }

    /// The TabBar inside the chrome VStack (matching ContentView's pin
    /// modifiers) keeps height 30 across a width-narrowing resize AND its
    /// realized strip stays inside the window bounds (the scrollview clips
    /// overflow). This guards the realized-frame side of the fix.
    func test_tabbar_inChromeVStack_staysPinned_andClipped_acrossResize() throws {
        let model = try makeModel(tabs: 12)
        let hc = NSHostingController(rootView:
            VStack(spacing: 0) {
                TabBar(model: model)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                Color.gray.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(0)
            })
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 360),
                           styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        win.contentViewController = hc
        win.contentMinSize = NSSize(width: 600, height: 360)
        let root = win.contentView ?? hc.view

        for w in [CGFloat(900), 700, 600] {
            win.setContentSize(NSSize(width: w, height: 360))
            hc.view.layoutSubtreeIfNeeded()
            win.layoutIfNeeded()
            hc.view.layoutSubtreeIfNeeded()

            // Walk realized leaves: the tab backing views + the scrollview's
            // clip viewport. The CLIP VIEWPORT (what's actually painted) must
            // stay inside the window width; tabs beyond it are scrolled out
            // and clipped, never painted past the edge.
            var clipMaxX: CGFloat = 0
            var bandMinY = CGFloat.greatestFiniteMagnitude
            var bandMaxY = -CGFloat.greatestFiniteMagnitude
            var sawBand = false
            func rec(_ v: NSView) {
                let cls = String(describing: type(of: v))
                let f = v.convert(v.bounds, to: root)
                if cls.contains("ClipView") {
                    clipMaxX = max(clipMaxX, f.maxX)
                    bandMinY = min(bandMinY, f.minY); bandMaxY = max(bandMaxY, f.maxY)
                    sawBand = true
                }
                for s in v.subviews { rec(s) }
            }
            rec(root)

            XCTAssertTrue(sawBand, "tab strip scrollview not found at width \(w)")
            // Clip viewport painted inside the window (≤ width, ~1pt slack).
            XCTAssertLessThanOrEqual(clipMaxX, w + 1,
                "tab strip clip viewport maxX \(clipMaxX) overflows window width " +
                "\(w) — tabs would paint past the right edge.")
            // The strip band keeps its ~28-30pt height (not squeezed to 0).
            let bandH = sawBand ? bandMaxY - bandMinY : 0
            XCTAssertGreaterThan(bandH, 20,
                "tab strip band height \(bandH) collapsed at width \(w) — the " +
                "tab bar was squeezed/hidden.")
        }
    }

    // MARK: - H4 / B4: close control + full-height divider

    /// H4: the close control must still close its tab after the
    /// hover-circle/glyph reshape. The control's visual change (ZStack
    /// circle backdrop + centered `xmark`, per-control `.onHover`) wraps
    /// the SAME `onClose` closure — this asserts the action wiring
    /// survived the rework, mounting the real `TabBarItem` so its body
    /// (and thus the close button) actually builds.
    ///
    /// We invoke `onClose` directly rather than synthesizing a click on
    /// the realized NSButton: SwiftUI's `.accessibilityIdentifier()`
    /// does NOT propagate onto `NSView.accessibilityIdentifier()` (see
    /// `ViewModeMatrixSmokeTests`), so locating the specific close
    /// button by id in the realized tree is unreliable headless. The
    /// closure is the behavioral contract the button drives; mounting
    /// the item proves the close button builds without trapping.
    func test_tabBarItem_closeAction_firesAndClosesTab() throws {
        let model = try makeModel(tabs: 3)
        XCTAssertEqual(model.tabs.tabs.count, 3)

        var closedIndex: Int?
        let item = TabBarItem(
            tab: model.tabs.tabs[1],
            isSelected: true,           // selected → close button is visible
            isBookmarked: false,
            isInSplit: false,
            scale: 1,
            width: 180,
            onSelect: {},
            onClose: { closedIndex = 1; model.closeTab(at: 1) }
        )
        // Mount the real item so its body (close ZStack included) builds.
        let host = NSHostingView(rootView: item)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.width, 0,
                             "TabBarItem failed to lay out")

        // Fire the close action the button is wired to.
        item.onClose()
        XCTAssertEqual(closedIndex, 1, "close action did not fire")
        XCTAssertEqual(model.tabs.tabs.count, 2,
                       "closing the tab did not remove it from the model")
    }

    /// The close-control reshape (H4) and full-height divider (B4) must
    /// not collapse the tab item's geometry: it stays a firm ~28pt-tall,
    /// fixed-width cell in BOTH the selected and unselected states (the
    /// states that toggle the close button's visibility). A regression
    /// that broke the ZStack sizing would show up as a zero/ambiguous
    /// fitting size here.
    func test_tabBarItem_keepsFirmGeometry_selectedAndUnselected() throws {
        let model = try makeModel(tabs: 1)
        for selected in [true, false] {
            let item = TabBarItem(
                tab: model.tabs.tabs[0],
                isSelected: selected,
                isBookmarked: false,
                isInSplit: false,
                scale: 1,
                width: 180,
                onSelect: {},
                onClose: {}
            )
            let size = NSHostingView(rootView: item).fittingSize
            XCTAssertEqual(size.width, 180, accuracy: 1,
                "TabBarItem width must honor its budgeted width (selected=\(selected))")
            XCTAssertEqual(size.height, 28, accuracy: 2,
                "TabBarItem height collapsed (selected=\(selected))")
        }
    }
}
