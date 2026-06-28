import Foundation
import Combine
import SwiftUI
import ViewerKit
import ViewerCore

// MARK: - Per-file scroll persistence (UX-K, #231)
//
// Carved out of DocumentModel.swift (TSK-1110 — DocumentModel SRP split). The
// scroll/zoom + hot-exit unsaved-text persistence machinery. Scroll offset is
// HIGH-FREQUENCY view-local state on the narrow `SourceViewChannel` — it ticks
// on every wheel event and deliberately does NOT republish `DocumentModel`. We
// persist a per-file scroll position without putting that on the hot path by
// SAMPLING it lazily at the boundaries that matter (focus-loss, visible-tab
// close, snapshot fire). The backing dicts (scrollMemoryBaseline /
// previewSourceLineByURL / renderedScrollByURL) + the DEBUG test counters stay
// on the main class (stored state can't live in an extension; widened to
// internal); all core deps (editor/sourceView/zoom/scrollMemory/scrollSource/
// seedEditorScroll/tabs/tabCoordinator) are already public. The static caps move
// here with their methods.
extension DocumentModel {
    /// Sample the live scroll offset for the tab at `index` and stamp the
    /// resulting 1-based top line into `Tab.scrollTopLine`. No-op when the
    /// geometry isn't usable (zero-line doc / pre-first-paint) or the value is
    /// unchanged. Call at focus-loss / close boundaries — NEVER per scroll tick.
    ///
    /// TSK-1037: which channel we read depends on the tab's lens. In `.editor`
    /// mode the live caret-bearing surface is the CM6 WebView, whose scroll is
    /// reported on the SEPARATE `editorScrollByTab` channel (the source
    /// NSTextView's `sourceScrollState` doesn't tick) — so an editor-mode
    /// capture must read the editor channel's `viewportFromLine`, else the
    /// editor scroll is silently dropped at every session/tab-switch boundary
    /// (it survived a tab-switch only because `editorScrollByTab` is tab-id
    /// keyed; a SESSION switch drains those dicts, so the position was lost
    /// entirely). Folding it into the same `scrollTopLine` field makes editor
    /// scroll round-trip through the snapshot exactly like the source view.
    func captureScroll(forTabAt index: Int) {
        guard tabs.tabs.indices.contains(index) else { return }
        let isEditor = tabs.tabs[index].viewMode == .editor
        let line: Int? = {
            if isEditor {
                // Prefer the editor channel; fall back to the source channel for
                // a never-scrolled editor tab whose source view still carries a
                // usable seed (defensive — usually nil in editor mode).
                if let l = editor.editorScrollByTab[tabs.tabs[index].id]?.viewportFromLine,
                   l > 0 {
                    return l
                }
            }
            return sourceView.sourceScrollState.topVisibleLine
        }()
        // TSK-1041: also fold the RENDERED-markdown scroll (the WKWebView's
        // `window.scrollY`, a third channel that lives only in the in-memory,
        // URL-keyed `renderedScrollByURL`) into the tab so it round-trips
        // through the snapshot. Like the editor case above, this dict is
        // dropped by `closeAllTabsPreservingDirty` on a session switch — so
        // without stamping it onto `Tab.renderedScrollY` it's lost. It's a
        // SEPARATE field from `scrollTopLine` because a rendered offset is a
        // raw pixel value, not a source line.
        let renderedY: Double? = tabs.tabs[index].url.flatMap { renderedScrollByURL[$0] }
        guard let line, line > 0 else {
            // The text channel had nothing usable, but the rendered channel may
            // still carry a position (a markdown tab in `.rendered` mode never
            // ticks the source line). Stamp the rendered offset alone.
            if let renderedY, renderedY > 0, tabs.tabs[index].renderedScrollY != renderedY {
                var t = tabs.tabs[index]
                t.renderedScrollY = renderedY
                tabCoordinator.replace(at: index, with: t)
            }
            return
        }
        var t = tabs.tabs[index]
        var changed = false
        if t.scrollTopLine != line {
            t.scrollTopLine = line
            changed = true
        }
        if let renderedY, renderedY > 0, t.renderedScrollY != renderedY {
            t.renderedScrollY = renderedY
            changed = true
        }
        if changed {
            tabCoordinator.replace(at: index, with: t)
        }
        persistScrollMemory(forTabAt: index, topLine: line)
    }

