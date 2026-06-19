import Foundation
import Combine
import AppKit
import ViewerKit
import ViewerCore

/// Owns the CM6 editor mode lifecycle: ⌘S / save path, dirty tracking,
/// close-prompt routing, external-edit conflict prompt,
/// `editorGotoLine`, per-tab cursor + scroll persistence, pending
/// diagnostics fan-out, and the two editor-only preferences
/// (`editorIndentation`, `saveEditorOnBlur`).
///
/// Extracted from `DocumentModel` (Quality #2, 2026-05-25) so that
/// views observing `DocumentModel` (TabBar, Sidebar, StatusBar) stop
/// re-rendering on every editor keystroke / cursor tick, and inversely
/// so editor-side mutations stop riding the DocumentModel publish chain.
///
/// Precedent: `FindCoordinator` (find state), `TabCoordinator` (tabs +
/// per-tab caches). Same shape — child `ObservableObject` hung off
/// DocumentModel, forwarders on the parent so existing call sites
/// compile unchanged.
///
/// ## editorBuffers ownership
///
/// `editorBuffers` stays on `TabCoordinator` (referenced from here,
/// not migrated). Two reasons:
///   1. `cleanupAfterClose` already drops `editorBuffers` as part of
///      its single-fan-out invariant. Moving the dict here would force
///      a second cleanup channel and the regression `TabCoordinator`
///      was built to prevent.
///   2. The per-tab cleanup invariants for `TabCoordinator`'s six
///      dicts have heavy test coverage; expanding ownership would
///      duplicate that infrastructure here for little gain.
///
/// We DO own `editorCursorByTab`, `editorScrollByTab`, and
/// `pendingEditorDiagnostics` outright — those weren't touched by
/// `TabCoordinator`. Their cleanup wires through
/// `TabCoordinator.addCloseHook(_:)` so every close path drains them
/// in lock-step with the coordinator's built-in drains.
///
/// ## Side-effect injection
///
/// Save + reload paths need to pause/resume the file watcher and the
/// external-edit prompt needs to drive a `reload(url:at:)` on
/// DocumentModel. Those are surfaced as plain closures (`onPauseWatcher`,
/// `onResumeWatcher`, `onReloadFromDisk`) registered by DocumentModel
/// at init time. Coordinator stays UI-toolkit-free except for the two
/// NSAlert call sites, which are themselves overridable via
/// `dirtyClosePromptOverride` / `externalEditPromptOverride` so unit
/// tests can drive both paths without bringing up an NSApplication.
@MainActor
public final class EditorCoordinator: ObservableObject {

    // MARK: - Outcome enums

    /// Result of `confirmCloseIfDirty(...)`. Plain enum so view / app-
    /// delegate code can switch without leaking AppKit types.
    public enum DirtyClosePrompt: Sendable, Equatable {
        /// Save the buffer, then proceed with close.
        case save
        /// Drop the buffer, then proceed with close.
        case discard
        /// Abort the close entirely.
        case cancel
    }

    /// Result of the external-edit conflict prompt. Plain enum for the
    /// same reason as `DirtyClosePrompt`.
    public enum ExternalEditPrompt: Sendable, Equatable {
        /// Leave the buffer alone (refresh its disk fingerprint so the
        /// next dup watcher event doesn't re-prompt).
        case keepEdits
        /// Drop the buffer and reload from disk.
        case discardAndReload
    }

    // MARK: - Published editor surface

    /// Bumped each time the host wants the CM6 editor to scroll +
    /// place the caret on a 1-based line. The active
    /// `CodeMirrorEditorView` builds the `CMGotoLineRequest` from this.
    @Published public var editorGotoLine: CMGotoLineRequest? = nil

    /// Set to a fresh `CMInsertRequest` to insert text at the active
    /// editor's caret (TSK-299). The active `CodeMirrorEditorView` reads
    /// this and dispatches `insertAtCursor`. One-shot; nonce-distinct.
    @Published public var editorInsertRequest: CMInsertRequest? = nil

    /// Queue an insert-at-caret of `text` into the active CM6 editor.
    public func insertIntoEditor(_ text: String) {
        guard !text.isEmpty else { return }
        editorInsertRequest = CMInsertRequest(text: text)
    }

    // MARK: - Snippet tab-stop navigation (TSK-705)

    /// Set to a fresh `CMSelectRequest` to move the caret / select a range in
    /// the active CM6 editor (drives `setSelection`). One-shot; nonce-distinct.
    /// Used by the snippet tab-stop walker to jump the caret to each `$N`.
    @Published public var editorSelectRequest: CMSelectRequest? = nil

