import XCTest
import SwiftUI
import AppKit
@testable import ViewerUI
@testable import ViewerCore
import ViewerKit

/// UX-F (#228) — zoom-scaling teeth for the window chrome.
///
/// The app scales chrome via `DocumentModel.uiSize(_:)` (== `base * zoom`).
/// Many bars/rows historically pinned their VERTICAL extent (`.frame(height:
/// 22/30)`), their internal paddings, and their icon frames at fixed points,
/// so a Cmd-+ zoom grew the text but NOT the row that contained it — the
/// "vertical heights don't grow proportionally" artifact the owner reported.
///
/// These tests mount each chrome bar (and the tab cell) at zoom 1.0 vs a
/// higher zoom and assert the intrinsic HEIGHT scales up roughly in
/// proportion. They use the same headless `NSHostingView.fittingSize` measure
/// as `TabBarIntrinsicSizeTests` — no VM / compositor needed (LESSONS.md: an
/// in-process fitting-size walk can't observe stage ④, but intrinsic SwiftUI
/// layout is exactly what we're pinning here).
///
/// Tolerance note: a bar's height is `chrome metric * zoom` PLUS a small
/// zoom-invariant constant (the 1pt top divider overlay, hairline insets).
/// So the ratio is slightly below the raw zoom factor. We assert the scaled
/// height is meaningfully taller than the base (well past any constant slack)
/// AND within a band around the ideal `base * zoom`, which catches both the
/// "didn't scale at all" regression and a "scaled by the wrong factor" bug.
@MainActor
final class ChromeZoomScalingTests: HeadlessUITestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "ChromeZoom-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// A model with one open text file (so the bars have real content to lay
    /// out) at the requested zoom level.
    private func makeModel(zoom: Double) throws -> DocumentModel {
        let m = DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmpDir.appendingPathComponent("history.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults)
        )
        let url = tmpDir.appendingPathComponent("doc.swift")
        try "let x = 1\nlet y = 2\n".data(using: .utf8)!.write(to: url)
        m.open(url: url)
        m.zoom = zoom
        return m
    }

    /// Measure a view's intrinsic height by mounting it in an NSHostingView.
    private func fittingHeight<V: View>(_ view: V) -> CGFloat {
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    /// Core assertion: `scaledH` is the height at `zoom`, `baseH` is at 1.0.
    /// We expect `scaledH ≈ baseH * zoom`, give or take the zoom-invariant
    /// constant (divider/hairline). Assert:
    ///   • it actually grew well past the base (not the "didn't scale" bug), and
    ///   • the ratio sits in a sane band around `zoom` (not off by 2×).
    private func assertScales(
        baseH: CGFloat, scaledH: CGFloat, zoom: Double,
        label: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertGreaterThan(baseH, 0, "\(label): base height was zero — view failed to lay out",
                             file: file, line: line)
        // Must have grown. The smallest scaling metric we expect to dominate is
        // the ~20pt row height; at zoom 2.0 that alone adds ~20pt, far past any
        // few-pt constant. Require at least a third of the ideal increase so a
        // mostly-pinned bar (only fonts scaled) still fails.
        let idealDelta = baseH * (CGFloat(zoom) - 1)
        XCTAssertGreaterThan(
            scaledH - baseH, idealDelta * 0.33,
            "\(label): height barely grew (\(baseH) → \(scaledH)) at zoom \(zoom). " +
            "The bar's vertical extent / paddings are still pinned — they must " +
            "route through model.uiSize(_:).",
            file: file, line: line)
        // And not overshoot wildly: within ±25% of the ideal `base*zoom`.
        let ideal = baseH * CGFloat(zoom)
        XCTAssertEqual(
            scaledH, ideal, accuracy: ideal * 0.25,
            "\(label): scaled height \(scaledH) is far from the ideal " +
            "\(ideal) (= base \(baseH) × zoom \(zoom)).",
            file: file, line: line)
    }

    // MARK: - Bars (owner "for sure": ContentToolbar, BottomAttributesBar) + footer

    func test_contentToolbar_heightScalesWithZoom() throws {
        let z = 2.0
        let baseH = fittingHeight(ContentToolbar(model: try makeModel(zoom: 1.0)))
        let scaledH = fittingHeight(ContentToolbar(model: try makeModel(zoom: z)))
        assertScales(baseH: baseH, scaledH: scaledH, zoom: z, label: "ContentToolbar")
    }

    func test_bottomAttributesBar_heightScalesWithZoom() throws {
        let z = 2.0
        // Editor mode so the Wrap / Special-chars toggles are present.
        let m1 = try makeModel(zoom: 1.0); m1.setCurrentViewMode(.editor)
        let m2 = try makeModel(zoom: z);   m2.setCurrentViewMode(.editor)
        let baseH = fittingHeight(BottomAttributesBar(model: m1))
        let scaledH = fittingHeight(BottomAttributesBar(model: m2))
        assertScales(baseH: baseH, scaledH: scaledH, zoom: z, label: "BottomAttributesBar")
    }

    func test_statusBar_heightScalesWithZoom() throws {
        let z = 2.0
        let m1 = try makeModel(zoom: 1.0)
        let m2 = try makeModel(zoom: z)
        let baseH = fittingHeight(
            StatusBar(model: m1, tabCoordinator: m1.tabCoordinator, sourceView: m1.sourceView))
        let scaledH = fittingHeight(
            StatusBar(model: m2, tabCoordinator: m2.tabCoordinator, sourceView: m2.sourceView))
        assertScales(baseH: baseH, scaledH: scaledH, zoom: z, label: "StatusBar")
    }

    // MARK: - Tab row (owner "for sure": TAB rows grow vertically)

    func test_tabBar_heightScalesWithZoom() throws {
        let z = 2.0
        let baseH = fittingHeight(TabBar(model: try makeModel(zoom: 1.0)))
        let scaledH = fittingHeight(TabBar(model: try makeModel(zoom: z)))
        assertScales(baseH: baseH, scaledH: scaledH, zoom: z, label: "TabBar")
    }

    /// The tab CELL itself (`TabBarItem`) carries the row height; its `scale`
    /// param is the zoom factor. Mounting it at scale 1 vs 2 must roughly
    /// double the cell height (28 → 56). This is the direct teeth for the
    /// `.frame(height: 28 * scale)` change.
    func test_tabBarItem_cellHeightScalesWithScale() throws {
        let model = try makeModel(zoom: 1.0)
        let tab = model.tabs.tabs[0]
        func item(_ scale: CGFloat) -> TabBarItem {
            TabBarItem(tab: tab, isSelected: false, isBookmarked: false,
                       isInSplit: false,
                       scale: scale, width: 180, onSelect: {}, onClose: {})
        }
        let h1 = fittingHeight(item(1))
        let h2 = fittingHeight(item(2))
        XCTAssertEqual(h1, 28, accuracy: 2, "TabBarItem base height should be ~28")
        // 28 → ~56; allow generous slack for text/line metrics.
        XCTAssertEqual(h2, 56, accuracy: 8,
            "TabBarItem cell height \(h2) did not scale with the zoom factor " +
            "(expected ~56 at scale 2; the .frame(height: 28*scale) must scale).")
    }

    // MARK: - File-tree icon (owner "for sure": file-nav tree row ICONS)

    /// The shared icon's square side must scale linearly with the zoom factor,
    /// and callers size their wrapping frame off `FileIconView.side(...)`. This
    /// is the pure-logic teeth for the tree-row-icon fix (the icon view itself
    /// is value-only, so we assert the helper that drives both its internal
    /// metrics and the call-site frame).
    func test_fileIconView_sideScalesLinearlyWithZoom() {
        let base = FileIconView.side(for: .tree, scale: 1)
        XCTAssertEqual(base, 16, accuracy: 0.001, "tree icon base side should be 16pt")
        XCTAssertEqual(FileIconView.side(for: .tree, scale: 2), 32, accuracy: 0.001,
                       "tree icon side must double at scale 2")
        XCTAssertEqual(FileIconView.side(for: .row, scale: 1.5), 30, accuracy: 0.001,
                       "row icon side must scale: 20 × 1.5 = 30")
        // Mounting the icon at scale 2 yields a ~32×32 box (frame-clip free).
        let host = NSHostingView(rootView:
            FileIconView(url: URL(fileURLWithPath: "/tmp/a.swift"),
                         isDirectory: false, size: .tree, scale: 2)
                .frame(width: FileIconView.side(for: .tree, scale: 2),
                       height: FileIconView.side(for: .tree, scale: 2)))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.fittingSize.height, 32, accuracy: 1,
                       "scaled tree icon should mount ~32pt tall, not clip to 16")
    }
}
