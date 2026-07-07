import XCTest
@testable import ViewerCore

/// TSK-1487 — age→bucket→color mapping + the blame porcelain parse.
final class LineAgeColoringTests: XCTestCase {

    func test_buckets_byAge() {
        XCTAssertEqual(LineAgeColoring.bucket(ageSeconds: 60), 0)             // < 1h
        XCTAssertEqual(LineAgeColoring.bucket(ageSeconds: 60 * 60 * 5), 1)    // < 1d
        XCTAssertEqual(LineAgeColoring.bucket(ageSeconds: 60 * 60 * 24 * 3), 2) // < 1w
        XCTAssertEqual(LineAgeColoring.bucket(ageSeconds: 60 * 60 * 24 * 400),
                       LineAgeColoring.bucketThresholds.count, "older than a year → last bucket")
    }

    func test_recentIsLighterThanOld() {
        let now: TimeInterval = 1_000_000_000
        let recent = LineAgeColoring.stripe(commitTime: now - 60, now: now)          // 1 min old
        let old = LineAgeColoring.stripe(commitTime: now - 60 * 60 * 24 * 400, now: now) // >1yr
        // "Lighter" = higher blue+green (LightBlue vs DarkBlue).
        XCTAssertGreaterThan(recent.b, old.b)
        XCTAssertGreaterThan(recent.g, old.g)
        // Ramp endpoints.
        XCTAssertEqual(recent.b, 1.0, accuracy: 0.05)
        XCTAssertLessThan(old.b, 0.6)
    }

    func test_stripeStaysInGamut() {
        let now: TimeInterval = 2_000_000_000
        for daysAgo in [0.0, 0.5, 3, 20, 200, 800] {
            let s = LineAgeColoring.stripe(commitTime: now - daysAgo * 86400, now: now)
            for c in [s.r, s.g, s.b] {
                XCTAssertGreaterThanOrEqual(c, 0)
                XCTAssertLessThanOrEqual(c, 1)
            }
        }
    }

    func test_parseBlamePorcelain_extractsPerLineTimes() {
        // Two lines: first committed at 1000, second uncommitted (no author-time).
        let porcelain = """
        abc123 1 1 1
        author Alice
        author-time 1000
        author-tz +0000
        summary first
        \tlet x = 1
        0000000000000000000000000000000000000000 2 2 1
        author Not Committed Yet
        \tlet y = 2
        """
        let times = LineAgeColoring.parseBlameTimes(porcelain)
        XCTAssertEqual(times.count, 2)
        XCTAssertEqual(times[0], 1000)
        XCTAssertNil(times[1], "an uncommitted line has no author-time")
    }

    func test_parseBlame_emptyIsEmpty() {
        XCTAssertEqual(LineAgeColoring.parseBlameTimes(""), [])
    }

    func test_untrackedStripe_isGreen() {
        let g = LineAgeColoring.untrackedStripe
        XCTAssertGreaterThan(g.g, g.r)
        XCTAssertGreaterThan(g.g, g.b)
    }
}
