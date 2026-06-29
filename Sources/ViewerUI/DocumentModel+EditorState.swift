import Foundation
import ViewerKit
import ViewerCore

// Editor-coordinator state forwarders + the CM6 mount-time scroll/selection seed
// (TSK-1110 SRP slice). Thin forwarders to EditorCoordinator for indentation,
// cursor/scroll persistence, diagnostics, gutter markers, and fold ranges, plus
// the `editorMountSelectionSeed` resolution (caret-wins, else restored-scroll
// line → offset). Behavior-preserving move out of DocumentModel.swift.
extension DocumentModel {

    /// Forwarder. New code should bind `$editor.editorIndentation`.
    public var editorIndentation: CMIndentation {
        get { editor.editorIndentation }
        set { editor.editorIndentation = newValue }
    }

    /// Forwarder. New code should read `editor.editorCursorByTab`.
    public var editorCursorByTab: [UUID: CMCursorPosition] {
        editor.editorCursorByTab
    }

    /// Forwarder. New code should read `editor.editorScrollByTab`.
    public var editorScrollByTab: [UUID: CMScrollPosition] {
        editor.editorScrollByTab
    }

    public func recordEditorCursor(_ pos: CMCursorPosition, forTabID id: UUID) {
        editor.recordEditorCursor(pos, forTabID: id)
    }

    public func recordEditorScroll(_ pos: CMScrollPosition, forTabID id: UUID) {
        editor.recordEditorScroll(pos, forTabID: id)
        // TSK-719: the pinned sticky-scroll headers depend on the top-visible
        // line — refresh them when the selected tab scrolls.
        if tabs.selected?.id == id { recomputeStickyScrollHeaders() }
    }

    /// Forwarder. See `EditorCoordinator.seedEditorScroll`.
    public func seedEditorScroll(fromTopLine line: Int, forTabID id: UUID) {
        editor.seedEditorScroll(fromTopLine: line, forTabID: id)
    }

    /// TSK-1046 (render-path scroll restore): the once-per-mount CM6 seed for
    /// the editor tab `id`, used by `ContentView` to drive `initialSelection`.
    ///
    /// This closes the render gap behind the TSK-1037 model fix: `restoreScroll`
    /// → `seedEditorScroll` re-injects the persisted top line into
    /// `editorScrollByTab`, but the ONLY mount-time CM6 scroll path is the
    /// `initialSelection` seed — and that was built solely from
    /// `editorCursorByTab` (the caret). A session/tab switch-IN that restores a
    /// SCROLL position but no caret therefore left CM6 at the top: the seeded
    /// dict was read by `captureScroll`/sticky-headers but never applied to the
    /// live editor. So the on-screen scroll reset even though the model had it.
    ///
    /// Resolution order (cursor wins — a restored caret already scrolls itself
    /// into view via `setSelection(scroll: true)`):
    ///   1. a restored caret (`editorCursorByTab`) → collapsed selection there;
    ///   2. else a restored scroll top line (`editorScrollByTab`) → collapsed
    ///      selection at that LINE START (UTF-16 offset), `scroll: true`, so CM6
    ///      brings that line to the top of the viewport on mount;
    ///   3. else nil (leave at the document start).
    ///
    /// The line→offset conversion uses the tab's live editor buffer text (or its
    /// loaded-from-disk text for a not-yet-materialized buffer) and clamps into
    /// range, so a stale/over-long line can't seed past the document end.
    public func editorMountSelectionSeed(forTabID id: UUID) -> CMSelectionSeed? {
        // 1. A restored caret takes precedence and already scrolls to itself.
        if let cursor = editor.editorCursorByTab[id] {
            return CMSelectionSeed(anchor: cursor.head, head: cursor.head, scroll: true)
        }
        // 2. No caret, but a restored scroll top line — seed a collapsed
        //    selection at that line's start so CM6 scrolls it into view.
        guard let line = editor.editorScrollByTab[id]?.viewportFromLine, line > 1 else {
            return nil
        }
        guard let text = editorTextForSeed(tabID: id), !text.isEmpty else { return nil }
        let converter = LSPPositionConverter(text: text, encoding: .utf16)
        // LSPPosition is 0-based; line-start = character 0.
        let rawOffset = converter.utf16Offset(
            for: LSPPosition(line: line - 1, character: 0))
        let offset = max(0, min(text.utf16.count, rawOffset))
        return CMSelectionSeed(anchor: offset, head: offset, scroll: true)
    }

    /// The text used by `editorMountSelectionSeed` to convert a 1-based top line
    /// into a UTF-16 offset: the live editor buffer if materialized, else the
    /// tab's loaded-from-disk contents. nil when neither is available (a tab not
    /// yet loaded — the seed then falls back to "no scroll seed").
    private func editorTextForSeed(tabID id: UUID) -> String? {
        if let buf = editor.editorBuffer(forTabID: id)?.text { return buf }
        guard let tab = tabs.tabs.first(where: { $0.id == id }) else { return nil }
        return Self.loadedText(of: tab)
    }

    /// Forwarder. See `EditorCoordinator.setEditorDiagnostics`.
    public func setEditorDiagnostics(_ diags: [LSPDiagnostic], forURL url: URL) {
        editor.setEditorDiagnostics(diags, forURL: url)
    }

    /// Forwarder. New code should read `editor.pendingEditorDiagnostics`.
    public var pendingEditorDiagnostics: [UUID: [CMDiagnostic]] {
        editor.pendingEditorDiagnostics
    }

    public func consumePendingEditorDiagnostics(forTabID id: UUID) {
        editor.consumePendingEditorDiagnostics(forTabID: id)
    }

    /// Forwarder. New code should read `editor.pendingEditorGutterMarkers`.
    public var pendingEditorGutterMarkers: [UUID: [CMGutterMarker]] {
        editor.pendingEditorGutterMarkers
    }

    /// Forwarder. New code should read `editor.editorFoldRangesByTab`.
    /// Read at the `CodeMirrorEditorView` call site (`foldingRanges:`).
    public var editorFoldRangesByTab: [UUID: [CMFoldRange]] {
        editor.editorFoldRangesByTab
    }

    public func consumePendingEditorGutterMarkers(forTabID id: UUID) {
        editor.consumePendingEditorGutterMarkers(forTabID: id)
    }
}
