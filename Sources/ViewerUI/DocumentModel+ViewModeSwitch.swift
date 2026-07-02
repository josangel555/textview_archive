import Foundation
import ViewerKit
import ViewerCore

// View-mode switching (TSK-1110 SRP slice) — toggle Rendered↔Source, positional
// ⌘1/⌘2/⌘3 selection, and the central setCurrentViewMode state machine (per-mode
// side effects: async HEX/text re-load, formatted flag, media-preview restore,
// editor-cap gate). Pure model logic — the content pane re-bodies on the @Published
// republish; no render here. Behavior-preserving move out of DocumentModel.swift.
extension DocumentModel {

    public func toggleViewMode() {
        // ⇧⌘R / toggle-view is scoped to markdown & mermaid (the only
        // types with a Rendered↔Source pairing). On every other type the
        // live menu greys the item out via validateMenuItem, but the model
        // action is reachable programmatically (--script toggle-view, MCP
        // set_view_mode, walkthrough); make it a true no-op there so a
        // single invoke can't leave the picker showing "Rendered" over a
        // Source pane (SC-MENU-01). `setCurrentViewMode` also rejects an
        // unavailable `.rendered`; this guard additionally avoids a no-op
        // republish.
        guard supportsViewModeToggle else { return }
        let new: ViewMode = currentViewMode == .rendered ? .source : .rendered
        setCurrentViewMode(new)
    }

    /// TSK-899: select the Nth view mode for the current file (⌘1/⌘2/⌘3 →
    /// the 1st/2nd/3rd button in the mode bar). Positional — robust across file
    /// types (markdown: Rendered/Source/HEX; CSV: Table/Source/HEX) — and a
    /// no-op when the slot doesn't exist for this file.
    public func selectViewMode(at index: Int) {
        let modes = availableViewModes
        guard modes.indices.contains(index) else { return }
        setCurrentViewMode(modes[index])
    }

