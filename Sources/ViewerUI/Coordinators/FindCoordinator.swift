import Foundation
import Combine
import SwiftUI

/// Owns the three find-mode bags (rendered, source, editor). Extracted
/// from `DocumentModel` (Quality #E, 2026-05-25) so that views that
/// only care about find state stop paying the cost of every other
/// `DocumentModel` mutation, and inversely so that find-bar keystrokes
/// stop forcing the entire model's observers to re-evaluate.
///
/// Three independent bags by design — they back distinct UI surfaces:
///   - rendered: WKWebView find runtime, "n/N" in MarkdownFindBar
///   - source:   NSTextView find, match minimap on the gutter
///   - editor:   CodeMirror v6 find bridge, "n/N" via JS callback
///
/// "Nonce" pattern recap: SwiftUI's value-blind dedupe swallows
/// `query = same`, but `…NextRequest &+= 1` always re-fires. We use it
/// for next/prev/focus signals — semantically these are *commands*, not
/// values, so the bump-counter shape is correct (LESSONS.md).
@MainActor
public final class FindCoordinator: ObservableObject {

    // MARK: Rendered (WKWebView)

    @Published public var isRenderedBarPresented: Bool = false
    @Published public var renderedQuery: String = ""
    @Published public var renderedCaseSensitive: Bool = false
    @Published public var renderedMatched: Bool? = nil
    @Published public var renderedMatchSummary: String = ""

    @Published public var renderedNextRequest: Int = 0
    @Published public var renderedPrevRequest: Int = 0
    @Published public var renderedFocusRequest: Int = 0

    public func setRenderedMatchSummary(_ s: String) {
        guard s != renderedMatchSummary else { return }
        renderedMatchSummary = s
    }

    /// Preserved find text (TSK-1207, TSK-770 parity): kept across a dismiss so a
    /// reopen restores it, while `renderedQuery` itself empties on dismiss so the
    /// existing empty-query path clears the `<mark>` highlights (no lingering marks).
    private var renderedQueryDraft = ""

    public func showRenderedBar() {
        isRenderedBarPresented = true
        if renderedQuery.isEmpty, !renderedQueryDraft.isEmpty {
            renderedQuery = renderedQueryDraft   // restore the previous find text
        }
        renderedFocusRequest &+= 1
    }

    public func dismissRenderedBar() {
        isRenderedBarPresented = false
        if !renderedQuery.isEmpty { renderedQueryDraft = renderedQuery }
        renderedQuery = ""
        renderedMatched = nil
    }

    /// Cmd+F semantics (TSK-739): a second invocation closes the bar.
    public func toggleRenderedBar() {
        if isRenderedBarPresented { dismissRenderedBar() } else { showRenderedBar() }
    }

    public func renderedNext() { renderedNextRequest &+= 1 }
    public func renderedPrev() { renderedPrevRequest &+= 1 }

    // MARK: Source (NSTextView)

    @Published public var isSourceBarPresented: Bool = false
    @Published public var sourceQuery: String = ""
    @Published public var sourceCaseSensitive: Bool = false
    @Published public var sourceIsRegex: Bool = false
    @Published public var sourceMatchSummary: String = ""
    @Published public var sourceMatchLines: [Int] = []
    @Published public var sourceCurrentMatchIndex: Int? = nil

    @Published public var sourceNextRequest: Int = 0
    @Published public var sourcePrevRequest: Int = 0
    @Published public var sourceFocusRequest: Int = 0

    public func setSourceMatchSummary(_ s: String) {
        guard s != sourceMatchSummary else { return }
        sourceMatchSummary = s
    }

    /// Apply a `FindMatchSet` update from the source view. Dedupes on
    /// equality so the publish chain doesn't churn SwiftUI on every
    /// apply() tick when the match set is unchanged.
    public func setSourceMatches(lines: [Int], currentIndex: Int?) {
        if sourceMatchLines != lines {
            sourceMatchLines = lines
        }
        if sourceCurrentMatchIndex != currentIndex {
            sourceCurrentMatchIndex = currentIndex
        }
    }

    /// Preserved find text (TSK-1207) — see `renderedQueryDraft`.
    private var sourceQueryDraft = ""

    public func showSourceBar() {
        isSourceBarPresented = true
        if sourceQuery.isEmpty, !sourceQueryDraft.isEmpty {
            sourceQuery = sourceQueryDraft   // restore the previous find text
        }
        sourceFocusRequest &+= 1
    }

    public func dismissSourceBar() {
        isSourceBarPresented = false
        if !sourceQuery.isEmpty { sourceQueryDraft = sourceQuery }
        sourceQuery = ""
        setSourceMatchSummary("")
        setSourceMatches(lines: [], currentIndex: nil)
    }

