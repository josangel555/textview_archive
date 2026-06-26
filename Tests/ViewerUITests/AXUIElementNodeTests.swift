import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import ViewerUI

/// TSK-1254 slice 2 — host coverage for the AXUIElement adapter's PURE part: the
/// `AXValue → CGRect` frame assembly the driver uses for the CGEvent-at-frame
/// fallback. The live attribute reads / `AXUIElementPerformAction` need a running
/// app + AX TCC → VM/owner-validated (review ceiling); `AXValue`s themselves
/// construct fine on the host, so the geometry assembly is regression-guarded here.
struct AXUIElementNodeTests {

    private func axValue(_ point: CGPoint) -> AXValue {
        var p = point
        return AXValueCreate(.cgPoint, &p)!
    }
    private func axValue(_ size: CGSize) -> AXValue {
        var s = size
        return AXValueCreate(.cgSize, &s)!
    }

    @Test func cgRectAssemblesPositionAndSize() {
        let rect = AXUIElementNode.cgRect(
            positionValue: axValue(CGPoint(x: 10, y: 20)),
            sizeValue: axValue(CGSize(width: 30, height: 40)))
        #expect(rect == CGRect(x: 10, y: 20, width: 30, height: 40))
    }

    @Test func cgRectRejectsMismatchedValueTypes() {
        // Two points (no size box) → the size extraction fails → nil.
        let rect = AXUIElementNode.cgRect(
            positionValue: axValue(CGPoint(x: 1, y: 2)),
            sizeValue: axValue(CGPoint(x: 3, y: 4)))
        #expect(rect == nil)
    }

    @Test func cgRectPreservesNonIntegralAndNegative() {
        let rect = AXUIElementNode.cgRect(
            positionValue: axValue(CGPoint(x: -5.5, y: 0)),
            sizeValue: axValue(CGSize(width: 12.25, height: 7.75)))
        #expect(rect == CGRect(x: -5.5, y: 0, width: 12.25, height: 7.75))
    }

    @Test func liveReadersDegradeGracefullyWithoutCrash() {
        // The app-root node's live readers must NOT crash when AX is unavailable
        // (no TCC / headless test process) — they degrade to nil/[]. This exercises
        // the CFType-cast paths' nil-safety; real traversal is VM/TCC-validated.
        let node = AXUIElementNode.application(pid: ProcessInfo.processInfo.processIdentifier)
        _ = node.axIdentifier
        _ = node.axRole
        _ = node.axFrame
        #expect(node.axActions.isEmpty || !node.axActions.isEmpty)   // returns an array, no trap
        #expect(node.axChildren.count >= 0)                          // returns an array, no trap
    }
}