    public func setCurrentViewMode(_ mode: ViewMode) {
        guard let i = tabs.selectedIndex, tabs.tabs.indices.contains(i) else { return }
        var t = tabs.tabs[i]
        // Reject `.rendered` on a TEXT tab that doesn't offer it.
        // `.rendered` is markdown/mermaid/html-only (see ViewModeOptions);
        // flipping it onto a plainText / source / JSON tab leaves the
        // picker selecting "Rendered" while the state-driven content pane
        // keeps drawing the Source NSTextView — a picker↔pane desync
        // (SC-MENU-01: toggle-view / ⇧⌘R, MCP set_view_mode, and any
        // programmatic caller route through here unguarded; the live menu
        // greys ⇧⌘R via validateMenuItem, but the model action itself was
        // not guarded). Scoped to `.rendered` on text categories rather
        // than a blanket availableModes gate on purpose: the
        // `.source`/`.rendered` arm below intentionally maps `.rendered`
        // onto MEDIA tabs (image/audio/video/pdf/sqlite — picker shows
        // only [.preview, .hex]) to RESTORE `.preview` when leaving HEX,
        // a documented round-trip a blanket gate would break.
        if mode == .rendered, let url = t.url {
            let cat = t.categoryOverride ?? FileTypeDetector.category(for: url)
            switch cat {
            case .markdown, .mermaid, .plainText, .code, .html, .canvas:
                // Text-representation category: trust availableModes.
                if !ViewModeOptions.availableModes(
                    for: url, forcedCategory: t.categoryOverride
                ).contains(.rendered) { return }
            case .image, .audio, .video, .pdf, .sqlite, .archive, .binary, .unknown:
                // Media / binary: `.rendered` is the leave-HEX escape
                // hatch handled below — leave it to the preview-restore arm.
                break
            }
        }
        // Side effects per mode:
        //   - .hex: state-swap is async (binary load can be slow on big
        //     files; main-thread blocking → beachball). View mode is
        //     set immediately so the picker reflects the user's pick.
        //   - .formatted: pretty-print is computed lazily by
        //     displayText(for:); just flip the flag.
        //   - .source / .rendered: clear formatted flag. Reverse from
        //     HEX (also async).
        switch mode {
        case .hex:
            // HEX is available for any file with bytes — text, image,
            // PDF, midi, anything. Trigger the binary load whenever
            // current state isn't already binary; loadBinaryAsync is
            // a no-op for an already-binary tab and re-reads cheaply
            // otherwise.
            if let url = t.url {
                switch t.state {
                case .binary, .empty, .loading, .hostedView: break
                case .loaded, .preview, .error:
                    loadBinaryAsync(url: url, intoTabID: t.id)
                }
            }
        case .formatted:
            if let url = t.url, Formatter.SupportedFormat.detect(url) != nil {
                tabCoordinator.setFormatted(true, forTabID: t.id)
            }
        case .preview:
            // Native-preview lens (image/audio/video/pdf/sqlite). The
            // content pane is state-driven: `.preview` state renders
            // MediaPreviewView. Coming back from HEX (state `.binary`) we
            // must restore the `.preview` state, mirroring the media-restore
            // arm in `.source/.rendered/...` below. For a fresh open the tab
            // is already in `.preview` state, so this is a no-op there.
            tabCoordinator.setFormatted(false, forTabID: t.id)
            if let url = t.url, case .binary = t.state {
                let state = controller.open(url: url)
                t.state = state
            }
        case .source, .rendered, .table, .diff:
            tabCoordinator.setFormatted(false, forTabID: t.id)
            if let url = t.url, case .binary = t.state {
                // Coming back from HEX. If the file is a media type
                // (image / audio / video / pdf / sqlite) it has no text
                // representation — `loadTextAsync` would silently fail
                // and the tab would stay in `.binary` state, so the
                // content area would keep showing HexView even though
                // the picker now says Source/Rendered. Restore the
                // native `.preview` state instead. For real text files
                // we still fall through to the async text reload.
                let cat = FileTypeDetector.category(for: url)
                switch cat {
                case .image, .audio, .video, .pdf, .sqlite, .archive:
                    let state = controller.open(url: url)
                    t.state = state
                case .markdown, .mermaid, .plainText, .code, .html, .canvas:
                    loadTextAsync(url: url, intoTabID: t.id)
                case .binary, .unknown:
                    // bug3: binary / unknown files have no Source/Rendered/
                    // Table/Diff mode (see ViewModeOptions.availableModes), so
                    // this arm is no longer reachable via the picker. Keep the
                    // tab in `.binary` (HexView) rather than kicking a
                    // `loadTextAsync` the loader already rejected as binary —
                    // that re-read silently failed and left the picker and the
                    // content view disagreeing. No-op.
                    break
                }
            }
        case .editor:
            // Activation gate: refuse the editor upgrade for files past
            // the CM6 cap (50 MB). `ContentView` already renders the
            // LargeEditorPlaceholderView so no 60 MB JS string reaches a
            // WebContent process — but without refusing here the mode
            // itself flips to `.editor`, which is both wrong (the picker
            // lies) and the contract EditorPhase4ScenarioTests pins. Keep
            // the tab on its current mode instead.
            if case .loaded(let file) = t.state,
               file.byteCount > codeMirrorEditorMaxBytes {
                return
            }
            // Editor needs the text contents in memory. If the tab
            // currently holds a binary view, kick a text re-load so
            // the buffer has something to bind to; the buffer itself
            // is created lazily by `editorBuffer(forTabID:)` once
            // the file lands as `.loaded`.
            tabCoordinator.setFormatted(false, forTabID: t.id)
            if let url = t.url, case .binary = t.state {
                loadTextAsync(url: url, intoTabID: t.id)
            }
            // Seed an EditorBuffer eagerly when the file is already
            // loaded so the view's first frame has real text rather
            // than an empty placeholder.
            if case .loaded(let file) = t.state {
                tabCoordinator.ensureEditorBuffer(for: file, tabID: t.id)
            }
        }
        t.viewMode = mode
        tabCoordinator.replace(at: i, with: t)
        // Republish DocumentModel so the picker + content re-evaluate.
        // View mode lives on `TabCoordinator`, but `ContentView` /
        // `ModeBar` observe `DocumentModel` — PERF #1 severed the
        // child→model `objectWillChange` forwarding and re-added direct
        // `@ObservedObject` only for `sidebar` + `find`, NOT `tabs`.
        // Every other display-changing tab mutation (open / close /
        // select) republishes through `updateDerived()`; this was the
        // lone gap, which left the Render|Source|Editor|HEX picker and
        // the content pane stuck on the previous mode. `updateDerived`'s
        // unconditional `windowTitle` assignment fires the publisher.
        updateDerived()
    }
}
