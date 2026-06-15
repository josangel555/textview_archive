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

        // TSK-952: best-of-3 cold computes (cache cleared each) — the single
        // wall-clock sample flaked under machine load. Min = least-noisy true
        // cost; a real cliff (e.g. quadratic) still blows past 250 ms on the min.
        var coldBest = Double.greatestFiniteMagnitude
        var regionCount = 0
        for _ in 0..<3 {
            TreeSitterEngine.shared._testOnly_clearFoldCaches()
            let t0 = Date()
            let regions = TreeSitterEngine.shared.computeFoldsSync(text: b, language: .json)
            coldBest = min(coldBest, Date().timeIntervalSince(t0) * 1000)
            regionCount = regions.count
        }
        print("[FoldBench] 10K-line JSON cold compute (best-of-3): \(coldBest) ms, " +
              "\(regionCount) regions")
        XCTAssertGreaterThan(regionCount, 2000,
                             "expected one fold per object")
        // Generous ceiling — design target is <50 ms; this guards the
        // engine never accidentally falls off a cliff (e.g. quadratic).
        XCTAssertLessThan(coldBest, 250)
    }

    func testWarmCacheIsConstantTime() async {
        var b = "[\n"
        for i in 0..<1000 {
            b += "  {\"id\":\(i),\"v\":[\n1,\n2,\n3\n]},\n"
        }
        b += "  null\n]\n"

        TreeSitterEngine.shared._testOnly_clearFoldCaches()
        _ = await TreeSitterEngine.shared.computeFolds(text: b, language: .json)  // warm it
        // TSK-952: best-of-5 warm lookups. A single sample at a <5 ms threshold
        // is extremely spike-prone (one scheduler hiccup → red); the min of a
        // pure cache hit is stable and still catches a real warm-path regression.
        var warmBest = Double.greatestFiniteMagnitude
        for _ in 0..<5 {
            let t0 = Date()
            _ = await TreeSitterEngine.shared.computeFolds(text: b, language: .json)
            warmBest = min(warmBest, Date().timeIntervalSince(t0) * 1000)
        }
        print("[FoldBench] warm-cache lookup (best-of-5): \(warmBest) ms")
        XCTAssertLessThan(warmBest, 5)
    }
}