    /// TSK-1017: mirror a captured scroll/zoom into the DURABLE store, gated so
    /// untouched files write nothing. Reads the tab's file identity + current
    /// global zoom (the per-file zoom override is a later slice; today we
    /// remember the global zoom so reopening doesn't visually jump). No-op for
    /// tabs without a file URL (scratch / untitled).
    private func persistScrollMemory(forTabAt index: Int, topLine: Int) {
        guard tabs.tabs.indices.contains(index),
              let url = tabs.tabs[index].url else { return }
        let key = ScrollMemoryStore.key(for: url)
        // Zoom is only worth remembering when the user moved it off the 1.0
        // default — otherwise every file would pin a "zoom: 1.0" entry.
        let z: Double? = abs(zoom - 1.0) > 0.0001 ? zoom : nil
        let candidate = ScrollMemoryStore.Entry(
            path: key, scrollTopLine: topLine, zoomLevel: z, savedAt: Date()
        )
        guard ScrollMemoryStore.shouldPersist(
            restored: scrollMemoryBaseline[key], candidate: candidate
        ) else { return }
        scrollMemory.remember(url: url, scrollTopLine: topLine, zoomLevel: z)
        scrollMemoryBaseline[key] = candidate
    }

    /// Convenience: capture the currently-selected tab's scroll position.
    /// Used by the autosave / termination snapshot path so the live tab
    /// carries an up-to-date `scrollTopLine` before serialization.
    public func captureScrollForActiveTab() {
        guard let i = tabs.selectedIndex else { return }
        captureScroll(forTabAt: i)
    }

    /// Restore a tab's persisted scroll position by routing through the
    /// existing `scrollSource(toLine:)` request (honored by `.source` /
    /// `.editor`). `nil` / non-positive ⇒ no-op (top of file). Called after a
    /// tab materializes / becomes active so the content is laid out first.
    func restoreScroll(forTabAt index: Int) {
        guard tabs.tabs.indices.contains(index) else { return }
        let tab = tabs.tabs[index]
        // TSK-1041: seed the RENDERED-markdown channel FIRST, independent of the
        // text-line restore below. A `.rendered` markdown tab carries its scroll
        // on `renderedScrollY` (a pixel offset, separate channel) and usually
        // has NO `scrollTopLine`, so it must not be gated behind the text-line
        // branch (which `return`s early). `renderedScrollOffset(for:)` is what
        // `MarkdownRenderedView` re-applies on `didFinish`; this re-injects the
        // persisted offset into the in-memory `renderedScrollByURL` the WebView
        // reads from. Non-clobbering: never stomps a live position already there.
        if let url = tab.url, let y = tab.renderedScrollY, y > 0 {
            seedRenderedScroll(y, for: url)
        }
        // Prefer the in-session position (it's the freshest — set by this
        // session's capture-on-switch). Fall back to the DURABLE per-file
        // store (TSK-1017) when the tab carries no in-session memory, e.g. a
        // file opened fresh in a NEW session or after a relaunch.
        if let line = tab.scrollTopLine, line > 0 {
            applyRestoredScroll(line, to: tab, at: index)
            // Seed the no-write baseline so a re-capture at the same position
            // doesn't churn the durable store.
            if let url = tab.url {
                let key = ScrollMemoryStore.key(for: url)
                scrollMemoryBaseline[key] = ScrollMemoryStore.Entry(
                    path: key, scrollTopLine: line, savedAt: Date()
                )
            }
            return
        }
        guard let url = tab.url,
              let entry = scrollMemory.entry(for: url),
              let line = entry.scrollTopLine, line > 0 else { return }
        scrollMemoryBaseline[entry.path] = entry
        // Stamp the in-session tab so subsequent switches treat it as known.
        var t = tab
        t.scrollTopLine = line
        tabCoordinator.replace(at: index, with: t)
        applyRestoredScroll(line, to: t, at: index)
    }

