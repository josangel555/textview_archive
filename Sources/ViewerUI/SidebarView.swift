import SwiftUI
import ViewerCore
import ViewerKit

struct SidebarView: View {
    @ObservedObject var sidebar: SidebarModel
    @ObservedObject var model: DocumentModel
    /// Multi-repo git registry observation surface. Observed DIRECTLY
    /// (a third independent observable alongside `sidebar` + `model`) so
    /// badge colors / repo-root glyphs / section visibility re-eval on a
    /// `version` bump WITHOUT routing through `DocumentModel.objectWillChange`
    /// — see `TrackedReposRepublishInvariantTests`.
    @ObservedObject var trackedRepos: TrackedReposChannel
    /// Shoulder-rail layout. Observed directly so the accordion's
    /// per-panel presence resolves through the SAME store the rails
    /// drive — toggling a rail button re-bodies this view and flips the
    /// matching section in/out. The explicit `.shown` / `.hidden`
    /// override is layered on top of the data-presence heuristic.
    @ObservedObject var panelLayout: PanelLayoutStore

    /// File-tree accordion state. Persisted across the session via
    /// `@AppStorage` so the user's last collapse choice survives a
    /// tab switch (DocumentModel sub-views recreate this view).
    @AppStorage("MarkdownViewer.sidebar.filesExpanded") private var filesExpanded: Bool = true

    /// Pointer-hover state for the FILES section-header row (UIRESP-13).
    /// Drives a faint hover tint + pointing-hand cursor so the collapse
    /// header reads as clickable.
    @State private var filesHeaderHovering = false

    // TSK-282 (mode A): type-to-fuzzy-filter the visible file tree.
    // VIEW-LOCAL @State, deliberately NOT @Published on SidebarModel —
    // widening model observation is what #215 punished (design doc rule 2).
    // The debounced copy drives the actual ranking (~130 ms, the palette/
    // CSV-filter cadence); matches are computed in onChange, never in body.
    @State private var filterQuery = ""
    @State private var debouncedFilterQuery = ""
    @State private var filterMatches: [SidebarFilterMatch] = []
    @State private var filterDebounceTask: Task<Void, Never>?

    /// P1 — TOOL-WINDOW BOUNDING. The sidebar's currently-allotted
    /// content height, measured via a NON-layout-driving
    /// `.background(GeometryReader …)` (the same intrinsic-size-safe trick
    /// `b38ed03` used for TabBar width — a WRAPPING GeometryReader would
    /// collapse the sidebar's intrinsic size, see
    /// `TabBarIntrinsicSizeTests`). Threaded into the per-panel body-height
    /// clamp so each accordion panel is bounded to a fraction of THIS
    /// height — panels shrink toward the floor as the window shrinks
    /// instead of over-subscribing the band and pushing the chrome out.
    /// Zero on the first pass (pre-measurement); the clamp falls back to
    /// the stored height until the measurement settles one pass later.
    @State private var sidebarContentHeight: CGFloat = 0

    /// Live sidebar content WIDTH, measured by the same non-layout-driving
    /// background `GeometryReader` that captures the height. Drives the
    /// FILES-header control-label breakpoint (replacing a `ViewThatFits`
    /// that double-rendered the control cluster every body pass). Tracks
    /// the resize-drag width live (the reader sees the real frame, unlike
    /// `model.sidebarWidth`, which is committed only at drag-end).
    @State private var sidebarContentWidth: CGFloat = 0

    /// Width (points) below which the FILES-header sort/recency menus
    /// collapse to icon-only. Picked so the labels ("Name", "Modified")
    /// + icons + lock + pin fit above it. Hysteresis isn't needed: the
    /// width @State is epsilon-guarded, so it won't flap at the threshold.
    private static let headerLabelsBreakpoint: CGFloat = 248

    /// Minimum measure delta (points) that commits a content-size @State
    /// write — suppresses sub-point jitter re-bodying the sidebar. Mirrors
    /// `BoundedAccordionScroll.measureEpsilon`.
    private static let measureEpsilon: CGFloat = 0.5

    // Folder-stats slide-down visibility lives on `DocumentModel`
    // (`folderStatsExpanded`) so it survives sidebar re-bodies and is
    // scriptable — see the model property doc (WAVE 2b item 3).

    // MARK: - Recency mode dropdown (file-tree-recency agent)
    //
    // Drives the left-edge color stripe on each `FileRowView`.
    // Persisted as the raw String of `FileTreeRecency.RecencyMode`;
    // unknown values (manual user edits, future renames) fall back
    // to the type's `.default` (`.modified`) via the rawValue init.
    @AppStorage("MarkdownViewer.sidebar.recencyMode")
    private var recencyModeRaw: String = FileTreeRecency.RecencyMode.default.rawValue
    private var recencyMode: FileTreeRecency.RecencyMode {
        FileTreeRecency.RecencyMode(rawValue: recencyModeRaw)
            ?? FileTreeRecency.RecencyMode.default
    }

    // MARK: - Resizable section divider
    //
    // One `@AppStorage`-backed height per resizable section. The
    // `ResizableSectionDivider` between two sections mutates the
    // binding for the section above it; the section reads its
    // override via `\.sidebarSectionBodyHeight` (Environment) and
    // sizes its body accordingly. FILES at the bottom keeps the
    // flex-fill behaviour (`maxHeight: .infinity`) and intentionally
    // does NOT get an entry here.
    //
    // Keys are sourced from `SidebarSection` (ViewerCore) so the
    // string constants live in one place — easier to audit, easier
    // to migrate on rename.
    @AppStorage(SidebarPanelKind.bookmarks.appStorageKey)
    private var bookmarksHeight: Double = Double(SidebarPanelKind.bookmarks.defaultHeight)
    @AppStorage(SidebarPanelKind.searchAnywhere.appStorageKey)
    private var searchHeight: Double = Double(SidebarPanelKind.searchAnywhere.defaultHeight)
    @AppStorage(SidebarPanelKind.git.appStorageKey)
    private var gitHeight: Double = Double(SidebarPanelKind.git.defaultHeight)
    @AppStorage(SidebarPanelKind.claudeTimeline.appStorageKey)
    private var claudeHeight: Double = Double(SidebarPanelKind.claudeTimeline.defaultHeight)
    @AppStorage(SidebarPanelKind.lspOutline.appStorageKey)
    private var lspHeight: Double = Double(SidebarPanelKind.lspOutline.defaultHeight)
    @AppStorage(SidebarPanelKind.markdownOutline.appStorageKey)
    private var markdownOutlineHeight: Double = Double(SidebarPanelKind.markdownOutline.defaultHeight)
    @AppStorage(SidebarPanelKind.lspNavigation.appStorageKey)
    private var lspNavHeight: Double = Double(SidebarPanelKind.lspNavigation.defaultHeight)
    @AppStorage(SidebarPanelKind.lspProblems.appStorageKey)
    private var lspProblemsHeight: Double = Double(SidebarPanelKind.lspProblems.defaultHeight)
    @AppStorage(SidebarPanelKind.recentlyOpened.appStorageKey)
    private var recentsHeight: Double = Double(SidebarPanelKind.recentlyOpened.defaultHeight)
    @AppStorage(SidebarPanelKind.pluginSections.appStorageKey)
    private var pluginHeight: Double = Double(SidebarPanelKind.pluginSections.defaultHeight)

    /// `CGFloat` binding adapter — `@AppStorage` only natively stores
    /// `Double`; the divider expects `Binding<CGFloat>` so we project
    /// + clamp on the way through.
    private func heightBinding(_ source: Binding<Double>) -> Binding<CGFloat> {
        Binding(
            get: { SidebarPanelHeights.clamp(CGFloat(source.wrappedValue)) },
            set: { source.wrappedValue = Double(SidebarPanelHeights.clamp($0)) }
        )
    }

    var body: some View {
        #if DEBUG
        let _ = BodyProbe.tick("SidebarView")   // TSK-615 re-eval width probe
        #endif
        sidebarBody
            .walkthroughAnchor(.sidebar)
    }

