import XCTest
@testable import ViewerCore

/// Pure coverage for the shared byte-size formatter (was a private
/// `byteString` triplicated across ContentView ×2 + HTMLRenderedView).
final class ByteSizeTests: XCTestCase {
    func test_mbString() {
        XCTAssertEqual(ByteSize.mbString(1_048_576), "1.0 MB")
        XCTAssertEqual(ByteSize.mbString(0), "0.0 MB")
        XCTAssertEqual(ByteSize.mbString(5 * 1_048_576), "5.0 MB")
        XCTAssertEqual(ByteSize.mbString(1_572_864), "1.5 MB")     // 1.5 MB
        XCTAssertEqual(ByteSize.mbString(50 * 1_048_576), "50.0 MB")
    }
}