    /// The snippet expansion currently being navigated, if any. While non-nil
    /// the CM6 host intercepts Tab / Shift-Tab (it posts `snippetTab` /
    /// `snippetShiftTab` to Swift instead of indenting) so `snippetTab()` /
    /// `snippetShiftTab()` can walk the caret through the `$1 → $2 → … → $0`
    /// stops. Cleared once the final stop is passed (`isFinished`) or the user
    /// inserts another snippet / switches tabs.
    @Published public private(set) var activeSnippetSession: SnippetSession? = nil

    /// True while a snippet session is live — the flag handed to the CM6 host so
    /// its Tab keymap routes to the snippet walker. Mirrors
    /// `activeSnippetSession != nil`; a plain Bool the editor view can observe
    /// without unwrapping the value type.
    public var isSnippetSessionActive: Bool { activeSnippetSession != nil }

    /// Begin a tab-stop navigation session for `snippet` whose expanded plain
    /// text was just inserted at `baseOffset` (absolute UTF-16 doc offset).
    /// Selects the FIRST stop (`$1`, or `$0` for a single-stop snippet) and
    /// returns true; a snippet with no tab stops can't be navigated, so it
    /// returns false and leaves no session.
    @discardableResult
    public func beginSnippetSession(_ snippet: Snippet, insertedAt baseOffset: Int) -> Bool {
        guard let session = SnippetSession(snippet: snippet.parsed, insertedAt: baseOffset) else {
            activeSnippetSession = nil
            return false
        }
        activeSnippetSession = session
        selectCurrentSnippetStop()
        return true
    }

    /// Advance the active snippet session to the next stop and select it.
    /// Returns true when a session was active (the caller — the CM6 host's Tab
    /// binding — should then swallow the Tab); false when no session is live
    /// (Tab falls through to normal indent). When the final stop is passed the
    /// session ends (`endSnippetSession`) but the call still returns true: the
    /// snippet "consumed" that Tab to land the caret at `$0`.
    @discardableResult
    public func snippetTab() -> Bool {
        guard var session = activeSnippetSession else { return false }
        session.advance()
        if session.isFinished {
            // Walked off the end of a snippet with no explicit `$0` — leave the
            // caret where it is; the session is done.
            endSnippetSession()
            return true
        }
        activeSnippetSession = session
        selectCurrentSnippetStop()
        // Landing on the final `$0` is the exit: place the caret there, then end
        // the session so the next Tab indents normally.
        if session.current?.index == 0 {
            endSnippetSession()
        }
        return true
    }

    /// Retreat the active snippet session to the previous stop and select it.
    /// Returns true when a session is live (clamped at the first stop), false
    /// otherwise.
    @discardableResult
    public func snippetShiftTab() -> Bool {
        guard var session = activeSnippetSession else { return false }
        session.retreat()
        activeSnippetSession = session
        selectCurrentSnippetStop()
        return true
    }

    /// Tear down the active snippet session (final stop passed, or the user did
    /// something that invalidates the offsets — switching tabs, inserting
    /// another snippet). Idempotent.
    public func endSnippetSession() {
        activeSnippetSession = nil
    }

    /// Select the current stop of the active session, if any.
    private func selectCurrentSnippetStop() {
        guard let stop = activeSnippetSession?.current else { return }
        editorSelectRequest = CMSelectRequest(
            anchor: stop.offset, head: stop.offset + stop.length
        )
    }

    /// Indent setting for CM6 editor. Drives CM6's `indentUnit` + tab
    /// size facets via the v1 bridge. Defaults to 2 spaces (matches
    /// the bundle's `applySetIndentation` default).
    @Published public var editorIndentation: CMIndentation = .spaces(2)

    /// Save the active editor when the WKWebView loses focus. Off by
    /// default — opt-in via Settings. The CM6 host always posts
    /// `editorBlurred`; this flag gates whether Swift acts on it.
    @Published public var saveEditorOnBlur: Bool = false

    /// Last-known editor cursor position per tab. Used to restore the
    /// caret when the user switches tabs (CM6 view dismantles + remounts
    /// today; without persistence, every tab switch jumps to line 1).
    /// Phase 4 shared-WebView refactor (design doc §14.3) will obsolete
    /// this; for now it's the minimum-cost UX win.
    @Published public private(set) var editorCursorByTab: [UUID: CMCursorPosition] = [:]

    /// Last-known editor scroll position per tab. Persistence story:
    /// in-memory only for now (lives across tab switches inside a single
    /// session). Cross-session persistence is a Phase 3+ deliverable.
    @Published public private(set) var editorScrollByTab: [UUID: CMScrollPosition] = [:]