    private var sidebarBody: some View {
        VStack(spacing: 0) {
            // (The root-name header row that used to sit here duplicated the
            // tree's own root node — removed, owner 2026-08-09. A hair of top
            // padding keeps the first section off the tab strip's hairline.)
            Spacer().frame(height: 4)
            // MARK: - Panel order
            //
            // FILES leads (matches VSCode / Xcode / IntelliJ
            // expectations — file tree on top, ancillary panels
            // below). The accordion below FILES is the legacy order
            // (Bookmarks → Search → Git → Claude → LSP → plugins).
            // Canonical order lives in
            // `SidebarPanelRegistry.defaultOrder` (ViewerCore); the
            // ordering pin-test there enforces FILES-first.
            //
            // Each panel ABOVE FILES previously got:
            //   - an environment-injected body height (read by the
            //     section's inner ScrollView via
            //     `\.sidebarSectionBodyHeight`)
            //   - a `ResizableSectionDivider` after it, whose drag
            //     binds to the same @AppStorage-backed height.
            // FILES sits at the top now and keeps its flex-fill
            // (`maxHeight: .infinity`) behaviour, so it absorbs
            // any leftover vertical space.
            if filesPanelVisible { filesPanel }
            // TSK-440 bug (B): the FILES↔accordion boundary gets a
            // resizable divider whenever FILES is expanded and at least
            // one tool window is visible below it — previously FILES +
            // one tool produced ZERO draggable boundaries. FILES owns no
            // height key (it's the flex-fill), so the divider drives the
            // FIRST tool window inversely: drag down grows FILES by
            // shrinking the tool below.
            if filesPanelVisible, let fullPlan = filesBoundaryPlan, fullPlan.drawFilesDivider,
               let first = fullPlan.entries.first {
                ResizableSectionDivider(
                    heightAbove: nil,
                    heightBelow: heightBinding(for: first.panel),
                    maxHeight: accordionCeiling
                )
            }
            // P1 — TOOL-WINDOW BOUNDING. The accordion run + plugin
            // sections live inside a BOUNDED, scrollable region so their
            // summed height can NEVER exceed the sidebar band and push the
            // window chrome (TabBar/ModeBar/StatusBar) out. FILES stays
            // OUTSIDE as the flex-fill (it shrinks first); the accordion
            // region is what was overflowing.
            //
            // Two layers of containment, both belt-and-suspenders:
            //   1. Each panel's body is clamped to a fraction of the
            //      measured `sidebarContentHeight` (see `panelView`), so
            //      panels shrink toward the floor as the window shrinks.
            //   2. `BoundedAccordionScroll` hugs its content up to a
            //      window-derived ceiling and SCROLLS past it — the hard
            //      guarantee that N panels at their floor can't overflow.
            BoundedAccordionScroll(
                availableHeight: sidebarContentHeight,
                panelCount: accordionPanelCount
            ) {
                // Divider placement is now driven by `SidebarSectionPlanner`
                // (ViewerCore) — a hidden panel (no git repo, no Claude
                // transcripts, non-LSP file) drops both itself AND the
                // divider that would have sat below it. Previously the
                // dividers were rendered unconditionally and stacked up
                // (the "3-4 lines bunched below GIT" bug).
                accordionStack
                // Plugin-contributed sidebar sections. Self-managing
                // collapse state; appears above FILES regardless of
                // whether a folder is open (a plugin may not need one).
                //
                // bug5: gate on the resolved visibility so the rail's
                // `.pluginSections` toggle actually works. This panel was
                // mounted unconditionally, bypassing `panelLayout.isVisible`
                // entirely — so its rail button's `.hidden` override was
                // computed but never read, leaving the "ROW COUNTS" window
                // permanently visible with a dead toggle. `dataPresent` is
                // always `true` for `.pluginSections` (a plugin section shows
                // regardless of folder), so only an explicit `.hidden` override
                // hides it — which is exactly the path the rail button drives.
                if pluginSectionsVisibleOnLeft {
                    PluginSidebarSections(model: model)
                        .environment(\.sidebarSectionBodyHeight,
                                     SidebarPanelHeights.clamp(CGFloat(pluginHeight),
                                                               availableHeight: sidebarContentHeight))
                }
            }
            // The flex-fill panel (owner 2026-08-09): when FILES is hidden the
            // LAST visible accordion panel takes its place — rendered OUTSIDE
            // the bounded scroll, `.infinity` = the flex sentinel, so it
            // absorbs the leftover band by LAYOUT (no computed heights, no
            // double scrollbars, no dead space).
            if let fill = accordionFillTarget {
                // Resizable boundary between the fixed run and the flex panel
                // — FILES-boundary parity: the drag drives the fixed panel
                // ABOVE; the flex panel absorbs the slack by layout. (In the
                // arithmetic-fill cut this divider wrote a stored height the
                // fill IGNORED — the drag visibly did nothing.)
                if let lastFixed = SidebarSectionPlanner.plan(panelVisibility)
                    .map(\.panel).filter({ $0 != fill }).last {
                    ResizableSectionDivider(
                        heightAbove: heightBinding(for: lastFixed),
                        maxHeight: accordionCeiling)
                }
                SidebarPanelBody.make(
                    for: fill,
                    model: model,
                    sidebar: sidebar,
                    trackedRepos: trackedRepos,
                    panelLayout: panelLayout,
                    bodyHeight: .infinity
                )
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(minWidth: 180, idealWidth: 240)
        // Top-align: without this, a short content stack centers
        // vertically in the available window height, leaving sections
        // floating in the middle. maxHeight:.infinity claims all the
        // height; alignment:.top pins content to the top.
        .frame(maxHeight: .infinity, alignment: .top)
        // P1 — hard envelope: even a transient mis-fit can never PAINT
        // outside the sidebar's allotted band into the chrome. The
        // bounded accordion above already keeps layout in-bounds; this is
        // the defensive backstop the brief's invariant calls for.
        .clipped()
        // P1 — measure the sidebar's allotted content height WITHOUT
        // driving layout (background overlay, not a wrapping
        // GeometryReader). Threaded into the per-panel clamp + the
        // bounded accordion ceiling.
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear {
                        sidebarContentHeight = geo.size.height
                        sidebarContentWidth = geo.size.width
                    }
                    .onChange(of: geo.size.height) { _, h in
                        // TSK-592 — RESIZE-JANK SUPPRESSION (PERF). This height
                        // feeds the per-panel `clamp(_:availableHeight:)` ceiling,
                        // then re-bodies the WHOLE sidebar. A live window/pane
                        // resize changes `h` by points every frame; committing
                        // each one re-runs the clamp for every accordion panel
                        // even when the resolved heights are byte-identical (the
                        // common "roomy" regime, where the ceiling sits above
                        // every stored height). `shouldCommitAvailableHeight`
                        // commits ONLY when some panel's resolved body height
                        // would actually change — dropping the no-op resize frames
                        // before they touch `@State`. (The old sub-point epsilon
                        // guard only caught jitter, not the pt-scale resize churn.)
                        if SidebarPanelHeights.shouldCommitAvailableHeight(
                            current: sidebarContentHeight,
                            measured: h,
                            storedHeights: accordionStoredHeights,
                            fraction: SidebarPanelHeights.ceilingFraction(
                                visiblePanelCount: accordionPanelCount)
                        ) {
                            sidebarContentHeight = h
                        }
                    }
                    .onChange(of: geo.size.width) { _, w in
                        // Same guard for the width (drives the header-control
                        // label breakpoint). Tracks the LIVE resize-drag width
                        // (the GeometryReader sees the real frame, unlike
                        // model.sidebarWidth which is stale mid-drag).
                        if abs(w - sidebarContentWidth) > Self.measureEpsilon {
                            sidebarContentWidth = w
                        }
                    }
            }
        )
        .background(Palette.textBackground)
        .background(
            SidebarKeyMonitor(
                isActive: sidebar.isVisible && !model.isPalettePresented
            ) { key in
                switch key {
                // TSK-272: arrowing the highlight also opens the newly-selected
                // FILE into the preview slot (Up/Down "changes current tab
                // content"); directories just move the highlight.
                case .up:    sidebar.selectPrevious(); previewSelectedFile()
                case .down:  sidebar.selectNext();     previewSelectedFile()
                case .left:  sidebar.collapseOrFocusParent()
                case .right: sidebar.expandOrFocusFirstChild()
                case .ret:
                    if let url = sidebar.selectedURL {
                        var isDir: ObjCBool = false
                        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                           isDir.boolValue {
                            sidebar.toggleExpansion(url)
                        } else {
                            model.open(url: url)
                        }
                    }
                case .f2:
                    // TSK-283: F2 renames the highlighted file/folder — the
                    // conventional rename key (Explorer / VS Code), additive
                    // so it doesn't disturb Return's existing open/toggle.
                    if let url = sidebar.selectedURL {
                        Self.presentRenamePrompt(for: url, model: model)
                    } else {
                        return false  // nothing selected → let others see it
                    }
                case .escape:
                    return false  // let other handlers (palette dismiss) see it
                }
                return true
            }
        )
    }

    /// TSK-272: open the currently-highlighted sidebar FILE into the ephemeral
    /// preview slot (Up/Down "changes current tab content"). A directory just
    /// moves the highlight — never previews. Mirrors the `.ret` file/dir guard;
    /// the `model.openPreview` slot-reuse keeps arrowing from spawning a tab
    /// per row. See `docs/PREVIEW_TAB_DESIGN.md`.
    private func previewSelectedFile() {
        guard let url = sidebar.selectedURL else { return }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              !isDir.boolValue else { return }
        model.openPreview(url: url)
    }

    /// TSK-283: modal rename prompt for a sidebar file/folder. Pre-fills the
    /// current name (selected) so the user can type over it. Shared by the
    /// F2 key and the right-click → Rename menu. Light NSAlert + text field,
    /// matching the Go-to-Line prompt idiom; the disk work + tree/bookmark
    /// follow-through live in `DocumentModel.renameFile`.
    @MainActor
    static func presentRenamePrompt(for url: URL, model: DocumentModel) {
        let alert = NSAlert()
        alert.messageText = "Rename"
        alert.informativeText = "Enter a new name for \u{201C}\(url.lastPathComponent)\u{201D}."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        field.stringValue = url.lastPathComponent
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        field.selectText(nil)  // select the whole name so a type replaces it
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        _ = model.renameFile(at: url, to: field.stringValue)
    }

