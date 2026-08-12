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

    func test_overFullBand_scalesAllPanelsProportionally_everythingInView() {
        // Owner 2026-08-12 ("opening 4-5 panels must all be in view"):
        // 400+400 stored + 120 flex floor = 920 into an 800 band → both
        // panels give EQUALLY (same above-floor share), the stack fits
        // exactly, nothing scrolls.
        let r = SidebarStackLayout.resolve(
            storedFixed: [400, 400], floor: floor, flexFloor: floor, available: 800)
        XCTAssertEqual(r.fixed[0], r.fixed[1], "equal shares scale equally")
        XCTAssertEqual(r.fixed.reduce(0, +) + r.flex, 800, accuracy: 0.001,
                       "the stack fits the band — every panel in view")
        XCTAssertEqual(r.flex, floor)
    }

    func test_overFullBand_scalingIsProportional_notFromTheFlexEnd() {
        // A big and a small panel: both give in proportion to their
        // above-floor size — never the old nearest-to-flex collapse.
        let r = SidebarStackLayout.resolve(
            storedFixed: [520, 220], floor: floor, flexFloor: floor, available: 640)
        // stretch = (520-120)+(220-120) = 500; target above floors =
        // 640-120-240 = 280 → factor 0.56.
        XCTAssertEqual(r.fixed[0], 120 + 400 * 0.56, accuracy: 0.001)
        XCTAssertEqual(r.fixed[1], 120 + 100 * 0.56, accuracy: 0.001)
        XCTAssertEqual(r.fixed.reduce(0, +) + r.flex, 640, accuracy: 0.001)
    }

    /// THE invariant the 2026-08-12 regression violated (owner: "this is
    /// simply about opening 4-5 side panels and seeing what happens"):
    /// for ANY panel count and stored heights, as long as the floors fit
    /// the band, the resolved stack FITS — no scrolling to reach a tool.
    func test_invariant_wheneverFloorsFit_everyPanelIsInView() {
        let bands: [CGFloat] = [400, 600, 800, 1000, 1400]
        let storedSets: [[CGFloat]] = [
            [220], [220, 220], [400, 220, 180], [220, 220, 220, 220],
            [500, 130, 480, 220, 300], [130, 130, 130, 130, 130],
        ]
        for band in bands {
            for stored in storedSets {
                let floorsNeed = CGFloat(stored.count) * floor + floor
                guard floorsNeed <= band else { continue }   // pathological: scroll
                let r = SidebarStackLayout.resolve(
                    storedFixed: stored, floor: floor, flexFloor: floor, available: band)
                let total = r.fixed.reduce(0, +) + r.flex
                XCTAssertLessThanOrEqual(total, band + 0.001,
                    "\(stored.count) panels @ band \(band): stack must fit "
                    + "(got \(total)) — every tool reachable without scrolling")
                for h in r.fixed {
                    XCTAssertGreaterThanOrEqual(h, floor - 0.001)
                }
            }
        }
    }

    func test_pathologicalBand_belowAllFloors_floorsStand_scrollEngages() {
        let r = SidebarStackLayout.resolve(
            storedFixed: [300, 300], floor: floor, flexFloor: floor, available: 200)
        XCTAssertEqual(r.fixed, [floor, floor],
                       "below everyone's floors: floors stand, the scroll engages")
        XCTAssertEqual(r.flex, floor)
    }

    func test_preMeasurementPass_rendersStoredHeights() {
        let r = SidebarStackLayout.resolve(
            storedFixed: [250], floor: floor, flexFloor: floor, available: 0)
        XCTAssertEqual(r.fixed, [250])
        XCTAssertEqual(r.flex, floor)
    }

    // (`boundaryMax` died 2026-08-12 — the flex-adjacent growth bound is
    // the DividerDragSession's origin slack; see SidebarResizeTests.)
}
