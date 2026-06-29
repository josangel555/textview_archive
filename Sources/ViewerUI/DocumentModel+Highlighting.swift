import Foundation
import ViewerKit
import ViewerCore

// Syntax-highlight cache access (TSK-1110 SRP slice) — the per-tab
// HighlightCacheActor registry accessor + the view-facing `highlightRuns` cache
// read. The `highlightCaches` registry and the `HighlightCacheKey` typealias stay
// on DocumentModel (extensions can't add stored properties). Behavior-preserving
// move out of DocumentModel.swift.
extension DocumentModel {

    /// Returns the per-tab cache actor for `tabID`, creating one
    /// lazily on first request. Views that need to observe
    /// highlight-ready events take `@ObservedObject` on the returned
    /// instance.
    public func highlightCacheActor(forTabID tabID: UUID) -> HighlightCacheActor {
        if let existing = highlightCaches[tabID] { return existing }
        let fresh = HighlightCacheActor()
        highlightCaches[tabID] = fresh
        return fresh
    }

    /// View-facing accessor. Returns runs immediately if cached on the
    /// active tab's actor; otherwise returns `[]` and kicks off an
    /// async tokenize whose completion bumps the per-tab cache actor's
    /// `version`. Calls with the same key while a task is in flight
    /// are coalesced. Safe to call from `body`.
    ///
    /// PERF #5: writes go to the per-tab `HighlightCacheActor`, not a
    /// `@Published` property on this model — so a tokenize completion
    /// never republishes DocumentModel.
    public func highlightRuns(
        forTabID tabID: UUID,
        url: URL, text: String, language: HighlightLanguage,
        modifiedTime: Date? = nil
    ) -> [HighlightRun] {
        // .diff / .patch files use a hand-rolled per-line highlighter
        // — there's no TreeSitter grammar for unified diff and the
        // logic is line-prefix scanning. Run synchronously: the
        // walk is O(n) and produces deterministic output.
        let ext = url.pathExtension.lowercased()
        if ext == "diff" || ext == "patch" {
            return DiffHighlighter.highlight(text)
        }
        guard language != .plainText else { return [] }
        // utf8.count is O(1) for native UTF-8 string storage (Swift 5+);
        // (text as NSString).length materializes a UTF-16 bridge which
        // is O(N) per call and was a measurable hot-path cost from
        // SwiftUI body re-evals on multi-hundred-KB files.
        let length = text.utf8.count
        // RWC-1: mtime joins the key so a same-byte reload invalidates.
        let key = HighlightCacheKey(
            url: url, length: length, language: language,
            modifiedTime: modifiedTime
        )
        let actor = highlightCacheActor(forTabID: tabID)
        return actor.runsOrEnqueue(key: key, text: text)
    }
}
