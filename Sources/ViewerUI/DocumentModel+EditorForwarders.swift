import Foundation
import Combine
import SwiftUI
import ViewerKit
import ViewerCore

// MARK: Editor lifecycle — forwarders to EditorCoordinator (Quality #2)
//
// Carved out of DocumentModel.swift (TSK-1110 — DocumentModel SRP split, slice 2).
// All editor-mode state (cursor / scroll persistence, pending diagnostics,
// goto-line nonce, indentation pref, save-on-blur) lives on `editor`. These
// thin forwarders keep call sites in ContentView / SettingsView / main.swift /
// ScriptRunner compiling unchanged. New code should observe `model.editor`
// directly so editor keystrokes / cursor ticks don't republish DocumentModel.
// Verbatim move — behavior is identical to the pre-split inline definitions.
extension DocumentModel {
    /// Forwarder. New code should write `editor.editorGotoLine`.
    public var editorGotoLine: CMGotoLineRequest? {
        get { editor.editorGotoLine }
        set { editor.editorGotoLine = newValue }
    }

    /// Forwarder. Read at the `CodeMirrorEditorView` call site
    /// (`insertRequest:`).
    public var editorInsertRequest: CMInsertRequest? {
        editor.editorInsertRequest
    }

    /// Edit → Insert Date & Time (TSK-299). Formats the current time in
    /// the user's locale and inserts it at the active editor's caret.
    /// No-op unless the selected tab is in editor mode.
    public func insertDateAndTime() {
        guard currentViewMode == .editor else { return }
        editor.insertIntoEditor(DateTimeStamp.string(for: Date()))
    }

    /// True when a snippet can be inserted — the active tab is in editor mode.
    public var canInsertSnippet: Bool { currentViewMode == .editor }

    /// Forwarder — read at the `CodeMirrorEditorView` call site
    /// (`selectRequest:`). Drives the snippet tab-stop caret walk.
    public var editorSelectRequest: CMSelectRequest? {
        editor.editorSelectRequest
    }

    /// Forwarder — read at the `CodeMirrorEditorView` call site
    /// (`snippetSessionActive:`). True while a snippet tab-stop session is live
    /// so the CM6 host's Tab keymap routes to `snippetTab`.
    public var isSnippetSessionActive: Bool { editor.isSnippetSessionActive }

    /// TSK-705 — insert `snippet`'s expanded text at the active editor caret AND
    /// begin a tab-stop navigation session if the snippet has stops (`$1`, `$2`,
    /// …, `$0`). The session's caret targets are computed from the insertion
    /// offset (the caret head BEFORE the insert) so subsequent Tab / Shift-Tab
    /// keypresses walk the placeholders. A snippet without tab stops just inserts
    /// the text (no session). No-op (returns false) unless in editor mode.
    @discardableResult
    public func insertSnippet(_ snippet: Snippet) -> Bool {
        guard currentViewMode == .editor else { return false }
        // The base offset for the session is where the inserted text will LAND
        // — the current caret head. CM6 inserts via `replaceSelection`, so if a
        // selection is active the snippet replaces it; we use the selection's
        // anchor (== head when collapsed) as the base. We read the last-known
        // caret from the editor cursor cache (fed by `cursorPositionChanged`).
        let base = tabs.selected.flatMap { editor.editorCursorByTab[$0.id]?.head } ?? 0
        editor.insertIntoEditor(snippet.parsed.plainText)
        editor.beginSnippetSession(snippet, insertedAt: base)
        return true
    }

    /// TSK-705 — drive the active snippet session forward (Tab) or back
    /// (Shift-Tab). Invoked by the editor view when the CM6 host posts
    /// `snippetTab` (the user pressed Tab inside a live session). Returns
    /// whether a session was active and handled the keypress.
    @discardableResult
    public func snippetTab(forward: Bool) -> Bool {
        forward ? editor.snippetTab() : editor.snippetShiftTab()
    }
}
