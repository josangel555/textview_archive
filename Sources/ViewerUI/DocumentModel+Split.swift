import Foundation
import ViewerCore
import ViewerKit

/// Split-pane API family for `DocumentModel`, carved out of the ~6.4k-line
/// `DocumentModel.swift` (TSK-308, first clean SRP-split slice).
///
/// HOT-FILE RULE: lifted into a NEW extension file (mirroring
/// `DocumentModel+Diagnostics.swift`) rather than edited in place, so the
/// monolith shrinks without colliding with the hot zone and the public API
/// stays byte-identical — `ContentView` / `SessionState` / `ScriptVerb`
/// call sites (`model.splitURL`, `model.openInSplit`, `model.closeSplit`,
/// `model.toggleSplit`, `model.swapSplit`, `model.splitPaneText`) are
/// untouched.
///
/// This is a SLICE: one cohesive, self-contained cluster. The pane state
/// itself lives on `tabCoordinator` (it shares the "what's on screen now"
/// lifecycle with the tab list); these are the model-level forwarders +
/// the two helpers that compose the pane API (`swapSplit`, `splitPaneText`).
/// Each member here touches ONLY the public surface (`tabCoordinator`,
/// `refreshSplitDiffMarks()`, `currentURL`, `openPath`, `tabs`, `editor`),
/// so the carve-out needs no visibility widening. The gutter-diff worker
/// `refreshSplitDiffMarks()` stays in `DocumentModel.swift` — it reaches the
/// `private splitDiffMarksTask` / `resolveGutterRoot` state, and Swift's
/// `private` is file-scoped.
@MainActor
extension DocumentModel {

    // MARK: - CSV filter state (per-tab, cleared on close)

    /// Forwarder. New code should call `tabCoordinator.clearCsvFilterState`.
    public func clearCsvFilterState(forTabID id: UUID) {
        tabCoordinator.clearCsvFilterState(forTabID: id)
    }

    // MARK: - Split view (forwarders to TabCoordinator)
    //
    // The split pane lives on `tabCoordinator` because it shares the
    // "what's currently on screen" lifecycle with the tab list.
    // Forwarders here preserve the existing `model.splitURL` /
    // `model.openInSplit` / `model.closeSplit` / `model.toggleSplit`
    // call sites.

    public var splitURL: URL? {
        get { tabCoordinator.splitURL }
        set { tabCoordinator.splitURL = newValue }
    }
    public var isSplitOpen: Bool { tabCoordinator.isSplitOpen }

    public func openInSplit(_ url: URL) {
        tabCoordinator.openInSplit(url)
        // CHANGE 2: feed the split pane's gutter diff. The `$splitURL`
        // Combine sink in RepoFocusTracker keeps the registry demand set
        // in sync; this drives the per-file gutter (which needs diff
        // TEXT, not status, so it stays a separate path).
        refreshSplitDiffMarks()
    }
    public func closeSplit() {
        tabCoordinator.closeSplit()
        // Clears the split task + leaves no markers (splitURL is now nil).
        refreshSplitDiffMarks()
    }
    public func toggleSplit() {
        // I-19 (2026-08-11): same-file markdown split is the PER-TAB
        // split-editing layout now — the menu toggle drives it when the
        // file offers edit-and-preview. The window pane (`splitURL`)
        // remains the two-file side-by-side mechanism (and the same-file
        // fallback for files with no rendered preview).
        if tabCoordinator.splitURL != nil { closeSplit() }
        else if isSplitEditingActive { exitSplitEditing() }
        else if splitEditingIsOffered { enterSplitEditing() }
        else if let url = currentURL { openInSplit(url) }
    }

    /// Swap which file is in each pane. Convenience for the user
    /// who wants to flip primary/secondary.
    public func swapSplit() {
        guard let secondary = splitURL, let primary = currentURL else { return }
        splitURL = primary
        openPath(secondary)
    }

    /// TSK-806: the text the SPLIT pane should render for `url` — the live
    /// UNSAVED edits when that file is open in a tab with a DIRTY editor buffer,
    /// else the on-disk `fallback`. Unlike `displayedText(for:)` this keys on the
    /// file's OWN tab (matched by URL), NOT `tabs.selected`: the split pane can
    /// show a DIFFERENT file than the active tab (`splitURL` is independent and
    /// swappable), so consulting the selected tab's buffer would render the wrong
    /// file's edits. A clean/absent buffer ⇒ on-disk text (same bytes anyway).
    public func splitPaneText(for url: URL, fallback: String) -> String {
        if let tab = tabs.tabs.first(where: { $0.url == url }),
           let buf = editor.editorBuffer(forTabID: tab.id), buf.isDirty {
            return buf.text
        }
        return fallback
    }
}
