import XCTest
import CoreGraphics
@testable import ViewerCore

/// TSK-1059 — teeth for the drag-to-draw shape geometry (view points → normalized
/// bounding box). Pure; the gesture + live preview are the VM-validated remainder.
final class ShapeDragGeometryTests: XCTestCase {

    private let displayed = CGRect(x: 10, y: 20, width: 100, height: 200)

    func test_normalizedRect_mapsCornersToFractions() {
        // (35,70) → (0.25, 0.25); (85,170) → (0.75, 0.75)
        let r = ShapeDragGeometry.normalizedRect(
            from: CGPoint(x: 35, y: 70), to: CGPoint(x: 85, y: 170), in: displayed)
        XCTAssertEqual(r.minX, 0.25, accuracy: 0.001)
        XCTAssertEqual(r.minY, 0.25, accuracy: 0.001)
        XCTAssertEqual(r.width, 0.5, accuracy: 0.001)
        XCTAssertEqual(r.height, 0.5, accuracy: 0.001)
    }

    func test_normalizedRect_standardizesUpLeftDrag() {
        // Drag bottom-right → top-left still yields a positive-size rect.
        let r = ShapeDragGeometry.normalizedRect(
            from: CGPoint(x: 85, y: 170), to: CGPoint(x: 35, y: 70), in: displayed)
        XCTAssertEqual(r.minX, 0.25, accuracy: 0.001)
        XCTAssertEqual(r.minY, 0.25, accuracy: 0.001)
        XCTAssertGreaterThan(r.width, 0)
        XCTAssertGreaterThan(r.height, 0)
    }

    func test_normalizedRect_clampsOffEdgePoints() {
        // Points well outside the rect clamp into 0...1.
        let r = ShapeDragGeometry.normalizedRect(
            from: CGPoint(x: -50, y: -50), to: CGPoint(x: 500, y: 500), in: displayed)
        XCTAssertEqual(r.minX, 0, accuracy: 0.001)
        XCTAssertEqual(r.minY, 0, accuracy: 0.001)
        XCTAssertEqual(r.maxX, 1, accuracy: 0.001)
        XCTAssertEqual(r.maxY, 1, accuracy: 0.001)
    }

    func test_normalizedRect_degenerateDisplayed_isNull() {
        XCTAssertTrue(ShapeDragGeometry.normalizedRect(
            from: .zero, to: CGPoint(x: 1, y: 1), in: .zero).isNull)
    }

    func test_normalizedSignedRect_preservesDirection() {
        // Drag from bottom-left (35,170) → top-right (85,70): rightward + upward.
        let r = ShapeDragGeometry.normalizedSignedRect(
            from: CGPoint(x: 35, y: 170), to: CGPoint(x: 85, y: 70), in: displayed)
        XCTAssertEqual(r.origin.x, 0.25, accuracy: 0.001, "origin = the start point")
        XCTAssertEqual(r.origin.y, 0.75, accuracy: 0.001)
        // `size` is the RAW signed size (`.width`/`.height` would be absolute).
        XCTAssertGreaterThan(r.size.width, 0, "rightward → positive width")
        XCTAssertLessThan(r.size.height, 0, "upward → negative height (direction kept, not standardized)")
    }
}
