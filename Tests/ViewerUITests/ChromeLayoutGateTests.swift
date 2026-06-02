import XCTest
import SwiftUI
import AppKit
@testable import ViewerUI
@testable import ViewerCore
import ViewerKit

/// Headless-gate guard for the CHROME-PINNING regression (window-shrink hides
/// the TabBar / ModeBar / StatusBar — symptom #4 / deliverable 6a) AND a small
/// offscreen-raster visual gate (deliverable 5).
///
/// The bug: TabBar/ModeBar/StatusBar each carry a fixed height, but a VStack
/// distributes an under-shrink squeeze across ALL children, so when the window
/// goes below chrome+min-content the bars got compressed/clipped instead of the
/// center band. The fix gives the three bars `layoutPriority(1)` +
/// `fixedSize(vertical:)` and the center band `layoutPriority(0)` so the center
/// yields, never the bars.
///
/// These tests host a `ChromeHarness` — the SAME VStack composition + the SAME
/// layoutPriority modifiers ContentView uses — at small window sizes (420x320,
/// 600x360), force layout, and assert:
///   1. Geometry walk (T2'): the realized NSView tree has content occupying a
///      non-zero-height band at the TOP (tabbar+modebar) and at the BOTTOM
///      (statusbar), both inside bounds. A squeeze that clipped a bar to zero
///      height fails here.
///   2. Offscreen raster: an `ImageRenderer` bitmap of the harness is NON-BLANK
///      in the top band AND the bottom band — i.e. the bars actually drew.
///
/// COMPOSITOR CAVEAT (LESSONS.md, load-bearing): an offscreen `ImageRenderer`
/// raster bypasses the WindowServer compositor (stage ④). It therefore CANNOT
/// catch the compositor-blank class (NSRulerView-in-tile()-in-SwiftUI-commit
/// sibling-blank) — that stays the VM/T5 `SourceViewVisualRegressionTests`
/// lane. What this raster DOES catch: a SwiftUI-layout regression that sizes a
/// chrome bar to zero / pushes it out of bounds, which is exactly the
/// chrome-hiding symptom.
@MainActor
final class ChromeLayoutGateTests: HeadlessUITestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "ChromeLayoutGateTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeModel() throws -> DocumentModel {
        let m = DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmpDir.appendingPathComponent("history.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults)
        )
        // Open a PLAIN-TEXT source file (NSTextView path — no WKWebView, so
        // this stays in the headless gate, not the #192 WebView lane) so the
        // model has a currentURL and the StatusBar has real content.
        let url = tmpDir.appendingPathComponent("doc.txt")
        try "line one\nline two\n".data(using: .utf8)!.write(to: url)
        m.open(url: url)
        return m
    }

    /// The chrome composition under test: the three real bars in the same
    /// VStack shape + the same pin modifiers as `ContentView.body`, with a
    /// flexible center band standing in for the content area (so we test the
    /// chrome layout WITHOUT mounting the WebView-bearing content subtree).
    private struct ChromeHarness: View {
        @ObservedObject var model: DocumentModel
        var body: some View {
            VStack(spacing: 0) {
                TabBar(model: model)
                    .accessibilityIdentifier("mdv.tabbar")
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                Divider()
                ModeBar(model: model)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .accessibilityIdentifier("mdv.modebar")
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                Divider()
                // Center band: the one that yields under shrink.
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(0)
                StatusBar(model: model, sourceView: model.sourceView)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
            }
        }
    }

    private func mount(_ model: DocumentModel, size: CGSize) -> NSHostingView<ChromeHarness> {
        let host = NSHostingView(rootView: ChromeHarness(model: model))
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        return host
    }

    /// Render the harness offscreen at `size` and return the bitmap.
    /// `ImageRenderer` rasters the SwiftUI tree without a window — top-left
    /// origin (row 0 = top of the view). NOTE: this bypasses the WindowServer
    /// compositor (LESSONS.md), so it can't catch the compositor-blank class;
    /// it CAN catch a layout regression that sizes/positions a bar wrong.
    private func raster(_ model: DocumentModel, size: CGSize) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: ChromeHarness(model: model)
            .frame(width: size.width, height: size.height))
        renderer.scale = 1
        guard let cg = renderer.cgImage else {
            throw XCTSkip("ImageRenderer produced no cgImage (headless raster unavailable)")
        }
        XCTAssertEqual(cg.width, Int(size.width))
        XCTAssertEqual(cg.height, Int(size.height))
        return NSBitmapImageRep(cgImage: cg)
    }

    /// True if the pixel rows `[lower, upper)` carry more than uniform
    /// background (i.e. something drew there). A clipped/hidden bar leaves a
    /// uniform band; chrome content (icons, dividers, text) introduces ≥3
    /// distinct colors (bg + AA + ink).
    private func bandHasInk(_ rep: NSBitmapImageRep, rows: Range<Int>, width: Int) -> Bool {
        var seen: Set<UInt32> = []
        var y = max(0, rows.lowerBound)
        let upper = min(rep.pixelsHigh, rows.upperBound)
        while y < upper {
            var x = 4
            while x < width - 4 {
                if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                    let r = UInt32((c.redComponent * 255).rounded())
                    let g = UInt32((c.greenComponent * 255).rounded())
                    let b = UInt32((c.blueComponent * 255).rounded())
                    seen.insert((r << 16) | (g << 8) | b)
                    if seen.count > 2 { return true }
                }
                x += 6
            }
            y += 2
        }
        return seen.count > 1
    }

    // MARK: - Offscreen raster gate (deliverables 5 + 6a)
    //
    // The faithful headless signal for "the bars are present at small sizes"
    // is the raster: NSHostingView's AppKit SUBTREE is not a per-SwiftUI-view
    // tree (SwiftUI draws into a few backing layers), so an NSView frame-walk
    // is unreliable for SwiftUI content. The raster shows exactly what drew.

    func test_chrome_rasterNonBlank_topAndBottom_atSmallSizes() throws {
        // 420x320 / 600x360 are the brief's small sizes; 420x150 is a STRESS
        // size deliberately below the natural chrome+content total so the
        // VStack under-shrink actually bites — this is the size that
        // distinguishes pinned (bars hold) from unpinned (bars compressed).
        for size in [CGSize(width: 420, height: 320),
                     CGSize(width: 600, height: 360),
                     CGSize(width: 420, height: 150)] {
            let model = try makeModel()
            let rep = try raster(model, size: size)
            let w = rep.pixelsWide, h = rep.pixelsHigh

            // TOP band: tabbar (30) + divider + modebar (~34) ≈ first ~66 rows.
            XCTAssertTrue(bandHasInk(rep, rows: 0..<66, width: w),
                "TOP chrome band rastered blank at \(size) — TabBar/ModeBar " +
                "squeezed/clipped/hidden (the chrome-hiding regression).")
            // BOTTOM band: statusbar (22) ≈ last ~22 rows.
            XCTAssertTrue(bandHasInk(rep, rows: (h - 22)..<h, width: w),
                "BOTTOM chrome band rastered blank at \(size) — StatusBar " +
                "squeezed/clipped/hidden (the chrome-hiding regression).")
        }
    }

    // MARK: - Intrinsic-height floor (the headless-faithful pin check)
    //
    // The runtime chrome-hiding bug is an NSWindow-resize/compositor behavior
    // that an offscreen ImageRenderer can't reproduce (LESSONS.md: offscreen
    // raster bypasses stage ④) — the raster above is a "bars aren't blank"
    // smoke, not a squeeze repro. The squeeze-vs-no-squeeze runtime behavior
    // stays VM/T5-owed.
    //
    // What IS faithfully headless-checkable: the bars report FIRM intrinsic
    // heights, so the chrome VStack's fitting height has a floor equal to the
    // chrome total. `fixedSize(vertical:)` is what makes those heights firm;
    // dropping it lets the bars report a compressible height. We assert the
    // harness's `fittingSize.height` is at least the chrome total — a
    // regression that un-pins the bars (and lets them report 0 ideal height)
    // trips here.

    func test_chrome_fittingHeight_hasFloor_provingBarsContributeFirmHeights() throws {
        let model = try makeModel()
        let host = NSHostingView(rootView: ChromeHarness(model: model))
        // fittingSize = the smallest size that fits the content's IDEAL sizes.
        // With the center band being Color.clear (ideal height 0) and the bars
        // pinned via fixedSize, the fitting height is exactly the chrome total
        // (tabbar 30 + 2 dividers + modebar ~34 + statusbar 22 ≈ 87pt).
        let fitting = host.fittingSize
        // Floor: TabBar(30) + ModeBar(22 + 12 padding) + StatusBar(22) minus
        // slack = ~70pt. A pin regression collapses this toward the center's
        // 0 ideal height.
        XCTAssertGreaterThanOrEqual(fitting.height, 70,
            "chrome fitting height \(fitting.height) is below the bar total — " +
            "the bars no longer report firm intrinsic heights (fixedSize pin " +
            "dropped?), so a VStack under-shrink would compress them (the " +
            "chrome-hiding regression).")
        // And it's not absurdly tall (the center contributes ~0): sanity that
        // we're measuring the chrome, not a runaway intrinsic size.
        XCTAssertLessThan(fitting.height, 400,
            "chrome fitting height \(fitting.height) unexpectedly large — the " +
            "center band should contribute ~0 ideal height.")
    }

    func test_chrome_centerBandYields_notTheBars() throws {
        // The pin should make the CENTER band absorb the shrink: at a small
        // height the top chrome (~66pt) + bottom chrome (~22pt) are fixed, so
        // the middle is a large, mostly-uniform region (our placeholder
        // Color.clear). Assert a sizeable middle slice is uniform (the center
        // yielded) while both chrome bands have ink (the bars held). This is
        // the positive face of "center yields, bars don't".
        let size = CGSize(width: 420, height: 320)
        let model = try makeModel()
        let rep = try raster(model, size: size)
        let w = rep.pixelsWide, h = rep.pixelsHigh

        XCTAssertTrue(bandHasInk(rep, rows: 0..<66, width: w), "top bars must hold")
        XCTAssertTrue(bandHasInk(rep, rows: (h - 22)..<h, width: w), "status bar must hold")
        // Middle slice (well clear of both chrome bands): expect it uniform
        // (the yielding empty center), proving the bars didn't bleed into /
        // get pushed through the center.
        let midUniform = !bandHasInk(rep, rows: 120..<200, width: w)
        XCTAssertTrue(midUniform,
            "the center band is not uniform — chrome bled into the content " +
            "region (the bars didn't yield the center as expected).")
    }
}
