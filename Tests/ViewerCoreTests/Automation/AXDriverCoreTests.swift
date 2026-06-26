import CoreGraphics
import Foundation
import Testing
@testable import ViewerCore

/// TSK-1254 — host coverage for the out-of-process AX driver's pure-logic core:
/// find-a-control-by-`mdv.*`-id over an abstract tree + resolve-how-to-press.
/// The real AXUIElement adapter is VM-tail; these tests feed a fake tree so the
/// traversal + action-resolution logic is regression-guarded on the host gate.
struct AXDriverCoreTests {

    /// Minimal `AXNode` for building fake trees.
    struct Fake: AXNode {
        var axIdentifier: String?
        var axRole: String?
        var axFrame: CGRect?
        var axActions: [String]
        var axChildren: [AXNode]
        init(_ id: String? = nil, role: String? = nil, frame: CGRect? = nil,
             actions: [String] = [], children: [AXNode] = []) {
            axIdentifier = id; axRole = role; axFrame = frame
            axActions = actions; axChildren = children
        }
    }

    /// window ▸ [toolbar ▸ [hexView-button, tab.dirtyDot], find ▸ field]
    private func sampleTree() -> Fake {
        Fake("mdv.window", children: [
            Fake("mdv.toolbar", children: [
                Fake("mdv.hexView", role: "AXButton", frame: CGRect(x: 10, y: 20, width: 40, height: 30),
                     actions: ["AXPress"]),
                Fake("mdv.tab.dirtyDot", role: "AXImage"),
            ]),
            Fake("mdv.findBar", children: [
                Fake("mdv.findBar.field", role: "AXTextField",
                     frame: CGRect(x: 0, y: 0, width: 100, height: 20)),
            ]),
        ])
    }

    // MARK: - AXQuery parsing

    @Test func exactByDefault() {
        let q = AXQuery("mdv.hexView")
        #expect(q.match == .exact)
        #expect(q.matches("mdv.hexView"))
        #expect(!q.matches("mdv.hexViewX"))
        #expect(!q.matches(nil))
    }

    @Test(arguments: ["mdv.tab.*", "mdv.tab*"])
    func trailingGlobIsPrefix(_ form: String) {
        let q = AXQuery(form)
        #expect(q.match == .prefix)
        #expect(q.matches("mdv.tab.dirtyDot"))
        #expect(q.matches("mdv.tab.overflowMenu"))
    }

    @Test func dotStarGlobKeepsTheDotBoundary() {
        // ".*" keeps the trailing dot, so the sibling "mdv.tabBar" does NOT match
        // (only true children "mdv.tab.<x>" do).
        #expect(!AXQuery("mdv.tab.*").matches("mdv.tabBar"))
        // The bare "*" form drops only the star, so it DOES match the sibling.
        #expect(AXQuery("mdv.tab*").matches("mdv.tabBar"))
    }

    // MARK: - find / findAll

    @Test func findExact() {
        let hit = AXDriverCore.find("mdv.findBar.field", in: sampleTree())
        #expect(hit?.axIdentifier == "mdv.findBar.field")
        #expect(hit?.axRole == "AXTextField")
    }

    @Test func findMissingReturnsNil() {
        #expect(AXDriverCore.find("mdv.nope", in: sampleTree()) == nil)
    }

    @Test func findPrefixReturnsFirstPreOrder() {
        // Pre-order DFS → the dirtyDot (first declared under toolbar) wins.
        let hit = AXDriverCore.find("mdv.tab.*", in: sampleTree())
        #expect(hit?.axIdentifier == "mdv.tab.dirtyDot")
    }

    @Test func findAllPrefix() {
        let tree = Fake("root", children: [
            Fake("mdv.row.a"), Fake("group", children: [Fake("mdv.row.b")]), Fake("mdv.other"),
        ])
        let ids = AXDriverCore.findAll(AXQuery("mdv.row.*"), in: tree).map(\.axIdentifier)
        #expect(ids == ["mdv.row.a", "mdv.row.b"])
    }