    /// TSK-743: editor scroll/cursor remembered per FILE URL for the ephemeral
    /// preview slot. The slot reuses ONE tab id across file swaps, so its
    /// id-keyed scroll/cursor is RESET on each swap (isolation — TSK-744); this
    /// is the complementary "remember & restore" half — re-previewing a file you
    /// scrolled earlier restores its position. FIFO-bounded so a long session
    /// previewing many distinct files can't grow it without limit.
    private var previewScrollByURL: [URL: CMScrollPosition] = [:]
    private var previewCursorByURL: [URL: CMCursorPosition] = [:]
    private var previewURLOrder: [URL] = []
    private let previewMemoryCap = 64

    /// Per-tab pending diagnostics payload. `CodeMirrorEditorView`
    /// reads + clears this on each `updateNSView` cycle so re-renders
    /// don't re-ship the same set.
    @Published public internal(set) var pendingEditorDiagnostics: [UUID: [CMDiagnostic]] = [:]

    /// Per-tab pending diff/blame gutter markers (added / modified /
    /// removed bars). Fed by `DocumentModel.refreshDiffMarks` (the
    /// off-main `git diff HEAD -- <path>` task) and consumed by the
    /// active `CodeMirrorEditorView` on its next `updateNSView` cycle.
    /// Empty array clears all markers for that tab.
    ///
    /// Mirror of `pendingEditorDiagnostics` in shape + lifecycle —
    /// drained in lock-step with the other three editor-owned dicts
    /// via the TabCoordinator close hook.
    @Published public internal(set) var pendingEditorGutterMarkers: [UUID: [CMGutterMarker]] = [:]

    /// Per-tab syntax fold ranges for the CM6 editor (TSK-466). Produced
    /// off-main by `DocumentModel.refreshEditorFolds` (TreeSitter
    /// `FoldRegion` → `SyntaxFoldRangeMapping` → CM6 `CMFoldRange`) and
    /// read at the `CodeMirrorEditorView` call site, which dedups via its
    /// own `lastSentFoldingRanges`. Mirror of the diagnostics/gutter
    /// dicts in shape + close-hook lifecycle. Empty array clears the
    /// editor's fold gutter for that tab.
    @Published public internal(set) var editorFoldRangesByTab: [UUID: [CMFoldRange]] = [:]

    /// Per-tab LINE-based fold regions (TSK-719 sticky scroll). Same producer
    /// as `editorFoldRangesByTab` (`refreshEditorFolds`), kept alongside the
    /// CM6-offset form because sticky scroll reasons in 1-based lines, not
    /// UTF-16 offsets. Cleared on tab close / preview-slot reuse like the rest.
    @Published public internal(set) var editorFoldRegionsByTab: [UUID: [FoldRegion]] = [:]

    // MARK: - Test seams

    /// Override the dirty-close NSAlert with a test-driven response.
    /// When non-nil, `confirmCloseIfDirty` returns the override's
    /// result instead of running the modal. UI / app code never sets
    /// this — only unit tests.
    public var dirtyClosePromptOverride: ((_ tab: ViewerCore.Tab) -> DirtyClosePrompt?)?

    /// Override the external-edit NSAlert with a test-driven response.
    /// Same shape as `dirtyClosePromptOverride`.
    public var externalEditPromptOverride: ((_ url: URL) -> ExternalEditPrompt)?

    // MARK: - Dependencies / injected effects

    /// TabCoordinator holds `editorBuffers` (the dict we don't own)
    /// and the tab list. Held weakly to avoid a strong DocumentModel →
    /// EditorCoordinator → TabCoordinator cycle (TabCoordinator lives
    /// on DocumentModel, so DocumentModel transitively owns both).
    private unowned let tabCoordinator: TabCoordinator

    /// Closure injected by DocumentModel to mirror the editor cursor
    /// position onto the shared `sourceSelection` field — the status
    /// bar's "Ln X, Col Y" readout reads `sourceSelection` for both
    /// source and editor modes. Nil during tests.
    public var onCursorMirrorToStatusBar: ((CMCursorPosition) -> Void)?

    /// Closures injected by DocumentModel so the save path can pause +
    /// resume the file watcher around the write. Nil during tests
    /// where the watcher isn't running anyway.
    public var onPauseFileWatcher: (() -> Void)?
    public var onResumeFileWatcherIfApplicable: ((URL?) -> Void)?
    /// Snapshot of the URL the watcher is currently bound to (read
    /// before pause). DocumentModel hands this through so the resume
    /// callback can decide whether to rebind.
    public var watchedURLSnapshot: (() -> URL?)?

