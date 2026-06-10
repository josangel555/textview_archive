import XCTest
import SwiftUI
import AppKit
@testable import ViewerUI
@testable import ViewerCore
import ViewerKit

/// TSK-440 render-half guards — the two gaps that held the ticket at
/// `fixed` after its model half (SidebarResizeTests) was fully pinned:
///
/// 1. **Realized presence**: the FILES↔accordion boundary divider (and the
///    pair divider between two fixed tools) must actually be CONSTRUCTED
///    in the hosted `SidebarView` tree — `SidebarSectionPlannerTests` pins
///    the PLAN, but a `sidebarBody` wiring slip that drops the divider
///    would stay green there. `ResizableSectionDivider.body` ticks
///    `BodyProbe` with its role; hosting the real sidebar and asserting
///    the per-role count fails on exactly that slip. (Pure-SwiftUI
///    container — no representable sibling, so body-eval presence is the
///    honest oracle; the divider component's on-screen visibility predates
///    TSK-440 and is unchanged.)
/// 2. **Drag routing**: the divider's `onChanged` is origin-capture +
///    `apply(delta:)` — exercising `apply` IS the exact action closure
///    (TSK-620 doctrine). Pin that pair drags are sum-preserving via
///    `SidebarResize.redistribute` and the boundary drag drives the below
///    panel inversely.
@MainActor
final class SidebarDividerWiringTests: HeadlessUITestCase {

    private var tmpDir: URL!
    private var folderRoot: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "SidebarDividerWiring-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName)
        folderRoot = tmpDir.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: folderRoot, withIntermediateDirectories: true)
        try "alpha\n".write(to: folderRoot.appendingPathComponent("a.txt"),
                            atomically: true, encoding: .utf8)
        BodyProbe.reset()
        BodyProbe.enabled = false
    }

    override func tearDown() async throws {
        BodyProbe.enabled = false
        BodyProbe.reset()
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
        if let suiteName, let defaults {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    /// Model with a folder root and EXACTLY `tools` non-FILES panels
    /// forced visible (everything else forced hidden, so data-presence
    /// can't add panels behind the config's back).
    private func makeModel(tools: Int) -> DocumentModel {
        let m = DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmpDir.appendingPathComponent("history.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults)
        )
        m.sidebar.setRoot(folderRoot)
        m.sidebar.isVisible = true
        var remaining = tools
        for kind in SidebarPanelKind.allCases where kind != .files {
            m.panelLayout.setOverride(kind, remaining > 0 ? .shown : .hidden)
            remaining -= remaining > 0 ? 1 : 0
        }
        return m
    }

    /// Host the REAL SidebarView (ToolPanelBoundingTests pattern) inside a
    /// BodyProbe window and return the per-role divider body-eval counts.
    private func dividerRoles(tools: Int) -> [String: Int] {
        let m = makeModel(tools: tools)
        BodyProbe.reset()
        BodyProbe.enabled = true
        let host = NSHostingView(rootView: SidebarView(
            sidebar: m.sidebar,
            model: m,
            trackedRepos: m.trackedRepos,
            panelLayout: m.panelLayout
        ))
        host.frame = NSRect(x: 0, y: 0, width: 280, height: 700)
        for _ in 0..<4 { host.layoutSubtreeIfNeeded() }
        for _ in 0..<6 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        host.layoutSubtreeIfNeeded()
        BodyProbe.enabled = false
        return BodyProbe.counts.filter { $0.key.hasPrefix("ResizableSectionDivider.") }
    }

    // MARK: - Realized presence (gap 1)

    /// THE TSK-440 bug-B configuration: FILES + exactly one tool. Pre-fix
    /// the planner drew ZERO dividers here; the fix adds the boundary
    /// divider. A sidebarBody wiring slip that drops it goes red here.
    func test_filesPlusOneTool_boundaryDividerIsRealized() throws {
        let roles = dividerRoles(tools: 1)
        XCTAssertGreaterThanOrEqual(
            roles["ResizableSectionDivider.boundary"] ?? 0, 1,
            "the FILES↔accordion boundary divider must be constructed in "
            + "the realized sidebar tree; divider roles seen: \(roles)")
    }

    /// FILES + two tools: the boundary divider AND the sum-preserving pair
    /// divider between the two fixed tools must both be realized.
    func test_filesPlusTwoTools_boundaryAndPairDividersRealized() throws {
        let roles = dividerRoles(tools: 2)
        XCTAssertGreaterThanOrEqual(
            roles["ResizableSectionDivider.boundary"] ?? 0, 1,
            "boundary divider missing with 2 tools; roles: \(roles)")
        XCTAssertGreaterThanOrEqual(
            roles["ResizableSectionDivider.pair"] ?? 0, 1,
            "pair divider between the two fixed tools missing; roles: \(roles)")
    }

    /// Lone FILES: no divider at all (nothing to resize against).
    func test_lonelyFiles_noDividerRealized() throws {
        let roles = dividerRoles(tools: 0)
        XCTAssertTrue(roles.isEmpty,
            "lone FILES must render no resize divider; roles: \(roles)")
    }

    // MARK: - Drag routing (gap 2 — exact closure)

    private func makeBindings(_ above: CGFloat, _ below: CGFloat)
        -> (Binding<CGFloat>, Binding<CGFloat>, () -> (CGFloat, CGFloat)) {
        // Reference box so the bindings outlive the local scope.
        final class Box { var a: CGFloat; var b: CGFloat
            init(_ a: CGFloat, _ b: CGFloat) { self.a = a; self.b = b } }
        let box = Box(above, below)
        return (Binding(get: { box.a }, set: { box.a = $0 }),
                Binding(get: { box.b }, set: { box.b = $0 }),
                { (box.a, box.b) })
    }

    /// Pair drag: the divider's apply(delta:) — the exact closure the
    /// gesture drives — must move height BETWEEN the neighbors,
    /// sum-preserving, matching SidebarResize.redistribute verbatim.
    func test_pairDrag_appliesSumPreservingRedistribution() throws {
        let (above, below, read) = makeBindings(220, 220)
        let divider = ResizableSectionDivider(heightAbove: above, heightBelow: below)
        divider.apply(delta: 37)
        let (a, b) = read()
        let expected = SidebarResize.redistribute(above: 220, below: 220, delta: 37)
        XCTAssertEqual(a, expected.above, accuracy: 0.001,
            "above must follow redistribute (got \(a))")
        XCTAssertEqual(b, expected.below, accuracy: 0.001,
            "below must follow redistribute (got \(b))")
        XCTAssertEqual(a + b, 440, accuracy: 0.001,
            "pair drag must be sum-preserving (got \(a) + \(b))")
    }

    /// Boundary drag (FILES above, fixed tool below): drag DOWN grows the
    /// flex FILES panel by shrinking the tool — the below binding moves
    /// inversely; nothing else is mutated.
    func test_boundaryDrag_drivesBelowInversely() throws {
        let (_, below, read) = makeBindings(0, 240)
        let divider = ResizableSectionDivider(heightAbove: nil, heightBelow: below)
        divider.apply(delta: 25)
        let (_, b) = read()
        XCTAssertEqual(b, SidebarPanelHeights.clamp(240 - 25), accuracy: 0.001,
            "boundary drag down must shrink the below panel (got \(b))")
    }
}
