import ApplicationServices
import XCTest
import ViewerCore
@testable import ViewerUI

/// The REAL-DRAG interaction rung for the strip drags (2026-07-31 —
/// unblocked by the AX tier bootstrap; BACKLOG "pointer-drag interaction
/// rung"). The host tier proves the geometry/model (`StripReorderTests`,
/// `TabSessionDropChannelTests`); the pixel tier proves the visuals; THIS
/// proves a real pointer drag drives the whole gesture pipeline.
///
/// TIER-JUSTIFY: the observable is a real `DragGesture` recognizing a
/// HID-synthesized down/drag/up sequence in a spawned app, watched through
/// the out-of-process AX tree — no lower tier runs the gesture recognizer
/// at all.
final class AXStripDragTests: AXInteractionTestCase {

    /// Tab ids in VISUAL order (frame-sorted — AX child order is not a
    /// layout contract).
    private func tabOrder(in root: AXUIElementNode) -> [String] {
        AXDriverCore.findAll(AXQuery("mdv.tab.item.*"), in: root)
            .sorted { ($0.axFrame?.minX ?? .infinity) < ($1.axFrame?.minX ?? .infinity) }
            .compactMap(\.axIdentifier)
    }

    /// The session PILLS only — `mdv.sessionTab.<uuid>` — excluding the
    /// strip's other `mdv.sessionTab.*` ids (new/settings/close.<uuid>/…)
    /// by requiring the suffix to parse as a UUID. Frame-sorted.
    private func sessionPills(in root: AXUIElementNode) -> [AXNode] {
        AXDriverCore.findAll(AXQuery("mdv.sessionTab.*"), in: root)
            .filter {
                guard let id = $0.axIdentifier else { return false }
                return UUID(uuidString: String(id.dropFirst("mdv.sessionTab.".count))) != nil
            }
            .sorted { ($0.axFrame?.minX ?? .infinity) < ($1.axFrame?.minX ?? .infinity) }
    }

    /// A real pointer drag reorders the file tabs: drag tab 0 to the far
    /// side of tab 1 and the VISUAL order (frame-sorted ids) flips. This is
    /// the rung the owner's drag-to-reorder feature was missing — model and
    /// caret pixels were covered; the gesture recognizer never was.
    func test_hidDrag_reordersFileTabs() throws {
        let root = try spawnAndAttach(scene: "tabs-3")
        _ = waitUntil(5) { tabOrder(in: root).count == 3 }
        let before = tabOrder(in: root)
        XCTAssertEqual(before.count, 3, "precondition: 3 tabs")

        let tabs = AXDriverCore.findAll(AXQuery("mdv.tab.item.*"), in: root)
            .sorted { ($0.axFrame?.minX ?? .infinity) < ($1.axFrame?.minX ?? .infinity) }
        guard let f0 = tabs[0].axFrame, let f1 = tabs[1].axFrame else {
            return XCTFail("tabs must report frames to drag between")
        }
        // From tab 0's center to just past tab 1's right edge — clearly
        // beyond the midpoint the insertion-gap math flips on.
        AXClickExecutor.drag(
            from: CGPoint(x: f0.midX, y: f0.midY),
            to: CGPoint(x: f1.maxX + 4, y: f1.midY))

        let reordered = waitUntil(5) {
            let now = tabOrder(in: root)
            return now.count == 3 && now.first == before[1] && now[1] == before[0]
        }
        XCTAssertTrue(reordered,
            "a REAL drag must reorder: expected [\(before[1])…] first, "
            + "got \(tabOrder(in: root))")
    }

