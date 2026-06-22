import XCTest
@testable import ViewerCore

/// TSK-709 (owner spec, seq 8818): ⌘K is FREED for the terminal; the command
/// palette opens on ⇧⌘P (nav.showPalette) + double-Shift. Pins both halves so a
/// rebind regresses here. (The menu key-handling itself is the VM/render tail;
/// this pins the binding DEFINITION the menu reads via applyShortcut.)
final class QuickOpenShortcutTests: XCTestCase {

    private func shortcut(_ id: String) -> Shortcut? {
        CommandRegistry.builtIn.commands.first { $0.id == id }?.defaultShortcut
    }

    func test_quickOpen_no_longer_binds_cmdK() {
        let sc = shortcut("view.quickOpen")
        XCTAssertNil(sc, "view.quickOpen must not bind ⌘K (freed for the terminal), got \(String(describing: sc))")
    }

    func test_commandPalette_binds_cmdShiftP() {
        let sc = shortcut("nav.showPalette")
        XCTAssertEqual(sc?.key, "p")
        XCTAssertEqual(sc?.modifiers, [.command, .shift])
    }

    func test_no_builtin_command_binds_cmdK() {
        // Nothing may claim ⌘K now, so the terminal can use it (owner ask).
        let claimants = CommandRegistry.builtIn.commands.filter {
            $0.defaultShortcut?.key == "k" && $0.defaultShortcut?.modifiers == [.command]
        }
        XCTAssertTrue(claimants.isEmpty, "⌘K must be free, but is bound by: \(claimants.map(\.id))")
    }
}