    /// Reload the file at `url` into the tab at `index`. Called by the
    /// external-edit "Discard & Reload" branch. DocumentModel owns the
    /// reload because it touches the controller + tab state.
    public var onReloadFromDisk: ((URL, Int) -> Void)?

    /// Closure that returns the current `tabs.tabs` snapshot. We avoid
    /// holding a strong DocumentModel reference; this is the cheapest
    /// indirection (closure capture is value-cheap, no retain cycle).
    public var tabsSnapshot: () -> [ViewerCore.Tab] = { [] }

    /// Closure to replace the tab at `index` with `tab`. Routes through
    /// TabCoordinator.replace which fires `tabCoordinator.objectWillChange`
    /// (the dirty-dot republish path) without touching DocumentModel.
    public var onReplaceTab: ((Int, ViewerCore.Tab) -> Void)?

    public init(tabCoordinator: TabCoordinator) {
        self.tabCoordinator = tabCoordinator
        // Register our cleanup hook before any tabs can close. Drains
        // the three editor-owned dicts in lock-step with TabCoordinator's
        // six built-in dicts. Idempotent removeValue — no preflight
        // contains-check (dicts return nil for missing keys, the close
        // path doesn't care).
        tabCoordinator.addCloseHook { [weak self] id in
            self?.resetEditorState(forTabID: id)
        }
    }

    /// Drop ALL per-tab editor UI state for `id` (cursor, scroll, pending
    /// diagnostics + gutter markers, fold ranges). Idempotent (dicts return nil
    /// for missing keys). Called by the close hook, and — TSK-742/743/744 — when
    /// the ephemeral preview slot REUSES its tab id for a DIFFERENT file: that
    /// id's editor state belongs to the previous file and must not leak into the
    /// new one (stale scroll/cursor) the way the stale buffer leaked its content.
    public func resetEditorState(forTabID id: UUID) {
        editorCursorByTab.removeValue(forKey: id)
        editorScrollByTab.removeValue(forKey: id)
        pendingEditorDiagnostics.removeValue(forKey: id)
        pendingEditorGutterMarkers.removeValue(forKey: id)
        editorFoldRangesByTab.removeValue(forKey: id)
        editorFoldRegionsByTab.removeValue(forKey: id)
    }

    /// TSK-743: remember `id`'s current editor scroll/cursor under `url` (the
    /// file LEAVING the preview slot) so a later re-preview of `url` can restore
    /// it. A no-op when nothing is recorded (don't pollute the store with nil).
    /// Call BEFORE `resetEditorState` drops the id-keyed state.
    public func stashPreviewState(forTabID id: UUID, url: URL) {
        let scroll = editorScrollByTab[id]
        let cursor = editorCursorByTab[id]
        guard scroll != nil || cursor != nil else { return }
        if previewScrollByURL[url] == nil, previewCursorByURL[url] == nil {
            previewURLOrder.append(url)
            if previewURLOrder.count > previewMemoryCap {
                let evict = previewURLOrder.removeFirst()
                previewScrollByURL.removeValue(forKey: evict)
                previewCursorByURL.removeValue(forKey: evict)
            }
        }
        previewScrollByURL[url] = scroll
        previewCursorByURL[url] = cursor
    }

    /// TSK-743: re-seed `id`'s editor scroll/cursor from `url`'s remembered
    /// preview state, if any. Returns true when state was restored (the caller's
    /// `ensureEditorBuffer`/CM6 seed then applies the position). No stored entry
    /// ⇒ leaves `id` reset (top), which is also the isolation case (TSK-744).
    @discardableResult
    public func restorePreviewState(forTabID id: UUID, url: URL) -> Bool {
        var restored = false
        if let scroll = previewScrollByURL[url] {
            editorScrollByTab[id] = scroll
            restored = true
        }
        if let cursor = previewCursorByURL[url] {
            editorCursorByTab[id] = cursor
            restored = true
        }
        return restored
    }

    // MARK: - editorBuffers (forwarders to TabCoordinator)
    //
    // The dict itself lives on TabCoordinator so the close-path
    // cleanup invariant (six-dict fan-out via `cleanupAfterClose`)
    // stays in one place. Forwarders here let editor-aware call sites
    // talk to a single coordinator and don't have to know the dict's
    // physical home.

    /// Map of tab id → buffer. Forwarder onto TabCoordinator.
    public var editorBuffers: [UUID: EditorBuffer] {
        tabCoordinator.editorBuffers
    }

    /// True when any tab in the workspace has unsaved edits. Used by
    /// the app delegate's terminate path + window-close confirmation.
    public var hasAnyUnsavedEdits: Bool {
        tabsSnapshot().contains(where: { $0.isDirty })
    }

