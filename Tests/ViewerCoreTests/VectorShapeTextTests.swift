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
}