    /// Cmd+F semantics (TSK-739): a second invocation closes the bar.
    public func toggleSourceBar() {
        if isSourceBarPresented { dismissSourceBar() } else { showSourceBar() }
    }

    public func sourceNext() { sourceNextRequest &+= 1 }
    public func sourcePrev() { sourcePrevRequest &+= 1 }

    // MARK: Editor (CM6)

    @Published public var isEditorBarPresented: Bool = false
    @Published public var editorQuery: String = ""
    @Published public var editorCaseSensitive: Bool = false
    @Published public var editorIsRegex: Bool = false
    @Published public var editorMatchSummary: String = ""

    /// Replacement string for the editor find-and-replace row. The
    /// editor (CM6) is the only editable surface — the rendered
    /// (WKWebView) and source (read-only NSTextView) bars have no
    /// replace affordance — so replace state lives only on the editor
    /// bag. Carried into CM's `SearchQuery.replace` via the
    /// `setSearchQuery` bridge call; `replaceNext` / `replaceAll`
    /// consume it.
    @Published public var editorReplacement: String = ""
    /// Whether the editor find bar is expanded to show the replace row.
    /// Cmd+F opens find-only; Cmd+Option+F (or the disclosure) expands
    /// to find-and-replace. Persisting it on the coordinator keeps the
    /// row state stable across re-bodies of the find bar.
    @Published public var editorReplaceVisible: Bool = false

    @Published public var editorNextRequest: Int = 0
    @Published public var editorPrevRequest: Int = 0
    @Published public var editorFocusRequest: Int = 0
    /// Command nonces for the two replace actions. Bump-counter shape
    /// (same as next/prev) because "replace the current match" and
    /// "replace every match" are commands, not values — a repeated
    /// click must always re-fire even when the strings are unchanged.
    @Published public var editorReplaceNextRequest: Int = 0
    @Published public var editorReplaceAllRequest: Int = 0

    public func setEditorMatchSummary(_ s: String) {
        guard s != editorMatchSummary else { return }
        editorMatchSummary = s
    }

    public func showEditorBar() {
        isEditorBarPresented = true
        editorFocusRequest &+= 1
    }

    public func dismissEditorBar() {
        isEditorBarPresented = false
        // TSK-770: KEEP `editorQuery` so a reopen (Cmd+F) restores the prior
        // search text — the owner's "Cmd+F again opens keeping prev text". This
        // is safe: ContentView gates the CM6 `findQuery` on `isEditorBarPresented`
        // (not on the string), so a HIDDEN bar still feeds CM6 "" and highlights
        // clear; reopening re-feeds the preserved query and re-highlights — no
        // stale highlights while hidden. The replacement + row visibility DO
        // reset so a fresh find opens find-only with no stale replacement.
        editorReplacement = ""
        editorReplaceVisible = false
        editorMatchSummary = ""
    }

    /// Cmd+F semantics (TSK-739): a second invocation closes the bar. Note Cmd+F
    /// opens find-only — if the bar is showing the replace row, a re-press still
    /// closes it (consistent "toggle the find surface" behavior).
    public func toggleEditorBar() {
        if isEditorBarPresented { dismissEditorBar() } else { showEditorBar() }
    }

    public func editorNext() { editorNextRequest &+= 1 }
    public func editorPrev() { editorPrevRequest &+= 1 }

    /// Show the editor bar already expanded to its find-and-replace
    /// shape (Cmd+Option+F entry point).
    public func showEditorReplaceBar() {
        editorReplaceVisible = true
        showEditorBar()
    }

    public func toggleEditorReplaceVisible() {
        editorReplaceVisible.toggle()
    }

    public func editorReplaceNext() { editorReplaceNextRequest &+= 1 }
    public func editorReplaceAll() { editorReplaceAllRequest &+= 1 }

    // MARK: Cross-bar next/prev router (⌘G / ⌥⌘G)

    /// True when ANY find bar is open — gates the Find Next/Previous menu
    /// items so ⌘G/⌥⌘G grey out when there's no active search surface.
    public var isAnyBarPresented: Bool {
        isEditorBarPresented || isRenderedBarPresented || isSourceBarPresented
    }

    /// Advance to the next match on whichever find bar is currently open.
    /// The three bars are mutually exclusive in practice (the active view
    /// mode determines which one Cmd+F opened), so the first presented bag
    /// wins. No-ops when no bar is open — ⌘G has nothing to step through.
    public func next() {
        if isEditorBarPresented { editorNext() }
        else if isRenderedBarPresented { renderedNext() }
        else if isSourceBarPresented { sourceNext() }
    }

    /// Step to the previous match on whichever find bar is open (⌥⌘G).
    public func prev() {
        if isEditorBarPresented { editorPrev() }
        else if isRenderedBarPresented { renderedPrev() }
        else if isSourceBarPresented { sourcePrev() }
    }
}