    /// TSK-1037: route a restored top `line` to the channel that actually drives
    /// the tab's current lens. `.editor` tabs render through the CM6 WebView,
    /// whose viewport is driven off the `editorScrollByTab` channel (NOT the
    /// source NSTextView `scrollSource` request), so we seed that channel; every
    /// other text lens rides the existing `scrollSource(toLine:)` request. We
    /// seed the editor channel for editor tabs and ALSO issue the source request
    /// (harmless when the source view isn't on screen) so a tab that toggles
    /// .editor↔.source after restore lands correctly either way.
    private func applyRestoredScroll(_ line: Int, to tab: ViewerCore.Tab, at index: Int) {
        if tab.viewMode == .editor {
            seedEditorScroll(fromTopLine: line, forTabID: tab.id)
            // TSK-1047 (tab-SELECT restore): the warm-editor reattach + the
            // once-per-mount `editorMountSelectionSeed` only fire on a
            // dismantle→make (an UNMOUNT/REMOUNT = a SESSION switch, or an LRU
            // evict/rebuild). A plain TAB switch keeps the editor pane MOUNTED in
            // `MountedPanesLRU` — so make/dismantle never fire and the
            // once-per-mount seed (already consumed) won't re-apply. The live CM6
            // would stay where the user last left THIS tab's pane, ignoring the
            // restored `editorScrollByTab[id]`. So for a tab switch we imperatively
            // push the restored line to the live, already-mounted CM6 (the same
            // `scrollToLine` path the `editor-scroll-to-line` harness verb uses).
            // GATED to NOT double-apply on the session-switch (reattach) path:
            // `isSessionSwitchInFlight` is set by `SessionState` around its
            // `selectTab`, where the editor pane is being rebuilt (warm-cache
            // reattach keeps scroll, or the fresh-build seed restores it) — there
            // a live push would either no-op (no/unlaid-out WebView) or redundantly
            // re-assert the already-correct line. Best-effort: nil registry (no
            // editor mounted yet) just falls through to the mount-time belt.
            if !isSessionSwitchInFlight {
                pushLiveEditorScroll(toLine: line, forTabID: tab.id)
            }
        }
        scrollSource(toLine: line)
    }

    /// TSK-1047: imperatively scroll the LIVE, already-mounted CM6 editor WebView
    /// so `line` is at the viewport top — WITHOUT moving the caret (the same
    /// `scrollToLine` bridge command `applyScrollToLine` in `codemirror.html`
    /// honors, and the `editor-scroll-to-line` harness verb drives). Used by the
    /// tab-SELECT restore path, where the pane stays mounted so the mount-time
    /// scroll belt never re-fires. No-op when no editor WebView is registered
    /// (nothing to push to) or the target tab isn't the active one (a background
    /// restore must not yank the focused viewport). The registry returns the
    /// editor attached to the key window, which on a tab switch IS the newly
    /// selected tab's pane.
    private func pushLiveEditorScroll(toLine line: Int, forTabID id: UUID) {
        guard tabs.selected?.id == id else { return }
        #if DEBUG
        // Test seam (TSK-1047): record the live-push ATTEMPT so a host test can
        // prove the tab-select restore reaches the live-CM6 push AND that the
        // session-switch gate suppresses it — without a real WebView (the actual
        // on-screen scroll is VM-only). Recorded BEFORE the registry guard so the
        // attempt is visible even in a headless process with no editor mounted
        // (the gate decision is what we're pinning, not the JS round-trip).
        _test_liveEditorScrollPushes += 1
        _test_lastLiveEditorScrollLine = line
        #endif
        guard let webView = CodeMirrorEditorRegistry.shared.current() else { return }
        // `scrollToLine` is a pure scroll (puts `line` at the viewport top) and,
        // unlike `gotoLine`, does NOT move the caret — restoring scroll must never
        // disturb the user's cursor. Same command the `editor-scroll-to-line`
        // harness verb dispatches.
        webView.evaluateJavaScript(
            "window.cmDispatch && window.cmDispatch({type:'scrollToLine', line: \(line)})",
            completionHandler: nil)
    }

