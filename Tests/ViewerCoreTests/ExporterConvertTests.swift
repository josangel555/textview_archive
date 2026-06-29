import XCTest
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import ViewerCore

/// TSK-1325 — `Exporter.convert(contentsOf:to:)` (image FILE → re-encoded bytes per
/// `ExportSpec`: target format + quality). The encode half (`Exporter.encode`) was
/// already covered; this pins the NEW decode→convert primitive end-to-end (format
/// actually changes, pixels survive) + its error cases.
final class ExporterConvertTests: XCTestCase {

    private func makeImage(_ w: Int, _ h: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    private func writeTempPNG(_ image: CGImage) throws -> URL {
        let data = try Exporter.encode(image, ExportSpec(format: .png))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-convert-\(UUID().uuidString).png")
        try data.write(to: url)
        return url
    }

    func test_convert_pngFileToJpeg_changesFormatAndKeepsSize() throws {
        let url = try writeTempPNG(makeImage(8, 6))
        defer { try? FileManager.default.removeItem(at: url) }
        let jpeg = try Exporter.convert(contentsOf: url, to: ExportSpec(format: .jpeg, quality: 0.8))
        XCTAssertFalse(jpeg.isEmpty)
        let src = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(src), UTType.jpeg.identifier as CFString)
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        XCTAssertEqual(decoded.width, 8)
        XCTAssertEqual(decoded.height, 6)
    }

    func test_convert_toTiff_isDecodableTiff() throws {
        let url = try writeTempPNG(makeImage(4, 4))
        defer { try? FileManager.default.removeItem(at: url) }
        let tiff = try Exporter.convert(contentsOf: url, to: ExportSpec(format: .tiff))
        let src = try XCTUnwrap(CGImageSourceCreateWithData(tiff as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(src), UTType.tiff.identifier as CFString)
    }

    func test_convert_missingFile_throwsNotReadable() {
        let bogus = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-nonexistent-\(UUID().uuidString).png")
        XCTAssertThrowsError(try Exporter.convert(contentsOf: bogus, to: ExportSpec(format: .png))) {
            XCTAssertEqual($0 as? ImageEditError, .sourceNotReadable)
        }
    }

    func test_convert_nonImageFile_throwsDecodeFailed() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-notimage-\(UUID().uuidString).png")
        try Data("not an image".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try Exporter.convert(contentsOf: url, to: ExportSpec(format: .png))) {
            XCTAssertEqual($0 as? ImageEditError, .sourceDecodeFailed)
        }
    }
}
