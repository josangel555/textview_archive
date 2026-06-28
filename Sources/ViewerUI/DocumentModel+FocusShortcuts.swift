import Foundation
import Combine
import SwiftUI
import ViewerKit
import ViewerCore

// MARK: - Focus shortcuts (TSK-937)
//
// Carved out of DocumentModel.swift (TSK-1110 — DocumentModel SRP split). Move
// keyboard focus to a specific surface via the same focus-request nonce idiom as
// `editorFocusRequest` / `previewFocusRequest` / `gitPanelFocusRequest`: a
// monotonically-bumped `Int` the target view observes with `.onChange` and
// consumes by taking first responder. SwiftUI's value-blind publish dedupes
// identical values, so a nonce (never the same twice) guarantees a repeat
// "focus X" ask isn't swallowed. Each command is enablement-gated on its target
// surface's visibility so a hidden target's menu item / palette entry greys out.
// The `*FocusRequest` nonce STATE stays on the main class (an extension can't
// declare stored `@Published`); these are the gates + actions that drive it.
extension DocumentModel {

    /// True iff the terminal pane is open — the only state in which the
    /// terminal surface can take focus. Gates "Focus Terminal".
    public var canFocusTerminal: Bool { terminalPane.isOpen }

    /// True iff the Files panel has data to show (a folder root is open).
    /// Mirrors `SidebarDataPresence` for `.files` (`hasRoot`). Gates
    /// "Focus File Navigator".
    public var canFocusFileNav: Bool { sidebar.rootURL != nil }

    /// True iff there's an active document tab whose surface can take focus.
    /// Gates "Focus Active File".
    public var canFocusActiveDocument: Bool { tabs.selected != nil }

    /// Focus the in-app terminal. Opens the pane if it's closed (so the
    /// command is useful even when the terminal is dismissed) and bumps the
    /// focus nonce so the surface takes first responder. No-op-safe: the
    /// menu/palette gate already requires `canFocusTerminal`, but the open
    /// here keeps the action robust if invoked headlessly.
    public func focusTerminal() {
        if !terminalPane.isOpen { terminalPane.setOpen(true) }
        terminalFocusRequest &+= 1
    }

    /// Focus the Files (file-nav) panel. Ensures the sidebar is visible
    /// (the file tree lives inside it) then bumps the focus nonce.
    public func focusFileNav() {
        if sidebar.rootURL != nil { sidebar.isVisible = true }
        fileNavFocusRequest &+= 1
    }

    /// Focus the Git panel (status tab). Thin alias over `showGitPanel`
    /// so the focus-shortcut family reads uniformly; reuses the existing
    /// expand + focus + tab-select plumbing.
    public func focusGitPanel() {
        showGitPanel(tab: .status)
    }

    /// Focus the active document surface (editor / source / rendered
    /// preview). Bumps the document-focus nonce the active surface observes.
    public func focusActiveDocument() {
        documentFocusRequest &+= 1
    }
}
