import Testing
import CoreGraphics
@testable import ViewerCore

/// TSK-1088 / TSK-1441 — the pure image-editor viewport: zoom clamp, pan clamp,
/// the transformed content rect, pixel-under-cursor mapping, and grid/ruler
/// geometry. Host teeth; the gestures + drawing are the VM tail.
struct ImageViewportTests {

    private let fitted = CGRect(x: 100, y: 50, width: 400, height: 300)
    private let imageSize = CGSize(width: 200, height: 150)

    @Test func zoomClampsToBounds() {
        let vp = ImageViewport(minZoom: 1, maxZoom: 8)
        #expect(vp.withZoom(0.2).zoom == 1)     // floored at minZoom
        #expect(vp.withZoom(99).zoom == 8)      // capped at maxZoom
        #expect(vp.zoomed(by: 2).zoom == 2)
    }

    @Test func fitIsIdentity() {
        let vp = ImageViewport().zoomed(by: 3).panned(byX: 20, y: 20, in: fitted)
        let f = vp.fit()
        #expect(f.isFit)
        #expect(f.transformedRect(fitted: fitted) == fitted)
    }

    @Test func transformedRect_zoomScalesAboutCentre() {
        let vp = ImageViewport().withZoom(2)
        let r = vp.transformedRect(fitted: fitted)
        #expect(r.width == 800 && r.height == 600)      // 2× the fitted size
        #expect(r.midX == fitted.midX && r.midY == fitted.midY)  // same centre
    }

    @Test func panClampsToOverscroll_neverOffScreen() {
        // At 2× zoom the image overhangs by (400)/2 = 200 in x. A huge pan is
        // clamped to that, so the fitted rect is never fully uncovered.
        let vp = ImageViewport().withZoom(2).panned(byX: 10_000, y: 0, in: fitted)
        let r = vp.transformedRect(fitted: fitted)
        #expect(r.minX <= fitted.minX)   // left edge still at/left of the container
        #expect(r.maxX >= fitted.maxX)   // right edge still at/right of it
    }

    @Test func noPanWhenNotZoomed() {
        let vp = ImageViewport().panned(byX: 50, y: 50, in: fitted)
        // overscroll is 0 at zoom 1 → pan clamps to 0.
        #expect(vp.transformedRect(fitted: fitted) == fitted)
    }

    @Test func imagePixel_mapsCentreToImageCentre() {
        let vp = ImageViewport()
        let px = vp.imagePixel(at: CGPoint(x: fitted.midX, y: fitted.midY),
                               fitted: fitted, imageSize: imageSize)
        #expect(px?.x == 100 && px?.y == 75)   // centre → (w/2, h/2)
    }

    @Test func imagePixel_outsideReturnsNil() {
        let vp = ImageViewport()
        #expect(vp.imagePixel(at: CGPoint(x: 0, y: 0), fitted: fitted, imageSize: imageSize) == nil)
    }

    @Test func gridLines_spanTheImage() {
        let vp = ImageViewport()
        let g = vp.gridLines(fitted: fitted, imageSize: imageSize, spacingPx: 50)
        // 200px wide / 50 = lines at 0,50,100,150,200 → 5 verticals.
        #expect(g.vertical.count == 5)
        #expect(g.horizontal.count == 4)   // 150 / 50 = 0,50,100,150
        // First vertical is the left image edge, last is the right edge.
        #expect(g.vertical.first! == fitted.minX)
        #expect(g.vertical.last! == fitted.maxX)
    }

    @Test func rulerTicks_carryPixelValues() {
        let vp = ImageViewport()
        let t = vp.rulerTicks(fitted: fitted, imageSize: imageSize, stepPx: 100)
        #expect(t.x.map(\.px) == [0, 100, 200])
        #expect(t.x.first!.view == fitted.minX)
    }

    @Test func degenerateInputs_areSafe() {
        let vp = ImageViewport()
        #expect(vp.gridLines(fitted: fitted, imageSize: .zero, spacingPx: 10).vertical.isEmpty)
        #expect(vp.rulerTicks(fitted: fitted, imageSize: imageSize, stepPx: 0).x.isEmpty)
    }
}
