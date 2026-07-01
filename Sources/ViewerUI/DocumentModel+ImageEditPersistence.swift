import Foundation
import ViewerCore

// MARK: - Per-image edit-state persistence (TSK-1303)
//
// The image-editor's in-progress edits (tonal/geometry ops + vector overlay) live
// on a view-local `ImageEditorViewModel` @StateObject, which is DESTROYED and
// recreated on a SESSION switch — so the edits were silently lost on switch-back
// (the same session-switch drain class as the scroll / hot-exit fields; see
// LESSONS.md). This mirrors the rendered-scroll persistence (TSK-1041): the image
// editor view publishes its live edit state into the URL-keyed `imageEditStateByURL`
// dict; at the session-switch snapshot boundary we FOLD that onto `Tab.imageEditState`
// (serialized in `TabSnapshot`); on restore we SEED the dict back from the tab so the
// recreated view reads it at construction. All capture/fold happens at the boundary,
// NEVER on the per-edit hot path.
extension DocumentModel {
    /// Record the live edit state for `url` — called by the image editor view as the
    /// user edits. Bounded by construction: one entry per open image tab (tens at most).
    public func rememberImageEditState(_ state: ImageEditState, for url: URL) {
        imageEditStateByURL[url] = state
    }

    /// The remembered edit state for `url`, preferring the LIVE in-memory value and
    /// FALLING BACK to the tab's persisted `imageEditState` — the same pull-based,
    /// seed-race-free resolution as `renderedScrollOffset(for:)`. The recreated
    /// `ImageEditorViewModel` reads this at construction so a session switch-back (the
    /// live dict is drained, the tab carries the durable copy) restores correctly
    /// regardless of when `restoreImageEditState`'s async seed lands.
    public func imageEditState(for url: URL?) -> ImageEditState? {
        guard let url else { return nil }
        if let live = imageEditStateByURL[url] { return live }
        return tabs.tabs.first(where: { $0.url == url })?.imageEditState
    }

    /// Re-inject a persisted edit state into the live dict on restore (mirrors
    /// `seedRenderedScroll`). Non-clobbering: never stomps a live value already
    /// present (a tab the user has since edited in this session).
    func seedImageEditState(_ state: ImageEditState, for url: URL) {
        guard imageEditStateByURL[url] == nil else { return }
        imageEditStateByURL[url] = state
    }

    /// Fold each image tab's LIVE edit state (`imageEditStateByURL`) onto its
    /// `Tab.imageEditState` so the next `makeSnapshot` persists it — mirroring
    /// `captureUnsavedTextForAllTabs`. Runs at the session-switch drain boundary,
    /// NEVER on the per-edit path. Iterates ALL tabs (a background image tab can
    /// carry edits). No-op per tab when nothing changed (the equality guard keeps a
    /// re-capture from churning the tab list). Reads only URLs the view has published
    /// state for — an unedited image tab has no dict entry, so nothing is stamped.
    public func captureImageEditStateForAllTabs() {
        for index in tabs.tabs.indices {
            let tab = tabs.tabs[index]
            guard let url = tab.url, let live = imageEditStateByURL[url] else { continue }
            guard tab.imageEditState != live else { continue }
            var t = tab
            t.imageEditState = live
            tabCoordinator.replace(at: index, with: t)
        }
    }

    /// Seed the live dict from a materialized tab's persisted `imageEditState` so the
    /// recreated image editor view restores the user's edits (mirrors `restoreScroll`).
    /// No-op when the tab carries none. Called after a tab materializes on restore.
    func restoreImageEditState(forTabAt index: Int) {
        guard tabs.tabs.indices.contains(index) else { return }
        let tab = tabs.tabs[index]
        guard let url = tab.url, let state = tab.imageEditState else { return }
        seedImageEditState(state, for: url)
    }
}
