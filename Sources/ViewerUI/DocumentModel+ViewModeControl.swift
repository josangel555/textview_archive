import Foundation
import Combine
import SwiftUI
import ViewerKit
import ViewerCore

// MARK: - UX-A (#224) view-mode CONTROL (presentation layer)
//
// Carved out of DocumentModel.swift (TSK-1110 — DocumentModel SRP split). The
// content-toolbar's Render | Editor | HEX × ViewOnly + Format control is a
// PRESENTATION layer over the existing `ViewMode` set. It does NOT introduce new
// modes or new routing — every state below maps onto a `ViewMode` the model
// already loads/routes, via the pure `ViewModeControl` mapping. A clean verbatim
// move: all deps (currentURL/currentViewMode/setCurrentViewMode/isHexEditArmed/
// setHexEditArmed/panelLayout/tabs) are already public, no stored state, no
// private core machinery — so no widen/vend.
extension DocumentModel {
    /// The view modes the current file can show — the gate `ViewModeControl`
    /// resolves against. Honors the per-tab "Open As…" override so a
    /// forced-type tab offers the override's lenses.
    public var availableViewModes: [ViewMode] {
        ViewModeOptions.availableModes(
            for: currentURL, forcedCategory: tabs.selected?.categoryOverride,
            isRenderableText: Self.renderableTextHint(tabs.selected?.state))
    }

    /// Derive the `isRenderableText` content hint (TSK-332) from a loaded
    /// document state. `.loaded` is the loader's verdict that the bytes
    /// decoded as text (it rejects on NUL/undecodable), so an unknown- or
    /// binary-EXTENSION file that actually IS text upgrades from HEX-only to
    /// Source. Returns `nil` (NOT `false`) for every other state so the
    /// extension-driven default is left untouched: only `.loaded` is a
    /// positive text signal — `.binary`/`.preview`/`.loading`/`.empty` must
    /// not assert "renderable text" (a `.loading` tab hasn't decided yet, and
    /// `availableViewModes` re-derives once it lands `.loaded`).
    nonisolated static func renderableTextHint(_ state: DocumentState?) -> Bool? {
        if case .loaded = state { return true }
        return nil
    }

    /// TSK-900: the off-main (deferred, ≥4 MiB) open resolves the view mode
    /// WITHOUT the content hint — so an unknown-/binary-EXTENSION file gets the
    /// hint-less `.hex` default. When the async load lands and the loader's
    /// verdict is TEXT (`.loaded`), a tab still in `.hex` must UPGRADE to the
    /// content-aware default (e.g. `.source`) — otherwise the picker re-derives
    /// to offer Source while the pane stays a hex dump of a text file (the
    /// reported desync). Non-hex tabs and non-text states are unchanged, so a
    /// genuinely binary file (`.binary`) stays in HEX.
    nonisolated static func deferredLoadViewModeUpgrade(
        current: ViewMode, isLoadedText: Bool, url: URL,
        preferred: [FileCategory: ViewMode]
    ) -> ViewMode {
        guard current == .hex, isLoadedText else { return current }
        let upgraded = ViewModeOptions.defaultMode(
            for: url, isRenderableText: true, preferred: preferred)
        return upgraded == .hex ? current : upgraded
    }

    /// TSK-1588 — the SIZE-AWARE half of the editor-by-default lens. The
    /// category→lens map (`ViewMode.canonicalDefaultLens`) now defaults text
    /// families to `.editor`, but it is size-blind by design; a file past the
    /// CM6 cap (`codeMirrorEditorMaxBytes`, 50 MiB) must open in the read-only
    /// Source lens instead — CM6-read-only under the `WebSourceViewGate`
    /// threshold, the NSTextView large-file fallback beyond it — rather than
    /// dead-ending in `LargeEditorPlaceholderView`. Applied wherever an
    /// open-time mode meets its loaded byte count (sync open, off-main open,
    /// lazy-tab materialize); the manual picker path has its own refusal in
    /// `setCurrentViewMode`.
    nonisolated static func editorDefaultSizeCoercion(
        mode: ViewMode, byteCount: Int
    ) -> ViewMode {
        (mode == .editor && byteCount > codeMirrorEditorMaxBytes) ? .source : mode
    }