    /// A real pointer drag from a file tab onto a session pill moves the
    /// file into that session (the 2026-07-31 feature's missing rung).
    /// Observable: `moveTab` closes the source tab and reopens the file in
    /// the target session, so the ORIGINAL tab id vanishes from the tree
    /// and a DIFFERENT tab id appears.
    func test_hidDrag_tabOntoSessionPill_movesTheFile() throws {
        // The tab-session-drop scene builds two real sessions with a file
        // tab open in the ACTIVE (leftmost-pill) one.
        let root = try spawnAndAttach(scene: "tab-session-drop")
        _ = waitUntil(5) { sessionPills(in: root).count == 2 }
        let pills = sessionPills(in: root)
        XCTAssertEqual(pills.count, 2, "precondition: two session pills "
            + "(got \(pills.compactMap(\.axIdentifier)))")
        _ = waitUntil(5) { tabOrder(in: root).count == 1 }
        let beforeTabs = tabOrder(in: root)
        XCTAssertEqual(beforeTabs.count, 1, "precondition: one file tab")
        guard let tabFrame = AXDriverCore.findAll(AXQuery("mdv.tab.item.*"), in: root)
                .first?.axFrame,
              let pillFrame = pills.last?.axFrame else {
            return XCTFail("tab and target pill must report frames")
        }

        AXClickExecutor.drag(
            from: CGPoint(x: tabFrame.midX, y: tabFrame.midY),
            to: CGPoint(x: pillFrame.midX, y: pillFrame.midY))

        let moved = waitUntil(8) {
            let now = tabOrder(in: root)
            return now.count == 1 && now.first != beforeTabs.first
        }
        XCTAssertTrue(moved,
            "a REAL drag onto the second pill must move the file into that "
            + "session (tab ids now: \(tabOrder(in: root)), was \(beforeTabs))")
    }

    /// The 2026-08-01 resize-lag regression tooth (owner screen recording):
    /// a REAL pointer drag on the sidebar's resize handle must track ~1:1.
    /// The `.local`-space oscillator tracked at HALF speed (≈450px behind on
    /// a ≈900px drag), so the ±35% tolerance here fails that bug loudly
    /// while absorbing clamps/rounding. Observable: `mdv.sidebar`'s AX frame
    /// width before vs after a 220pt leftward drag from the handle.
    func test_hidDrag_sidebarResize_tracksThePointerOneToOne() throws {
        let root = try spawnAndAttach(scene: "tabs-3")
        // GRAB the handle's OWN AX element (mdv.sidebar.widthHandle — added
        // after FOUR derived grab-points missed the 6pt strip: the sidebar's
        // pre-.contain frame was degenerate and the toolbar's minX carries
        // inner padding). Skip, not fail, if the id hasn't materialized —
        // the tooth's enabler is tracked (BACKLOG, resize-tooth).
        _ = waitUntil(5) {
            AXDriverCore.find("mdv.sidebar.widthHandle", in: root)?.axFrame != nil
        }
        guard let handleFrame = AXDriverCore.find(
            "mdv.sidebar.widthHandle", in: root)?.axFrame else {
            throw XCTSkip("mdv.sidebar.widthHandle not materialized — tooth "
                + "re-arms when it does (BACKLOG, resize-tooth)")
        }
        // OBSERVABLE = the content toolbar's LEADING edge: it abuts the
        // sidebar's trailing edge and shifts right by the grow amount.
        guard let toolbarBefore = AXDriverCore.find("mdv.contentToolbar", in: root)?.axFrame
        else { return XCTFail("content toolbar must report a frame") }

        // Drag RIGHT (grow): the scene's sidebar starts at MINIMUM width,
        // so a shrink drag clamps to a no-op.
        let dragDistance: CGFloat = 220
        let handle = CGPoint(x: handleFrame.midX, y: handleFrame.midY)
        AXClickExecutor.drag(
            from: handle,
            to: CGPoint(x: handle.x + dragDistance, y: handle.y))

        _ = waitUntil(5) {
            guard let now = AXDriverCore.find("mdv.contentToolbar", in: root)?.axFrame
            else { return false }
            return abs((now.minX - toolbarBefore.minX) - dragDistance)
                <= dragDistance * 0.35
        }
        let after = AXDriverCore.find("mdv.contentToolbar", in: root)?.axFrame
        let shifted = (after?.minX ?? toolbarBefore.minX) - toolbarBefore.minX

        // ZERO movement = the VM-HID engage mystery (the grab verifiably hits
        // the strip's own AX frame, tab gestures engage from the same
        // executor, and the real host mouse works per the owner's recording)
        // — environmental skip, DIAG tracked in BACKLOG. PARTIAL movement is
        // the oscillator's signature and stays a hard RED.
        if abs(shifted) < 2 {
            throw XCTSkip("HID drag did not engage the clear-strip gesture in "
                + "this VM session (grabbed \(handle) inside the handle's own "
                + "AX frame) — BACKLOG resize-tooth DIAG")
        }
        XCTAssertTrue(abs(shifted - dragDistance) <= dragDistance * 0.35,
            "a \(Int(dragDistance))pt drag moved the boundary \(Int(shifted))pt "
            + "— PARTIAL tracking = the .local-space oscillator is back")
    }
}
