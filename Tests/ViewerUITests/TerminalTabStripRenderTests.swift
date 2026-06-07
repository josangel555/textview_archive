import XCTest
import SwiftUI
import AppKit
@testable import ViewerUI
@testable import ViewerCore
import ViewerKit

/// Headless VISIBILITY coverage for the terminal tab strip (TSK-488 / owner
/// "I see a gap but no tabs"). The model layer (`TerminalPaneStoreTests`)
/// proves the store always has ≥1 tab; the earlier frame-walk proved the
/// chips occupy layout space — but BOTH were satisfied while the chips were
/// invisible on screen, because they were wrapped in a `ScrollView` whose
/// content does not paint here. The real signal is PIXELS.
///
/// `ImageRenderer` rasterizes SwiftUI's OWN drawing — colors included —
/// unlike `cacheDisplay` (which doesn't capture SwiftUI CA layers) or an
/// `NSView` frame walk (which sees layout, not paint). The selected chip is
/// the user's vivid ACCENT colour; the rail background is unsaturated
/// (grey/white). So "a highly-saturated pixel in the strip's edge band"
/// proves the chip actually painted, AND its location proves the strip is on
/// the configured edge.
///
/// The terminal surface is an `NSViewRepresentable`; `ImageRenderer` draws a
/// placeholder (a saturated red glyph) for it, CENTERED — so each test scans
/// only the thin EDGE band where the chip lives and the centered placeholder
/// never reaches.
@MainActor
final class TerminalTabStripRenderTests: HeadlessUITestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "TermStripRender-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }
    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private let W = 400, H = 240

    /// LEFT strip (default): the selected chip paints a saturated swatch in
    /// the LEFT rail band.
    func test_leftStrip_chipPaintsOnLeftEdge() throws {
        let rep = try renderPane(.left)
        // The LEFT rail band contains the chip; the surface is on the right,
        // so its centered placeholder never reaches x<48 — a saturated pixel
        // here is the chip.
        XCTAssertTrue(hasSaturatedPixel(rep, x: 0..<48, y: 0..<rep.pixelsHigh),
            "no saturated chip swatch in the LEFT rail — the strip isn't painting")
    }

    /// RIGHT strip: the chip paints in the RIGHT rail band.
    func test_rightStrip_chipPaintsOnRightEdge() throws {
        let rep = try renderPane(.right)
        XCTAssertTrue(hasSaturatedPixel(rep, x: (rep.pixelsWide - 48)..<rep.pixelsWide, y: 0..<rep.pixelsHigh),
            "no saturated chip swatch in the RIGHT rail — the strip isn't painting")
    }

    /// TOP strip: the chip paints in the TOP band.
    func test_topStrip_chipPaintsOnTopEdge() throws {
        let rep = try renderPane(.top)
        XCTAssertTrue(hasSaturatedPixel(rep, x: 0..<rep.pixelsWide, y: 0..<44),
            "no saturated chip swatch in the TOP band — the strip isn't painting")
    }

    /// A single tab (no `addTab`) must STILL paint a chip (owner: "even if
    /// only one tab, show tab").
    func test_singleTab_stillPaintsChip() throws {
        let rep = try renderPane(.left, tabs: 1)
        XCTAssertTrue(hasSaturatedPixel(rep, x: 0..<48, y: 0..<rep.pixelsHigh),
            "a single selected tab must still paint a visible chip")
    }

    // MARK: - Harness

    /// Rasterize `TerminalPaneView` (terminal open, `tabs` tabs, last one
    /// selected) at the given strip position via `ImageRenderer`.
    private func renderPane(_ pos: TerminalTabPosition, tabs: Int = 2) throws -> NSBitmapImageRep {
        let store = TerminalPaneStore(defaults: defaults)
        store.setOpen(true)
        store.setTabPosition(pos)
        for _ in 1..<tabs { store.addTab() }
        defer { store.shutdown() }

        let view = TerminalPaneView(store: store, fontSize: 13)
            .frame(width: CGFloat(W), height: CGFloat(H))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        guard let img = renderer.nsImage,
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else {
            throw XCTSkip("ImageRenderer produced no image")
        }
        return rep
    }

    /// True if any pixel in the box is highly saturated (a vivid chip swatch).
    /// The rail background (grey/white) and the title-bar chrome are
    /// unsaturated, so this isolates the accent-selected chip.
    private func hasSaturatedPixel(_ rep: NSBitmapImageRep, x xs: Range<Int>, y ys: Range<Int>) -> Bool {
        let xr = xs.clamped(to: 0..<rep.pixelsWide)
        let yr = ys.clamped(to: 0..<rep.pixelsHigh)
        for x in xr {
            for y in yr {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let r = c.redComponent, g = c.greenComponent, b = c.blueComponent
                if max(r, g, b) - min(r, g, b) > 0.35 { return true }
            }
        }
        return false
    }
}
