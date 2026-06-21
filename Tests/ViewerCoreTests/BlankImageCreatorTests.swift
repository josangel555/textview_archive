import XCTest
import CoreGraphics
import ImageIO
@testable import ViewerCore

/// TSK-1054 — teeth for the blank-image creator behind File ▸ New Image. The PNG
/// it produces must be valid and exactly the requested size (the dimensions
/// assertion fails if creation regresses); non-positive / oversize dimensions
/// are rejected rather than allocating wildly.
final class BlankImageCreatorTests: XCTestCase {

    private func decode(_ data: Data) throws -> CGImage {
        let src = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
    }

    func test_default_isValidPNG_4x3() throws {
        let data = try XCTUnwrap(BlankImageCreator.pngData())
        XCTAssertEqual(Array(data.prefix(4)), [0x89, 0x50, 0x4E, 0x47], "PNG signature")
        let cg = try decode(data)
        XCTAssertEqual(cg.width, 800)
        XCTAssertEqual(cg.height, 600)
    }

    func test_customDimensions() throws {
        let cg = try decode(try XCTUnwrap(BlankImageCreator.pngData(width: 40, height: 24)))
        XCTAssertEqual(cg.width, 40)
        XCTAssertEqual(cg.height, 24)
    }

    func test_rejectsNonPositiveDimensions() {
        XCTAssertNil(BlankImageCreator.pngData(width: 0, height: 10))
        XCTAssertNil(BlankImageCreator.pngData(width: 10, height: -1))
    }

    func test_rejectsOversizeDimensions() {
        XCTAssertNil(BlankImageCreator.pngData(width: 50_000, height: 50_000),
                     "a pathological size is refused, not allocated")
    }
}