    /// Returns the cached buffer for `id`, or seeds one from the tab's
    /// `.loaded` state if not yet present. Forwarder.
    public func editorBuffer(forTabID id: UUID) -> EditorBuffer? {
        tabCoordinator.editorBuffer(forTabID: id)
    }

    /// Idempotent seed — preserves an existing buffer with unsaved
    /// edits. Forwarder.
    public func ensureEditorBuffer(for file: TextFile, tabID: UUID) {
        tabCoordinator.ensureEditorBuffer(for: file, tabID: tabID)
    }

    /// Drop the buffer for a tab. Also clears the Tab.isDirty mirror
    /// (the dirty dot in the TabBar) because the buffer is the source
    /// of truth and dropping it without resyncing leaves a stale dot.
    public func discardEditorBuffer(forTabID id: UUID) {
        tabCoordinator.discardEditorBuffer(forTabID: id)
        let tabs = tabsSnapshot()
        if let idx = tabs.firstIndex(where: { $0.id == id }), tabs[idx].isDirty {
            var t = tabs[idx]
            t.isDirty = false
            onReplaceTab?(idx, t)
        }
    }

    /// Push a new text value into the active tab's buffer. Called from
    /// the editor view's change handler (debounced inside CodeMirror's
    /// JS bootstrap, ~200 ms after the last keystroke). Updates
    /// `Tab.isDirty` so the TabBar dot mirrors the state.
    ///
    /// O(1) — no text comparison here; the buffer's `isDirty` getter
    /// is the one place that runs the (cheap, length-short-circuited)
    /// String equality.
    public func updateEditorText(_ newText: String, forTabID id: UUID) {
        guard var buf = tabCoordinator.editorBuffer(forTabID: id) else { return }
        // Fast path: identical-string assignment is a no-op. Avoids
        // republishing `editorBuffers` for callers that fire the
        // setter on every paint (some NSTextView subclasses do).
        if buf.text == newText { return }
        buf.setText(newText)
        tabCoordinator.setEditorBuffer(buf, forTabID: id)
        // Sync the Tab snapshot so SwiftUI re-renders the dirty dot.
        let tabs = tabsSnapshot()
        if let idx = tabs.firstIndex(where: { $0.id == id }) {
            let nowDirty = buf.isDirty
            if tabs[idx].isDirty != nowDirty {
                var t = tabs[idx]
                t.isDirty = nowDirty
                onReplaceTab?(idx, t)
            }
        }
    }

    // MARK: - Cursor / scroll persistence

    /// Record the editor's current cursor position for `id`. Also
    /// mirrors onto the status-bar selection via the injected hook so
    /// the "Ln X, Col Y" readout works in editor mode.
    public func recordEditorCursor(_ pos: CMCursorPosition, forTabID id: UUID) {
        editorCursorByTab[id] = pos
        onCursorMirrorToStatusBar?(pos)
    }

    /// Record the editor's current scroll position for `id`.
    public func recordEditorScroll(_ pos: CMScrollPosition, forTabID id: UUID) {
        editorScrollByTab[id] = pos
    }

    // MARK: - Diagnostics fan-out

    /// Called by `CodeMirrorEditorView.Coordinator` once it's pushed
    /// the diagnostics so the next `updateNSView` doesn't re-ship them.
    public func consumePendingEditorDiagnostics(forTabID id: UUID) {
        pendingEditorDiagnostics.removeValue(forKey: id)
    }

    /// Called by `CodeMirrorEditorView.Coordinator` once it's pushed
    /// the gutter markers so the next `updateNSView` doesn't re-ship them.
    public func consumePendingEditorGutterMarkers(forTabID id: UUID) {
        pendingEditorGutterMarkers.removeValue(forKey: id)
    }

    /// Park a diff/blame gutter-marker payload on the per-tab pending
    /// dict for `url`. No-op if `url` isn't open in any editor tab.
    /// Empty array clears (a previously-marked file now shows clean).
    ///
    /// Producer side: `DocumentModel.refreshDiffMarks` runs the off-
    /// main `git diff` task and calls this with the parsed markers
    /// once the result arrives. We resolve URL → tab here (rather
    /// than the caller passing tab id) so an editor switch between
    /// task launch + completion can't mis-route the payload.
    public func setEditorGutterMarkers(_ markers: [CMGutterMarker], forURL url: URL) {
        let standardized = url.standardizedFileURL.resolvingSymlinksInPath()
        for tab in tabsSnapshot() {
            guard let tabURL = tab.url else { continue }
            let stdTab = tabURL.standardizedFileURL.resolvingSymlinksInPath()
            guard stdTab == standardized else { continue }
            pendingEditorGutterMarkers[tab.id] = markers
        }
    }

