import XCTest
@testable import ViewerKit

/// Pure-logic coverage for image-preview zoom math. No AppKit
/// involved — runs on host (no UI test gating needed).
final class ImageZoomStateTests: XCTestCase {

    // MARK: - Clamping

    func testClampedFloor() {
        XCTAssertEqual(ImageZoomState.clamped(0.01),
                       ImageZoomState.minMagnification,
                       accuracy: 1e-9)
        XCTAssertEqual(ImageZoomState.clamped(-5),
                       ImageZoomState.minMagnification,
                       accuracy: 1e-9)
    }

    func testClampedCeiling() {
        XCTAssertEqual(ImageZoomState.clamped(50),
                       ImageZoomState.maxMagnification,
                       accuracy: 1e-9)
    }

    func testClampedInRangePassThrough() {
        XCTAssertEqual(ImageZoomState.clamped(1.0), 1.0, accuracy: 1e-9)
        XCTAssertEqual(ImageZoomState.clamped(2.5), 2.5, accuracy: 1e-9)
    }

    func testClampedHandlesNaNAndInfinity() {
        XCTAssertEqual(ImageZoomState.clamped(.nan), 1.0, accuracy: 1e-9)
        XCTAssertEqual(ImageZoomState.clamped(.infinity), 1.0, accuracy: 1e-9)
        XCTAssertEqual(ImageZoomState.clamped(-.infinity), 1.0, accuracy: 1e-9)
    }

    func testBoundaryValuesAreLegal() {
        XCTAssertEqual(ImageZoomState.clamped(ImageZoomState.minMagnification),
                       ImageZoomState.minMagnification, accuracy: 1e-9)
        XCTAssertEqual(ImageZoomState.clamped(ImageZoomState.maxMagnification),
                       ImageZoomState.maxMagnification, accuracy: 1e-9)
    }

    // MARK: - Incremental zoom

    func testNextMagnificationMultipliesAndClamps() {
        // 1.0 × 2.0 = 2.0, still in range
        XCTAssertEqual(
            ImageZoomState.nextMagnification(current: 1.0, factor: 2.0),
            2.0, accuracy: 1e-9)
        // 8.0 × 2.0 = 16.0 → clamped to max (10).
        XCTAssertEqual(
            ImageZoomState.nextMagnification(current: 8.0, factor: 2.0),
            ImageZoomState.maxMagnification, accuracy: 1e-9)
        // 0.2 × 0.25 = 0.05 → clamped to min (0.1).
        XCTAssertEqual(
            ImageZoomState.nextMagnification(current: 0.2, factor: 0.25),
            ImageZoomState.minMagnification, accuracy: 1e-9)
    }

    // MARK: - Focal-point math

    /// The canonical property: after the zoom, the image point that
    /// was under the focal cursor should still be under the focal
    /// cursor. We verify by re-projecting the document point through
    /// the new (origin, mag) and checking it lands on `focal`.
    func testFocalPointStaysUnderCursor() {
        let oldOrigin = CGPoint(x: 100, y: 80)
        let oldMag: CGFloat = 1.0
        let focal = CGPoint(x: 200, y: 150)
        let newMag: CGFloat = 2.0

        // Image point currently under the focal cursor in document
        // coordinates.
        let docPoint = CGPoint(
            x: (oldOrigin.x + focal.x) / oldMag,
            y: (oldOrigin.y + focal.y) / oldMag)

        let newOrigin = ImageZoomState.scrollOffsetForZoom(
            clipOrigin: oldOrigin, focal: focal,
            oldMag: oldMag, newMag: newMag)

        // Where does docPoint land in clip-view coords after the zoom?
        let projectedX = docPoint.x * newMag - newOrigin.x
        let projectedY = docPoint.y * newMag - newOrigin.y
        XCTAssertEqual(projectedX, focal.x, accuracy: 1e-6)
        XCTAssertEqual(projectedY, focal.y, accuracy: 1e-6)
    }

    func testFocalPointInvariantAcrossZoomOut() {
        let oldOrigin = CGPoint(x: 400, y: 300)
        let oldMag: CGFloat = 3.0
        let focal = CGPoint(x: 50, y: 50)
        let newMag: CGFloat = 1.5

        let docPoint = CGPoint(
            x: (oldOrigin.x + focal.x) / oldMag,
            y: (oldOrigin.y + focal.y) / oldMag)
        let newOrigin = ImageZoomState.scrollOffsetForZoom(
            clipOrigin: oldOrigin, focal: focal,
            oldMag: oldMag, newMag: newMag)
        let projectedX = docPoint.x * newMag - newOrigin.x
        let projectedY = docPoint.y * newMag - newOrigin.y
        XCTAssertEqual(projectedX, focal.x, accuracy: 1e-6)
        XCTAssertEqual(projectedY, focal.y, accuracy: 1e-6)
    }

    func testFocalPointZeroMagSafely() {
        // Degenerate input: returns clipOrigin unchanged instead of
        // dividing by zero.
        let origin = CGPoint(x: 10, y: 20)
        XCTAssertEqual(
            ImageZoomState.scrollOffsetForZoom(
                clipOrigin: origin, focal: .zero,
                oldMag: 0, newMag: 2),
            origin)
    }

    // MARK: - Fit-to-window scale

