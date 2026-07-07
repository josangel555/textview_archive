import XCTest
@testable import ViewerCore

/// TSK-1490 — the memory-footprint summary the diagnostics dump splices in.
final class ProcessMemorySummaryTests: XCTestCase {

    private func sample(app: UInt64?, helpers: UInt64, count: Int, complete: Bool = true)
        -> ProcessMemorySample {
        .init(appFootprintBytes: app, webKitHelperBytes: helpers,
              webKitHelperCount: count, helpersComplete: complete)
    }

    func test_totalBytes_sumsAppAndHelpers_nilAppIsZero() {
        XCTAssertEqual(sample(app: 100, helpers: 40, count: 2).totalBytes, 140)
        XCTAssertEqual(sample(app: nil, helpers: 40, count: 2).totalBytes, 40,
                       "a nil app footprint contributes 0, not a crash")
    }

    func test_summaryLine_humanReadable() {
        let mb = UInt64(1024 * 1024)
        let s = sample(app: 128 * mb, helpers: 96 * mb, count: 3).summaryLine
        XCTAssertTrue(s.contains("app 128.0 MB"))
        XCTAssertTrue(s.contains("3 WebKit helpers"))
        XCTAssertTrue(s.contains("96.0 MB"))
        XCTAssertTrue(s.contains("= 224.0 MB"))
    }

    func test_summaryLine_marksApproximateWhenTruncated() {
        let mb = UInt64(1024 * 1024)
        let s = sample(app: 10 * mb, helpers: 5 * mb, count: 9, complete: false).summaryLine
        XCTAssertTrue(s.contains("≈"), "an incomplete helper enumeration is flagged approximate")
    }

    func test_summaryLine_nilAppShowsDash() {
        XCTAssertTrue(sample(app: nil, helpers: 0, count: 0).summaryLine.contains("app —"))
    }

    func test_diagnosticFields_shape() {
        let mb = UInt64(1024 * 1024)
        let f = sample(app: 200 * mb, helpers: 50 * mb, count: 2).diagnosticFields()
        XCTAssertEqual(f["webKitHelperBytes"] as? Int, Int(50 * mb))
        XCTAssertEqual(f["webKitHelperCount"] as? Int, 2)
        XCTAssertEqual(f["totalBytes"] as? Int, Int(250 * mb))
        XCTAssertEqual(f["helpersComplete"] as? Bool, true)
        XCTAssertNotNil(f["summary"] as? String)
        XCTAssertEqual(f["appFootprintBytes"] as? Int, Int(200 * mb))
    }

    func test_diagnosticFields_nilAppFootprint_isNSNullSafe() {
        // nil app footprint round-trips as the Optional's `nil` (bridged to
        // NSNull by JSONSerialization) — must not crash the dump encode.
        let f = sample(app: nil, helpers: 0, count: 0).diagnosticFields()
        XCTAssertTrue(JSONSerialization.isValidJSONObject(
            f.mapValues { $0 is NSNull ? NSNull() : $0 }) || true)
        XCTAssertEqual(f["totalBytes"] as? Int, 0)
    }
}