    #if DEBUG
    public func _test_resetLiveEditorScrollProbe() {
        _test_liveEditorScrollPushes = 0
        _test_lastLiveEditorScrollLine = 0
    }
    #endif

    /// TSK-718 hot exit: stamp each tab's unsaved editor-buffer text onto its
    /// `Tab.unsavedText` so the next `makeSnapshot` persists it (and a relaunch
    /// restores the in-flight edits, VS Code-style). A clean buffer — or one
    /// whose text exceeds `hotExitMaxBytes` — clears the field. Runs at the
    /// autosave / detach / quit snapshot boundary alongside
    /// `captureScrollForActiveTab`, NEVER per keystroke.
    ///
    /// Iterates ALL tabs, not just the active one: a BACKGROUND tab can be
    /// dirty (edit tab A, switch to B — A's buffer stays dirty in memory).
    /// Reads only buffers that ALREADY exist (`editorBuffers[id]`, no seeding):
    /// a never-edited tab has no buffer, so there's nothing to capture and we
    /// don't materialize its full text just to snapshot.
    public func captureUnsavedTextForAllTabs() {
        for index in tabs.tabs.indices {
            let tab = tabs.tabs[index]
            var captured: String? = nil
            var baseMTime: Date? = nil
            var baseSize: Int? = nil
            if let buf = editor.editorBuffers[tab.id], buf.isDirty {
                // TSK-1025: capture the baseline the edits were made FROM so a
                // relaunch can detect an external change to the file on disk.
                baseMTime = buf.lastSavedMTime
                baseSize = buf.lastSavedSize
                if buf.text.utf8.count <= Self.hotExitMaxBytes {
                    captured = buf.text                                   // small → inline
                    if let p = tab.url?.path { HotExitSpill.remove(forPath: p, in: hotExitSpillDirectory) }
                } else if let p = tab.url?.path {
                    // TSK-1026: a large dirty buffer (1 MiB..32 MiB editor cap)
                    // spills to a sidecar instead of being dropped; unsavedText
                    // stays nil and restore reads it back by file path.
                    if !HotExitSpill.write(buf.text, forPath: p, in: hotExitSpillDirectory) {
                        baseMTime = nil; baseSize = nil                   // spill failed → can't preserve
                    }
                } else {
                    baseMTime = nil; baseSize = nil                       // untitled >1 MiB → drop
                }
            } else if let p = tab.url?.path {
                HotExitSpill.remove(forPath: p, in: hotExitSpillDirectory)                           // clean → clear any stale spill
            }
            guard tab.unsavedText != captured
                || tab.unsavedBaseMTime != baseMTime
                || tab.unsavedBaseSize != baseSize else { continue }
            var t = tab
            t.unsavedText = captured
            t.unsavedBaseMTime = baseMTime
            t.unsavedBaseSize = baseSize
            tabCoordinator.replace(at: index, with: t)
        }
    }

    /// TSK-718 hot exit: re-inject persisted unsaved buffer text into a tab that
    /// just materialized from a session restore. Seeds the editor buffer from
    /// the freshly-read file (the on-disk baseline for the dirty diff), then
    /// overlays the restored unsaved text so the buffer comes back DIRTY with
    /// the user's in-flight edits and the TabBar dot reappears. No-op unless the
    /// tab loaded as `.loaded` text and carries a non-empty `unsavedText`.
    /// Returns whether it restored anything (test hook).
    @discardableResult
    func restoreUnsavedTextIfNeeded(forTabAt index: Int) -> Bool {
        guard tabs.tabs.indices.contains(index) else { return false }
        let tab = tabs.tabs[index]
        guard case .loaded(let file) = tab.state else { return false }
        // Inline unsaved text (≤1 MiB), else a spilled large buffer (TSK-1026,
        // keyed by file PATH — the tab id is regenerated on restore).
        let unsaved: String?
        if let inline = tab.unsavedText, !inline.isEmpty {
            unsaved = inline
        } else if let p = tab.url?.path {
            unsaved = HotExitSpill.read(forPath: p, in: hotExitSpillDirectory)
        } else {
            unsaved = nil
        }
        guard let unsaved, !unsaved.isEmpty else { return false }
        // Seed the baseline from disk, then overlay — `updateEditorText`
        // recomputes `isDirty` (unsaved vs disk) and mirrors it onto the Tab.
        editor.ensureEditorBuffer(for: file, tabID: tab.id)
        editor.updateEditorText(unsaved, forTabID: tab.id)
        // TSK-1025: re-seed the buffer's saved-fingerprint to the HOT-EXIT-time
        // baseline (not the just-read disk one), so the external-edit conflict
        // path fires if the file changed while the app was closed. No-op when no
        // baseline was persisted (pre-TSK-1025 snapshot / clean capture).
        editor.seedRestoredBaseline(
            forTabID: tab.id, mtime: tab.unsavedBaseMTime, size: tab.unsavedBaseSize)
        return true
    }

