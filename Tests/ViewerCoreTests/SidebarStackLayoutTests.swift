import XCTest
@testable import ViewerCore

/// Owner 2026-08-09 structural rework — the one-rule panel stack.
final class SidebarStackLayoutTests: XCTestCase {

    private let floor: CGFloat = 120

    func test_roomyBand_flexAbsorbsTheRemainder() {
        let r = SidebarStackLayout.resolve(
            storedFixed: [200, 300], floor: floor, flexFloor: floor, available: 1000)
        XCTAssertEqual(r.fixed, [200, 300])
        XCTAssertEqual(r.flex, 500, "flex takes every leftover point — no dead band")
    }

    func test_soloFlex_takesTheWholeBand() {
        let r = SidebarStackLayout.resolve(
            storedFixed: [], floor: floor, flexFloor: floor, available: 900)
        XCTAssertEqual(r.flex, 900)
    }

    func test_crowdedBand_neverShrinksPanels_theStackOverflowsInstead() {
        // Owner 2026-08-12 ("it should only grow in the direction you
        // drag"): 400+400 stored + 120 flex floor = 920 into an 800 band —
        // the panels KEEP their stored heights; the overflow scrolls.
        let r = SidebarStackLayout.resolve(
            storedFixed: [400, 400], floor: floor, flexFloor: floor, available: 800)
        XCTAssertEqual(r.fixed, [400, 400],
                       "a panel only changes size when ITS divider is dragged")
        XCTAssertEqual(r.flex, floor)
        XCTAssertGreaterThan(r.fixed.reduce(0, +) + r.flex, 800,
                             "the stack overflows the band — the scroll engages")
    }

    func test_tinyBand_storedHeightsStand_containerScrolls() {
        let r = SidebarStackLayout.resolve(
            storedFixed: [300, 300], floor: floor, flexFloor: floor, available: 200)
        XCTAssertEqual(r.fixed, [300, 300],
                       "no auto-shrink at any band size — overflow scrolls")
        XCTAssertEqual(r.flex, floor)
    }

    func test_preMeasurementPass_rendersStoredHeights() {
        let r = SidebarStackLayout.resolve(
            storedFixed: [250], floor: floor, flexFloor: floor, available: 0)
        XCTAssertEqual(r.fixed, [250])
        XCTAssertEqual(r.flex, floor)
    }

    func test_boundaryMax_isAbovePlusFlexSlack_neverACeilingFraction() {
        // The dual-split wall: the old 50%-of-band ceiling stopped the
        // above panel at half the shoulder. Now it may grow until the flex
        // panel hits its floor — nothing else.
        XCTAssertEqual(
            SidebarStackLayout.boundaryMax(aboveRendered: 300, flexRendered: 500, flexFloor: 120),
            300 + 380)
        XCTAssertEqual(
            SidebarStackLayout.boundaryMax(aboveRendered: 300, flexRendered: 120, flexFloor: 120),
            300, "a flex at its floor gives nothing")
    }
}
