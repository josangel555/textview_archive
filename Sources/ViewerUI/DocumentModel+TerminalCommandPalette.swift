import Foundation
import ViewerCore

/// TSK-1176 — the Terminal Command Palette's DocumentModel wiring: open the palette seeded
/// over the live favorites + command history. The @Published flag + view-model live on
/// DocumentModel (stored props can't be in an extension); this is the open method. The
/// presentation (.sheet) + trigger + PTY-insert are the view-side companions; this is
/// host-testable.
extension DocumentModel {

    /// Open the Terminal Command Palette, seeded over the live favorites store + the
    /// process-wide command history (the chosen command is inserted via
    /// `insertTerminalFavorite`, the existing no-newline PTY-insert path).
    public func openTerminalCommandPalette() {
        terminalCommandPaletteVM = TerminalCommandPaletteViewModel(
            favorites: terminalFavorites,
            history: TerminalCommandHistory.shared)
        showTerminalCommandPalette = true
    }
}
