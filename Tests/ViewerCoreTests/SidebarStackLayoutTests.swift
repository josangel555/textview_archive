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

    func test_crowdedBand_shrinksFromTheFlexEnd_first() {
        // 400+400 stored + 120 flex floor = 920 into an 800 band → the
        // SECOND fixed panel gives up the 120 overage first.
        let r = SidebarStackLayout.resolve(
            storedFixed: [400, 400], floor: floor, flexFloor: floor, available: 800)
        XCTAssertEqual(r.fixed, [400, 280])
        XCTAssertEqual(r.flex, floor)
        XCTAssertEqual(r.fixed.reduce(0, +) + r.flex, 800, "the stack exactly fits")
    }

    func test_crowdedBand_cascadesShrink_acrossPanels() {
        // Overage larger than what the last panel can give — the shrink
        // cascades to the one above it.
        let r = SidebarStackLayout.resolve(
            storedFixed: [500, 200], floor: floor, flexFloor: floor, available: 600)
        XCTAssertEqual(r.fixed[1], floor, "the near-flex panel hits its floor first")
        XCTAssertEqual(r.fixed[0], 600 - floor - floor)
        XCTAssertEqual(r.fixed.reduce(0, +) + r.flex, 600)
    }

    func test_tinyBand_everythingFloors_containerClips() {
        let r = SidebarStackLayout.resolve(
            storedFixed: [300, 300], floor: floor, flexFloor: floor, available: 200)
        XCTAssertEqual(r.fixed, [floor, floor],
                       "below everyone's floors nothing shrinks further — the container clips")
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
