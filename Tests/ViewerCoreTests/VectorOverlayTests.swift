import CoreGraphics
import XCTest
@testable import ViewerCore

/// T1 headless tests for the vector annotation overlay model (TSK-287). Pure
/// value-type logic — add / remove / move / z-order / serialize round-trip — so
/// it carries real host teeth; the SwiftUI draw path is the render-gated
/// remainder validated on the VM pixel lane.
final class VectorOverlayTests: XCTestCase {

    private func rect(_ id: UUID = UUID(), _ x: Double = 0, _ y: Double = 0,
                      _ w: Double = 0.2, _ h: Double = 0.2) -> VectorShape {
        VectorShape(id: id, kind: .rect,
                    frame: CGRect(x: x, y: y, width: w, height: h))
    }

    // MARK: - Add / count / read

    func testAddAppendsFrontMostAndReturnsId() {
        var overlay = VectorOverlay()
        XCTAssertTrue(overlay.isEmpty)
        let a = overlay.add(rect())
        let b = overlay.add(rect())
        XCTAssertEqual(overlay.count, 2)
        XCTAssertFalse(overlay.isEmpty)
        // Last added is front-most (highest index).
        XCTAssertEqual(overlay.index(of: a), 0)
        XCTAssertEqual(overlay.index(of: b), 1)
        XCTAssertNotNil(overlay.shape(id: a))
        XCTAssertEqual(overlay.shape(id: b)?.id, b)
    }

    func testRemoveByIdReportsFoundOrNot() {
        var overlay = VectorOverlay()
        let a = overlay.add(rect())
        overlay.add(rect())
        XCTAssertTrue(overlay.remove(id: a))
        XCTAssertEqual(overlay.count, 1)
        XCTAssertNil(overlay.shape(id: a))
        XCTAssertFalse(overlay.remove(id: a))          // already gone
        XCTAssertFalse(overlay.remove(id: UUID()))     // never existed
    }

    func testRemoveAllClears() {
        var overlay = VectorOverlay(shapes: [rect(), rect(), rect()])
        XCTAssertEqual(overlay.count, 3)
        overlay.removeAll()
        XCTAssertTrue(overlay.isEmpty)
    }

    // MARK: - Move (position)

    func testMoveTranslatesOrigin() {
        var overlay = VectorOverlay()
        let id = overlay.add(rect(UUID(), 0.1, 0.1, 0.2, 0.2))
        XCTAssertTrue(overlay.move(id: id, byX: 0.2, y: 0.3))
        let moved = overlay.shape(id: id)!
        XCTAssertEqual(moved.frame.origin.x, 0.3, accuracy: 1e-9)
        XCTAssertEqual(moved.frame.origin.y, 0.4, accuracy: 1e-9)
        // Size is preserved by a move.
        XCTAssertEqual(moved.frame.width, 0.2, accuracy: 1e-9)
        XCTAssertEqual(moved.frame.height, 0.2, accuracy: 1e-9)
    }

    func testMoveUnknownIdIsNoOp() {
        var overlay = VectorOverlay()
        overlay.add(rect())
        XCTAssertFalse(overlay.move(id: UUID(), byX: 0.5, y: 0.5))
    }

    func testMoveClampsOriginToUnitRange() {
        var overlay = VectorOverlay()
        let id = overlay.add(rect(UUID(), 0.9, 0.9, 0.2, 0.2))
        // Drag far past the bottom-right: origin clamps to 1, not beyond.
        overlay.move(id: id, byX: 5, y: 5)
        let s = overlay.shape(id: id)!
        XCTAssertEqual(s.frame.origin.x, 1, accuracy: 1e-9)
        XCTAssertEqual(s.frame.origin.y, 1, accuracy: 1e-9)
        // Drag far past the top-left: origin clamps to 0.
        overlay.move(id: id, byX: -5, y: -5)
        let s2 = overlay.shape(id: id)!
        XCTAssertEqual(s2.frame.origin.x, 0, accuracy: 1e-9)
        XCTAssertEqual(s2.frame.origin.y, 0, accuracy: 1e-9)
    }

    func testSetFrameAndSetStyle() {
        var overlay = VectorOverlay()
        let id = overlay.add(rect())
        XCTAssertTrue(overlay.setFrame(id: id, CGRect(x: 0.5, y: 0.5, width: 0.1, height: 0.1)))
        XCTAssertEqual(overlay.shape(id: id)?.frame.origin.x, 0.5)
        let style = ShapeStyle(stroke: .red, lineWidth: 5, fill: .white)
        XCTAssertTrue(overlay.setStyle(id: id, style))
        XCTAssertEqual(overlay.shape(id: id)?.style, style)
        XCTAssertFalse(overlay.setStyle(id: UUID(), style))
    }

    // MARK: - Z-order / hierarchy

    func testBringForwardSendBackwardSwapOneStep() {
        var overlay = VectorOverlay()
        let a = overlay.add(rect())   // index 0 (back)
        let b = overlay.add(rect())   // index 1
        let c = overlay.add(rect())   // index 2 (front)
        XCTAssertTrue(overlay.bringForward(id: a))   // a: 0 -> 1
        XCTAssertEqual([overlay.index(of: b), overlay.index(of: a), overlay.index(of: c)],
                       [0, 1, 2])
        XCTAssertTrue(overlay.sendBackward(id: a))   // a: 1 -> 0
        XCTAssertEqual([overlay.index(of: a), overlay.index(of: b), overlay.index(of: c)],
                       [0, 1, 2])
    }

    func testBringForwardAtFrontIsNoOp() {
        var overlay = VectorOverlay()
        overlay.add(rect())
        let front = overlay.add(rect())
        XCTAssertFalse(overlay.bringForward(id: front))   // already front-most
    }

