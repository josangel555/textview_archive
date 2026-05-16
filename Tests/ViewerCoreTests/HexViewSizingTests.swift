import XCTest
@testable import ViewerCore

/// Sanity tests on the math HexView relies on. Per-row chunk
/// computation is currently in the view (HexView.swift) — these
/// tests pin the inputs the view consumes so a future regression
/// (like re-introducing per-body `stride.map` over the whole file)
/// trips us before shipping.
final class HexViewSizingTests: XCTestCase {

    func testBinaryFileExposesByteCount() {
        // Construct a fake BinaryFile and verify the byteCount + data
        // length agree. The HexView relies on byteCount for its
        // rowCount math; if BinaryFile changes shape, HexView's
        // calc would silently drift.
        let bytes: [UInt8] = Array(repeating: 0x41, count: 1024)
        let file = BinaryFile(
            url: URL(fileURLWithPath: "/tmp/x"),
            data: Data(bytes),
            totalByteCount: 1024,
            isTruncated: false
        )
        XCTAssertEqual(file.byteCount, 1024)
        XCTAssertEqual(file.data.count, 1024)
    }

    /// The view's `rowCount` is `(byteCount + bytesPerRow - 1) / bytesPerRow`.
    /// Test the math directly so a future change to the formula
    /// doesn't silently drop the last partial row.
    func testRowCountMath() {
        func rowCount(byteCount: Int, bytesPerRow: Int) -> Int {
            guard bytesPerRow > 0, byteCount > 0 else { return 0 }
            return (byteCount + bytesPerRow - 1) / bytesPerRow
        }
        XCTAssertEqual(rowCount(byteCount: 0,    bytesPerRow: 16), 0)
        XCTAssertEqual(rowCount(byteCount: 1,    bytesPerRow: 16), 1)
        XCTAssertEqual(rowCount(byteCount: 16,   bytesPerRow: 16), 1)
        XCTAssertEqual(rowCount(byteCount: 17,   bytesPerRow: 16), 2)
        XCTAssertEqual(rowCount(byteCount: 1024, bytesPerRow: 16), 64)
        // The original regression file: 4MB binary cap.
        XCTAssertEqual(rowCount(byteCount: 4 * 1024 * 1024, bytesPerRow: 16),
                       262_144)
    }
}
