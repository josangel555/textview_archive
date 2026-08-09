import XCTest
@testable import ViewerUI

/// The 2026-08-01 resize-lag class (owner screen recording): a resize
/// handle's `DragGesture` measured in the DEFAULT `.local` space — the space
/// of the very view the drag moves — under-reports translation by the applied
/// delta each frame. The math degenerates to `W_n = 2·W₀ − W_{n−1} − g_n`: an
/// oscillator (the flicker) whose average tracks the pointer at HALF speed
/// (the boundary trailed ~450px on a ~900px drag). Two sites additionally
/// re-read the LIVE value as the drag base each tick (double-integration).
///
/// Rule pinned here: every resize-handle `DragGesture` declares
/// `coordinateSpace: .global` (the window doesn't move during these drags).
final class ResizeGestureSpaceAuditTests: XCTestCase {

    /// file → expected count of resize DragGestures (ALL must be .global).
    /// (Terminal/TerminalView.swift left the audit 2026-08-09 — both terminal
    /// resize handles were deleted with the terminal-as-a-panel rework; the
    /// terminal now resizes via the audited dock/divider handles.
    /// DockedToolWindow.swift stays at 2: the right pane's edge handle + the
    /// tabbed bottom dock's gutter.)
    private static let resizeFiles: [(String, Int)] = [
        ("DraggableSidebar.swift", 1),
        ("DockedToolWindow.swift", 2),
        ("ResizableSectionDivider.swift", 1),
        ("CSVTableView.swift", 1),
        ("SQLiteBrowserView.swift", 1),
    ]

    func test_everyResizeDrag_measuresInGlobalSpace() throws {
        let uiRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ViewerUI")
        for (file, expected) in Self.resizeFiles {
            let src = try String(
                contentsOf: uiRoot.appendingPathComponent(file), encoding: .utf8)
            let all = src.components(separatedBy: "DragGesture(").count - 1
            let global = src.components(
                separatedBy: "coordinateSpace: .global").count - 1
            XCTAssertEqual(all, expected,
                "\(file): expected \(expected) DragGesture site(s), found \(all) — "
                + "a NEW drag here must join this audit")
            XCTAssertEqual(global, expected,
                "\(file): every resize DragGesture must declare "
                + "coordinateSpace: .global (found \(global)/\(all)) — the default "
                + ".local space MOVES with the resized view (oscillator + half-speed lag)")
        }
    }
}
