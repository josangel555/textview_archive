import XCTest
import ViewerKit
@testable import ViewerCore

/// Bench: parse → fold-regions throughput on a synthetic 10K-line JSON
/// blob. Design target is <50 ms cold on Apple Silicon; we assert a
/// loose 250 ms ceiling so CI on older hardware doesn't flap, and log
/// the actual number so regressions show up in CI output.
///
/// Filter target: `swift test --filter ViewerCoreTests.FoldBench`
final class FoldBenchTests: XCTestCase {

    func testCold10KLineJSONUnder250ms() {
        // 10K lines: an outer array of 2500 4-line objects.
        var b = "[\n"
        for i in 0..<2500 {
            b += "  {\n"
            b += "    \"id\": \(i),\n"
            b += "    \"v\": \"x\(i)\"\n"
            b += "  }\(i == 2499 ? "" : ",")\n"
        }
        b += "]\n"

        // Confirm we hit the 10K-line target.
        let lineCount = b.split(separator: "\n", omittingEmptySubsequences: false).count
        XCTAssertGreaterThanOrEqual(lineCount, 10_000)

        TreeSitterEngine.shared._testOnly_clearFoldCaches()
        let t0 = Date()
        let regions = TreeSitterEngine.shared.computeFoldsSync(
            text: b, language: .json
        )
        let elapsedMs = Date().timeIntervalSince(t0) * 1000
        print("[FoldBench] 10K-line JSON cold compute: \(elapsedMs) ms, " +
              "\(regions.count) regions")
        XCTAssertGreaterThan(regions.count, 2000,
                             "expected one fold per object")
        // Generous ceiling — design target is <50 ms; this guards the
        // engine never accidentally falls off a cliff (e.g. quadratic).
        XCTAssertLessThan(elapsedMs, 250)
    }

    func testWarmCacheIsConstantTime() async {
        var b = "[\n"
        for i in 0..<1000 {
            b += "  {\"id\":\(i),\"v\":[\n1,\n2,\n3\n]},\n"
        }
        b += "  null\n]\n"

        TreeSitterEngine.shared._testOnly_clearFoldCaches()
        _ = await TreeSitterEngine.shared.computeFolds(text: b, language: .json)
        let t0 = Date()
        _ = await TreeSitterEngine.shared.computeFolds(text: b, language: .json)
        let warmMs = Date().timeIntervalSince(t0) * 1000
        print("[FoldBench] warm-cache lookup: \(warmMs) ms")
        XCTAssertLessThan(warmMs, 5)
    }
}