    func testFitScaleShrinksOversizeImage() {
        // 4000×3000 image into an 800×600 viewport: both ratios are
        // 0.2, so fit = 0.2.
        let fit = ImageZoomState.fitScale(
            image: CGSize(width: 4000, height: 3000),
            viewport: CGSize(width: 800, height: 600))
        XCTAssertEqual(fit, 0.2, accuracy: 1e-9)
    }

    func testFitScalePicksTighterAxis() {
        // Wide image: width ratio (1000/2000 = 0.5) is tighter than
        // height ratio (1000/500 = 2.0). min → 0.5.
        let fit = ImageZoomState.fitScale(
            image: CGSize(width: 2000, height: 500),
            viewport: CGSize(width: 1000, height: 1000))
        XCTAssertEqual(fit, 0.5, accuracy: 1e-9)
    }

    func testFitScaleNeverUpscalesByDefault() {
        // Small image in a big viewport: would-be fit is 2.0 but the
        // default (allowUpscale: false) caps at 1:1.
        let fit = ImageZoomState.fitScale(
            image: CGSize(width: 200, height: 200),
            viewport: CGSize(width: 400, height: 400))
        XCTAssertEqual(fit, 1.0, accuracy: 1e-9)
    }

    func testFitScaleUpscalesWhenRequested() {
        let fit = ImageZoomState.fitScale(
            image: CGSize(width: 200, height: 200),
            viewport: CGSize(width: 400, height: 400),
            allowUpscale: true)
        XCTAssertEqual(fit, 2.0, accuracy: 1e-9)
    }

    func testFitScaleClampsToMaxMagnification() {
        // Tiny image, huge viewport, upscaling on: raw fit would be 1000
        // but the band ceiling is 10×.
        let fit = ImageZoomState.fitScale(
            image: CGSize(width: 1, height: 1),
            viewport: CGSize(width: 1000, height: 1000),
            allowUpscale: true)
        XCTAssertEqual(fit, ImageZoomState.maxMagnification, accuracy: 1e-9)
    }

    func testFitScaleDegenerateInputs() {
        // Zero/negative dims → fall back to 1:1.
        XCTAssertEqual(
            ImageZoomState.fitScale(image: .zero,
                                    viewport: CGSize(width: 100, height: 100)),
            1.0, accuracy: 1e-9)
        XCTAssertEqual(
            ImageZoomState.fitScale(image: CGSize(width: 100, height: 100),
                                    viewport: .zero),
            1.0, accuracy: 1e-9)
    }

    // MARK: - Pan-bounds clamp

    /// Zoomed in (2×) on a 1000×1000 image in a 400×400 viewport: the
    /// visible span is 200×200 document units, so the legal origin range
    /// is 0…800 on each axis.
    func testClampPanWithinBounds() {
        let clamped = ImageZoomState.clampPan(
            proposedOrigin: CGPoint(x: 300, y: 500),
            viewport: CGSize(width: 400, height: 400),
            docFrame: CGSize(width: 1000, height: 1000),
            magnification: 2.0)
        // 300 and 500 are both inside 0…800 → unchanged.
        XCTAssertEqual(clamped.x, 300, accuracy: 1e-9)
        XCTAssertEqual(clamped.y, 500, accuracy: 1e-9)
    }

    func testClampPanClampsPastFarEdge() {
        let clamped = ImageZoomState.clampPan(
            proposedOrigin: CGPoint(x: 5000, y: 5000),
            viewport: CGSize(width: 400, height: 400),
            docFrame: CGSize(width: 1000, height: 1000),
            magnification: 2.0)
        // maxOrigin = doc - visible = 1000 - 200 = 800.
        XCTAssertEqual(clamped.x, 800, accuracy: 1e-9)
        XCTAssertEqual(clamped.y, 800, accuracy: 1e-9)
    }

    func testClampPanClampsPastNearEdge() {
        let clamped = ImageZoomState.clampPan(
            proposedOrigin: CGPoint(x: -300, y: -10),
            viewport: CGSize(width: 400, height: 400),
            docFrame: CGSize(width: 1000, height: 1000),
            magnification: 2.0)
        XCTAssertEqual(clamped.x, 0, accuracy: 1e-9)
        XCTAssertEqual(clamped.y, 0, accuracy: 1e-9)
    }

    /// When the scaled document is SMALLER than the viewport on an axis,
    /// that axis is pinned to the centering origin (negative) and the
    /// proposed value is ignored — you can't pan an axis that fully fits.
    func testClampPanCentersWhenDocFitsAxis() {
        // 200-wide doc, 400-wide viewport, 1× zoom: visible = 400 > 200.
        // Centering origin = (200 - 400) / 2 = -100. Whatever the user
        // proposes on X is overridden. Y axis: doc 1000 > visible 400,
        // so X is pinned, Y is clamped to 0…600.
        let clamped = ImageZoomState.clampPan(
            proposedOrigin: CGPoint(x: 999, y: 999),
            viewport: CGSize(width: 400, height: 400),
            docFrame: CGSize(width: 200, height: 1000),
            magnification: 1.0)
        XCTAssertEqual(clamped.x, -100, accuracy: 1e-9)
        XCTAssertEqual(clamped.y, 600, accuracy: 1e-9)  // maxOrigin = 1000-400
    }

    func testClampPanZeroMagSafely() {
        let origin = CGPoint(x: 7, y: 9)
        XCTAssertEqual(
            ImageZoomState.clampPan(
                proposedOrigin: origin,
                viewport: CGSize(width: 100, height: 100),
                docFrame: CGSize(width: 100, height: 100),
                magnification: 0),
            origin)
    }
}
