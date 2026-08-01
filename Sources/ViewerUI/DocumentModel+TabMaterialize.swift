import Foundation
import ViewerCore

// Lazy tab materialization (TSK-1110 SRP slice) — turns a lazy `.empty`
// placeholder tab into real content on first focus: flip to `.loading`, read the
// file off-main, then re-locate the tab by id and swap to the final state (with
// the closed-meanwhile / superseded-by-reselect guards, scroll + unsaved-edit
// restore, and the HEX-mode carry). Callers (selectTab, settleSelectionAfterClose)
// stay on DocumentModel. Behavior-preserving move out of DocumentModel.swift.
extension DocumentModel {

    /// If the tab at `index` is a lazy placeholder (state == .empty
    /// while url is set), kick a background read and flip state to
    /// `.loading(url)`. The file read happens on a detached Task; on
    /// completion we re-locate the tab by id and swap to the final
    /// state. Idempotent: tabs in any non-.empty state are left alone.
    ///
    /// Why off-main: `controller.open(_:)` reads the entire file
    /// synchronously. For a 32 MB log the read alone is ~50-100 ms on
    /// SSD, plus encoding detection — long enough to drop a frame
    /// when the user clicks a tab. State going to `.loading` makes
    /// the UI show a placeholder (after a small grace period) rather
    /// than appear frozen.
    func materializeIfNeeded(at index: Int) {
        guard tabs.tabs.indices.contains(index) else { return }
        let t = tabs.tabs[index]
        guard let url = t.url, case .empty = t.state else { return }
        #if DEBUG
        materializeCalls += 1   // P3 probe: a bulk drain must NOT bump this
        #endif
        let tabID = t.id
        // Cancel any in-flight read for this tab id (rapid re-select
        // would otherwise pile up). Cooperative cancellation: we can't
        // interrupt the sync `controller.open(url:)` mid-read, but the
        // completion checks `Task.isCancelled` before hopping to main.
        tabCoordinator.materializeTask(forTabID: tabID)?.cancel()
        var loading = t
        loading.state = .loading(url)
        tabCoordinator.replace(at: index, with: loading)
        let viewMode = t.viewMode
        // WAVE 2b item 6: honor a restored "Open As…" override when the
        // lazy tab finally materializes.
        let override = t.categoryOverride
        let matToken = PerfSignpost.begin(.materialize, "materializeIfNeeded")
        let task = Task.detached(priority: .userInitiated) { [controller] in
            let state = controller.open(url: url, forcedCategory: override)
            PerfSignpost.end(matToken)
            if Task.isCancelled { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                // Clear our slot regardless of outcome — the Task is
                // done from here on out, even if we drop the result.
                self.tabCoordinator.clearMaterializeTask(forTabID: tabID)
                if Task.isCancelled { return }
                // The tab may have been closed, replaced, or had its
                // state mutated meanwhile. Only swap if the slot we
                // started on is still the same tab + still .loading
                // for the same URL. Otherwise drop the result.
                guard let idx = self.tabs.tabs.firstIndex(where: { $0.id == tabID }) else {
                    return
                }
                let current = self.tabs.tabs[idx]
                guard case .loading(let pendingURL) = current.state, pendingURL == url else {
                    return
                }
                var t2 = current
                t2.state = state
                // TSK-1588: a restored lazy tab may carry the size-blind
                // `.editor` default; past the CM6 cap coerce to read-only
                // Source (same rule as both open paths).
                if case .loaded(let f) = state {
                    t2.viewMode = Self.editorDefaultSizeCoercion(
                        mode: t2.viewMode, byteCount: f.byteCount)
                }
                self.tabCoordinator.replace(at: idx, with: t2)
                // UX-K (#231): the lazy tab's content is now laid out — restore
                // its persisted scroll position. The `selectTab` immediate
                // `restoreScroll` fired before this content existed (the source
                // view had no glyphs to scroll to), so re-fire here for the
                // tab that just materialized into focus. Only when it's still
                // the selected tab (a background materialize must not yank the
                // viewport of whatever the user is now looking at).
                if self.tabs.selectedIndex == idx {
                    self.restoreScroll(forTabAt: idx)
                }
                // TSK-718 hot exit: the file is now read (buffer baseline
                // available) — overlay any persisted unsaved edits so the tab
                // comes back dirty with the user's in-flight content. Runs for
                // background materializes too (each restored tab gets its edits
                // back when it first loads, not only the focused one).
                self.restoreUnsavedTextIfNeeded(forTabAt: idx)
                // TSK-1303: seed `imageEditStateByURL` from the tab's persisted
                // image edit state so the recreated image editor view restores the
                // user's in-flight edits (the session-switch data-loss fix).
                self.restoreImageEditState(forTabAt: idx)
                // Hex hot-exit (2026-08-01): re-stash persisted dirty hex bytes
                // + mark dirty, so ⌘S/close-confirm operate on the restored
                // bytes and the hex view seeds from the stash.
                self.restoreUnsavedHexIfNeeded(forTabAt: idx)
                // LOADBUG (2026-06-01): PERF #1 severed the
                // `tabCoordinator.objectWillChange` → `DocumentModel.
                // objectWillChange` forwarding, so `replace` alone fires the
                // coordinator's publisher but NOT the model's. ContentView /
                // ModeBar observe `DocumentModel`, so without this the
                // just-landed `.loaded`/`.binary`/`.error` state is correct on
                // the model but the realized view never re-bodies — it stays
                // frozen on the `.loading` placeholder ("main.swift cannot be
                // loaded" / blank). Mirror `openLargeFileOffMain`'s completion
                // (which already calls `updateDerived()`); the synchronous open
                // / select / close paths all republish this way too.
                self.updateDerived()
                // Mirror openResolved's HEX-mode carry: if a text file
                // lands with the tab already set to .hex view, kick the
                // binary load. Exclude `.preview` (native-preview
                // categories whose default mode is now `.preview`, Bug B)
                // — hex-loading them would replace the native viewer (e.g.
                // SQLite browser) with a hex dump on a plain lazy
                // materialize. See the matching block in `openResolved`.
                if viewMode == .hex {
                    switch state {
                    case .binary, .empty, .loading, .hostedView, .preview: break
                    case .loaded, .error:
                        self.loadBinaryAsync(url: url, intoTabID: tabID)
                    }
                }
            }
        }
        tabCoordinator.setMaterializeTask(task, forTabID: tabID)
    }
}