    func testSendBackwardAtBackIsNoOp() {
        var overlay = VectorOverlay()
        let back = overlay.add(rect())
        overlay.add(rect())
        XCTAssertFalse(overlay.sendBackward(id: back))    // already back-most
    }

    func testBringToFrontAndSendToBack() {
        var overlay = VectorOverlay()
        let a = overlay.add(rect())   // 0
        let b = overlay.add(rect())   // 1
        let c = overlay.add(rect())   // 2
        XCTAssertTrue(overlay.bringToFront(id: a))        // a -> top
        XCTAssertEqual([overlay.index(of: b), overlay.index(of: c), overlay.index(of: a)],
                       [0, 1, 2])
        XCTAssertTrue(overlay.sendToBack(id: a))          // a -> bottom
        XCTAssertEqual([overlay.index(of: a), overlay.index(of: b), overlay.index(of: c)],
                       [0, 1, 2])
        // No-ops when already at the extreme.
        XCTAssertFalse(overlay.sendToBack(id: a))
        XCTAssertFalse(overlay.bringToFront(id: c))
        // Unknown id.
        XCTAssertFalse(overlay.bringToFront(id: UUID()))
        XCTAssertFalse(overlay.sendToBack(id: UUID()))
    }

    // MARK: - Open-shape endpoints

    func testOpenFrameStandardizesAndEndpointsRoundTrip() {
        // Endpoints given bottom-right -> top-left; openFrame standardizes.
        let frame = VectorShape.openFrame(
            from: CGPoint(x: 0.8, y: 0.9), to: CGPoint(x: 0.2, y: 0.1))
        let shape = VectorShape(kind: .arrow, frame: frame)
        // Standardized box has non-negative size; corners are the extremes.
        XCTAssertGreaterThanOrEqual(shape.frame.width, 0)
        XCTAssertGreaterThanOrEqual(shape.frame.height, 0)
        // `standardized` rebuilds corners by subtraction, so compare with a
        // float tolerance rather than bit-exact.
        XCTAssertEqual(shape.start.x, 0.2, accuracy: 1e-9)
        XCTAssertEqual(shape.start.y, 0.1, accuracy: 1e-9)
        XCTAssertEqual(shape.end.x, 0.8, accuracy: 1e-9)
        XCTAssertEqual(shape.end.y, 0.9, accuracy: 1e-9)
    }

    // MARK: - Color / style clamping

    func testOverlayColorClampsOutOfGamutComponents() {
        let c = OverlayColor(r: 2, g: -1, b: 0.5, a: 99)
        XCTAssertEqual(c.r, 1)
        XCTAssertEqual(c.g, 0)
        XCTAssertEqual(c.b, 0.5)
        XCTAssertEqual(c.a, 1)
        // Non-finite collapses to 0.
        XCTAssertEqual(OverlayColor(r: .nan, g: .infinity, b: 0, a: 1).r, 0)
        XCTAssertEqual(OverlayColor(r: .nan, g: .infinity, b: 0, a: 1).g, 0)
    }

    func testShapeStyleSanitizesLineWidth() {
        XCTAssertEqual(ShapeStyle(lineWidth: -5).lineWidth, 0)
        XCTAssertEqual(ShapeStyle(lineWidth: .nan).lineWidth, 0)
        XCTAssertEqual(ShapeStyle(lineWidth: 4).lineWidth, 4)
    }

    // MARK: - Serialize round-trip

    func testSerializeRoundTripPreservesShapesOrderAndIdentity() throws {
        var overlay = VectorOverlay()
        let a = overlay.add(VectorShape(
            kind: .rect, frame: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
            style: ShapeStyle(stroke: .red, lineWidth: 3, fill: .white)))
        let b = overlay.add(VectorShape(
            kind: .arrow,
            frame: VectorShape.openFrame(from: .init(x: 0.1, y: 0.1), to: .init(x: 0.5, y: 0.6)),
            style: ShapeStyle(stroke: .black, lineWidth: 2)))
        let c = overlay.add(VectorShape(
            kind: .ellipse, frame: CGRect(x: 0, y: 0, width: 1, height: 1)))

        let data = try overlay.jsonData()
        let restored = try VectorOverlay.decoded(from: data)

        XCTAssertEqual(restored, overlay)
        XCTAssertEqual(restored.count, 3)
        // Identity AND z-order survive the round-trip.
        XCTAssertEqual(restored.shapes.map(\.id), [a, b, c])
        XCTAssertEqual(restored.shape(id: b)?.kind, .arrow)
        XCTAssertEqual(restored.shape(id: a)?.style.fill, .white)
    }

    func testSerializeIsDeterministic() throws {
        let overlay = VectorOverlay(shapes: [
            VectorShape(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                        kind: .rect, frame: CGRect(x: 0, y: 0, width: 0.5, height: 0.5)),
        ])
        XCTAssertEqual(try overlay.jsonData(), try overlay.jsonData())
    }

    func testDecodeClampsCorruptColor() throws {
        // A hand-corrupted blob with out-of-gamut components must clamp on decode.
        let json = """
        {"shapes":[{"frame":[[0,0],[0.5,0.5]],"id":"\(UUID().uuidString)","kind":"rect",\
        "style":{"lineWidth":2,"stroke":{"a":5,"b":0,"g":0,"r":3}}}]}
        """
        let overlay = try VectorOverlay.decoded(from: Data(json.utf8))
        let stroke = overlay.shapes.first?.style.stroke
        XCTAssertEqual(stroke?.r, 1)
        XCTAssertEqual(stroke?.a, 1)
    }
}