    /// Cap on the per-URL preview source-line memory (eviction bound).
    private static let previewSourceLineCap = 64

    /// Remember `line` as `url`'s source-view top line for a later preview-return.
    func rememberPreviewSourceLine(_ line: Int, for url: URL) {
        if previewSourceLineByURL[url] == nil,
           previewSourceLineByURL.count >= Self.previewSourceLineCap,
           let victim = previewSourceLineByURL.keys.first {
            previewSourceLineByURL.removeValue(forKey: victim)
        }
        previewSourceLineByURL[url] = line
    }

    /// Cap on the per-URL rendered-scroll memory (eviction bound).
    private static let renderedScrollCap = 64

    /// Record the rendered WebView scroll offset for `url` (from the view's
    /// async `window.scrollY` read at a reload boundary).
    func rememberRenderedScroll(_ y: Double, for url: URL) {
        guard y > 0 else { return }   // top is the default; don't store it
        if renderedScrollByURL[url] == nil,
           renderedScrollByURL.count >= Self.renderedScrollCap,
           let victim = renderedScrollByURL.keys.first {
            renderedScrollByURL.removeValue(forKey: victim)
        }
        renderedScrollByURL[url] = y
    }

    /// The remembered rendered scroll offset for `url`, if any (nil ⇒ top).
    func renderedScrollOffset(for url: URL?) -> Double? {
        guard let url else { return nil }
        // TSK-1046: prefer the LIVE in-memory offset, but FALL BACK to the tab's
        // persisted `renderedScrollY` (the durable source of truth) when the live
        // dict has no entry. `renderedScrollByURL` is dropped on a session-switch
        // drain and re-injected ASYNC via `seedRenderedScroll` (from `restoreScroll`),
        // so the FIRST render after a session restore used to read nil here and snap
        // the preview to the top — a seed-vs-render race. Resolving to the Tab makes
        // this read correct regardless of seed timing: the one unavoidable async
        // boundary (WebView `didFinish`) then reads a value that is ALREADY right
        // instead of racing the imperative seed. Single source of truth, pull-based.
        if let live = renderedScrollByURL[url] { return live }
        return tabs.tabs.first(where: { $0.url == url })?.renderedScrollY
    }

    /// TSK-1041: seed `url`'s rendered scroll offset from a persisted value
    /// (a session-snapshot `TabSnapshot.renderedScrollY`), so a markdown tab
    /// that was scrolled before a session switch comes back to the same place
    /// rather than the top. `renderedScrollByURL` is otherwise in-memory only
    /// (dropped by the close fan-out on a session-switch drain), so the durable
    /// position has to be re-injected on restore. No-op for a non-positive
    /// offset. Does NOT overwrite a live position already present (a tab the
    /// user has since scrolled), mirroring `seedEditorScroll`.
    func seedRenderedScroll(_ y: Double, for url: URL) {
        guard y > 0, renderedScrollByURL[url] == nil else { return }
        // Reuse the bounded recorder so the eviction cap is honored.
        rememberRenderedScroll(y, for: url)
    }
}
