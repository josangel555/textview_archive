import XCTest
import SwiftUI
import AppKit
@testable import ViewerUI
@testable import ViewerCore
import ViewerKit

/// SwiftUI-RASTER smoke for the terminal tab strip (TSK-488). Proves a
/// narrow thing: SwiftUI's OWN drawing of `TerminalPaneView` paints an
/// accent-coloured chip swatch on the configured edge. It does NOT — and
/// structurally CANNOT — prove the chip is VISIBLE in the live window.
///
/// ⚠️ WHY THIS IS NOT A VISIBILITY GUARD (owner: "test is broken" — it was a
/// false green): the real "gap but no tabs" bug was COMPOSITOR OCCLUSION.
/// The terminal surface is an opaque, layer-backed `NSViewRepresentable`
/// (`TerminalNSView`) that overdrew its sibling strip on the real screen.
/// `ImageRenderer` rasterizes SwiftUI's view tree in ISOLATION — it never
/// instantiates the real opaque AppKit layer (it draws a placeholder glyph
/// for the representable), so it renders the chips fine while the live window
/// is blank. It therefore passed green three times while the feature was
/// visibly broken. The actual on-screen-visibility guard is the T5
/// `TerminalTabStripVisualRegressionTests`, which reads the WindowServer
/// composite via `screencapture(1)`.
///
/// Kept (not deleted) because it still catches a real, distinct regression
/// class this raster CAN see: the chip being mis-coloured (e.g. unsaturated
/// so it blends into the rail) or dropped from the SwiftUI layout entirely.
/// Just don't mistake a green here for "the user can see the tabs."
@MainActor
final class TerminalTabStripRasterTests: HeadlessUITestCase {

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
            "no accent chip swatch in the LEFT rail of SwiftUI's raster — chip mis-coloured or dropped from layout (NOT a visibility check; see TerminalTabStripVisualRegressionTests)")
    }

    /// RIGHT strip: the chip paints in the RIGHT rail band.
    func test_rightStrip_chipPaintsOnRightEdge() throws {
        let rep = try renderPane(.right)
        XCTAssertTrue(hasSaturatedPixel(rep, x: (rep.pixelsWide - 48)..<rep.pixelsWide, y: 0..<rep.pixelsHigh),
            "no accent chip swatch in the RIGHT rail of SwiftUI's raster — chip mis-coloured or dropped from layout (NOT a visibility check; see TerminalTabStripVisualRegressionTests)")
    }

    /// TOP strip: the chip paints in the TOP band.
    func test_topStrip_chipPaintsOnTopEdge() throws {
        let rep = try renderPane(.top)
        XCTAssertTrue(hasSaturatedPixel(rep, x: 0..<rep.pixelsWide, y: 0..<44),
            "no accent chip swatch in the TOP band of SwiftUI's raster — chip mis-coloured or dropped from layout (NOT a visibility check; see TerminalTabStripVisualRegressionTests)")
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
