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
}
