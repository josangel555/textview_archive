import Foundation
import ViewerCore

/// TSK-1475 — the terminal-favorites editor's DocumentModel wiring: open the
/// management editor over the live favorites store. The @Published flag +
/// view-model live on DocumentModel (stored props can't be in an extension);
/// this is the open method. The presentation (.sheet) + the "Manage Favorites…"
/// menu trigger are the view-side companions; this is host-testable.
extension DocumentModel {

    /// Open the terminal-favorites management editor, seeded from the live
    /// favorites store (a fresh view-model each open so it mirrors current
    /// order). Supersedes the old raw-JSON-file edit path.
    public func openTerminalFavoritesEditor() {
        terminalFavoritesEditorVM = TerminalFavoritesEditorModel(store: terminalFavorites)
        showTerminalFavoritesEditor = true
    }
}