    /// Park syntax fold ranges on the per-tab fold dict for `id`.
    /// No-op when `id` isn't an open tab (a compute that finished after
    /// the tab closed) OR when the value is unchanged — the equality
    /// short-circuit avoids a redundant `@Published` republish when a
    /// re-select of an unedited tab recomputes the identical folds.
    ///
    /// Producer side: `DocumentModel.refreshEditorFolds` runs the
    /// off-main TreeSitter fold compute and calls this once the result
    /// arrives. Keys by tab id (not URL) because the fold buffer is
    /// itself tab-id-keyed, so there's no URL→tab ambiguity to resolve.
    public func setEditorFoldRanges(_ ranges: [CMFoldRange], forTabID id: UUID) {
        guard tabsSnapshot().contains(where: { $0.id == id }) else { return }
        if editorFoldRangesByTab[id] != ranges {
            editorFoldRangesByTab[id] = ranges
        }
    }

    /// TSK-719 — store the line-based fold regions for sticky scroll, kept in
    /// step with `setEditorFoldRanges`. Empty array clears.
    public func setEditorFoldRegions(_ regions: [FoldRegion], forTabID id: UUID) {
        guard tabsSnapshot().contains(where: { $0.id == id }) else { return }
        if editorFoldRegionsByTab[id] != regions {
            editorFoldRegionsByTab[id] = regions
        }
    }

    /// Push LSP diagnostics for `url` into the CM6 editor as squiggles.
    /// Looks up the active editor buffer to do the position translation;
    /// no-op if the URL doesn't have an open editor tab. The translated
    /// payload is parked on `pendingEditorDiagnostics[tabID]` so the
    /// active `CodeMirrorEditorView` can pick it up on its next
    /// `updateNSView`. Empty array clears.
    public func setEditorDiagnostics(_ diags: [LSPDiagnostic], forURL url: URL) {
        let standardized = url.standardizedFileURL.resolvingSymlinksInPath()
        for tab in tabsSnapshot() {
            guard let tabURL = tab.url else { continue }
            let stdTab = tabURL.standardizedFileURL.resolvingSymlinksInPath()
            guard stdTab == standardized else { continue }
            guard let buf = tabCoordinator.editorBuffers[tab.id] else { continue }
            let cmDiags = CMDiagnosticMapping.cmDiagnostics(
                from: diags,
                documentText: buf.text,
                encoding: .utf16
            )
            pendingEditorDiagnostics[tab.id] = cmDiags
        }
    }

    // MARK: - Save path

    /// Write the active tab's buffer to disk. ⌘S / menu Save / CM6
    /// `saveRequested` bridge all route here. Returns false when there
    /// is no selected tab (matches the old DocumentModel contract).
    @discardableResult
    public func saveActiveEditor() -> Bool {
        guard let id = activeTabIDSnapshot?() else { return false }
        return saveEditor(forTabID: id)
    }

    /// Snapshot of the currently-selected tab's id. Injected by
    /// DocumentModel so we can locate the active tab without holding
    /// a TabCoordinator strong reference (we already hold a weak one).
    public var activeTabIDSnapshot: (() -> UUID?)?

    /// Fired on the save SUCCESS path with the saved URL + text.
    /// DocumentModel wires this to `LSPPool.didSave` (TSK-464) so
    /// language servers see `textDocument/didSave` and can run their
    /// on-save behaviours (format/lint/index). The pool no-ops for
    /// files without a live LSP session, so this is safe for every
    /// file type.
    public var onDidSaveToDisk: ((URL, String) -> Void)?

