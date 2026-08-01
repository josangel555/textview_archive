import ApplicationServices
import XCTest
import ViewerCore
@testable import ViewerUI

/// TSK-1254 bootstrap (2026-07-31) — the FIRST out-of-process AX
/// interaction tests: prove the whole chain end-to-end on the real app.
///
///   spawn dist/TextView.app → AXUIElementCreateApplication(pid)
///   → AXDriverCore.find("mdv.*") → real HID event → observe the AX
///   tree change.
///
/// TIER-JUSTIFY: the observable is the OUT-OF-PROCESS AX tree of a real
/// app process — SwiftUI only materializes AX for external clients (the
/// in-process tree is empty, proven 2026-07-04), and a real HID event
/// exercises the actual routing an automation driver / user's mouse
/// uses. No lower tier can produce either.
final class AXChromeInteractionTests: AXInteractionTestCase {

    /// THE unlock: our `mdv.*` accessibility identifiers are visible to an
    /// external AX client, with real geometry — the fact every future AX
    /// test builds on. (System Events could never see these; the
    /// in-process tree is empty. First run of this suite also caught the
    /// tab button's `.accessibilityElement(children: .ignore)` dropping
    /// the close button from the tree entirely — a real a11y defect.)
    func test_axTree_exposesMdvIdentifiers_withRealFrames() throws {
        let root = try spawnAndAttach(scene: "tabs-3")

        let strip = AXDriverCore.find("mdv.sessionTabBar", in: root)
        XCTAssertNotNil(strip, "the session strip must be AX-addressable by id")
        XCTAssertNotNil(strip?.axFrame, "…with real on-screen geometry")

        let tabsOK = waitUntil(5) {
            AXDriverCore.findAll(AXQuery("mdv.tab.item.*"), in: root).count == 3
        }
        XCTAssertTrue(tabsOK, "all 3 tabs must be AX-addressable by their ids "
            + "(got \(AXDriverCore.findAll(AXQuery("mdv.tab.item.*"), in: root).count))")
        XCTAssertGreaterThanOrEqual(
            AXDriverCore.findAll(AXQuery("mdv.tab.closeButton"), in: root).count, 1,
            "at least the SELECTED tab's close button must be in the tree "
            + "(unhovered ones may fade at opacity 0)")
    }

    /// THE first real-event interaction, end-to-end: HID-click the
    /// session strip's "+" at its AX-reported frame and watch the GoTo
    /// panel materialize in the AX tree — real event → SwiftUI action →
    /// coordinator → new on-screen surface, all observed out-of-process.
    ///
    /// Mechanism, settled by measurement (2026-07-31, five rounds):
    /// AXPress is ACCEPTED but never dispatched by SwiftUI's bridge (the
    /// System-Events-adjacent trap); `postToPid` delivery is not
    /// hit-tested; the GLOBAL HID-tap click is what works — AX supplies
    /// find + geometry, HID supplies the event (`AXClickExecutor`).
    func test_hidClick_newSessionButton_opensGoToPrompt() throws {
        let root = try spawnAndAttach(scene: "tabs-3")
        _ = waitUntil(5) { AXDriverCore.find("mdv.sessionTab.new", in: root) != nil }
        guard let plus = AXDriverCore.find("mdv.sessionTab.new", in: root),
              let frame = plus.axFrame else {
            return XCTFail("the + button must be AX-addressable with a frame")
        }
        XCTAssertNil(AXDriverCore.find(AXQuery("mdv.goto.*"), in: root),
                     "precondition: no GoTo panel before the click")

        AXClickExecutor.click(centerOf: frame)

        let appeared = waitUntil(5) {
            AXDriverCore.find(AXQuery("mdv.goto.*"), in: root) != nil
        }
        XCTAssertTrue(appeared,
            "a REAL click on + must open the GoTo prompt (real event → "
            + "SwiftUI action → coordinator → new AX surface)")
    }
}
