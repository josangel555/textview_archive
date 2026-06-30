import XCTest
import CoreGraphics
@testable import ViewerCore

/// TSK-1310 — the retained text-overlay element model. A `.text` VectorShape carries an editable
/// string + font size (distinct from the one-shot `.drawText` raster op, which bakes into pixels);
/// it round-trips through Codable, and the geometric kinds keep nil text/fontSize so existing
/// persisted overlays decode unchanged (a missing key → nil).
final class VectorShapeTextTests: XCTestCase {

    func test_textShape_roundTripsTextAndFontSize_TSK1310() throws {
        let shape = VectorShape(
            kind: .text, frame: CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.12),
            style: ShapeStyle(stroke: .red, lineWidth: 1), text: "Hello", fontSize: 0.08)
        let back = try JSONDecoder().decode(VectorShape.self, from: try JSONEncoder().encode(shape))
        XCTAssertEqual(back.kind, .text)
        XCTAssertEqual(back.text, "Hello")
        XCTAssertEqual(back.fontSize, 0.08)
        XCTAssertEqual(back, shape, "a .text shape must round-trip identically")
    }

    func test_geometricShape_hasNilTextFields_andRoundTrips_TSK1310() throws {
        let rect = VectorShape(kind: .rect, frame: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3))
        XCTAssertNil(rect.text)
        XCTAssertNil(rect.fontSize)
        let back = try JSONDecoder().decode(VectorShape.self, from: try JSONEncoder().encode(rect))
        XCTAssertEqual(back, rect)
        XCTAssertNil(back.text, "geometric kinds carry no text")
        XCTAssertNil(back.fontSize)
    }

    func test_textKind_isCaseIterable_TSK1310() {
        XCTAssertTrue(VectorShape.Kind.allCases.contains(.text),
            "the .text kind must be enumerable (drives the shape-tool list)")
    }

    func test_rotation_roundTrips_andDefaultsNil_TSK1321() throws {
        let plain = VectorShape(kind: .rect, frame: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3))
        XCTAssertNil(plain.rotation, "rotation defaults to nil (unrotated)")
        let rotated = VectorShape(
            kind: .rect, frame: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3),
            rotation: 45)
        let back = try JSONDecoder().decode(VectorShape.self, from: try JSONEncoder().encode(rotated))
        XCTAssertEqual(back.rotation, 45)
        XCTAssertEqual(back, rotated)
    }

    func test_overlaySetRotation_updatesTheShape_TSK1321() {
        var overlay = VectorOverlay()
        let id = overlay.add(VectorShape(kind: .rect, frame: CGRect(x: 0, y: 0, width: 0.5, height: 0.5)))
        XCTAssertTrue(overlay.setRotation(id: id, 90))
        XCTAssertEqual(overlay.shapes.first?.rotation, 90)
        XCTAssertFalse(overlay.setRotation(id: UUID(), 30), "unknown id is a no-op")
    }

    func test_textStyle_roundTrips_andDefaultsNil_TSK1310() throws {
        let plain = VectorShape(kind: .text, frame: .zero, text: "x")
        XCTAssertNil(plain.bold, "font style defaults to nil (regular)")
        XCTAssertNil(plain.italic)
        let styled = VectorShape(kind: .text, frame: .zero, text: "x", bold: true, italic: true)
        let back = try JSONDecoder().decode(VectorShape.self, from: try JSONEncoder().encode(styled))
        XCTAssertEqual(back.bold, true)
        XCTAssertEqual(back.italic, true)
        XCTAssertEqual(back, styled)
    }

    func test_overlaySetTextStyle_updatesTheShape_TSK1310() {
        var overlay = VectorOverlay()
        let id = overlay.add(VectorShape(kind: .text, frame: .zero, text: "x"))
        XCTAssertTrue(overlay.setTextStyle(id: id, bold: true, italic: false))
        XCTAssertEqual(overlay.shapes.first?.bold, true)
        XCTAssertEqual(overlay.shapes.first?.italic, false)
        XCTAssertFalse(overlay.setTextStyle(id: UUID(), bold: true, italic: true), "unknown id is a no-op")
    }
}