    /// Save a specific tab's buffer. Used by `saveActiveEditor` and by
    /// the close-confirm path that targets a non-active tab.
    @discardableResult
    public func saveEditor(forTabID id: UUID) -> Bool {
        guard var buf = tabCoordinator.editorBuffers[id] else { return false }
        AuditLog.shared.record(.fileSave, action: "save", target: buf.url.path)
        // File-watcher reload during save would race the write — pause
        // it for the moment the write is in flight + the immediate
        // post-write watcher event we'd otherwise re-enter on. Caller
        // (DocumentModel) re-binds via the resume hook.
        let wasWatchingURL = watchedURLSnapshot?()
        let savedURL = buf.url
        onPauseFileWatcher?()
        // FW-7: the watcher is blind between pause and resume. If another
        // process writes the file in that window (after OUR write lands),
        // its inotify/FSEvents tick is dropped and we'd never reconcile.
        // We close the window deterministically (no polling): after the
        // watcher re-attaches, re-stat and compare to the fingerprint we
        // just wrote; a mismatch means a lost external edit → reconcile.
        // The post-save stamp is published into this box on the success
        // path so the recheck (which runs after resume) can read it.
        var savedStamp: (mtime: Date?, size: Int?)? = nil
        defer {
            onResumeFileWatcherIfApplicable?(wasWatchingURL)
            // Run the lost-event recheck only when we actually wrote
            // (savedStamp non-nil) and the watcher was/now is bound to
            // this file (avoid re-stat'ing an unrelated active tab).
            if let stamp = savedStamp {
                reconcileLostWatcherEvent(forTabID: id, url: savedURL, savedStamp: stamp)
            }
        }
        do {
            let stamp = try EditorWriter.save(buf.text, to: buf.url, encoding: buf.encoding)
            savedStamp = stamp
            buf.markSaved(diskMTime: stamp.mtime, diskSize: stamp.size)
            tabCoordinator.setEditorBuffer(buf, forTabID: id)
            // Clear the dirty dot.
            let tabs = tabsSnapshot()
            if let idx = tabs.firstIndex(where: { $0.id == id }) {
                var t = tabs[idx]
                t.isDirty = false
                onReplaceTab?(idx, t)
            }
            // Refresh the loaded TextFile so the rest of the app sees
            // the new bytes (sidebar diff marks, formatted cache, etc.
            // all key off URL + length and would otherwise serve stale
            // content if the user flips back to `.source`).
            let tabsAfterClear = tabsSnapshot()
            if let idx = tabsAfterClear.firstIndex(where: { $0.id == id }) {
                var t = tabsAfterClear[idx]
                if case .loaded(let oldFile) = t.state {
                    // EDIT-S2-SAVE: reuse the SINGLE write stamp for both
                    // the `markSaved` baseline (above) and this TextFile
                    // identity. The prior code re-stat'd the file here,
                    // which can read a *different* mtime/size than the
                    // one `markSaved` captured if another process touched
                    // the file in the window between the two stats — the
                    // two would then disagree about the post-save
                    // baseline and the external-edit detector could
                    // mis-fire (or fail to fire). One stamp, one truth.
                    //
                    // Fall back to a fresh stat only if the writer
                    // couldn't report attrs (`stamp.mtime == nil`); a
                    // last-resort `Date()` keeps the cache invalidation
                    // invariant ("mtime advances after a write") intact.
                    let bytes = stamp.size
                        ?? buf.text.data(using: buf.encoding)?.count
                        ?? oldFile.byteCount
                    let mtime: Date? = stamp.mtime ?? {
                        if let attrs = try? FileManager.default
                            .attributesOfItem(atPath: oldFile.url.path),
                           let d = attrs[.modificationDate] as? Date {
                            return d
                        }
                        return Date()
                    }()
                    let newFile = TextFile(
                        url: oldFile.url,
                        contents: buf.text,
                        encoding: oldFile.encoding,
                        byteCount: bytes,
                        modifiedTime: mtime
                    )
                    t.state = .loaded(newFile)
                    onReplaceTab?(idx, t)
                }
            }
            onDidSaveToDisk?(savedURL, buf.text)
            return true
        } catch {
            // Surface failure to the user. Stay dirty so the next ⌘S
            // retries instead of silently dropping the edit.
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn't save \(buf.url.lastPathComponent)"
            alert.informativeText = "\(error)"
            alert.runModal()
            return false
        }
    }