    /// TSK-1463: destructive-op confirmation for right-click → Move to Trash.
    /// Same light NSAlert idiom as the rename prompt; the disk work + tab/tree
    /// follow-through live in `DocumentModel.deleteFileToTrash` (always the
    /// Trash — recoverable — never a hard unlink).
    @MainActor
    static func presentDeleteConfirm(for url: URL, model: DocumentModel) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Move \u{201C}\(url.lastPathComponent)\u{201D} to Trash?"
        alert.informativeText =
            "You can put it back from the Trash. Tabs open on it stay open — saving them recreates the file."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        _ = model.deleteFileToTrash(at: url)
    }

    /// TSK-1463: right-click → Move to Folder… — a directory picker, then the
    /// collision-safe `DocumentModel.moveFile` (never overwrites; open tabs
    /// and bookmarks follow the move).
    @MainActor
    static func presentMovePanel(for url: URL, model: DocumentModel) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Move"
        panel.message = "Choose a destination folder for \u{201C}\(url.lastPathComponent)\u{201D}."
        panel.directoryURL = url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        _ = model.moveFile(at: url, to: dest)
    }

    // MARK: - Accordion stack (visibility-aware divider placement)
    //
    // Below FILES sits an ordered run of panels; each one is either
    // unconditionally visible (BOOKMARKS, plugin sections) or self-
    // gates on some condition (GIT only when in a repo, CLAUDE only
    // when transcripts exist, OUTLINE only when the file has an LSP
    // server). Previously the parent rendered a
    // `ResizableSectionDivider` between every pair regardless — so
    // any run of hidden panels produced multiple stacked hairlines.
    //
    // Fix: compute visibility per panel up front, hand the list to
    // `SidebarSectionPlanner` (pure logic in ViewerCore, unit-tested),
    // and render exactly the panels + dividers it returns.

    /// Resolved visibility for each accordion panel, in accordion order.
    ///
    /// `dataPresent` is the shared `SidebarDataPresence` heuristic (the
    /// same one the rail reads, so the rail button's filled-state and
    /// the accordion's presence can't diverge); the explicit
    /// `.auto` / `.shown` / `.hidden` override is layered on top via
    /// `panelLayout.isVisible(_:dataPresent:)`. Fresh-install (`.auto`
    /// everywhere) resolves === today's data-presence behavior.
    ///
    /// FILES + plugin sections render OUTSIDE this accordion stack, so
    /// they're excluded here. The bookmarks panel is data-present
    /// always (its fixed "(empty)" envelope is intentional); LSP
    /// navigation + problems are present whenever a root is open (they
    /// hold cross-file state useful even when the active tab isn't an
    /// LSP language) — all encoded in `SidebarDataPresence`.
    /// Single source for the `SidebarDataPresence.Inputs` so the accordion
    /// (`panelVisibility`), the plugin-section gate, and any other presence
    /// read all derive from one heuristic — the file's single-source-of-truth
    /// discipline. Lifted out of `panelVisibility` so #4/#5 don't recompute it
    /// independently and drift.
    private var presenceInputs: SidebarDataPresence.Inputs {
        SidebarDataPresence.Inputs(
            hasRoot: sidebar.rootURL != nil,
            // Multi-repo: the git accordion shows when ANY repo is
            // tracked, not just a single auto-discovered sidebar-root.
            hasRepo: trackedRepos.trackedRoots.isEmpty == false,
            hasLSPLanguage: model.currentURL.flatMap {
                LSPLanguageRegistry.default.language(for: $0)
            } != nil,
            claudeHasTranscripts: sidebar.claudeHasTranscripts,
            hasRecents: !model.recents.isEmpty,
            hasMarkdownFile: EditorCoordinator.isMarkdownProse(url: model.currentURL)
        )
    }

    /// TSK-440: the full divider plan including the FILES boundary —
    /// nil when there's no folder open or FILES is collapsed (a
    /// header-only FILES row has nothing meaningful to resize against).
    private var filesBoundaryPlan: SidebarSectionPlanner.FullPlan? {
        guard sidebar.rootURL != nil, filesExpanded else { return nil }
        return SidebarSectionPlanner.plan(
            filesVisible: true,
            accordion: panelVisibility
        )
    }

    private var panelVisibility: [(panel: SidebarPanelKind, isVisible: Bool)] {
        let presence = SidebarDataPresence.evaluate(presenceInputs)
        let accordionOrder: [SidebarPanelKind] = [
            .bookmarks, .searchAnywhere, .git, .claudeTimeline,
            .lspOutline, .markdownOutline, .lspNavigation, .lspProblems, .recentlyOpened,
        ]
        return accordionOrder.map { kind in
            // UX-E: a panel moved off the LEFT rail (docked to the right /
            // bottom tool-window area) must NOT also render in the accordion
            // — otherwise it appears twice. Gate accordion visibility on the
            // panel still being left-docked; the docked container renders the
            // moved ones.
            let leftDocked = panelLayout.edge(of: kind) == .left
            let visible = leftDocked
                && panelLayout.isVisible(kind, dataPresent: presence[kind] ?? false)
            return (kind, visible)
        }
    }

    /// Count of accordion panels that resolve VISIBLE — drives the per-panel
    /// ceiling fraction (a lone panel may fill the band; TSK-1590).
    private var accordionPanelCount: Int {
        SidebarSectionPlanner.plan(panelVisibility).count
    }

    /// The render ceiling a divider drag may write up to (the same
    /// window-fraction clamp `resolvedBodyHeight` renders with) — keeps the
    /// stored height equal to the rendered height so drags track the mouse
    /// 1:1 with no dead zone. nil before the first height measurement.
    private var accordionCeiling: CGFloat? {
        guard sidebarContentHeight.isFinite, sidebarContentHeight > 0 else { return nil }
        return max(SidebarPanelHeights.minExpandedHeight,
                   sidebarContentHeight * SidebarPanelHeights.ceilingFraction(
                       visiblePanelCount: accordionPanelCount))
    }

    /// Plugin sections' left-accordion visibility, extracted so the render
    /// gate and the fill-target logic read one expression.
    private var pluginSectionsVisibleOnLeft: Bool {
        panelLayout.edge(of: .pluginSections) == .left
            && panelLayout.isVisible(
                .pluginSections,
                dataPresent: SidebarDataPresence.isPresent(.pluginSections, presenceInputs))
    }

    /// The accordion panel that plays FILES' flex-fill role when FILES is
    /// hidden (owner 2026-08-09: panels capped at their persisted height
    /// stranded the rest of the shoulder). Selection logic is pure
    /// (`SidebarSectionPlanner.fillTarget`, host-tested); the panel renders
    /// OUTSIDE the bounded scroll with the `.infinity` body sentinel — the
    /// literal FILES treatment, generalized. (The first cut computed a fill
    /// HEIGHT arithmetically inside the scroll — chrome estimates drifted
    /// and produced double scrollbars + a dead band; layout does it right.)
    private var accordionFillTarget: SidebarPanelKind? {
        SidebarSectionPlanner.fillTarget(
            filesVisible: filesPanelVisible,
            pluginsVisible: pluginSectionsVisibleOnLeft,
            accordion: panelVisibility)
    }

    @ViewBuilder
    private var accordionStack: some View {
        // The fill target renders OUTSIDE the bounded scroll (flex-fill, the
        // FILES treatment) — exclude it here so it isn't laid out twice.
        let plan = SidebarSectionPlanner.plan(panelVisibility)
            .filter { $0.panel != accordionFillTarget }
        ForEach(Array(plan.enumerated()), id: \.element.panel) { idx, entry in
            panelView(for: entry.panel)
            // TSK-440: a divider between two fixed-height panels drives
            // BOTH of them (sum-preserving redistribution) — dragging it
            // moves height between the adjacent pair instead of the old
            // above-only mutation that let FILES absorb the slack.
            if entry.drawTrailingDivider, idx + 1 < plan.count {
                ResizableSectionDivider(
                    heightAbove: heightBinding(for: entry.panel),
                    heightBelow: heightBinding(for: plan[idx + 1].panel),
                    maxHeight: accordionCeiling
                )
            }
        }
        // Claude-transcript presence now lives on `SidebarModel`
        // (refreshed in `setRoot`) so the rail + accordion read one
        // source of truth. The old `@State` + `.onAppear` /
        // `.onChange(of: rootURL)` refresh plumbing that lived here was
        // removed — `sidebar.claudeHasTranscripts` is observed directly.
    }

    @ViewBuilder
    private func panelView(for kind: SidebarPanelKind) -> some View {
        // UX-E: the per-kind body construction now lives in the shared
        // `SidebarPanelBody` factory so the accordion + the docked tool
        // windows render identical content (one source of truth for e.g.
        // the Git `forcedShown` flag + the LSP jump callbacks). The
        // accordion injects the resizable-section clamp as the body height;
        // `.files`/`.pluginSections` resolve to `EmptyView` here (FILES is
        // inline above; pluginSections is rendered below the accordion).
        switch kind {
        case .files, .pluginSections:
            EmptyView()
        default:
            SidebarPanelBody.make(
                for: kind,
                model: model,
                sidebar: sidebar,
                trackedRepos: trackedRepos,
                panelLayout: panelLayout,
                bodyHeight: resolvedBodyHeight(for: kind)
            )
        }
    }

    /// The height a panel's body renders at inside the bounded scroll: the
    /// stored-height clamp (TSK-1590 ceiling). The fill target never routes
    /// through here — it renders outside the scroll with the `.infinity`
    /// flex sentinel.
    private func resolvedBodyHeight(for kind: SidebarPanelKind) -> CGFloat {
        SidebarPanelHeights.clamp(
            CGFloat(accordionHeight(for: kind)),
            availableHeight: sidebarContentHeight,
            fraction: SidebarPanelHeights.ceilingFraction(
                visiblePanelCount: accordionPanelCount)
        )
    }

    /// TSK-592: the per-panel stored body heights (pre-clamp `@AppStorage`
    /// values) fed to `SidebarPanelHeights.shouldCommitAvailableHeight` so
    /// a resize frame is committed only when it would change some panel's
    /// resolved height. Mirrors the `accordionHeight(for:)` mapping; kept in
    /// the same order, though the predicate is order-insensitive.
    private var accordionStoredHeights: [CGFloat] {
        [
            bookmarksHeight, searchHeight, gitHeight, claudeHeight,
            lspHeight, markdownOutlineHeight, lspNavHeight, lspProblemsHeight, recentsHeight,
        ].map { CGFloat($0) }
    }

    /// The stored accordion body height (points) for a resizable section.
    /// Mirrors the per-section `@AppStorage` bindings; centralised so the
    /// shared `SidebarPanelBody` factory gets the right clamp input.
    private func accordionHeight(for kind: SidebarPanelKind) -> Double {
        switch kind {
        case .bookmarks:      return bookmarksHeight
        case .searchAnywhere: return searchHeight
        case .git:            return gitHeight
        case .claudeTimeline: return claudeHeight
        case .lspOutline:     return lspHeight
        case .markdownOutline: return markdownOutlineHeight
        case .lspNavigation:  return lspNavHeight
        case .lspProblems:    return lspProblemsHeight
        case .recentlyOpened: return recentsHeight
        case .files, .pluginSections:
            return Double(SidebarPanelKind.recentlyOpened.defaultHeight)
        }
    }

    /// TSK-440: the clamped height binding for a resizable accordion
    /// panel, or nil for the kinds that own no height key (FILES is the
    /// flex-fill; pluginSections self-manages). Centralised so the pair
    /// dividers and the FILES boundary divider read one mapping.
    private func heightBinding(for kind: SidebarPanelKind) -> Binding<CGFloat>? {
        switch kind {
        case .bookmarks:      return heightBinding($bookmarksHeight)
        case .searchAnywhere: return heightBinding($searchHeight)
        case .git:            return heightBinding($gitHeight)
        case .claudeTimeline: return heightBinding($claudeHeight)
        case .lspOutline:     return heightBinding($lspHeight)
        case .markdownOutline: return heightBinding($markdownOutlineHeight)
        case .lspNavigation:  return heightBinding($lspNavHeight)
        case .lspProblems:    return heightBinding($lspProblemsHeight)
        case .recentlyOpened: return heightBinding($recentsHeight)
        case .files, .pluginSections:
            return nil
        }
    }

    // MARK: - FILES panel
    //
    // The FILES tree sits at the top of the accordion (was at the
    // bottom prior to the activity-bar groundwork refactor). Keeps
    // its own collapsible chevron header + sort/lock controls.
    //
    // When the section is expanded it gets a `frame(maxHeight:
    // .infinity)` so it absorbs all leftover vertical space — the
    // other panels are fixed-height (via `@AppStorage` per-panel
    // heights), FILES is the flex-fill in the layout.
    //
    // When there's no folder open the FILES panel collapses to a
    // single "No folder open" placeholder line; the sections below
    // (Bookmarks, etc.) still render normally so the user can pick
    // a bookmarked folder without first opening one.
    /// TSK-1314: the FILES tree must respect its per-panel `.files` override (the
    /// shoulder toggle), not just `rootURL`. Same class as the bug5 pluginSections
    /// fix above — a panel mounted on a presence/root check that bypassed
    /// `panelLayout.isVisible`, so its rail `.hidden` override was computed but never
    /// read (file-nav stayed visible when only Bookmark was enabled). `.auto`
    /// resolves to data-presence (rootURL), so the default behaviour is unchanged;
    /// only an explicit `.hidden` toggle now hides the tree.
    private var filesPanelVisible: Bool {
        panelLayout.isVisible(.files, dataPresent: SidebarDataPresence.isPresent(.files, presenceInputs))
    }

    @ViewBuilder
    private var filesPanel: some View {
        if sidebar.rootURL != nil {
            VStack(spacing: 0) {
                filesHeader
                // Folder-stats slide-down (WAVE 2b item 3). Renders the
                // WAVE 2a `FolderStatsView` inline under the header when
                // the `chart.bar` toggle is on AND the root is inside a
                // repo. The cache is the long-lived one on DocumentModel
                // (survives reopens); scope is repo-wide.
                if model.folderStatsExpanded, let repoRoot = sidebar.gitRepoRoot {
                    Divider()
                    FolderStatsView(
                        doc: model,
                        repoRoot: repoRoot,
                        scope: .repo,
                        cache: model.repoStatsCache,
                        title: repoRoot.lastPathComponent
                    )
                    .transition(.move(edge: .top).combined(with: .opacity))
                    Divider()
                }
                if filesExpanded {
                    // TSK-282: type-to-filter field. Additive — empty query
                    // renders the tree exactly as before.
                    sidebarFilterField
                    if !debouncedFilterQuery.isEmpty {
                        filteredResultsList
                    } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            // PERF #6: flatten the visible tree once and
                            // enumerate it inside a single LazyVStack so
                            // virtualization kicks in for deep trees.
                            // The prior shape recursed `FileRowView` ->
                            // `ForEach` -> child `FileRowView`, which
                            // SwiftUI materialized eagerly past the
                            // outer LazyVStack — defeating it as soon
                            // as the root expanded.
                            //
                            // `flatVisibleRows()` is memoized on
                            // SidebarModel; reading it from the body is
                            // O(1) on cache-hit (the common case) and
                            // O(visible-row-count) on miss. It does no
                            // IO either way.
                            let rows = sidebar.flatVisibleRows()
                            LazyVStack(alignment: .leading, spacing: 0) {
                                // J1: ".." parent-nav row, rendered as the
                                // FIRST row of the tree (replaces the former
                                // header up-arrow button). Re-roots to the
                                // parent on click via the existing `goUp`.
                                if canGoUp {
                                    parentNavRow
                                }
                                ForEach(rows) { row in
                                    // TSK-613: `.equatable()` + the value
                                    // snapshot means a model republish only
                                    // re-bodies rows whose snapshot changed
                                    // (selection / current / git status...),
                                    // not every visible row.
                                    FileRowView(
                                        node: row.node,
                                        depth: row.depth,
                                        state: FileRowState.make(
                                            node: row.node,
                                            model: model,
                                            sidebar: sidebar,
                                            trackedRepos: trackedRepos,
                                            recencyMode: recencyMode
                                        ),
                                        sidebar: sidebar,
                                        model: model,
                                        trackedRepos: trackedRepos
                                    )
                                    .equatable()
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        // CRIT-6: keep keyboard-selected row visible.
                        .onChange(of: sidebar.selectedURL) { _, new in
                            if let url = new {
                                proxy.scrollTo(url, anchor: .center)
                            }
                        }
                    }
                    // Flex-fill so FILES (now the top panel) eats
                    // the leftover vertical space below the other
                    // fixed-height accordion sections. Without this
                    // the tree would collapse to its intrinsic
                    // height and leave a gap at the sidebar bottom.
                    .frame(maxHeight: .infinity)
                    }
                }
            }
        } else {
            HStack {
                Text("No folder open")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }

    // MARK: - TSK-282 fuzzy filter (mode A — narrow the visible rows)

    /// The type-to-filter field under the FILES header. Esc clears (the
    /// field's exit command); the clear button is the discoverable twin.
    private var sidebarFilterField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: model.uiSize(10)))
                .foregroundStyle(Palette.secondaryLabel)
            TextField("Filter files", text: $filterQuery)
                .textFieldStyle(.plain)
                .font(.system(size: model.uiSize(11)))
                .onExitCommand { filterQuery = "" }
                .accessibilityIdentifier("sidebar.filterField")
            if !filterQuery.isEmpty {
                Button {
                    filterQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: model.uiSize(10)))
                        .foregroundStyle(Palette.secondaryLabel)
                }
                .buttonStyle(.plain)
                .help("Clear the file filter")
                .accessibilityIdentifier("sidebar.filterField.clear")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .onChange(of: filterQuery) { _, new in
            // Debounce keystrokes (~130 ms, the palette/CSV cadence);
            // clearing applies INSTANTLY so Esc snaps the tree back.
            filterDebounceTask?.cancel()
            if new.isEmpty {
                debouncedFilterQuery = ""
                filterMatches = []
                return
            }
            filterDebounceTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 130_000_000)
                guard !Task.isCancelled else { return }
                debouncedFilterQuery = new
                recomputeFilterMatches()
            }
        }
        // TSK-666: the global cache finished building mid-filter — upgrade
        // the mode-A results to global ones (one bump per build, not a
        // per-keystroke observation).
        .onChange(of: sidebar.descendantsVersion) { _, _ in
            if !debouncedFilterQuery.isEmpty { recomputeFilterMatches() }
        }
    }

    /// Flat ranked results replacing the tree while a filter is active.
    /// Matches are recomputed in `onChange`, never in `body` (design
    /// rule 1 — nothing expensive on the body pass).
    private var filteredResultsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if filterMatches.isEmpty {
                    HStack {
                        Text("No matches")
                            .foregroundStyle(.secondary)
                            .font(.system(size: model.uiSize(11)))
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                } else {
                    ForEach(filterMatches) { match in
                        SidebarFilterRow(
                            match: match,
                            uiSize: model.uiSize,
                            action: { activateFilterMatch(match) }
                        )
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxHeight: .infinity)
        .accessibilityIdentifier("sidebar.filterResults")
    }

    /// Mode B (TSK-666) when the global descendant cache is ready —
    /// finds files in COLLAPSED branches; mode A (visible rows) until
    /// then, so typing never blocks on the off-main walk. The cache kick
    /// lives here (a user actively filtering is the demand signal).
    private func recomputeFilterMatches() {
        if let entries = sidebar.globalFindCandidates() {
            filterMatches = SidebarFilter.filterGlobal(
                entries, query: debouncedFilterQuery)
        } else {
            sidebar.ensureDescendantsCache()
            filterMatches = SidebarFilter.filter(
                sidebar.flatVisibleRows(), query: debouncedFilterQuery)
        }
    }

    /// Same activation semantics as a tree row (`FileRowView.activate`):
    /// file → ephemeral preview tab; directory → toggle expansion (the
    /// newly visible children join the next recompute). Opening a FILE
    /// clears the filter — you found what you were looking for; the tree
    /// snaps back with the selection set. A global (mode B) hit may live
    /// in a collapsed branch — reveal its ancestors first so the file is
    /// visible after the filter clears.
    private func activateFilterMatch(_ match: SidebarFilterMatch) {
        sidebar.revealAncestors(of: match.url)
        sidebar.setSelected(match.url)
        if match.isDirectory {
            sidebar.toggleExpansion(match.url)
            recomputeFilterMatches()
        } else {
            model.openPreview(url: match.url)
            filterQuery = ""
        }
    }

    /// FILES section header — chevron + label + sort menu + lock.
    /// Visually consistent with every other section's header row.
    private var filesHeader: some View {
        HStack(spacing: 4) {
            Button(action: {
                // Animate the collapse so the section-header chevron
                // (driven by `isExpanded`) eases rather than snaps
                // (UIRESP-13).
                withAnimation(.easeInOut(duration: 0.15)) {
                    filesExpanded.toggle()
                }
            }) {
                HStack(spacing: 4) {
                    SidebarSectionHeaderLabel(
                        title: "Files",
                        isExpanded: filesExpanded,
                        uiSize: model.uiSize
                    )
                    Spacer()
                }
                .contentShape(Rectangle())
                // UIRESP-13: faint hover tint on the header row.
                .background(filesHeaderHovering
                            ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.10)
                            : Color.clear)
            }
            .buttonStyle(.plain)
            // TSK-892: balanced cursor push/pop (the old open-coded
            // push/pop double-pushed on AppKit's repeat onHover(true) and
            // had no onDisappear pop — see HoverCursorBalance).
            .hoverCursor(isHovering: $filesHeaderHovering)
            .helpInfo(title: filesExpanded ? "Collapse Files" : "Expand Files",
                      description: "Show or hide the file tree")
            .accessibilityIdentifier("mdv.sidebar.filesHeader")
            // Trailing controls cluster: sort + recency menus, lock, pin.
            // The two menus' VALUE LABELS ("Name", "Modified") collapse to
            // icon-only when the sidebar is too narrow to fit them; the
            // lock + pin icon-buttons stay visible either way. Without this
            // the `.fixedSize()` menus + the WAVE1 pin button overflowed a
            // narrow header — pushing the "FILES" title and the lock/pin
            // buttons off-screen.
            //
            // PERF: this was a `ViewThatFits`, which BUILDS BOTH variants
            // (two full control clusters, each with two `.fixedSize()`
            // Menus) on every body pass just to pick one. Replaced with a
            // single-build width breakpoint off the measured sidebar width
            // (`sidebarContentWidth`, captured by the existing background
            // GeometryReader at zero extra cost). Unmeasured (width 0, first
            // paint) shows labels — the common wide-sidebar case — so there's
            // no icon-only flash before the measurement settles.
            headerControls(
                showMenuLabels: sidebarContentWidth == 0
                    || sidebarContentWidth >= Self.headerLabelsBreakpoint
            )
        }
        .sidebarHeaderRow(uiSize: model.uiSize)
    }

    /// The FILES-header trailing controls (sort menu, recency menu, lock,
    /// pin). `showMenuLabels` drives whether the two menus show their value
    /// text or collapse to icon-only — the `ViewThatFits` in `filesHeader`
    /// picks the widest variant that fits the sidebar's current width.
    @ViewBuilder
    private func headerControls(showMenuLabels: Bool) -> some View {
        HStack(spacing: 4) {
            // Sort mode picker. Folders always sort before files
            // (Finder-like); the chosen mode applies within each group.
            Menu {
                ForEach(SidebarModel.FolderSortMode.allCases) { mode in
                    Button {
                        sidebar.sortMode = mode
                    } label: {
                        HStack {
                            Text(mode.rawValue)
                            if sidebar.sortMode == mode {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: model.uiSize(9)))
                    if showMenuLabels {
                        Text(sidebar.sortMode.rawValue)
                            .font(.system(size: model.uiSize(10)))
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            // 0c: uniform HelpInfo — bubble title + status-bar description.
            .helpInfo(title: "Sort",
                      description: "Sort folder contents by name, date, or kind")
            .accessibilityIdentifier("mdv.sidebar.sort")
            // MARK: - Recency mode dropdown (file-tree-recency agent)
            //
            // Picks which timestamp drives the left-edge color stripe
            // on each file row. Persisted in `@AppStorage` via
            // `recencyModeRaw`; the active mode is read by
            // `FileRowView` through the constructor.
            Menu {
                ForEach(FileTreeRecency.RecencyMode.allCases) { mode in
                    Button {
                        recencyModeRaw = mode.rawValue
                    } label: {
                        HStack {
                            Text(mode.rawValue)
                            if recencyMode == mode {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "paintpalette")
                        .font(.system(size: model.uiSize(9)))
                    if showMenuLabels {
                        Text(recencyMode.rawValue)
                            .font(.system(size: model.uiSize(10)))
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .helpInfo(title: "Recency colors",
                      description: "Color-code file rows by recency (Modified / Added / Created)")
            .accessibilityIdentifier("mdv.sidebar.recencyMode")
            // Folder-stats toggle (WAVE 2b item 3). Slides
            // `FolderStatsView` down under the FILES header. Shown only
            // when the root is inside a git repo (the stats are repo-wide
            // aggregates). Mirrors the lock/pin icon-button styling.
            if folderStatsAvailable {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        model.folderStatsExpanded.toggle()
                    }
                }) {
                    Image(systemName: "chart.bar")
                        .font(.system(size: model.uiSize(10)))
                        .foregroundStyle(model.folderStatsExpanded ? Color.accentColor : .secondary)
                        .frame(width: model.uiSize(18), height: model.uiSize(18))
                }
                .buttonStyle(IconHoverButtonStyle(cornerRadius: model.uiSize(4),
                                                  isSelected: model.folderStatsExpanded))
                .helpInfo(title: model.folderStatsExpanded ? "Hide folder statistics" : "Folder statistics",
                          description: "Show repo commit / author / file-type stats")
                .accessibilityIdentifier("mdv.sidebar.folderStats")
            }
            // Lock toggle. When locked, auto-reveal-on-click +
            // tab-reveal won't change the sidebar root; the user's
            // chosen folder stays put.
            Button(action: { model.toggleSidebarLock() }) {
                Image(systemName: model.isSidebarLocked
                      ? "lock.fill" : "lock.open")
                    .font(.system(size: model.uiSize(10)))
                    .foregroundStyle(model.isSidebarLocked
                                     ? Color.accentColor
                                     : .secondary)
                    .frame(width: model.uiSize(18), height: model.uiSize(18))
            }
            .buttonStyle(IconHoverButtonStyle(cornerRadius: model.uiSize(4),
                                              isSelected: model.isSidebarLocked))
            .helpInfo(title: model.isSidebarLocked ? "Unlock sidebar" : "Lock sidebar",
                      description: model.isSidebarLocked
                        ? "Sidebar root locked — click to unlock"
                        : "Lock sidebar root (prevent auto-navigation)")
            // item9: pin / follow-active-tab. When on, switching tabs reveals
            // the active file in the tree (select + expand, no re-root).
            Button(action: { model.toggleSidebarFollowsActiveTab() }) {
                Image(systemName: model.sidebarFollowsActiveTab
                      ? "pin.fill" : "pin")
                    .font(.system(size: model.uiSize(10)))
                    .foregroundStyle(model.sidebarFollowsActiveTab
                                     ? Color.accentColor
                                     : .secondary)
                    .frame(width: model.uiSize(18), height: model.uiSize(18))
            }
            .buttonStyle(IconHoverButtonStyle(cornerRadius: model.uiSize(4),
                                              isSelected: model.sidebarFollowsActiveTab))
            .helpInfo(title: model.sidebarFollowsActiveTab ? "Following active tab" : "Follow active tab",
                      description: model.sidebarFollowsActiveTab
                        ? "Sidebar follows the active tab — click to stop"
                        : "Reveal the active tab's file in the sidebar on every tab switch")
            .accessibilityIdentifier("mdv.sidebar.followActiveTab")
            // TSK-363: the former show-hidden eye toggle is gone — hidden
            // files are ALWAYS shown (`SidebarModel.includeHidden` stays
            // true for the app's lifetime; session restore no longer
            // flips it).
        }
        // Cluster hugs its content so the `ViewThatFits` measurement is the
        // cluster's intrinsic width (not a stretched one).
        .fixedSize()
    }

    /// J1: ".." parent-folder navigation row at the top of the file
    /// tree. Styled like a depth-0 folder row in `FileRowView` (chevron-
    /// width spacer + folder glyph + name, matching the `depth*14 + 8`
    /// leading inset), but it re-roots the sidebar via `goUp` instead of
    /// expanding. Only shown when `canGoUp`.
    private var parentNavRow: some View {
        Button(action: goUp) {
            HStack(spacing: model.uiSize(4)) {
                // Disclosure-chevron-width spacer so the icon aligns with
                // sibling folder rows (which reserve 12 pt for the chevron).
                Spacer().frame(width: model.uiSize(12))
                Image(systemName: "arrow.up.left")
                    .font(.system(size: model.uiSize(11)))
                    .frame(width: model.uiSize(16), height: model.uiSize(16))
                    .foregroundStyle(.secondary)
                Text("..")
                    .font(.system(size: model.uiSize(12)))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, model.uiSize(8))   // depth 0 → 0*14 + 8
            .padding(.vertical, model.uiSize(3))
            .padding(.trailing, model.uiSize(8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .helpInfo(title: "Open parent folder",
                  description: "Re-root the sidebar one level up")
        .accessibilityLabel("Open parent folder")
        .accessibilityIdentifier("mdv.sidebar.parentNav")
    }

    /// True when the sidebar root is inside a git repo — gates the
    /// folder-stats `chart.bar` toggle (WAVE 2b item 3). FolderStatsView
    /// reads repo-wide aggregates, so there's nothing to show outside a
    /// repo.
    private var folderStatsAvailable: Bool {
        // Memoized on SidebarModel (recomputed on root change / root-dir
        // `.git` change) — NOT an FS-walk per body pass. See `gitRepoRoot`.
        sidebar.gitRepoRoot != nil
    }

    /// True when the current root has a parent we can navigate to (not `/`).
    private var canGoUp: Bool {
        guard let root = sidebar.rootURL else { return false }
        let parent = root.deletingLastPathComponent()
        return parent.path != root.path  // false at filesystem root
    }

    private func goUp() {
        guard let root = sidebar.rootURL else { return }
        let parent = root.deletingLastPathComponent()
        if parent.path != root.path {
            model.openFolder(parent)
        }
    }

}

private struct FileRowContextMenu: View {
    let node: FileNode
    @ObservedObject var sidebar: SidebarModel
    @ObservedObject var model: DocumentModel
    @ObservedObject var trackedRepos: TrackedReposChannel

    var body: some View {
        if !node.isDirectory {
            Button("Open") { model.open(url: node.url) }
            Button("Open in New Tab") { model.openInNewTab(node.url) }
            Button("Open in Split") { model.openInSplit(node.url) }
            // TSK-916: re-read this file's open tab from disk (no-op/disabled
            // when it isn't open — the tree holds no content to reload).
            Button("Reload from Disk") { model.reloadFileFromDisk(node.url) }
                .disabled(!model.isFileOpenInTab(node.url))
            // WAVE 2b item 6: universal "Open As…" — open this file in a
            // new tab through any applicable viewer (Source, SQLite, HEX,
            // Image, …), including for binaries.
            Menu("Open As…") {
                ForEach(model.openAsCategories(for: node.url), id: \.self) { cat in
                    Button(LensLabels.categoryLabel(cat)) {
                        model.openAs(url: node.url, category: cat)
                    }
                }
            }
            // TSK-1152: per-filename "Lock View As" — PERSIST a view mode for
            // this file so REOPENING re-applies it (distinct from the one-time
            // "Open As…" above). "Unlock" shows once a lock is set.
            if model.viewModeIsLocked(node.url) {
                Button("Unlock View As") { model.unlockViewMode(node.url) }
            } else {
                Menu("Lock View As…") {
                    ForEach(ViewModeOptions.availableModes(for: node.url), id: \.self) { mode in
                        Button(mode.displayName) {
                            model.lockViewMode(node.url, to: mode)
                        }
                    }
                }
            }
            Divider()
            Button(model.bookmarksStore.contains(node.url)
                   ? "Remove Bookmark" : "Bookmark File") {
                _ = model.bookmarksStore.toggle(
                    url: node.url,
                    displayName: node.url.lastPathComponent
                )
                model.refreshBookmarks()
            }
            Divider()
        } else {
            Button(sidebar.isExpanded(node.url) ? "Collapse" : "Expand") {
                sidebar.toggleExpansion(node.url)
            }
            Button("Open Folder") { model.openFolder(node.url) }
            if let openInNewSession = model.openFolderInNewSession {
                Button("Open in New Session") {
                    openInNewSession(node.url)
                }
            }
            Divider()
            // Bookmark / unbookmark — works on folders too. Cmd+D in
            // the global menu only bookmarks the current TAB; folder
            // bookmarks need an explicit context-menu entry.
            Button(model.bookmarksStore.contains(node.url)
                   ? "Remove Bookmark" : "Bookmark Folder") {
                _ = model.bookmarksStore.toggle(
                    url: node.url,
                    displayName: node.url.lastPathComponent
                )
                model.refreshBookmarks()
            }
            // Pin a repo into the tracked set so its badges / gutter /
            // panel stay live even with no open tab inside it (monorepo
            // subdir, submodule, or a repo you're about to work in). The
            // multi-pin successor to the old single-slot "Set as Git
            // Root" override.
            if trackedRepos.isRepoRoot(node.url) {
                Button(model.repoFocus.pinned.contains(TrackedReposReducer.normalize(node.url))
                       ? "Unpin Repo" : "Pin Repo") {
                    model.repoFocus.togglePin(node.url)
                }
                Divider()
            }
        }
        Button("Copy Path") { Pasteboard.copy(node.url.path) }
        Button("Copy Relative Path") { Pasteboard.copy(relativePath) }
        // TSK-1256 / OwnerWishlist "Copy Reference": an mdv:// agent reference an
        // agent can open/locate via the element-ref pipeline (file form).
        Button("Copy Reference") {
            Pasteboard.copy(ElementRef.file(path: node.url.path, line: nil, endLine: nil).serialized)
        }
        Button("Reveal in Finder") { Finder.reveal(node.url) }
        // TSK-355: hand the file to its default external app (Preview, Numbers, …).
        Button("Open in Default App") { Finder.openInDefaultApp(node.url) }
        // TSK-283: rename this file/folder (also bound to F2). Collision-safe
        // via the model; the tree + bookmarks + open tabs follow the move.
        Button("Rename…") { SidebarView.presentRenamePrompt(for: node.url, model: model) }
        // TSK-1463: move into another folder (picker). Never overwrites; open
        // tabs and bookmarks follow.
        Button("Move to Folder…") { SidebarView.presentMovePanel(for: node.url, model: model) }
        // TSK-1463: trash — confirmed, recoverable, never a hard delete. Open
        // tabs stay open (marked "deleted on disk"); saving recreates the file.
        Button("Move to Trash…", role: .destructive) {
            SidebarView.presentDeleteConfirm(for: node.url, model: model)
        }
        if node.isDirectory {
            // TSK-329/747: create a new file in this folder (the right-click →
            // New File entry point). Atomic + non-colliding via the model.
            // The submenu offers the text-based types (txt/md/csv/json).
            Menu("New File") {
                ForEach(NewFileType.allCases, id: \.self) { type in
                    // TSK-1605: prompt for the name, then create it.
                    Button(type.title) { model.promptForNewFile(in: node.url, type: type) }
                }
                // TSK-1167: Image (binary) — create a blank image in this folder + open.
                Button("Image") {
                    if let url = model.createNewBlankImage(in: node.url) {
                        model.openPath(url)
                    }
                }
            }
            // TSK-1463: non-colliding "untitled folder" here.
            Button("New Folder") { _ = model.createNewFolder(in: node.url) }
            Divider()
            Button("Open in Terminal") {
                model.openTerminalInApp(at: node.url, isDirectory: node.isDirectory)
            }
            // TSK-916: manual "Refresh" — force a fresh re-list of this folder
            // and its expanded descendants (the FSEvents auto-refresh can miss
            // network/iCloud mounts or a dropped watcher stream).
            Button("Refresh") { sidebar.refreshFromDisk(node.url) }
            // MARK: - Search in Folder (folder-context agent)
            // Presents the unified search panel with the scope picker
            // pre-set to this folder (pickedFolder), bypassing the
            // sidebar root. Keeps the existing showCrossSearch() path
            // intact for callers that want sidebar-root behavior.
            Button("Search in Folder") {
                model.showCrossSearch(scope: .pickedFolder(node.url))
            }
        }
        if !node.isDirectory {
            // Unified Local History viewer (TSK-1103): list saved versions →
            // view / diff-vs-current / range cumulative diff / restore. Works on
            // any file (not just tracked ones); the viewer shows a friendly empty
            // state when there are no saved versions yet.
            Divider()
            Button("Local History") {
                model.openLocalHistory(for: node.url)
            }
            .disabled(!model.canShowLocalHistory(for: node.url))
        }
        if trackedRepos.trackedRoots.isEmpty == false {
            Divider()
            if !node.isDirectory {
                // WAVE 2b item 2: route to the in-app FileHistoryView
                // (master-detail commits + diff) instead of the old
                // synthetic-markdown `showGitLog`. Gated on the file
                // being in a repo + tracked.
                Button("File History") {
                    model.openFileHistory(for: node.url)
                }
                .disabled(!model.canShowFileHistory(for: node.url))
            } else {
                Button("Show Folder History") {
                    model.showGitLog(forPath: node.url, scope: .folder)
                }
            }
        }
    }

    /// Path relative to the sidebar root. Falls back to the filename when
    /// `node.url` isn't under the root (shouldn't happen via the UI, but
    /// it's defensive).
    private var relativePath: String {
        guard let root = sidebar.rootURL else { return node.url.lastPathComponent }
        let rootComponents = root.standardizedFileURL.pathComponents
        let nodeComponents = node.url.standardizedFileURL.pathComponents
        if nodeComponents.count > rootComponents.count,
           Array(nodeComponents.prefix(rootComponents.count)) == rootComponents {
            return nodeComponents.dropFirst(rootComponents.count).joined(separator: "/")
        }
        return node.url.lastPathComponent
    }
}

struct GitStatusBadge: View {
    let status: GitStatusEntry.Status
    /// UX-F (#228): zoom-scale helper threaded from the host
    /// (`DocumentModel.uiSize`). Defaults to identity so call sites
    /// without a model render at the base size.
    var uiSize: (CGFloat) -> CGFloat = { $0 }

    var body: some View {
        Text(status.rawValue)
            .font(.system(size: uiSize(9), weight: .bold))
            .foregroundStyle(color)
            .frame(width: uiSize(12), height: uiSize(12))
            .helpInfo(title: "Git status", description: label)
    }

    private var color: Color {
        switch status {
        case .modified:   return .orange
        case .added:      return .green
        case .deleted:    return .red
        case .renamed, .copied: return .blue
        case .untracked, .ignored: return .secondary
        case .conflicted: return .red
        }
    }

    private var label: String {
        switch status {
        case .modified:   return "Modified"
        case .added:      return "Added"
        case .deleted:    return "Deleted"
        case .renamed:    return "Renamed"
        case .copied:     return "Copied"
        case .untracked:  return "Untracked"
        case .ignored:    return "Ignored"
        case .conflicted: return "Conflict"
        }
    }
}

/// Everything a `FileRowView` body reads, extracted to an Equatable
/// value (TSK-613). The rows used to observe DocumentModel / SidebarModel
/// / TrackedReposChannel directly, so EVERY visible row re-evaluated on
/// EVERY model republish — 144ms inclusive per 4s nav sweep in the
/// TSK-603 capture. The parent enumeration (which already observes all
/// three objects) now computes this snapshot per row and the row is
/// `.equatable()`: SwiftUI skips the body for rows whose snapshot didn't
/// change, so a tab switch re-bodies ~3 rows instead of all of them.
///
/// CONTRACT: every model/sidebar/trackedRepos read inside the row's body
/// MUST come through this struct (or `@State` local to the row). A read
/// that bypasses it renders stale because nothing re-bodies the row.
struct FileRowState: Equatable, Sendable {
    let isCurrent: Bool
    let isSelected: Bool
    let isOpenInOtherTab: Bool
    /// The file sits in the ONE ephemeral preview slot (TSK-306) — its row
    /// renders in italics to match the preview tab's italic title (owner
    /// 2026-08-09).
    let isPreviewTab: Bool
    let isBookmarked: Bool
    let isViewModeLocked: Bool
    let isExpanded: Bool
    let gitStatus: GitStatusEntry.Status?
    let repoRootKind: RepoRootKind
    let isTrackedRoot: Bool
    let zoom: Double
    let recencyMode: FileTreeRecency.RecencyMode
    let recencyVersion: Int

    /// One row's snapshot. `internal` so the skip contract is testable
    /// headlessly: unrelated model changes must produce an EQUAL state.
    @MainActor
    static func make(
        node: FileNode,
        model: DocumentModel,
        sidebar: SidebarModel,
        trackedRepos: TrackedReposChannel,
        recencyMode: FileTreeRecency.RecencyMode
    ) -> FileRowState {
        let kind: RepoRootKind = node.isDirectory
            ? trackedRepos.repoRootKind(node.url) : .none
        return FileRowState(
            isCurrent: model.currentURL == node.url,
            isSelected: sidebar.selectedURL == node.url,
            isOpenInOtherTab: !node.isDirectory
                && model.openTabURLs.contains(node.url)
                && node.url != model.currentURL,
            isPreviewTab: !node.isDirectory
                && model.tabs.tabs.first(where: { $0.url == node.url })?.isPreview == true,
            isBookmarked: model.bookmarksStore.contains(node.url),
            isViewModeLocked: !node.isDirectory
                && model.viewModeLocks.isLocked(for: node.url),
            isExpanded: sidebar.isExpanded(node.url),
            gitStatus: trackedRepos.status(for: node.url),
            repoRootKind: kind,
            isTrackedRoot: kind != .none && trackedRepos.isTrackedRoot(node.url),
            zoom: model.zoom,
            recencyMode: recencyMode,
            recencyVersion: sidebar.recencyVersion
        )
    }
}

/// One flat row in the TSK-282 filtered-results list: icon + fuzzy-bolded
/// name + root-relative path. Deliberately lighter than `FileRowView` (no
/// tree depth, no git stripe) — filter mode is a transient find surface.
private struct SidebarFilterRow: View {
    let match: SidebarFilterMatch
    let uiSize: (CGFloat) -> CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                FileIconView(
                    url: match.url,
                    isDirectory: match.isDirectory,
                    isExpanded: false,
                    size: .tree
                )
                .frame(width: 16, height: 16)
                Text(FuzzyHighlight.attributed(
                    match.display,
                    matchedIndices: match.matchedIndices,
                    size: uiSize(12),
                    regular: .primary,
                    highlight: .accentColor))
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 4)
                if !match.secondary.isEmpty {
                    Text(match.secondary)
                        .font(.system(size: uiSize(10)))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowHoverButtonStyle(cornerRadius: 0))
        // TSK-284 (a): filter results drag out like tree rows.
        .onDrag { FileDragProvider.make(for: match.url) }
        .accessibilityIdentifier("sidebar.filterRow.\(match.display)")
    }
}

private struct FileRowView: View, Equatable {
    let node: FileNode
    let depth: Int
    let state: FileRowState
    /// UNOBSERVED references — used only inside action closures and the
    /// lazily-built context menu, never read in the body (TSK-613; see
    /// `FileRowState`'s contract). `model.uiSize` is the one body-time
    /// call: it reads `zoom`, which is mirrored in `state.zoom` so a
    /// zoom change still re-bodies the row.
    let sidebar: SidebarModel
    let model: DocumentModel
    let trackedRepos: TrackedReposChannel

    /// SwiftUI skips the body when this returns true (`.equatable()` at
    /// the call site). The object references are deliberately excluded.
    nonisolated static func == (lhs: FileRowView, rhs: FileRowView) -> Bool {
        lhs.node == rhs.node && lhs.depth == rhs.depth && lhs.state == rhs.state
    }

    /// Cached file attributes (mtime + ctime) for this row's URL.
    /// Loaded once on `.onAppear` via the bounded LRU in
    /// `FileTreeRecencyCache`; the lookup is a syscall on cache miss
    /// only. Re-loaded when FolderWatcher invalidates the URL.
    @State private var recencyAttrs: FileTreeRecencyAttributes?

    /// Pointer-hover state for the row affordance (UIRESP-01/13). Drives
    /// a faint hover tint (below the selection/current/other-tab tints)
    /// and a pointing-hand cursor so file rows read as clickable.
    @State private var isHovering = false

    var body: some View {
        // PERF #6: renders exactly *this* row — children live as
        // sibling rows in the parent `LazyVStack`, fed by
        // `SidebarModel.flatVisibleRows()`. The previous shape
        // wrapped the child enumeration in a non-lazy `VStack`
        // inside each row's body, which forced SwiftUI to
        // materialize every descendant of an expanded root in one
        // pass (defeating the outer LazyVStack's virtualization).
        //
        // FolderWatcher publishes via `expanded`; observing it
        // here would re-fire on every collapse/expand too, which
        // is wasteful. We accept that the stripe is "as of first
        // render" — `FileTreeRecencyCache.invalidate(_:)` is the
        // public escape hatch for callers that touch a file from
        // within the app (Save, Git apply, etc.) and want the
        // stripe refreshed on the next body pass.
        Button(action: activate) {
            HStack(spacing: 0) {
                // MARK: - Recency stripe (file-tree-recency agent)
                //
                // 3 px vertical bar at the leading edge of the row.
                // The `padding(.leading, depth*14 + 8)` previously
                // hugged the chevron; we move the indent + the
                // existing HStack into an inner HStack and prepend
                // the stripe so it always touches the row's left
                // edge regardless of depth.
                recencyStripe
                HStack(spacing: model.uiSize(4)) {
                    if node.isDirectory {
                        // UIRESP: animate the disclosure chevron via a
                        // rotation on a single glyph (collapsed = 0°,
                        // expanded = 90°) instead of swapping two SF
                        // symbols — gives a smooth spin on expand/collapse.
                        Image(systemName: "chevron.right")
                            .font(.system(size: model.uiSize(9), weight: .semibold))
                            .frame(width: model.uiSize(12))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(state.isExpanded ? 90 : 0))
                            .animation(.easeInOut(duration: 0.15),
                                       value: state.isExpanded)
                    } else {
                        Spacer().frame(width: model.uiSize(12))
                    }
                    FileIconView(
                        url: node.url,
                        isDirectory: node.isDirectory,
                        isExpanded: state.isExpanded,
                        isGitRoot: state.repoRootKind == .repo,
                        isNestedRoot: state.repoRootKind == .nested,
                        size: .tree,
                        scale: CGFloat(model.zoom)
                    )
                    .frame(width: FileIconView.side(for: .tree, scale: CGFloat(model.zoom)),
                           height: FileIconView.side(for: .tree, scale: CGFloat(model.zoom)))
                    // Active-repo treatment: a filled dot when this repo
                    // root is LIVE in the tracked set (cheap stat said
                    // it's a repo; the tracked-set membership says it's
                    // actively being observed). Lets the user see WHICH
                    // repo roots are live vs merely on-disk.
                    .overlay(alignment: .bottomTrailing) {
                        if state.isTrackedRoot {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: model.uiSize(4), height: model.uiSize(4))
                                .offset(x: 1, y: 1)
                                .accessibilityHidden(true)
                        }
                    }
                    Text(node.name)
                        // Bold the file's name if it's the currently-
                        // visible tab — matches the bold treatment in
                        // the tab bar so the "current document" is
                        // obvious in both surfaces. Preview-slot files
                        // render italic to match their italic tab title;
                        // the CURRENT row gets white-on-accent (owner
                        // 2026-08-09 — the active file must pop).
                        .font(.system(size: model.uiSize(12), weight: state.isCurrent ? .semibold : .regular))
                        .italic(state.isPreviewTab)
                        .foregroundStyle(state.isCurrent ? Color.white : Color.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if state.isBookmarked {
                        Image(systemName: "star.fill")
                            .font(.system(size: model.uiSize(8)))
                            .foregroundStyle(.yellow)
                            .helpInfo(title: "Bookmarked", description: "This file is bookmarked")
                            .accessibilityLabel("Bookmarked")
                    }
                    // TSK-1152: a lock badge when this file's view mode is
                    // pinned (set via the row's "Lock View As" menu). Mirrors
                    // the bookmark star; in FileRowState so it re-renders on
                    // lock-change (the body must not read `model` directly).
                    if state.isViewModeLocked {
                        Image(systemName: "lock.fill")
                            .font(.system(size: model.uiSize(8)))
                            .foregroundStyle(.secondary)
                            .helpInfo(title: "View locked",
                                      description: "This file opens in a pinned view mode")
                            .accessibilityLabel("View-mode locked")
                    }
                    Spacer(minLength: 0)
                    if let status = state.gitStatus {
                        GitStatusBadge(status: status, uiSize: model.uiSize)
                    }
                }  // inner HStack(spacing: 4)
                .padding(.leading, CGFloat(depth) * model.uiSize(14) + model.uiSize(8))
                .padding(.vertical, model.uiSize(3))
                .padding(.trailing, model.uiSize(8))
            }  // outer HStack(spacing: 0) — stripe + content
            .contentShape(Rectangle())
            .background(rowBackground)
        }
        .buttonStyle(.plain)
        // TSK-284 (a): every tree row is a drag-OUT source — drop on
        // Finder copies the file/folder, on Mail attaches, elsewhere opens.
        .onDrag { FileDragProvider.make(for: node.url) }
        .id(node.url)  // for ScrollViewReader.scrollTo
        .help(node.url.path)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .contextMenu {
            FileRowContextMenu(
                node: node, sidebar: sidebar, model: model,
                trackedRepos: trackedRepos
            )
        }
        .onAppear {
            if recencyAttrs == nil {
                recencyAttrs = FileTreeRecencyCache.attributes(for: node.url)
            }
        }
        // RWC-3: re-load the stripe attributes when the model signals a
        // recency change (FolderWatcher fire / in-app save). The cache
        // entry for this URL was already invalidated by the bump source,
        // so this re-read sees fresh mtime/ctime. Cheap: cache-hit unless
        // *this* URL was the one that changed.
        .onChange(of: state.recencyVersion) { _, _ in
            recencyAttrs = FileTreeRecencyCache.attributes(for: node.url)
        }
        // UIRESP-01/13: pointer affordance for file rows. Hover updates
        // the tint (via `rowBackground`) and shows the pointing-hand
        // cursor so rows read as clickable.
        // TSK-892: balanced cursor push/pop — the prior open-coded
        // push/pop double-pushed on AppKit's repeat onHover(true) and
        // over-popped on a stray onHover(false), storming the global
        // cursor stack during a sustained drag across rows (the felt
        // "file-tree hover is slow" jank). See HoverCursorBalance.
        .hoverCursor(isHovering: $isHovering)
    }

    // MARK: - Recency stripe rendering
    //
    // 3 px-wide vertical bar at the leading edge. Width fixed regardless
    // of depth so it always touches the sidebar's edge (the row's
    // indentation lives inside the inner HStack via `.padding(.leading)`).
    //
    // Folder policy: folders render a stripe based on the folder's own
    // mtime — not muted-out — so the user can scan "this directory
    // changed recently" at a glance (matches Finder's Date Modified
    // column for directories). Trade-off accepted: directory mtime
    // updates whenever any direct child is added/removed, so folder
    // stripes are noisier than file stripes. If that proves visually
    // distracting we can flip this to a muted-grey constant for folders
    // here without touching FileTreeRecency.
    @ViewBuilder
    private var recencyStripe: some View {
        let tier = currentRecencyTier
        Rectangle()
            .fill(Color(nsColor: FileTreeRecency.color(for: tier)))
            .frame(width: model.uiSize(3))
            // Fill the row's vertical extent — the parent HStack stretches
            // this to match the tallest sibling.
            .frame(maxHeight: .infinity)
            .accessibilityHidden(true)
            .accessibilityIdentifier("mdv.sidebar.fileRow.recencyStripe.\(tier.rawValue)")
    }

    /// The tier to paint for this row, given the active mode and the
    /// cached file attributes. Falls through to `.older` (barely-visible
    /// stripe) until `.onAppear` populates the cache; that one-frame
    /// flash is invisible at scroll speeds and avoids a synchronous
    /// stat during the SwiftUI body re-eval.
    private var currentRecencyTier: FileTreeRecency.RecencyTier {
        guard let date = recencyAttrs?.date(for: state.recencyMode) else {
            return .older
        }
        return FileTreeRecency.tier(for: date)
    }

    private func activate() {
        sidebar.setSelected(node.url)
        if node.isDirectory {
            sidebar.toggleExpansion(node.url)
        } else {
            // Single-click opens into the ONE ephemeral preview slot (TSK-306):
            // a second click on the same row (double-click) finds it already
            // open and promotes it to a permanent tab, as does Enter / editing.
            // See `docs/PREVIEW_TAB_DESIGN.md`.
            model.openPreview(url: node.url)
        }
    }

    /// Selected (keyboard), current (active tab), and other-open
    /// (has a non-active tab) get distinct shading so users can tell
    /// at a glance: which row is about to be activated by ↵, which
    /// file is in front, and which other files are already open.
    private var rowBackground: Color {
        // FULL accent for the file you're LOOKING AT (owner 2026-08-09) —
        // the 0.22 tint was too easy to miss; white label text pairs with it.
        if state.isCurrent  { return Color.accentColor }
        if state.isSelected { return Color(nsColor: .alternateSelectedControlColor).opacity(0.25) }
        if state.isOpenInOtherTab {
            return Color.accentColor.opacity(0.08)
        }
        // UIRESP-01/13: faint hover tint, strictly below the
        // selection / current / other-tab tints so it never masks a
        // stronger state. Uses the system control-accent at low alpha
        // for theme consistency.
        if isHovering {
            return Color(nsColor: .selectedContentBackgroundColor).opacity(0.12)
        }
        return Color.clear
    }


    private var accessibilityLabel: String {
        var parts: [String] = []
        if node.isDirectory {
            parts.append(state.isExpanded ? "Folder expanded" : "Folder collapsed")
        } else {
            parts.append("File")
        }
        parts.append(node.name)
        if let s = state.gitStatus {
            parts.append("git: \(s.rawValue)")
        }
        if state.isCurrent { parts.append("currently open") }
        return parts.joined(separator: ", ")
    }

}

/// Sidebar wrapper for the LSP outline section. Owns the
/// `LSPOutlineModel` so it persists across body re-evals + reacts to
/// the active tab changing. Self-gates: returns empty content when
/// the current file's language has no LSP server.
@MainActor
struct LSPOutlineWrapper: View {
    @ObservedObject var model: DocumentModel
    /// True when the rail button forced the OUTLINE panel on
    /// (`PanelOverride.shown`) even though the current file has no language
    /// server. Renders a placeholder instead of nothing so the toggle
    /// visibly works (bug4).
    var forcedShown: Bool = false
    @StateObject private var outline: LSPOutlineModel

    init(model: DocumentModel, forcedShown: Bool = false) {
        self.model = model
        self.forcedShown = forcedShown
        _outline = StateObject(
            wrappedValue: LSPOutlineModel(pool: model.lspPool)
        )
    }

    var body: some View {
        Group {
            if outline.isSupported {
                LSPOutlineSection(
                    model: outline,
                    onJump: { symbol in
                        // Jump callback: scroll the source view to the
                        // symbol's start line + select that tab if it
                        // isn't already the active one.
                        if let url = currentFileURL,
                           !model.selectTab(forURL: url) {
                            model.openPath(url)
                        }
                        let line = symbol.selectionRange.start.line + 1
                        model.scrollSource(toLine: line)
                    },
                    uiSize: model.uiSize
                )
            } else if forcedShown {
                SidebarEmptyPlaceholder(message: "No language server for this file.")
                    .sidebarSectionContainer()
            }
        }
        .onAppear { refresh() }
        .onChange(of: model.currentURL) { _, _ in refresh() }
        // F-LSP-1: also re-resolve `isSupported`/symbols when the document
        // STATE transitions (e.g. `.loading → .loaded`), not just when the
        // URL changes. A `.swift` file opens with `currentURL` set
        // immediately but `currentState == .loading` while the async read is
        // in flight; the `.onAppear`/`currentURL` `refresh()` then runs
        // against `.loading`, `setFile(nil,…)` clears `isSupported`, and the
        // OUTLINE section renders nothing. The load completing flips
        // `currentState` to `.loaded` (and republishes — see commit
        // `61c1aef`) but leaves `currentURL` unchanged, so without this the
        // section stayed permanently absent for a supported language.
        .onChange(of: model.currentState) { _, _ in refresh() }
    }

    private var currentFileURL: URL? { model.currentURL }

    private func refresh() {
        guard let url = model.currentURL,
              case .loaded(let file) = model.currentState else {
            outline.setFile(nil, text: nil)
            return
        }
        outline.setFile(url, text: file.contents)
    }
}

/// Sidebar wrapper for the Markdown outline section (TSK-1438). Owns the
/// `MarkdownOutlineModel` so it survives body re-evals + reacts to the active
/// tab changing. Rebuilds the heading list from the active document's source;
/// self-gates to markdown files (renders "No headings." otherwise, which
/// `panelVisibility` already keeps hidden for non-markdown via presence).
/// Mirrors `LSPOutlineWrapper`.
@MainActor
struct MarkdownOutlineWrapper: View {
    @ObservedObject var model: DocumentModel
    @StateObject private var outline = MarkdownOutlineModel()

    var body: some View {
        MarkdownOutlineSection(
            model: outline,
            onJump: { line in
                // Make the outline's document the active tab, then scroll its
                // source view to the heading's 1-based line (mirrors the LSP
                // outline jump; preview-mode scroll-on-jump is a follow-on).
                if let url = model.currentURL, !model.selectTab(forURL: url) {
                    model.openPath(url)
                }
                model.scrollSource(toLine: line)
            },
            uiSize: model.uiSize
        )
        .onAppear {
            refresh()
            // TSK-1570 (U2): seed the current-section highlight from the source
            // view's current viewport top so the highlight is right on first paint,
            // not only after the next scroll.
            if let top = model.sourceView.sourceScrollState.topVisibleLine {
                outline.viewportChanged(topLine: top)
            }
        }
        .onChange(of: model.currentURL) { _, _ in refresh() }
        // Rebuild when the async read completes (.loading → .loaded): the URL
        // is set before the contents arrive (same race LSPOutlineWrapper fixed).
        .onChange(of: model.currentState) { _, _ in refresh() }
        // TSK-1570 (U2): SCROLL-HIGHLIGHT — feed the source view's visible top
        // line into the outline so the current-section highlight follows scroll.
        // `viewportChanged` is host-tested (binary-search of the current heading);
        // this is the missing view-layer wire.
        .onChange(of: model.sourceView.sourceScrollState.topVisibleLine) { _, top in
            if let top { outline.viewportChanged(topLine: top) }
        }
    }

    private func refresh() {
        guard let url = model.currentURL,
              EditorCoordinator.isMarkdownProse(url: url),
              case .loaded(let file) = model.currentState else {
            outline.rebuild(fromSource: "")
            return
        }
        outline.rebuild(fromSource: file.contents)
    }
}

/// Singleton holder for the most-recent workspace-symbol query's
/// cancellation token. SidebarView is a value type so it can't own
/// mutable state across body re-evals; this @MainActor singleton sits
/// alongside it and lets each call to `runWorkspaceSymbolQuery` cancel
/// its predecessor.
@MainActor
final class WorkspaceSymbolDispatch {
    static let shared = WorkspaceSymbolDispatch()
    var current: LSPCancellationToken?
    func cancel() { current?.cancel(); current = nil }
    private init() {}
}

// MARK: - Bounded accordion scroll region (P1 — tool-window bounding)
//
// The shoulder-rail tool panels (Bookmarks, Search, Git, Claude, LSP
// Outline/References/Problems, Recents, plugin sections) used to render
// as a bare run of RIGID 220pt panels directly inside the sidebar
// VStack — no ceiling, no scroll. Once a rich folder (git repo + LSP
// language + Claude transcripts + recents) resolved ~7-8 panels visible,
// their summed ~1700pt demand over-subscribed the sidebar band; SwiftUI
// resolved the impossible fit by overflowing, which shoved the window
// chrome (TabBar / ModeBar / StatusBar) off-screen — the owner's bug.
//
// This view bounds that run to a window-derived ceiling and lets it
// SCROLL past the ceiling instead of overflowing:
//
//   * `available` is the sidebar's measured content height. The accordion
//     may claim up to `accordionFraction` of it; FILES (the flex-fill,
//     rendered OUTSIDE this view) keeps the remainder. Past the ceiling
//     the content scrolls — N panels at their floor can never push the
//     chrome out, regardless of panel count.
//   * It HUGS its content when the content is shorter than the ceiling
//     (measured via a non-layout-driving background reader), so with one
//     or two small panels the sidebar looks exactly as it did before —
//     no always-reserved half-height accordion. Appearance is preserved
//     in the common (fits) case; containment only engages when panels
//     would otherwise overflow.
//   * Before the sidebar height is measured (`available <= 0`, the first
//     body pass) it falls back to hugging content with no ceiling — the
//     measurement settles one pass later and the ceiling engages.
private struct BoundedAccordionScroll<Content: View>: View {
    let availableHeight: CGFloat
    /// Number of visible accordion panels (TSK-1590). A single tool window
    /// gets a taller band so it can fill the sidebar instead of being pinned
    /// under the multi-panel share.
    var panelCount: Int = 0
    @ViewBuilder var content: Content

    /// Fraction of the sidebar's content height the accordion run may
    /// occupy before it scrolls. The remainder is FILES' floor. With MANY
    /// panels 0.62 leaves FILES ~38%; with a SINGLE tool window (no siblings
    /// to balance) the band grows to 0.85 so a lone Git/Outline panel fills
    /// the sidebar rather than stranding the lower half empty — FILES keeps a
    /// ~15% floor (owner report 2026-07-21).
    private var accordionFraction: CGFloat { panelCount <= 1 ? 0.85 : 0.62 }

    /// Minimum height delta (points) that commits a `contentHeight` write.
    /// Suppresses sub-point measure jitter from re-bodying the view every
    /// frame (the measure→frame→measure feedback loop). 0.5pt is well below
    /// any real panel-size change and above float-rounding noise.
    private static var measureEpsilon: CGFloat { 0.5 }

    /// Measured natural height of the accordion content, so the scroll
    /// region can hug it when it fits under the ceiling.
    @State private var contentHeight: CGFloat = 0
    /// TSK-440: whether a real measurement has landed — distinguishes
    /// "not measured yet" from "measured empty" in the resolver.
    @State private var hasMeasured = false

    private var ceiling: CGFloat? {
        guard availableHeight.isFinite, availableHeight > 0 else { return nil }
        return availableHeight * accordionFraction
    }

    var body: some View {
        let cap = ceiling
        // Hug content up to the ceiling; scroll past it. When unmeasured
        // (cap == nil) or content fits, the frame is just the content
        // height (no behavioral change). When content exceeds the cap,
        // the frame is the cap and the inner ScrollView scrolls.
        // TSK-440 bug (A): resolution now lives in the pure
        // `AccordionHeightResolver` (ViewerCore) — the load-bearing fix is
        // distinguishing "not measured yet" (→ cap, the first-pass
        // behavior) from "measured EMPTY" (→ 0). The old `contentHeight >
        // 0` guard conflated them, so a lone FILES panel sat above an
        // empty scroll region frozen at ~62% of the sidebar.
        let resolved = AccordionHeightResolver.resolve(
            contentHeight: contentHeight,
            hasMeasured: hasMeasured,
            cap: cap
        )

        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 0) {
                content
            }
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear {
                            contentHeight = geo.size.height
                            hasMeasured = true
                        }
                        .onChange(of: geo.size.height) { _, h in
                            // EPSILON-GUARD (PERF — accordion measure feedback):
                            // the measured natural height feeds `resolved` →
                            // `.frame(height:)`, which re-bodies this view, which
                            // re-measures. Sub-point layout jitter (≈10⁻²pt) would
                            // otherwise re-body every frame in the live run loop
                            // (multiplying passes-per-frame). Only commit a write
                            // when it moves the height by a visible amount; the
                            // clamp resolution is unaffected (real changes are pt-
                            // scale, far above the threshold). ToolPanelBounding
                            // still settles within its 3 passes.
                            if abs(h - contentHeight) > Self.measureEpsilon {
                                contentHeight = h
                            }
                        }
                }
            )
        }
        // `frame(height:)` makes the ScrollView hug exactly `resolved`
        // rather than greedily expand to fill the sidebar. `maxHeight`
        // alone would let it grow; an explicit height pins it to the
        // measured content (capped). When `resolved` is nil (very first
        // pass) the ScrollView falls back to its default flexible sizing.
        .frame(height: resolved)
        // Identity for the headless bounding test (`ToolPanelBoundingTests`):
        // the test walks the realized tree for THIS scroll viewport and
        // asserts it stays within the sidebar band. Pre-fix this container
        // did not exist (the panels rendered as a bare VStack run), so the
        // test's "found AND in-bounds" assertion fails before the fix.
        .accessibilityIdentifier("mdv.sidebar.accordionScroll")
    }
}
