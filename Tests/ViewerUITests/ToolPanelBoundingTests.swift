import XCTest
import SwiftUI
import AppKit
@testable import ViewerUI
@testable import ViewerCore
import ViewerKit

/// P1 — TOOL-WINDOW BOUNDING (the owner's chrome bug).
///
/// THE BUG: opening the shoulder-rail tool panels jams them all into the
/// sidebar accordion, which had NO height ceiling and NO outer scroll
/// container. Each panel rendered a RIGID `.frame(height: 220)` body; once
/// a rich folder resolved ~7-8 panels visible, their summed ~1700pt demand
/// over-subscribed the sidebar band. SwiftUI resolved the impossible fit by
/// overflowing the center band, which shoved the window chrome
/// (TabBar / ModeBar / StatusBar) OUT — the StatusBar in particular got
/// pushed past the window's bottom edge (the owner's "footer/header pushed
/// out" report).
///
/// THE FIX (`SidebarView` + `SidebarPanelHeights`):
///   1. Each panel's body height is clamped to a fraction of the MEASURED
///      sidebar content height (`SidebarPanelHeights.clamp(_:availableHeight:)`)
///      so panels shrink toward the floor as the window shrinks.
///   2. The accordion + plugin run lives inside a `BoundedAccordionScroll`
///      that hugs its content up to a window-derived ceiling and SCROLLS
///      past it — N panels at their floor can never overflow the band.
///   3. The whole sidebar is `.clipped()` so a transient mis-fit can't
///      paint into the chrome.
///
/// WHY THE EXISTING `ChromeLayoutGateTests` DIDN'T CATCH IT: that harness
/// uses a `Color.clear` center band (0 ideal height) — it exercises an
/// UNDER-content squeeze (window smaller than the chrome). This bug is an
/// OVER-content squeeze: the center's CONTENT (the panels) demands more
/// than the window. The decisive difference here is that we host the REAL
/// `SidebarView` as the center band, with EVERY panel forced `.shown`.
///
/// TEETH — all three proved fail-before / pass-after by temporarily
/// reverting the fix in this branch's review:
///
///   * `test_allPanelsShown_panelsStayWithinSidebarBounds` (the load-bearing
///     "panels within bounds" assertion the brief asks for): walk the
///     realized NSView tree for the SHALLOW, full-width panel clip viewports.
///     Pre-fix the panels are direct VStack children and their viewports
///     overflow far past the sidebar's bounds (maxY ≈ 888 in a 280pt host);
///     post-fix the bounded accordion caps the shallow viewport at the host
///     height (the overflow moves DEEP, inside the bounded scroll).
///   * `test_allPanelsShown_sidebarReportsCompressibleHeight_notRigidPanelSum`:
///     the sidebar's fitting height must NOT be the ~1700pt rigid panel sum
///     (pre-fix 1583pt → post-fix bounded).
///   * `test_allPanelsShown_compositionFitsWindow_statusBarNotPushedOut`:
///     the FULL chrome+sidebar composition's fitting height must be
///     dominated by the chrome + a compressible center, not the rigid
///     accordion (pre-fix 1671pt → post-fix bounded). A composition whose
///     ideal height is ~1700pt can't satisfy the chrome bars' heights AND
///     the center within a normal window — the StatusBar gets pushed out.
///
/// HEADLESS CAVEAT (LESSONS.md, load-bearing): an in-process `fittingSize` /
/// frame walk CANNOT observe the WindowServer compositor (stage ④). The
/// live-window-resize repro stays VM/T5-owed. What these pin is the
/// SwiftUI-layout regression — the accordion over-subscribing its band —
/// which is the root cause of the chrome push-out.
@MainActor
final class ToolPanelBoundingTests: HeadlessUITestCase {

