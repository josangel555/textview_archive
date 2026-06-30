import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import ViewerUI
import ViewerCore

/// TSK-1325 (slice 1) — host tests for the image-convert view-model: the format/quality selection
/// drives a real `Exporter.convert` and the result is a valid file of the chosen format; errors
/// surface; the quality knob tracks format lossiness. Pure controller logic (host-safe).
@MainActor
final class ConvertImageViewModelTests: XCTestCase {

    private func makeImage(_ w: Int, _ h: Int) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    private func writeTempPNG(_ image: CGImage) throws -> URL {
        let data = try Exporter.encode(image, ExportSpec(format: .png))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("convertvm-\(UUID().uuidString).png")
        try data.write(to: url)
        return url
    }

    func test_convert_pngToJpeg_writesValidJpeg() async throws {
        let src = try writeTempPNG(makeImage(8, 8))
        defer { try? FileManager.default.removeItem(at: src) }
        let vm = ConvertImageViewModel(sourceURL: src)
        vm.format = .jpeg
        let result = await vm.convert()
        let out = try XCTUnwrap(result, "convert should produce an output URL")
        defer { try? FileManager.default.removeItem(at: out) }
        XCTAssertNil(vm.lastError)
        let data = try Data(contentsOf: out)
        let imgSrc = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(imgSrc), UTType.jpeg.identifier as CFString,
                       "the output must be a JPEG (the selected target format)")
    }

    func test_convert_missingSource_setsError_returnsNil() async {
        let bogus = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).png")
        let vm = ConvertImageViewModel(sourceURL: bogus)
        let out = await vm.convert()
        XCTAssertNil(out)
        XCTAssertNotNil(vm.lastError, "a missing source must surface an error, not crash")
    }

    func test_isQualityMeaningful_tracksFormatLossiness() {
        let vm = ConvertImageViewModel(sourceURL: URL(fileURLWithPath: "/tmp/x.png"))
        vm.format = .png
        XCTAssertFalse(vm.isQualityMeaningful, "PNG is lossless — quality is moot")
        vm.format = .jpeg
        XCTAssertTrue(vm.isQualityMeaningful, "JPEG is lossy — quality applies")
        XCTAssertEqual(vm.availableFormats.count, ExportSpec.Format.allCases.count)
    }
}
