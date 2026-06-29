import Foundation
import ViewerCore

// In-app terminal launching (TSK-1110 SRP slice; TSK-769/914) — open a terminal
// tab cd'd to a file's/folder's directory, and insert a favorite command at the
// prompt. The `terminalPane` coordinator + `terminalFavorites` store stay on
// DocumentModel. Behavior-preserving move out of DocumentModel.swift.
extension DocumentModel {

    /// Open a terminal tab `cd`'d to the focused file's folder (TSK-769
    /// "Open Terminal Here"). Adds the located tab BEFORE opening the pane so
    /// `setOpen`'s `ensureTerminal` doesn't also spawn a default home tab.
    /// With no focused file the new terminal falls back to the shell's home.
    public func openTerminalHere() {
        let cwd = TerminalCwd.workingDirectory(forFocusedFile: currentURL)
        terminalPane.addTab(workingDirectory: cwd)
        terminalPane.setOpen(true)
    }

    /// TSK-914: "Open in Terminal" on a sidebar node opens the IN-APP terminal
    /// (a new tab in the embedded pane), cd'd to the node's directory — a file's
    /// containing folder, or the folder itself — NOT a system Terminal.app
    /// window. `isDirectory` comes from the file tree (see TerminalCwd note).
    public func openTerminalInApp(at url: URL, isDirectory: Bool) {
        let cwd = TerminalCwd.workingDirectory(for: url, isDirectory: isDirectory)
        terminalPane.addTab(workingDirectory: cwd)
        terminalPane.setOpen(true)
    }

    /// Insert a favorite at the in-app terminal prompt (TSK-769): open the pane
    /// (spawning a tab if none is live) and type the command WITHOUT a trailing
    /// newline — the user reviews + presses Return. Returns false on a blank
    /// command or when no live terminal can receive it.
    @discardableResult
    public func insertTerminalFavorite(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if terminalPane.terminal == nil {
            terminalPane.addTab(
                workingDirectory: TerminalCwd.workingDirectory(forFocusedFile: currentURL))
        }
        terminalPane.setOpen(true)
        guard let term = terminalPane.terminal else { return false }
        term.sendString(trimmed)
        return true
    }
}
