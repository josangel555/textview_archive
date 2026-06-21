import XCTest
@testable import ViewerCore

/// TSK-1073 — teeth for the image resize math (percent + aspect-locked sizing).
final class ImageResizeMathTests: XCTestCase {

    func test_scaled_byPercent() {
        let r = ImageResizeMath.scaled((width: 200, height: 100), percent: 50)
        XCTAssertEqual(r.width, 100)
        XCTAssertEqual(r.height, 50)
    }

    func test_scaled_clampsToOnePixel() {
        let r = ImageResizeMath.scaled((width: 10, height: 10), percent: 1)
        XCTAssertEqual(r.width, 1, "never collapses below 1px")
        XCTAssertEqual(r.height, 1)
    }

    func test_sized_maintainAspect_derivesHeightFromWidth() {
        let r = ImageResizeMath.sized(
            current: (width: 200, height: 100), width: 50, height: 999, maintainAspect: true)
        XCTAssertEqual(r.width, 50)
        XCTAssertEqual(r.height, 25, "height follows the 2:1 aspect; the passed 999 is ignored")
    }

    func test_sized_freeform_usesBothDimensions() {
        let r = ImageResizeMath.sized(
            current: (width: 200, height: 100), width: 80, height: 30, maintainAspect: false)
        XCTAssertEqual(r.width, 80)
        XCTAssertEqual(r.height, 30)
    }
}