    /// How the toolbar should render itself for the current mode (which
    /// primary button is selected, whether ViewOnly reads on, whether the
    /// Format button is the active lens).
    public var viewModePresentation: ViewModeControl.Presentation {
        let base = ViewModeControl.present(currentViewMode)
        // HEX edit-armed state rides DocumentModel, not the (single) `.hex`
        // ViewMode, so `present` always reports HEX read-only. Reflect the
        // per-tab armed flag here so the ViewOnly checkbox + HexView.isEditable
        // read a live value (#234 / TSK-467).
        guard base.primary == .hex, let id = tabs.selected?.id else { return base }
        return ViewModeControl.Presentation(
            primary: .hex,
            viewOnly: !isHexEditArmed(forTabID: id),
            isFormatted: false)
    }

    /// Select a primary lens (Render / Editor / HEX) from the toolbar.
    /// Resolves through the pure mapping against the file's available
    /// modes, then routes via the UNCHANGED `setCurrentViewMode`. A tap the
    /// file can't satisfy falls back to its nearest available lens rather
    /// than forcing an unavailable mode.
    public func selectViewPrimary(
        _ primary: ViewModeControl.Primary, viewOnly: Bool
    ) {
        guard let mode = ViewModeControl.resolve(
            primary: primary, viewOnly: viewOnly, available: availableViewModes
        ) else { return }
        setCurrentViewMode(mode)
    }

    /// Flip the ViewOnly toggle while keeping the current primary lens.
    /// For the Editor primary this is the Source(read-only) ↔ Editor(edit)
    /// swap. For HEX it arms/disarms byte editing via the per-tab flag (the
    /// `.hex` ViewMode is the same either way — #234 / TSK-467). For Render
    /// it's a no-op (always read-only).
    public func setViewOnly(_ viewOnly: Bool) {
        let primary = viewModePresentation.primary
        if primary == .hex {
            if let id = tabs.selected?.id { setHexEditArmed(!viewOnly, forTabID: id) }
            return
        }
        selectViewPrimary(primary, viewOnly: viewOnly)
    }

    /// TSK-936 — flip the ViewOnly (read-only) lock on the active tab, keeping
    /// the current primary lens (Editor↔Source for text, arm/disarm for HEX,
    /// no-op for the always-read-only Render lens). Drives the same path as the
    /// toolbar "View Only" toggle; exposed for the View-menu command + the
    /// `toggle-view-only` script verb.
    public func toggleViewOnly() {
        setViewOnly(!viewModePresentation.viewOnly)
    }

    /// TSK-1116 / TSK-381 — apply a `FocusWorkMode` preset: pin the sidebar to
    /// the mode's relevant panels (every other panel forced hidden) and switch
    /// the active tab to the mode's preferred lens WHEN the open file supports
    /// it (else leave the file on its own lens — never force an unrenderable
    /// lens). The panel/lens logic is the pure, host-tested `FocusWorkMode`
    /// engine; this just routes it to the live stores.
    public func applyFocusMode(_ mode: FocusWorkMode) {
        panelLayout.applyOverrides(mode.panelOverrides())
        if let lens = mode.appliedMode(available: availableViewModes) {
            setCurrentViewMode(lens)
        }
    }

    /// True when the Format button should be shown for the current file
    /// (pretty-printable types only — JSON / XML / plist / SVG / HTML / …).
    public var showsFormatButton: Bool {
        ViewModeControl.showsFormat(available: availableViewModes)
    }

    /// Toolbar Format button: flip into the `.formatted` lens, or back to
    /// the underlying text source when already formatted. Routes through
    /// the UNCHANGED `setCurrentViewMode` (not the standalone
    /// `toggleFormat()` flag-only path) so `currentViewMode` stays
    /// authoritative — the presentation reads `isFormatted` off the enum
    /// case, so the button's active state and the picker can't desync.
    public func toggleFormatLens() {
        guard showsFormatButton else { return }
        if currentViewMode == .formatted {
            setCurrentViewMode(.source)
        } else {
            setCurrentViewMode(.formatted)
        }
    }