    @Test func findMatchesRootItself() {
        #expect(AXDriverCore.find("mdv.window", in: sampleTree())?.axIdentifier == "mdv.window")
    }

    // MARK: - resolvePress

    @Test func resolvePrefersNativeAXAction() {
        // Has BOTH AXPress and a frame → native action wins (the teeth assert:
        // if resolvePress regressed to prefer the frame, this goes red).
        let node = Fake("b", frame: CGRect(x: 0, y: 0, width: 10, height: 10), actions: ["AXPress"])
        #expect(AXDriverCore.resolvePress(node) == .axAction("AXPress"))
    }

    @Test func resolveActionPriorityOrder() {
        // No AXPress, but AXConfirm present → next in priority.
        let node = Fake("b", actions: ["AXConfirm", "AXShowMenu"])
        #expect(AXDriverCore.resolvePress(node) == .axAction("AXConfirm"))
    }

    @Test func resolveFallsBackToFrameCenter() {
        let node = Fake("b", frame: CGRect(x: 10, y: 20, width: 40, height: 30))  // no actions
        #expect(AXDriverCore.resolvePress(node) == .clickAtFrame(CGPoint(x: 30, y: 35)))
    }

    @Test func resolveUnavailableWithoutActionOrFrame() {
        if case .unavailable = AXDriverCore.resolvePress(Fake("b")) {} else {
            Issue.record("expected .unavailable for a node with no action and no frame")
        }
    }

    @Test func resolveZeroSizeFrameIsUnavailable() {
        let node = Fake("b", frame: CGRect(x: 5, y: 5, width: 0, height: 0))
        if case .unavailable = AXDriverCore.resolvePress(node) {} else {
            Issue.record("a zero-size frame is not a clickable target")
        }
    }

    // MARK: - resolve(plan:in:) — the executor's host-testable entry

    private func driveTree() -> Fake {
        Fake("mdv.window", children: [
            Fake("mdv.hexView", role: "AXButton",
                 frame: CGRect(x: 10, y: 20, width: 40, height: 30), actions: ["AXPress"]),
            Fake("mdv.csvTable", role: "AXTable",
                 frame: CGRect(x: 0, y: 50, width: 200, height: 300)),
            Fake("mdv.findBar.field", role: "AXTextField",
                 frame: CGRect(x: 0, y: 0, width: 100, height: 20)),
        ])
    }

    @Test func resolvePlan_press_usesNativeActionOnFoundNode() throws {
        let plan = try #require(AXDrivePlan(parsing: "press mdv.hexView"))
        #expect(AXDriverCore.resolve(plan, in: driveTree()) == .press(.axAction("AXPress")))
    }

    @Test func resolvePlan_scroll_carriesDirectionAndFrame() throws {
        let plan = try #require(AXDrivePlan(parsing: "scroll mdv.csvTable down"))
        #expect(AXDriverCore.resolve(plan, in: driveTree())
                == .scroll(.down, frame: CGRect(x: 0, y: 50, width: 200, height: 300)))
    }

    @Test func resolvePlan_read_carriesRoleAndFrame() throws {
        let plan = try #require(AXDrivePlan(parsing: "read mdv.findBar.field"))
        #expect(AXDriverCore.resolve(plan, in: driveTree())
                == .read(role: "AXTextField", frame: CGRect(x: 0, y: 0, width: 100, height: 20)))
    }

    @Test func resolvePlan_set_carriesValue() throws {
        let plan = try #require(AXDrivePlan(parsing: "set mdv.findBar.field hello"))
        #expect(AXDriverCore.resolve(plan, in: driveTree()) == .setValue("hello"))
    }

    @Test func resolvePlan_missingTarget_isNotFound() throws {
        let plan = try #require(AXDrivePlan(parsing: "press mdv.doesNotExist"))
        #expect(AXDriverCore.resolve(plan, in: driveTree()) == .targetNotFound(AXQuery("mdv.doesNotExist")))
    }
}
