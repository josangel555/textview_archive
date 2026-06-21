import XCTest
@testable import ViewerCore

/// TSK-1118 — teeth for the recent-colors MRU model.
final class RecentColorsTests: XCTestCase {

    func test_record_addsNewestFirst() {
        var r = RecentColors()
        r.record(.red)
        r.record(.blue)
        XCTAssertEqual(r.colors, [.blue, .red], "newest first")
    }

    func test_record_existing_movesToFrontNoDuplicate() {
        var r = RecentColors()
        r.record(.red)
        r.record(.blue)
        r.record(.red)   // re-pick red
        XCTAssertEqual(r.colors, [.red, .blue], "moved to front, not duplicated")
    }

    func test_record_enforcesLimit() {
        var r = RecentColors(limit: 3)
        for i in 0..<6 {
            r.record(RGBAColor(r: UInt8(i), g: 0, b: 0))
        }
        XCTAssertEqual(r.colors.count, 3, "capped at the limit")
        XCTAssertEqual(r.colors.first, RGBAColor(r: 5, g: 0, b: 0), "newest kept")
        XCTAssertEqual(r.colors.last, RGBAColor(r: 3, g: 0, b: 0), "oldest beyond cap dropped")
    }
}
