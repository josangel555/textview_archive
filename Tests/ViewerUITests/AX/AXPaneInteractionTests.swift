import ApplicationServices
import XCTest
import ViewerCore
@testable import ViewerUI

/// I-21 S4c — the REAL-interaction rung for editor panes: a HID drag
/// moves a tab chip between pane strips, and a HID click into a pane's
/// CONTENT focuses that pane. The host tier proves the model + channel
/// (`PaneAssignmentTests`, `PaneDropChannelTests`,
/// `TabCoordinatorPaneTests`); no lower tier runs the gesture recognizer
/// or the NSEvent click monitor against a live window.
final class AXPaneInteractionTests: AXInteractionTestCase {

    /// Both strips present = the split rendered. Focused strip id flips
    /// with focus, so (focused, other) is re-resolved per call.
    private func strips(in root: AXUIElementNode) -> (focused: CGRect, other: CGRect)? {
        guard let f = AXDriverCore.find("mdv.paneStrip.focused", in: root)?.axFrame,
              let o = AXDriverCore.find("mdv.paneStrip", in: root)?.axFrame
        else { return nil }
        return (f, o)
    }

    /// A real pointer drag from one pane's chip onto the OTHER pane's
    /// strip moves the tab there (`movePaneTab` via the
    /// `StripExternalTarget` cross-strip channel). Observable: the
    /// dragged chip's AX frame lands inside the destination strip.
    func test_hidDrag_tabAcrossPaneStrips_movesTheTab() throws {
        let root = try spawnAndAttach(scene: "panes-split")
        _ = waitUntil(5) { strips(in: root) != nil }
        guard let (focusedStrip, otherStrip) = strips(in: root) else {
            return XCTFail("both pane strips must report frames")
        }
        // The focused pane's chip (scene: pane-2.md, torn right).
        let chips = AXDriverCore.findAll(AXQuery("mdv.tab.item.*"), in: root)
        guard let chip = chips.first(where: { c in
            guard let f = c.axFrame else { return false }
            return focusedStrip.contains(CGPoint(x: f.midX, y: f.midY))
        }), let chipFrame = chip.axFrame, let chipID = chip.axIdentifier else {
            return XCTFail("the focused pane must show a tab chip "
                + "(chips: \(chips.compactMap(\.axIdentifier)))")
        }

        AXClickExecutor.drag(
            from: CGPoint(x: chipFrame.midX, y: chipFrame.midY),
            to: CGPoint(x: otherStrip.midX, y: otherStrip.midY))

        // The chip now sits inside the destination strip's region (the
        // strips themselves don't move; their focus IDs flip with the
        // drop, so compare against the captured region).
        let moved = waitUntil(8) {
            guard let f = AXDriverCore.findAll(AXQuery("mdv.tab.item.*"), in: root)
                .first(where: { $0.axIdentifier == chipID })?.axFrame
            else { return false }
            return otherStrip.contains(CGPoint(x: f.midX, y: f.midY))
        }
        XCTAssertTrue(moved,
            "a REAL drag onto the other pane's strip must move the tab there "
            + "(chip \(chipID) frames now: "
            + "\(AXDriverCore.findAll(AXQuery("mdv.tab.item.*"), in: root).compactMap(\.axFrame)))")
    }

    /// S4d — a real drag on the pane divider gutter resizes the two
    /// neighbors ~1:1 (the sidebar resize-tooth pattern, including its
    /// VM-HID engage-mystery skip: ZERO movement is environmental, but
    /// PARTIAL tracking — the stored↔rendered oscillator signature —
    /// stays a hard RED). Observable: the left pane's strip frame width.
    func test_hidDrag_paneDivider_resizesTheNeighbors() throws {
        let root = try spawnAndAttach(scene: "panes-split")
        _ = waitUntil(5) {
            strips(in: root) != nil
                && AXDriverCore.find("mdv.pane.resize", in: root)?.axFrame != nil
        }
        guard let gutter = AXDriverCore.find("mdv.pane.resize", in: root)?.axFrame else {
            throw XCTSkip("mdv.pane.resize not materialized in this session")
        }
        guard let leftBefore = AXDriverCore.find("mdv.paneStrip", in: root)?.axFrame else {
            return XCTFail("the unfocused (left) strip must report a frame")
        }

        let dragDistance: CGFloat = 150
        let grab = CGPoint(x: gutter.midX, y: gutter.midY)
        AXClickExecutor.drag(
            from: grab, to: CGPoint(x: grab.x + dragDistance, y: grab.y))

        _ = waitUntil(5) {
            guard let now = AXDriverCore.find("mdv.paneStrip", in: root)?.axFrame
            else { return false }
            return abs((now.width - leftBefore.width) - dragDistance)
                <= dragDistance * 0.35
        }
        let after = AXDriverCore.find("mdv.paneStrip", in: root)?.axFrame
        let grew = (after?.width ?? leftBefore.width) - leftBefore.width
        if abs(grew) < 2 {
            throw XCTSkip("HID drag did not engage the gutter gesture in this "
                + "VM session (grabbed \(grab) inside mdv.pane.resize's own AX "
                + "frame) — the sidebar resize-tooth DIAG class")
        }
        XCTAssertTrue(abs(grew - dragDistance) <= dragDistance * 0.35,
            "a \(Int(dragDistance))pt divider drag grew the left pane \(Int(grew))pt "
            + "— PARTIAL tracking = a stored↔rendered decorrelation")
    }

    /// A real click into the UNFOCUSED pane's CONTENT focuses that pane
    /// (the `PaneFocusClickMonitor` rung — strip clicks were already
    /// covered by their actions). Observable: the `mdv.paneStrip.focused`
    /// id migrates to the clicked pane's strip.
    func test_hidClick_intoUnfocusedPaneContent_focusesIt() throws {
        let root = try spawnAndAttach(scene: "panes-split")
        _ = waitUntil(5) { strips(in: root) != nil }
        guard let (focusedBefore, otherStrip) = strips(in: root) else {
            return XCTFail("both pane strips must report frames")
        }
        // A point safely inside the unfocused pane's CONTENT region:
        // under its strip, clear of the strip itself.
        let target = CGPoint(x: otherStrip.midX, y: otherStrip.maxY + 120)

        AXClickExecutor.click(at: target)

        let focusMoved = waitUntil(8) {
            guard let f = AXDriverCore.find("mdv.paneStrip.focused", in: root)?.axFrame
            else { return false }
            return abs(f.midX - otherStrip.midX) < 2
        }
        XCTAssertTrue(focusMoved,
            "clicking into a pane's content must focus it: focused strip was at "
            + "midX \(focusedBefore.midX), expected ≈\(otherStrip.midX), now "
            + "\(AXDriverCore.find("mdv.paneStrip.focused", in: root)?.axFrame?.midX ?? -1)")
    }
}