    /// Toolbar-button visibility for the three primaries (media / PDF /
    /// binary tabs hide Editor; plain `.txt` hides Render).
    public var showsRenderPrimary: Bool {
        ViewModeControl.showsRender(available: availableViewModes)
    }
    public var showsEditorPrimary: Bool {
        ViewModeControl.showsEditor(available: availableViewModes)
    }

    /// TSK-898 — the ordered list of primary lenses the segmented mode
    /// control should surface for the current file, leftmost first:
    /// Render (if a rich lens exists) → Editor (if a text lens exists) →
    /// HEX (always, every file with bytes offers it). This is the single
    /// source of truth the segmented group iterates, so the segment set +
    /// order can't drift from the per-button `showsRenderPrimary` /
    /// `showsEditorPrimary` gating. Examples:
    ///   • markdown → [.render, .editor, .hex]
    ///   • plain `.txt` → [.editor, .hex] (no rich lens)
    ///   • image / media / PDF → [.render, .hex] (no text lens)
    ///   • binary / unknown → [.hex] only
    public var visibleViewPrimaries: [ViewModeControl.Primary] {
        var primaries: [ViewModeControl.Primary] = []
        if showsRenderPrimary { primaries.append(.render) }
        if showsEditorPrimary { primaries.append(.editor) }
        primaries.append(.hex)
        return primaries
    }

    // MARK: - Per-TAB display variants (I-21 pane toolbars, owner 2026-08-11)
    //
    // "Each tab gets to identify the content and render its own visualization
    // possibilities and decide its own visualization" — while the window is
    // SPLIT, every pane hosts its own `ContentToolbar` rendering the display
    // state of THAT pane's selected tab (which is generally NOT the app-wide
    // selected tab). These mirror the selected-tab derivations above verbatim,
    // reading the given tab's url / categoryOverride / state / viewMode
    // instead of the `currentURL`/`currentViewMode` conveniences; the
    // COMMANDS deliberately stay selected-tab-routed — a click in an
    // unfocused pane first focuses it (`PaneFocusClickMonitor` on mouse-down),
    // so by the time a control's action runs, its tab IS the selected tab.

    /// Per-tab `availableViewModes`.
    public func availableViewModes(for tab: ViewerCore.Tab) -> [ViewMode] {
        ViewModeOptions.availableModes(
            for: tab.url, forcedCategory: tab.categoryOverride,
            isRenderableText: Self.renderableTextHint(tab.state))
    }

    /// Per-tab `viewModePresentation` (the tab's own lens + hex-armed flag).
    public func viewModePresentation(for tab: ViewerCore.Tab) -> ViewModeControl.Presentation {
        let base = ViewModeControl.present(tab.viewMode)
        guard base.primary == .hex else { return base }
        return ViewModeControl.Presentation(
            primary: .hex,
            viewOnly: !isHexEditArmed(forTabID: tab.id),
            isFormatted: false)
    }

    /// Per-tab `showsFormatButton`.
    public func showsFormatButton(for tab: ViewerCore.Tab) -> Bool {
        ViewModeControl.showsFormat(available: availableViewModes(for: tab))
    }

    /// Per-tab `showsEditorPrimary` (drives the View Only toggle's presence).
    public func showsEditorPrimary(for tab: ViewerCore.Tab) -> Bool {
        ViewModeControl.showsEditor(available: availableViewModes(for: tab))
    }

    /// Per-tab `visibleViewPrimaries`.
    public func visibleViewPrimaries(for tab: ViewerCore.Tab) -> [ViewModeControl.Primary] {
        let available = availableViewModes(for: tab)
        var primaries: [ViewModeControl.Primary] = []
        if ViewModeControl.showsRender(available: available) { primaries.append(.render) }
        if ViewModeControl.showsEditor(available: available) { primaries.append(.editor) }
        primaries.append(.hex)
        return primaries
    }
}
