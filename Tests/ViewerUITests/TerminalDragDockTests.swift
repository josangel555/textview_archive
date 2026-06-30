import XCTest
import Foundation
import ViewerCore
@testable import ViewerUI

/// TSK-1317 — dragging the terminal shoulder icon onto a shoulder docks the
/// terminal pane to that edge (the drag-driven equivalent of the Settings
/// pane-placement picker). Host-tests the model/closure layer + the exported-UTI
/// declaration; the literal pointer drag itself is the AX tier.
@MainActor
final class TerminalDragDockTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "TerminalDragDockTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }
    override func tearDown() async throws {
        if let suiteName { defaults?.removePersistentDomain(forName: suiteName) }
    }

    func test_shoulderEdge_mapsToTerminalPaneEdge() {
        // The single arbiter of "drop on shoulder X → dock the pane to X".
        // Hardcoded expectations (independent oracle) — a swapped case fails here.
        XCTAssertEqual(terminalPaneEdge(forShoulder: .left), .left)
        XCTAssertEqual(terminalPaneEdge(forShoulder: .right), .right)
        XCTAssertEqual(terminalPaneEdge(forShoulder: .bottom), .bottom)
    }

    func test_drop_docksPaneToEdge_andOpensClosedTerminal() {
        let store = TerminalPaneStore(defaults: defaults)
        XCTAssertFalse(store.isOpen, "precondition: a fresh terminal starts closed")
        applyTerminalShoulderDrop(.right, to: store)
        XCTAssertEqual(store.paneEdge, .right, "drop on the right shoulder docks the pane right")
        XCTAssertTrue(store.isOpen, "a drop makes the terminal visible (else nothing appears)")
    }

    func test_drop_onOpenTerminal_movesEdge_staysOpen() {
        let store = TerminalPaneStore(defaults: defaults)
        store.toggle()                       // open it
        XCTAssertTrue(store.isOpen)
        applyTerminalShoulderDrop(.left, to: store)
        XCTAssertEqual(store.paneEdge, .left)
        XCTAssertTrue(store.isOpen, "moving an already-open terminal must NOT toggle it closed")
    }

    /// TSK-327/1317 footgun: a `UTType(exportedAs:)` UTI MUST be declared in the
    /// app Info.plist's UTExportedTypeDeclarations, or the drag payload writes to
    /// the pasteboard but no drop zone ever accepts it (the silently-dead drag —
    /// invisible to host render tests). Pin the declaration so it can't regress.
    func test_terminalDragUTI_declaredInInfoPlist() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ViewerUITests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        let plist = root.appendingPathComponent("scripts/Info.plist")
        let text = try String(contentsOf: plist, encoding: .utf8)
        XCTAssertTrue(text.contains("com.markdownviewer.terminal-drag"),
                      "the terminal-drag UTI must be declared in UTExportedTypeDeclarations")
    }
}