    private var tmpDir: URL!
    private var folderRoot: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "ToolPanelBounding-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        // A folder root so FILES + the data-presence panels have something
        // to render. A couple of files so the tree isn't a single line.
        folderRoot = tmpDir.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: folderRoot, withIntermediateDirectories: true)
        try "alpha\n".data(using: .utf8)!.write(to: folderRoot.appendingPathComponent("a.txt"))
        try "beta\n".data(using: .utf8)!.write(to: folderRoot.appendingPathComponent("b.txt"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// A model with a folder root open, a current source file (so the
    /// StatusBar renders), and EVERY sidebar panel forced `.shown` — the
    /// "jam them all in" condition that triggers the over-subscription.
    private func makeModelAllPanelsShown() throws -> DocumentModel {
        let m = DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmpDir.appendingPathComponent("history.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults)
        )
        // Open a plain-text source file (NSTextView path — keeps this in the
        // headless gate, no WKWebView). currentURL != nil → StatusBar present.
        m.open(url: folderRoot.appendingPathComponent("a.txt"))
        // A folder root so FILES + presence-gated panels render.
        m.sidebar.setRoot(folderRoot)
        // Force EVERY panel on (override .shown ignores data-presence) — this
        // is exactly the owner's "open all the tool windows" condition.
        for kind in SidebarPanelKind.allCases {
            m.panelLayout.setOverride(kind, .shown)
        }
        return m
    }

    private func sidebar(_ model: DocumentModel) -> SidebarView {
        SidebarView(
            sidebar: model.sidebar,
            model: model,
            trackedRepos: model.trackedRepos,
            panelLayout: model.panelLayout
        )
    }

    /// The composition under test: the three real chrome bars in the SAME
    /// VStack shape + the SAME pin modifiers as `ContentView.body`, but with
    /// the REAL `SidebarView` (inside an HStack standing in for the body row)
    /// as the center band — instead of `Color.clear`. This is what makes the
    /// over-content squeeze observable: the sidebar's panels are the content
    /// that over-subscribes.
    private struct ChromeWithSidebarHarness: View {
        @ObservedObject var model: DocumentModel
        var body: some View {
            VStack(spacing: 0) {
                TabBar(model: model)
                    .accessibilityIdentifier("mdv.tabbar")
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                Divider()
                // 2026-08-01: ModeBar deleted — ContentToolbar is the live
                // mid-band chrome (same height + padding arithmetic).
                ContentToolbar(model: model)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .accessibilityIdentifier("mdv.harness.toolbar")
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                Divider()
                // Center band: the REAL sidebar (with all panels shown) over
                // a flexible content placeholder, mirroring ContentView's
                // body row (sidebar | content). The sidebar is the subtree
                // that over-subscribed and pushed the chrome out.
                HStack(spacing: 0) {
                    SidebarView(
                        sidebar: model.sidebar,
                        model: model,
                        trackedRepos: model.trackedRepos,
                        panelLayout: model.panelLayout
                    )
                    .accessibilityIdentifier("mdv.sidebar")
                    Divider()
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(0)
                StatusBar(model: model, tabCoordinator: model.tabCoordinator, sourceView: model.sourceView)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
            }
        }
    }

    /// Walk the realized NSView tree of `host`; return the maximum bottom
    /// edge (in `host` coords) among the SHALLOW (depth ≤ `maxDepth`),
    /// full-width clip viewports — i.e. the sidebar's own structural scroll
    /// regions, NOT the inner panel scrolls nested inside the bounded
    /// accordion container.
    ///
    /// Pre-fix the accordion panels are direct children of the sidebar
    /// VStack, so their (shallow) clip viewports overflow the host bounds.
    /// Post-fix those panels live DEEP inside `BoundedAccordionScroll`, so
    /// the only shallow viewports are FILES + the bounded accordion
    /// container, both within the host.
    private func maxShallowClipBottom(_ host: NSView,
                                      maxDepth: Int,
                                      minWidth: CGFloat) -> CGFloat {
        var maxBottom: CGFloat = 0
        func rec(_ v: NSView, _ depth: Int) {
            let cls = String(describing: type(of: v))
            if cls.contains("ClipView") {
                let f = v.convert(v.bounds, to: host)
                if depth <= maxDepth, f.width >= minWidth, f.height > 0 {
                    maxBottom = max(maxBottom, f.maxY)
                }
            }
            for s in v.subviews { rec(s, depth + 1) }
        }
        rec(host, 0)
        return maxBottom
    }

    /// Settle the layout across a few passes — the sidebar measures its
    /// allotted height via a background GeometryReader that updates @State,
    /// which schedules another layout pass; the ceiling engages then.
    private func settle(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
    }

    // MARK: - Teeth #1: panels stay WITHIN the sidebar bounds (the brief's ask)

    func test_allPanelsShown_panelsStayWithinSidebarBounds() throws {
        // Small + normal sidebar bands (a 360pt window's center band is
        // ~280pt; a 650pt window's is ~570pt). Both are far below the
        // ~1700pt rigid-panel sum, so pre-fix the shallow panel viewports
        // overflow in both.
        for proposed in [CGSize(width: 240, height: 280),
                         CGSize(width: 240, height: 570)] {
            let model = try makeModelAllPanelsShown()
            let host = NSHostingView(rootView: sidebar(model))
            host.frame = NSRect(origin: .zero, size: proposed)
            settle(host)

            let maxBottom = maxShallowClipBottom(host, maxDepth: 6, minWidth: 150)
            // The shallow, full-width scroll viewports must stay within the
            // sidebar band (≤ host height, small slack). Pre-fix this is the
            // overflowing panel run (maxY ≈ 888 in a 280pt host) → FAILS.
            XCTAssertLessThanOrEqual(maxBottom, proposed.height + 2,
                "shallow sidebar scroll viewports overflow to maxY \(maxBottom) " +
                "in a \(proposed.height)pt sidebar — the tool panels are not " +
                "bounded to their region (they push past it into the chrome). " +
                "This is the owner's tool-window-pushes-chrome-out bug.")
            // Sanity: we DID find a real viewport (not a vacuous pass on an
            // empty walk). The bounded accordion + FILES always realize at
            // least one full-width clip viewport.
            XCTAssertGreaterThan(maxBottom, 0,
                "no full-width scroll viewport found — harness/walk broken.")
        }
    }

    // MARK: - Teeth #2: the sidebar reports a COMPRESSIBLE height

    func test_allPanelsShown_sidebarReportsCompressibleHeight_notRigidPanelSum() throws {
        let model = try makeModelAllPanelsShown()
        let proposed = CGSize(width: 240, height: 280)
        let host = NSHostingView(rootView: sidebar(model))
        host.frame = NSRect(origin: .zero, size: proposed)
        settle(host)

        // The realized sidebar view stays within the proposed height
        // (clipped + bounded). A rigid ~1700pt accordion would make the
        // hosting view content overflow; the bounds itself stays pinned by
        // the explicit frame, so the meaningful signal is fittingSize below.
        XCTAssertLessThanOrEqual(host.bounds.height, proposed.height + 2)

        // The FITTING height — the smallest size that fits the content's
        // ideal — must be compressible, NOT the rigid ~1700pt sum of 8 panels
        // at 220pt. The bounded accordion + clip cap it well under that.
        let fitting = host.fittingSize
        XCTAssertLessThan(fitting.height, 1200,
            "sidebar fitting height \(fitting.height) is dominated by the " +
            "rigid panel sum (8×220 ≈ 1700pt) — the panels are not bounded, " +
            "so the center band over-subscribes and pushes the chrome out.")
    }

    // MARK: - Teeth #3: the WHOLE composition stays satisfiable

    func test_allPanelsShown_compositionFitsWindow_statusBarNotPushedOut() throws {
        let model = try makeModelAllPanelsShown()
        let host = NSHostingView(rootView: ChromeWithSidebarHarness(model: model))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 650)
        settle(host)

        let fitting = host.fittingSize
        // The composition's ideal height = chrome bars (firm) + the center
        // band's ideal. With the bounded sidebar the center contributes a
        // compressible (small) ideal; with the rigid accordion it contributes
        // ~1700pt. Assert the whole composition stays well under that so the
        // VStack can satisfy the chrome bars' heights AND the center within a
        // normal window (the StatusBar isn't pushed past the bottom edge).
        XCTAssertLessThan(fitting.height, 1400,
            "full chrome+sidebar composition fitting height \(fitting.height) " +
            "is dominated by the rigid accordion — the center band can't yield, " +
            "so on a real window the StatusBar gets pushed past the bottom edge.")
    }
}