    /// FW-7: reconcile a write that another process may have landed while
    /// the file watcher was paused around our own save. Compares the
    /// current on-disk fingerprint against the stamp we just wrote; if
    /// they diverge, an external edit slipped through the unwatched
    /// window and we reconcile it the same way a live watcher tick would
    /// — *without* polling.
    ///
    /// Branching mirrors `DocumentModel.reloadCurrentFile(matching:)`:
    ///   - buffer now dirty (user typed again post-save, racing the
    ///     external write): definite conflict → run the prompt.
    ///   - buffer clean (the common case): straight reload to pick up the
    ///     external bytes — nothing to lose, so no prompt.
    /// A nil current stat (file deleted/renamed in the window) is left to
    /// the watcher's own delete handling; we only act on a *proven*
    /// divergence so we never reload spuriously.
    private func reconcileLostWatcherEvent(
        forTabID id: UUID, url: URL, savedStamp: (mtime: Date?, size: Int?)
    ) {
        // Only meaningful if this file is the one the watcher tracks
        // (the active tab). If the snapshot is wired and disagrees, the
        // watcher will handle its own file; skip to avoid cross-tab
        // reloads. When the snapshot is unwired (tests), proceed.
        if let snapshot = watchedURLSnapshot, let watched = snapshot(), watched != url {
            return
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let curMTime = attrs?[.modificationDate] as? Date
        let curSize = attrs?[.size] as? Int
        // Compare against the stamp we just wrote. A mismatch on either
        // dimension == someone else wrote after us in the blind window.
        let diverged: Bool = {
            if let s = savedStamp.mtime, let c = curMTime, s != c { return true }
            if let s = savedStamp.size, let c = curSize, s != c { return true }
            return false
        }()
        guard diverged else { return }
        let tabs = tabsSnapshot()
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        if tabs[idx].isDirty {
            presentExternalEditConflict(forTabID: id, at: idx, url: url)
        } else {
            onReloadFromDisk?(url, idx)
        }
    }

    // MARK: - Close prompt

    /// If the tab at `index` has unsaved edits, run the
    /// Save / Don't Save / Cancel NSAlert and return the user's choice.
    /// Returns `nil` when the tab is clean (caller proceeds directly
    /// to close). Modal on the main thread by design — matches every
    /// other AppKit close-confirm flow.
    ///
    /// In tests, set `dirtyClosePromptOverride` to drive the response
    /// without bringing up NSApplication.
    public func confirmCloseIfDirty(at index: Int) -> DirtyClosePrompt? {
        let tabs = tabsSnapshot()
        guard tabs.indices.contains(index) else { return nil }
        let tab = tabs[index]
        guard tab.isDirty else { return nil }
        if let override = dirtyClosePromptOverride {
            return override(tab)
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        let name = tab.url?.lastPathComponent ?? tab.title
        alert.messageText = "Save changes to \(name)?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")          // .alertFirstButtonReturn
        alert.addButton(withTitle: "Don't Save")    // .alertSecondButtonReturn
        alert.addButton(withTitle: "Cancel")        // .alertThirdButtonReturn
        switch alert.runModal() {
        case .alertFirstButtonReturn:  return .save
        case .alertSecondButtonReturn: return .discard
        default:                       return .cancel
        }
    }

    // MARK: - External-edit conflict prompt

    /// Modal alert presented when the file underneath an editor tab
    /// has changed on disk while the buffer is dirty. Drives the
    /// appropriate side-effects (discard + reload, or refresh
    /// fingerprint) and returns the chosen outcome.
    ///
    /// In tests, set `externalEditPromptOverride` to drive the response
    /// and stub `onReloadFromDisk` to observe the reload call.
    @discardableResult
    public func presentExternalEditConflict(
        forTabID id: UUID, at index: Int, url: URL
    ) -> ExternalEditPrompt {
        let outcome: ExternalEditPrompt
        if let override = externalEditPromptOverride {
            outcome = override(url)
        } else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "\(url.lastPathComponent) changed on disk"
            alert.informativeText = "You have unsaved changes. Reloading will discard them."
            alert.addButton(withTitle: "Keep My Edits")
            alert.addButton(withTitle: "Discard & Reload")
            let response = alert.runModal()
            outcome = (response == .alertSecondButtonReturn) ? .discardAndReload : .keepEdits
        }

        switch outcome {
        case .discardAndReload:
            discardEditorBuffer(forTabID: id)
            onReloadFromDisk?(url, index)
        case .keepEdits:
            // Refresh the fingerprint so the next watcher tick (often
            // a duplicate event from the same write) doesn't re-prompt.
            // Crucially we MUST NOT touch `originalText` — keeping the
            // pre-conflict baseline preserves `isDirty == true` and
            // leaves Revert / future "compare original" features usable.
            if var buf = tabCoordinator.editorBuffers[id] {
                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                buf.refreshSavedFingerprint(
                    diskMTime: attrs?[.modificationDate] as? Date,
                    diskSize: attrs?[.size] as? Int
                )
                tabCoordinator.setEditorBuffer(buf, forTabID: id)
            }
        }
        return outcome
    }

    /// TSK-1025: seed a just-restored buffer's saved-fingerprint to the
    /// HOT-EXIT-time baseline (not the fresh-from-disk read), so the existing
    /// external-edit conflict path fires if the file changed while the app was
    /// closed. `refreshSavedFingerprint` leaves `originalText` untouched, so the
    /// buffer stays DIRTY with the user's restored edits. No-op when no buffer
    /// exists for the tab or no baseline was persisted.
    public func seedRestoredBaseline(forTabID id: UUID, mtime: Date?, size: Int?) {
        guard mtime != nil || size != nil,
              var buf = tabCoordinator.editorBuffers[id] else { return }
        buf.refreshSavedFingerprint(diskMTime: mtime, diskSize: size)
        tabCoordinator.setEditorBuffer(buf, forTabID: id)
    }
}
