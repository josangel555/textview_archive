import SwiftUI
import UniformTypeIdentifiers
import ViewerKit
import ViewerCore

public struct ContentView: View {
    @ObservedObject var model: DocumentModel
    /// Direct observation of the sidebar — see PERF #1 note in
    /// `DocumentModel.init`. ContentView's body branches on
    /// `sidebar.isVisible`; without this, the only way the body
    /// would re-eval on a visibility toggle was through the (now-
    /// removed) `objectWillChange` forwarding.
    @ObservedObject var sidebar: SidebarModel
    /// Find state lives on its own coordinator (Quality #E, 2026-05-25).
    /// ContentView observes it directly so that the rendered/source/
    /// editor sub-branches re-eval when find query / case / next-nonce
    /// changes — without re-publishing every DocumentModel observer.
    @ObservedObject var find: FindCoordinator
    /// Shoulder-rail layout (per-panel edge + visibility override).
    /// Observed DIRECTLY (same narrow pattern as `sidebar` / `find`) so
    /// the `leftContainerVisible` predicate — which reads BOTH
    /// `sidebar.isVisible` and the resolved per-panel visibility off
    /// `panelLayout` — re-evaluates on a rail toggle. Without this
    /// second observation the predicate would go stale (the latent
    /// derived-state trap; pinned by `PanelLayoutResolutionTests`).
    @ObservedObject var panelLayout: PanelLayoutStore
    /// Bottom terminal pane (#226). Observed DIRECTLY (narrow pattern,
    /// same as `panelLayout`) so the center column re-evaluates when the
    /// pane opens/closes or is drag-resized — without republishing the
    /// whole content tree. The live per-frame terminal output rides a
    /// SEPARATE `ObservableObject` (`terminalPane.terminal`) observed only
    /// inside the terminal view.
    @ObservedObject var terminalPane: TerminalPaneStore
    /// Tab + split state lives on `tabCoordinator` (see PERF #1 note in
    /// `DocumentModel.init`: its `objectWillChange` is deliberately NOT
    /// forwarded into `DocumentModel.objectWillChange`, to avoid a
    /// republish storm). ContentView's body GATES the split pane on
    /// `splitURL` (the `if let splitURL = model.splitURL` branch below) —
    /// so it MUST observe the coordinator directly, or that branch never
    /// re-evaluates when `splitURL` changes. Without this, `openInSplit` /
    /// `closeSplit` mutate `tabCoordinator.splitURL` (firing only
    /// `tabCoordinator.objectWillChange`) yet ContentView never re-bodies,
    /// so the split pane doesn't appear/disappear until an UNRELATED
    /// mutation that DOES fire `DocumentModel.objectWillChange` (e.g. a tab
    /// switch) forces a recompute — the "works only when I switch tabs"
    /// race (TSK-921/922). Same narrow-observation pattern as `sidebar` /
    /// `find` / `panelLayout` / `terminalPane`. Pinned by
    /// `SplitObservationTests`.
    @ObservedObject var tabCoordinator: TabCoordinator
    @StateObject var walkthrough: WalkthroughPlayerController
    /// App-level sessions coordinator. Optional so SwiftUI previews
    /// and host-side unit tests that construct a bare `ContentView`
    /// don't need to spin up the full SessionStore stack — the
    /// session tab row is simply hidden when nil.
    var sessionsApp: SessionsAppCoordinator?
    /// Whether the multi-session UI (the `SessionTabBar` strip) is shown
    /// (TSK-264). Sourced from `PreferencesStore.sessionsEnabled` at launch.
    /// Defaults to `true` so existing callers / previews are unaffected; the
    /// strip is shown only when BOTH this is `true` AND `sessionsApp != nil`.
    let sessionsUIEnabled: Bool
    @State private var isDropTargeted = false
    private let renderer = HTMLRenderer()
    private let stylesheet: String

    public init(model: DocumentModel,
                sessionsApp: SessionsAppCoordinator? = nil,
                sessionsUIEnabled: Bool = true) {
        self.model = model
        self.sidebar = model.sidebar
        self.find = model.find
        self.panelLayout = model.panelLayout
        self.terminalPane = model.terminalPane
        self.tabCoordinator = model.tabCoordinator
        self.sessionsApp = sessionsApp
        self.sessionsUIEnabled = sessionsUIEnabled
        self.stylesheet = MarkdownStylesheet.load()
        // Persist the controller across body re-evals. The controller
        // owns the engine, delegate, and auto-advance scheduler — all
        // of which hold weak refs that would dangle if the controller
        // were rebuilt per body call.
        //
        // F-WCR-STRIP: seed from the MODEL-OWNED singleton rather than
        // constructing a fresh controller here. The app delegate drives
        // playback by reading `model.walkthroughController` directly, so
        // this guarantees `body` observes the EXACT instance the
        // delegate's `start(_:)` flips `isActive` on — otherwise the
        // strip's `if walkthrough.isActive` gate never re-bodies (the
        // delegate had captured a phantom controller off a not-yet-
        // installed view struct). See the accessor doc on DocumentModel.
        _walkthrough = StateObject(
            wrappedValue: model.walkthroughController
        )
    }

    /// Public accessor for `main.swift` to drive the player from CLI
    /// args / future external transports. Returns the model-owned
    /// singleton (identical to `_walkthrough`'s observed instance), so
    /// reading it off a not-yet-installed `ContentView` is safe.
    public var walkthroughController: WalkthroughPlayerController {
        model.walkthroughController
    }

    public var body: some View {
        #if DEBUG
        let _ = BodyProbe.tick("ContentView")   // TSK-615 re-eval width probe
        #endif
        ZStack {
            VStack(spacing: 0) {
                // TSK-264: the session tab strip shows only when the
                // multi-session experience is enabled. With sessions off
                // (`SingleRootContext`) the strip is hidden — we do NOT
                // rip sessions out, just gate the chrome.
                if sessionsUIEnabled, let sessionsApp {
                    SessionTabBar(sessionsApp: sessionsApp)
                    Divider()
                }
                TabBar(model: model)
                    .accessibilityIdentifier("mdv.tabbar")
                    // CHROME PIN (2026-06-01): the chrome bars carry their own
                    // fixed heights (TabBar 30, content-toolbar 22, StatusBar
                    // 22), but a VStack distributes an under-shrink squeeze
                    // across ALL children — so when the window goes below
                    // chrome+min-content, the bars got compressed/clipped
                    // instead of the center band. layoutPriority(1) makes
                    // SwiftUI satisfy the bars' heights FIRST; the center HStack
                    // (priority 0, maxHeight:.infinity) then absorbs 100% of any
                    // shrink. fixedSize(vertical:) pins each bar's reported
                    // height as a hard floor so it can't be compressed below
                    // content (and still grows with dynamic-type / zoom).
                    //
                    // UX-A (#224): the old ModeBar (wrap / special-char /
                    // Source·Raw·Hex picker) that lived here was removed. The
                    // view-mode control + breadcrumb moved into `ContentToolbar`
                    // (directly above the content pane, inside `bodyRow`), and
                    // the text-attribute controls moved into
                    // `BottomAttributesBar` (above the StatusBar).
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                Divider()
                // MARK: - Shoulder rails + body band
                //
                // The rails frame the MIDDLE band only (between ModeBar
                // and StatusBar). They are pure-SwiftUI sibling strips
                // wrapping the UNTOUCHED center column — they never
                // change how `TextDisplayView` / the WKWebView are
                // hosted. COMPOSITOR RULE (LESSONS.md, load-bearing):
                // every wrapper around `content` keeps
                // `.frame(maxWidth:.infinity, maxHeight:.infinity)` so
                // the NSScrollView/WKWebView intrinsic size can't
                // collapse the pane; rails are FIXED thickness via
                // `.frame(width:)` / `.frame(height:)` so they never
                // claim the flex axis. StatusBar stays the last sibling
                // of the OUTER VStack (the "siblings-after-source-render-
                // fine" property).
                HStack(spacing: 0) {
                    // LEFT rail: gated on the master switch (left
                    // shoulder = one unit; menu "off" hides rail +
                    // accordion together).
                    if sidebar.isVisible {
                        ShoulderRailView(
                            edge: .left,
                            panelLayout: panelLayout,
                            sidebar: sidebar,
                            model: model,
                            terminalPane: terminalPane
                        )
                        // SNAP ZONE (UX-E): dropping a dragged tool window on
                        // the left rail redocks it back to the accordion.
                        .panelDropZone(.left, panelLayout: panelLayout)
                        Divider()
                    }
                    // LEFT-docked terminal column (TSK-491): a fixed-WIDTH
                    // sibling of the whole center column, beside the left rail —
                    // mirrors RightDockContainer's placement so the content
                    // WebView is NOT nested deeper (nesting it collapsed the
                    // render — caught via real-pixel capture).
                    if terminalPane.isOpen && terminalPane.paneEdge == .left {
                        sideTerminalColumn
                    }
                    // Center column: body row over the optional terminal
                    // pane over the bottom dock + bottom rail.
                    VStack(spacing: 0) {
                        // The content/body MUST win the vertical flex: pin it
                        // greedy + high layout priority so a runtime terminal
                        // TOGGLE (vs. open-at-launch) can't let the terminal's
                        // own `maxHeight:.infinity` interior steal the column
                        // and paint over the document (the reported "terminal
                        // takes the whole page" bug — only repro'd on toggle,
                        // not launch). The terminal stays a PINNED height.
                        bodyRow
                            .frame(maxHeight: .infinity, alignment: .top)
                            .layoutPriority(1)
                        // BOTTOM terminal pane (#226), only when docked `.bottom`
                        // (TSK-491). Fixed-height shell pane below the content.
                        // `.clipped()` is load-bearing: the terminal surface is
                        // an opaque, layer-backed NSView; if SwiftUI ever
                        // proposes it more than `height` mid-relayout it must NOT
                        // paint past its band onto the document / its own header
                        // (the "no header / covers the file" half of the bug).
                        if terminalPane.isOpen && terminalPane.paneEdge == .bottom {
                            TerminalResizeHandle(store: terminalPane)
                            TerminalPaneView(
                                store: terminalPane,
                                fontSize: model.uiSize(12)
                            )
                            .frame(height: terminalPane.height)
                            .clipped()
                            .layoutPriority(0)
                        }
                        // BOTTOM dock (UX-E / #227): free-standing,
                        // fixed-height tool windows for panels the user has
                        // dragged onto the bottom rail. Renders nothing (no
                        // border) when no panel is bottom-docked, so the
                        // default layout is unchanged. Its own resize handle
                        // pins the band height; the body row above keeps
                        // maxHeight:.infinity so IT absorbs the squeeze.
                        BottomDockContainer(
                            model: model, sidebar: sidebar,
                            trackedRepos: model.trackedRepos,
                            panelLayout: panelLayout
                        )
                        Divider()
                        // BOTTOM rail: independent of the master switch.
                        // Thin icon strip; the bottom-docked panel BODIES
                        // render in the BottomDockContainer above.
                        ShoulderRailView(
                            edge: .bottom,
                            panelLayout: panelLayout,
                            sidebar: sidebar,
                            model: model,
                            terminalPane: terminalPane
                        )
                        // SNAP ZONE (UX-E): drop a dragged tool window here
                        // to redock it to the bottom.
                        .panelDropZone(.bottom, panelLayout: panelLayout)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // COMPOSITOR (TSK-960): the center column hosts the opaque
                    // WKWebView content surface. Pin it to the BASE layer so the
                    // side-docked terminal column (its own `.zIndex(1)`) sits
                    // ABOVE it and neither opaque representable occludes the
                    // other (the right-dock "terminal no longer composites"
                    // regression of TSK-491). Applies in every layout branch
                    // since the center column is unconditional. Z-order from the
                    // named `SideDockCompositing` contract (host-testable).
                    .zIndex(SideDockCompositing.contentColumnZIndex)
                    // RIGHT-docked terminal column (TSK-491): a fixed-WIDTH
                    // sibling between the center column and the right dock —
                    // same level as RightDockContainer (NOT nested in the center
                    // column), so the content WebView keeps its full size.
                    if terminalPane.isOpen && terminalPane.paneEdge == .right {
                        sideTerminalColumn
                    }
                    // RIGHT dock (UX-E / #227): free-standing, fixed-WIDTH
                    // tool windows for panels dragged onto the right rail.
                    // Sits between the center column and the right shoulder
                    // rail. Renders nothing when no panel is right-docked, so
                    // the default layout is byte-for-byte unchanged.
                    RightDockContainer(
                        model: model, sidebar: sidebar,
                        trackedRepos: model.trackedRepos,
                        panelLayout: panelLayout
                    )
                    Divider()
                    // RIGHT rail: independent of the master switch. Thin
                    // icon strip; the right-docked panel BODIES render in
                    // the RightDockContainer to its left.
                    ShoulderRailView(
                        edge: .right,
                        panelLayout: panelLayout,
                        sidebar: sidebar,
                        model: model,
                        terminalPane: terminalPane
                    )
                    // SNAP ZONE (UX-E): drop a dragged tool window here to
                    // redock it to the right.
                    .panelDropZone(.right, panelLayout: panelLayout)
                }
                // The center band is the one that yields under shrink:
                // explicit layoutPriority(0) (the default, stated for intent)
                // + maxHeight:.infinity means it absorbs all the squeeze while
                // the priority-1 bars keep their heights.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(0)
                if model.currentURL != nil {
                    // UX-A (#224): bottom toggle-button group (Wrap / Special
                    // chars / Enable-JS / unified type control). These are
                    // FILE attributes, so this bar stays file-gated.
                    BottomAttributesBar(model: model)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                }
                // TSK-738: the status footer shows for a file OR a folder-only
                // project (path "—" + folder-scoped git chip), so it no longer
                // vanishes after relaunch / opening a folder with no file picked.
                if model.hasOpenContext {
                    StatusBar(model: model, tabCoordinator: model.tabCoordinator, sourceView: model.sourceView)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                }
            }
            .frame(minWidth: 600, minHeight: 360)
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers)
            }
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.accentColor, lineWidth: 3)
                        .padding(2)
                        .allowsHitTesting(false)
                }
            }

            if model.isPalettePresented {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .onTapGesture { model.dismissPalette() }
                CommandPaletteView(model: model)
                    .padding(.top, 80)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }

            if model.isCrossSearchPresented {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .onTapGesture { model.dismissCrossSearch() }
                CrossSearchPanel(model: model, sidebar: sidebar)
                    .padding(.top, 80)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }

            // MARK: - GoToPath overlay
            // Lives under its own MARK so a parallel branch touching
            // ContentView (e.g. nested-tabs) doesn't clobber it on
            // merge. The overlay mirrors the palette / cross-search
            // pattern: scrim + centered floating panel.
            if model.isGoToPathPresented {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .onTapGesture { model.dismissGoToPath() }
                GoToPathPrompt(model: model, sessionsApp: sessionsApp)
                    .padding(.top, 80)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }

            // MARK: - LSP Rename prompt overlay (TSK-640)
            if model.isLSPRenamePromptPresented {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .onTapGesture { model.dismissLSPRenamePrompt() }
                LSPRenamePrompt(model: model)
                    .padding(.top, 80)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }

            // MARK: - LSP Code Actions picker overlay (TSK-640)
            if model.codeActionPicker != .hidden {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .onTapGesture { model.dismissCodeActionPicker() }
                CodeActionPicker(model: model)
                    .padding(.top, 80)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }

            // UX-H (#230): the custom floating tooltip overlay. Mounted
            // LAST so it sits at the top of the Z-order (above every
            // chrome bar + panel). It observes only the small, dedicated
            // `TooltipPresenter` (NOT DocumentModel), so a hover re-bodies
            // just this overlay. `allowsHitTesting(false)` inside the
            // overlay keeps it from stealing events from the panes beneath
            // (compositor-safe). Scales with `model.uiSize`/`zoom`.
            FloatingTooltipOverlay(
                presenter: .shared,
                uiScale: CGFloat(model.zoom)
            )
        }
        // Window-root coordinate space the `.helpInfo` modifier reports
        // its anchor frame in and the overlay positions the bubble
        // against. Both sides reference `.tooltipRoot` (same `name:`
        // overload the WalkthroughOverlay uses), so they agree.
        .coordinateSpace(name: TooltipCoordinateSpace.name)
        // First-paint GoTo: when a brand-new session is requested
        // (SessionTabBar `+`, or openFolder(forceNew:)), the
        // SessionsAppCoordinator bumps `firstPaintGoToToken`. We
        // observe the bump, consume the gate, and present the prompt.
        .background(firstPaintGoToBridge)
        // IntelliJ-style double-Shift opens the command palette (TSK-707).
        // App-wide local NSEvent monitor; observation-only (Shift still types).
        .background(
            DoubleShiftMonitor(isActive: true) { [model] in model.showPalette() }
                .frame(width: 0, height: 0)
        )
        // Esc returns keyboard focus to the active document tab (TSK-938) when
        // it's parked in a tool surface; a no-op (passes Esc through) when focus
        // is already on the document.
        .background(
            EscFocusMonitor(isActive: true) { [model] onDoc in
                model.returnFocusToActiveDocument(currentFocusIsDocument: onDoc)
            }
            .frame(width: 0, height: 0)
        )
    }

    // MARK: - Body row (sidebar accordion + content + split)
    //
    // Extracted VERBATIM from the prior middle `HStack` so the rails
    // restructure stays minimal + reviewable. The ONLY change vs the
    // pre-rails tree: the `if sidebar.isVisible` accordion gate is now
    // `leftContainerVisible` (sidebar not master-hidden AND ≥1 left
    // panel resolves visible), and the row carries an explicit
    // `.frame(maxWidth:.infinity, maxHeight:.infinity)` so the new
    // wrapping VStack/HStack can't let the NSScrollView/WKWebView
    // intrinsic size collapse the content pane. The `content` /
    // `loadedView` subtree is byte-for-byte unchanged.
    @ViewBuilder
    /// The terminal as a fixed-WIDTH side column (TSK-491), with its resize
    /// handle on the content-facing edge. Used only when `paneEdge` is
    /// `.left`/`.right`. `.clipped()` matches the bottom-band discipline so the
    /// opaque terminal surface can't paint past its column. The pane keeps its
    /// own internal tab strip (TSK-488) via `TerminalPaneView`.
    ///
    /// COMPOSITOR (TSK-960, regression of TSK-491; rule in CLAUDE.md/LESSONS
    /// TSK-488): this column hosts an opaque, layer-backed `NSViewRepresentable`
    /// terminal surface, and it sits as a plain `HStack` sibling of the center
    /// content column — which itself hosts an opaque WKWebView surface. Two
    /// opaque representable siblings in one container composite by PAINT ORDER:
    /// without explicit z-ordering the later-painted surface occludes the
    /// earlier one, so depending on the dock edge either the terminal column
    /// fails to composite (right dock) or it overdraws the content. Force the
    /// terminal column into its OWN compositing layer ordered ABOVE the content
    /// surface — `.compositingGroup().zIndex(1)` here vs `.zIndex(0)` on the
    /// center column — applied in BOTH the left- and right-dock layout
    /// branches (this single helper is used for both at ContentView call
    /// sites). Mirrors the in-pane fix at `TerminalView.swift` (strip vs
    /// surface).
    private var sideTerminalColumn: some View {
        let column = TerminalPaneView(store: terminalPane, fontSize: model.uiSize(12))
            .frame(width: terminalPane.sideWidth)
            .clipped()
            .layoutPriority(0)
        return HStack(spacing: 0) {
            // Right dock → handle on the LEFT (content-facing) edge.
            if terminalPane.paneEdge == .right { TerminalSideResizeHandle(store: terminalPane) }
            column
            // Left dock → handle on the RIGHT (content-facing) edge.
            if terminalPane.paneEdge == .left { TerminalSideResizeHandle(store: terminalPane) }
        }
        // Own compositing layer ordered ABOVE the center content surface so the
        // opaque terminal NSView neither occludes nor is occluded by the
        // opaque WKWebView sibling, regardless of paint order (TSK-960). The
        // z-order is driven from the named `SideDockCompositing` contract so the
        // ordering is a host-testable invariant, not a scattered literal.
        .compositingGroup()
        .zIndex(SideDockCompositing.terminalColumnZIndex)
    }

    private var bodyRow: some View {
        HStack(spacing: 0) {
            if leftContainerVisible {
                DraggableSidebar(model: model)
                    .accessibilityIdentifier("mdv.sidebar")
                Divider()
            }
            VStack(spacing: 0) {
                // UX-A (#224): content-toolbar sits DIRECTLY ABOVE the content
                // pane (inside the center column, NOT spanning the sidebar /
                // shoulder rails). Breadcrumb on the left, view-mode control on
                // the right. Shown only when a file is open. Pinned height +
                // layoutPriority so the content pane (priority 0) absorbs shrink.
                if model.currentURL != nil {
                    ContentToolbar(model: model)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                    Divider()
                }
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("mdv.content")
                    .overlay(
                        // Window-root overlay scoped to the content
                        // pane. Lives above the source view so highlight
                        // stripes and floating popovers align with the
                        // editor, not the whole window.
                        WalkthroughOverlay(model: model)
                            .allowsHitTesting(
                                model.walkthroughBridge.popover != nil
                            )
                    )
                if walkthrough.isActive {
                    // Docked at the bottom of the right pane. Only
                    // present when a walkthrough is running (per user
                    // decision §1).
                    WalkthroughPlayerView(controller: walkthrough)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Read `splitURL` off the DIRECTLY-observed coordinator (not via
            // the `model.splitURL` forwarder): this branch is what creates /
            // destroys the split pane, and `tabCoordinator.splitURL` is the
            // `@Published` it must track. `model.splitURL` returns the same
            // value, but reading it off `model` does NOT register a dependency
            // on the coordinator (its `objectWillChange` isn't forwarded into
            // `DocumentModel` — PERF #1), so this branch would only re-evaluate
            // on an unrelated `DocumentModel` republish. See the property doc.
            if let splitURL = tabCoordinator.splitURL {
                Divider()
                SplitPaneView(
                    url: splitURL,
                    zoom: model.zoom,
                    theme: model.activeTheme,
                    onClose: { model.closeSplit() },
                    model: model,
                    tabs: tabCoordinator
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("mdv.split")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Sidebar / left-shoulder reconciliation
    //
    // `sidebar.isVisible` is the COLLECTIVE left-shoulder master switch
    // (driven by the menu "Toggle Sidebar"; unchanged). The accordion
    // CONTAINER additionally gates on ≥1 left-docked panel resolving
    // visible — so when every left panel resolves hidden (no folder, no
    // data, or user `.hidden` everything) the accordion collapses while
    // the rail (gated only on `sidebar.isVisible`) stays, ready to bring
    // a panel back. Pinned by `PanelLayoutResolutionTests`.
    private var leftContainerVisible: Bool {
        guard sidebar.isVisible else { return false }
        let pres = railDataPresence
        return panelLayout.railPanels(on: .left).contains {
            panelLayout.isVisible($0, dataPresent: pres[$0] ?? false)
        }
    }

    /// Per-panel data-presence for the CURRENT inputs. Same heuristic
    /// (`SidebarDataPresence`) the rail buttons + accordion read, so the
    /// container gate, the rail fills, and the accordion presence agree.
    private var railDataPresence: [SidebarPanelKind: Bool] {
        SidebarDataPresence.evaluate(
            SidebarDataPresence.Inputs(
                hasRoot: sidebar.rootURL != nil,
                hasRepo: model.trackedRepos.trackedRoots.isEmpty == false,
                hasLSPLanguage: model.currentURL.flatMap {
                    LSPLanguageRegistry.default.language(for: $0)
                } != nil,
                claudeHasTranscripts: sidebar.claudeHasTranscripts,
                // RECENTS RAIL FIX (2026-06-01): the Recents rail button
                // already exists (`.recentlyOpened` is a registered panel) but
                // both rail-side presence builders omitted `hasRecents`, so it
                // defaulted false — the button read permanently "no data" /
                // off and never reflected history. Mirror SidebarView's
                // accordion builder so the rail fill + accordion presence
                // agree.
                hasRecents: model.recents.isEmpty == false
            )
        )
    }

    /// Hidden bridge view that observes the coordinator's published
    /// token when present. Exists as a separate view so SwiftUI's
    /// dynamic-property mechanism doesn't blow up when `sessionsApp`
    /// is nil (previews + headless tests).
    @ViewBuilder
    private var firstPaintGoToBridge: some View {
        if let sessionsApp {
            FirstPaintGoToBridge(model: model, sessionsApp: sessionsApp)
        } else {
            EmptyView()
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        // Delegates to `DropRouter.handle` so the test suite can
        // exercise the same code path. Lazy multi-open: only the
        // last file becomes the focused tab; the rest land as empty
        // tabs that materialize on first click.
        DropRouter.handle(providers) { [model] resolved in
            model.openMultiple(resolved)
        }
        return true
    }

    @ViewBuilder
    private var content: some View {
        // Perf Fix#1 (TSK-108): render a ZStack of every MOUNTED tab pane
        // (the MRU-bounded `MountedPanesLRU`), not just the active one.
        // Inactive panes stay MOUNTED (gated opacity 0 / hit-testing off) so
        // switching back is a pure visibility flip — no WKWebView teardown +
        // reload (the ~1s tab-switch freeze). `dismantleNSView` fires only on
        // LRU tail eviction. `ForEach` keyed on the stable `Tab.id` preserves
        // each pane's SwiftUI identity — the load-bearing invariant.
        // Design: docs/research/perf-fix1-view-retention.md (Approach A).
        let mounted = model.mountedTabs
        if mounted.isEmpty {
            // No open/retained tab yet (cold launch, all tabs closed): render
            // the active state directly so the pane is never blank.
            tabContent(for: model.tabs.selected ?? ViewerCore.Tab(), isActive: true)
        } else {
            ZStack {
                ForEach(mounted) { tab in
                    let isActive = (tab.id == model.tabs.selected?.id)
                    // Per-pane render attributes are driven from the named,
                    // host-testable `PaneCompositingPolicy` contract (TSK-839)
                    // rather than inline ternaries — so the per-nav CA-commit
                    // decisions (visibility, hit-testing, z-order, and the
                    // per-pane compositing isolation) are pinned by a host test
                    // even though the commit-cost win itself is VM-only.
                    let render = PaneCompositingPolicy.render(isActive: isActive)
                    tabContent(for: tab, isActive: isActive)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        // Each retained pane gets its OWN compositing layer so a
                        // sibling pane's (or surrounding chrome's) re-layout does
                        // not pull every pane's opaque-representable subtree into
                        // one CA commit reconciliation per nav action (TSK-839 /
                        // LESSONS compositor rule, TSK-488).
                        .compositingGroup()
                        // opacity:0 (NOT `.hidden()`): keeps the inactive
                        // WKWebView "visible" to WebKit so it never fires
                        // `visibilitychange` → no page self-reload (cmux #1228).
                        // Background-throttled only.
                        .opacity(render.opacity)
                        .allowsHitTesting(render.hitTesting)
                        .accessibilityHidden(render.accessibilityHidden)
                        .zIndex(render.zIndex)
                }
            }
        }
    }

    /// Render ONE tab's content for its OWN `state` / `viewMode` / id — NOT
    /// the globally-active tab's. This is what lets inactive retained panes
    /// keep showing their own document while invisible. `isActive` gates the
    /// find bar + find query so only the visible pane shows/drives find
    /// (otherwise N hidden find bars fight for first-responder focus).
    @ViewBuilder
    private func tabContent(for tab: ViewerCore.Tab, isActive: Bool) -> some View {
        switch tab.state {
        case .empty:
            EmptyStateView(model: model)
        case .loading(let url):
            LoadingStateView(url: url)
        case .loaded(let file):
            loadedView(for: file, tab: tab, isActive: isActive)
        case .binary(let binary):
            // For binaries (HEX mode) we always show the byte grid;
            // the metadata panel pairs naturally with .preview state
            // below.
            HexView(file: binary,
                    fontSize: 12 * model.zoom,
                    tabID: tab.id,
                    model: model)
        case .error(let failure):
            ErrorView(failure: failure, model: model)
        case .hostedView(let id, _):
            // View-hosting tab (WAVE 2b item 1): render the embedded
            // SwiftUI view the model owns for this hosted id. If the
            // registry entry is gone (shouldn't happen while the tab is
            // live), fall back to the empty state rather than crashing.
            if let hosted = model.hostedView(forID: id) {
                hosted
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyStateView(model: model)
            }
        case .preview(let url, let cat):
            HStack(spacing: 0) {
                MediaPreviewView(
                    url: url, category: cat,
                    onOpenSibling: { sibling in model.open(url: sibling) },
                    uiScale: CGFloat(model.zoom)
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                // TSK-608: dismissible via the BottomAttributesBar "Info"
                // toggle — this panel previously rendered unconditionally.
                if model.showPreviewMetadataPanel {
                    MetadataPanel(url: url, category: cat, uiScale: CGFloat(model.zoom))
                }
            }
        }
    }

    @ViewBuilder
    private func loadedView(for file: TextFile, tab: ViewerCore.Tab, isActive: Bool) -> some View {
        // WAVE 2b item 6: a per-tab "Open As…" override wins over
        // extension/UTI detection so e.g. a `.db` opened as Markdown
        // renders through the markdown pipeline.
        let category = tab.categoryOverride
            ?? FileTypeDetector.category(for: file.url)
        if NotebookGate.handles(file.url),
           let notebook = try? NotebookDocument(jsonText: file.contents) {
            // TSK-717 (experimental — NotebookGate off by default): render a
            // Jupyter .ipynb as typed cells. Gated ⇒ no default-path impact; a
            // parse failure falls through to the normal JSON / source view.
            NotebookCellListView(document: notebook)
        } else if tab.viewMode == .table {
            // Per-tab CSV filter state lives on DocumentModel keyed by tab id;
            // pass THIS pane's id so each retained pane keeps its own filter.
            CSVTableView(text: file.contents, model: model, tabID: tab.id)
        } else if tab.viewMode == .editor {
            // Hard cap. Above ~50 MB the WKWebView path becomes a
            // liability (JS-heap pressure + LSP diagnostics push cost);
            // route the user to source view instead. See
            // `codeMirrorEditorMaxBytes` for rationale.
            if file.byteCount > codeMirrorEditorMaxBytes {
                LargeEditorPlaceholderView(file: file, model: model)
                    .accessibilityIdentifier("mdv.editor.largePlaceholder")
                    .id("largeEditorCap-\(file.url.path)")
            } else {
            // Editor mode: editable in-memory buffer. The buffer is
            // owned by `DocumentModel.editorBuffers` keyed by tab id;
            // we seed it lazily here (idempotent) so re-entering the
            // mode for a freshly-loaded tab gets a real backing buffer.
            //
            // View is CodeMirror 6 inside a WKWebView — see
            // `CodeMirrorEditorView` header for why. The Swift-side
            // data flow (EditorBuffer / isDirty / saveActiveEditor)
            // is unchanged from the prior NSTextView PoC.
            let tid = tab.id
            let _ = { model.ensureEditorBuffer(for: file, tabID: tid) }()
            let buf = model.editorBuffer(forTabID: tid)
            let lang = model.effectiveLanguage(forTabID: tid, url: file.url)
            let diags = model.pendingEditorDiagnostics[tid] ?? []
            let gutter = model.pendingEditorGutterMarkers[tid] ?? []
            // TSK-1046: the once-per-mount CM6 seed now honors a RESTORED SCROLL
            // position, not just a restored caret. A session/tab switch-IN may
            // re-inject only `editorScrollByTab` (a scroll top line, no caret);
            // `editorMountSelectionSeed` resolves cursor-first, else seeds a
            // collapsed selection at the restored line's start so the editor
            // comes back to the same viewport instead of jumping to the top.
            let seed = model.editorMountSelectionSeed(forTabID: tid)
            // TSK-1047: warm-editor-cache key — the resolved file path (stable
            // across the `Tab.id` churn a session switch causes, like the
            // rendered view's key). The EPHEMERAL preview slot opts OUT (nil): it
            // deliberately resets scroll/cursor on file swap (TSK-743/744
            // isolation), so it must not park/re-attach a warm editor that would
            // resurrect a prior position. The seed belt (above) still restores
            // scroll for cache-miss / opted-out panes.
            let editorCacheKey: String? = tab.isPreview
                ? nil
                : file.url.resolvingSymlinksInPath().standardizedFileURL.path
            VStack(spacing: 0) {
                if isActive && model.isEditorFindBarPresented {
                    EditorFindBar(find: model.find, uiSize: model.uiSize)
                }
                CodeMirrorEditorView(
                    text: buf?.text ?? file.contents,
                    fontSize: model.effectiveContentFontSize,
                    language: lang,
                    isDarkTheme: model.activeTheme.name == .xcodeDark,
                    themePalette: model.activeThemeCMPalette,
                    // TSK-732: feed CM6 the RESOLVED family (what the AppKit
                    // View renders), not the raw picker string — CSS family
                    // matching ≠ NSFont(name:) matching, so the raw name let
                    // View and Edit diverge onto different fonts.
                    fontFamily: FontPreference.cssFamily(for: model.sourceFontName),
                    wordWrap: model.sourceWordWrap,
                    readOnly: model.isEditorReadOnly,   // TSK-936
                    lineNumbers: true,
                    indentation: model.editorIndentation,
                    gotoLineRequest: model.editorGotoLine,
                    insertRequest: model.editorInsertRequest,
                    selectRequest: model.editorSelectRequest,
                    snippetSessionActive: model.isSnippetSessionActive,
                    showInvisibles: model.showInvisibleChars,
                    vimMode: model.vimModeEnabled,
                    editorFocusRequest: model.editorFocusRequest,
                    indentGuides: model.editorIndentGuides,
                    foldingRanges: model.editorFoldRangesByTab[tid] ?? [],
                    gutterMarkers: gutter,
                    diagnostics: diags,
                    findQuery: (isActive && model.isEditorFindBarPresented) ? model.editorFindQuery : "",
                    findCaseSensitive: model.editorFindCaseSensitive,
                    findRegex: model.editorFindIsRegex,
                    findNextRequest: model.editorFindNextRequest,
                    findPrevRequest: model.editorFindPrevRequest,
                    findReplacement: model.editorFindReplacement,
                    replaceNextRequest: model.editorReplaceNextRequest,
                    replaceAllRequest: model.editorReplaceAllRequest,
                    initialSelection: seed,
                    cacheKey: editorCacheKey,
                    onTextChange: { newText in
                        model.updateEditorText(newText, forTabID: tid)
                    },
                    onSaveRequested: {
                        _ = model.saveActiveEditor()
                    },
                    onCursorChange: { pos in
                        model.recordEditorCursor(pos, forTabID: tid)
                    },
                    onVimModeChange: { mode in
                        model.setEditorVimMode(mode)
                    },
                    onScrollChange: { pos in
                        model.recordEditorScroll(pos, forTabID: tid)
                    },
                    onFindResultChange: { result in
                        if result.matches == 0 {
                            model.setEditorFindMatchSummary("")
                        } else {
                            model.setEditorFindMatchSummary("\(result.current)/\(result.matches)")
                        }
                    },
                    onHoverRequest: { req in
                        model.respondToEditorHover(
                            tabID: tid, fileURL: file.url, request: req
                        )
                    },
                    onCompletionRequest: { req in
                        model.respondToEditorCompletion(
                            tabID: tid, fileURL: file.url, request: req
                        )
                    },
                    onDefinitionRequest: { req in
                        model.handleEditorDefinition(
                            tabID: tid, fileURL: file.url, request: req
                        )
                    },
                    onContextMenuRequest: { req in
                        model.showEditorContextMenu(
                            tabID: tid, fileURL: file.url, request: req
                        )
                    },
                    onBlur: {
                        if model.saveEditorOnBlur {
                            _ = model.saveActiveEditor()
                        }
                    },
                    onSnippetTab: { forward in
                        // TSK-705: walk the active snippet session's tab stops.
                        model.snippetTab(forward: forward)
                    }
                )
                .accessibilityIdentifier("mdv.editor")
                .onAppear {
                    // Clear pending diagnostics + gutter markers once
                    // they're shipped to the editor so updateNSView
                    // doesn't re-push every SwiftUI redraw. Coordinator-
                    // side `lastSent*` dedup is the primary defense;
                    // this is belt-and-suspenders for the model's
                    // `@Published` churn.
                    DispatchQueue.main.async {
                        if !diags.isEmpty {
                            model.consumePendingEditorDiagnostics(forTabID: tid)
                        }
                        if !gutter.isEmpty {
                            model.consumePendingEditorGutterMarkers(forTabID: tid)
                        }
                    }
                }
            }
            } // end size-cap else
        } else if tab.viewMode == .diff {
            DiffView(text: file.contents, doc: model)
        } else if (category == .markdown && tab.viewMode == .rendered)
                    || (category == .mermaid && tab.viewMode == .rendered) {
            // Soft cap on rendered-markdown size. The parser → HTML →
            // WKWebView pipeline transiently allocates a few multiples
            // of input size (AST + emitted HTML + DOM in the WebContent
            // process). On a 50 MB markdown that's hundreds of MB. Above
            // the cap, fall back to a placeholder that points the user
            // at source mode (still navigable, no rendering attempted).
            if file.byteCount > markdownRenderMaxBytes {
                LargeMarkdownPlaceholderView(file: file, model: model)
            } else {
                renderedMarkdownView(for: file, category: category,
                                     tab: tab, isActive: isActive)
            }
        } else if category == .html && tab.viewMode == .rendered {
            // Raw-HTML rendered mode — the SEPARATE, sanitized +
            // JS-default-deny path (HTMLRenderedView), NOT the markdown
            // WebView. L0 size cap: above HTMLDocumentPolicy.renderMaxBytes
            // we refuse to slurp an untrusted multi-MB document into the
            // WebContent process and point the user at source mode.
            if file.byteCount > HTMLDocumentPolicy.renderMaxBytes {
                LargeHTMLPlaceholderView(file: file, model: model)
            } else {
                VStack(spacing: 0) {
                    // TSK-1189: offer "Trust & Run" when a local, script-dependent
                    // doc rendered partially because its scripts were stripped.
                    if model.shouldOfferHTMLTrust(forTabID: tab.id, contents: file.contents) {
                        HTMLTrustBanner(
                            fileName: file.url.lastPathComponent,
                            onTrust: { model.setHTMLTrusted(true, forTabID: tab.id) }
                        )
                    }
                    HTMLRenderedView(
                    rawHTML: file.contents,
                    documentURL: file.url,
                    zoom: model.zoom,
                    // L2: per-tab JS opt-in. Default-OFF lives in the
                    // model (absence of the tab id ⇒ false).
                    javaScriptEnabled: model.htmlJavaScriptEnabled(forTabID: tab.id),
                    // TSK-1189: trust-local-HTML — runs the page's own scripts
                    // only for a local, user-opted-in, non-quarantined doc.
                    trusted: model.htmlTrusted(forTabID: tab.id),
                    printNonce: isActive ? model.renderedPrintRequest : 0,
                    pdfExportNonce: isActive ? (model.renderedPDFExportRequest?.nonce ?? 0) : 0,
                    pdfExportURL: model.renderedPDFExportRequest?.url,
                    onPDFExportResult: { nonce, ok, message in
                        Task { @MainActor in
                            model.recordPDFExportResult(nonce: nonce, ok: ok, message: message)
                        }
                    }
                )
                .accessibilityIdentifier("mdv.htmlRendered")
                }
            }
        } else {
            // PERF #5: source view subtree extracted into
            // `SourceModeView` so it can observe the per-tab
            // `HighlightCacheActor` via `@ObservedObject`. The actor
            // bumps its `version` when a tokenize completes, which
            // re-evals only this subtree (not ContentView and not
            // every sibling).
            SourceModeView(
                model: model,
                highlightCache: model.highlightCacheActor(forTabID: tab.id),
                find: model.find,
                sourceView: model.sourceView,
                file: file,
                tabID: tab.id,
                isActive: isActive
            )
        }
    }

    /// Rendered-markdown branch extracted so the size-cap fork stays
    /// readable. Mermaid standalone files synthesize a single-fence
    /// markdown document, then ride the same WebView path.
    @ViewBuilder
    private func renderedMarkdownView(
        for file: TextFile, category: FileCategory, tab: ViewerCore.Tab, isActive: Bool
    ) -> some View {
        let renderedContents: String = {
            if category == .mermaid {
                return "```mermaid\n\(file.contents)\n```\n"
            }
            return file.contents
        }()
        // tabID is BOTH the rendered-HTML cache identity and this pane's id —
        // each retained pane caches + renders its OWN document.
        let tabID = tab.id
        VStack(spacing: 0) {
            if isActive && model.isRenderedFindBarPresented {
                MarkdownFindBar(find: model.find, uiSize: model.uiSize)
            }
            // TSK-611: body only READS the rendered-HTML cache. The cold
            // render (markdown→HTML + TreeSitter grammar query compiles
            // for code fences) measured 927ms of main-thread hang when it
            // ran inline here during a layout pass — it now runs off-main
            // via requestRenderedHTML, and this branch shows a spinner
            // until the cache fills (one republish, one WebView load).
            if let html = model.renderedHTMLIfCached(forTabID: tabID, file: file) {
                markdownWebView(html: html, file: file, isActive: isActive)
            } else {
                ZStack {
                    Color.clear
                    ProgressView()
                        .controlSize(.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("mdv.renderedMarkdownPending")
                // .task(id:) refires when the key changes (file reloads
                // with new mtime while this pane stays mounted), unlike
                // .onAppear.
                .task(id: DocumentModel.RenderedHTMLKey(
                    tabID: tabID,
                    byteCount: file.byteCount,
                    modifiedTime: file.modifiedTime
                )) {
                    model.requestRenderedHTML(
                        forTabID: tabID,
                        file: file,
                        contents: renderedContents,
                        renderer: renderer,
                        stylesheet: stylesheet
                    )
                }
            }
        }
    }

    /// The WKWebView leg of the rendered-markdown branch, extracted so the
    /// cache-hit and pending forks above stay readable.
    @ViewBuilder
    private func markdownWebView(html: String, file: TextFile, isActive: Bool) -> some View {
        MarkdownRenderedView(
            html: html,
            baseURL: file.url.deletingLastPathComponent(),
            zoom: model.zoom,
            contentScale: ContentFontSizing.markdownScale(contentFontSize: model.contentFontSize),
            findQuery: isActive ? model.renderedFindQuery : "",
            findCaseSensitive: model.renderedFindCaseSensitive,
            findNextNonce: model.renderedFindNextRequest,
            findPrevNonce: model.renderedFindPrevRequest,
            onFindResult: { matched in
                Task { @MainActor in model.renderedFindMatched = matched }
            },
            onFindSummary: { summary in
                Task { @MainActor in model.setRenderedFindMatchSummary(summary) }
            },
            // Print / Export-as-PDF (TSK-638): only the ACTIVE tab's view
            // answers the model's nonce, never a background sibling.
            printNonce: isActive ? model.renderedPrintRequest : 0,
            pdfExportNonce: isActive ? (model.renderedPDFExportRequest?.nonce ?? 0) : 0,
            pdfExportURL: model.renderedPDFExportRequest?.url,
            onPDFExportResult: { nonce, ok, message in
                Task { @MainActor in
                    model.recordPDFExportResult(nonce: nonce, ok: ok, message: message)
                }
            },
            // TSK-905: only the ACTIVE tab's preview answers the focus nonce
            // (a background sibling must never grab first responder).
            focusRequest: isActive ? model.previewFocusRequest : 0,
            // TSK-1271: while the find bar holds focus, forward scroll keys to
            // this ACTIVE pane's webview (background siblings ignore the nonce).
            findScrollNonce: isActive ? model.renderedFindScrollRequest : 0,
            findScrollCommand: model.renderedFindScrollCommand,
            // TSK-821: per-file rendered-scroll persistence — capture this
            // file's scrollY before it's swapped out, restore it on return.
            fileURL: file.url,
            restoreScrollY: model.renderedScrollOffset(for: file.url),
            onScrollCapture: { url, y in
                Task { @MainActor in model.rememberRenderedScroll(y, for: url) }
            }
        )
    }
}

/// PERF #5 (2026-05-25): source-view subtree.
///
/// Extracted from `ContentView.loadedView` so it can take the per-tab
/// `HighlightCacheActor` as an `@ObservedObject`. When a TreeSitter
/// tokenize completes the actor bumps its `version` — SwiftUI re-evals
/// only this view (because nothing above it observes the actor) and
/// re-reads `runs(for:)` synchronously off the cache. ContentView,
/// TabBar, StatusBar etc. are not republished.
struct SourceModeView: View {
    @ObservedObject var model: DocumentModel
    /// Per-tab cache. Storing `@ObservedObject` is the narrow channel
    /// — only this subtree re-bodies on highlight-ready.
    @ObservedObject var highlightCache: HighlightCacheActor
    /// Find state pulled in directly so source-find keystrokes
    /// (query, case, next/prev nonce) re-eval the TextDisplayView
    /// without going through DocumentModel republish. The whole
    /// point of the FindCoordinator split (Quality #E, 2026-05-25).
    @ObservedObject var find: FindCoordinator
    /// High-frequency scroll/caret/scroll-to-line channel. Observed
    /// DIRECTLY (not via `model`) so a scroll tick or caret move re-bodies
    /// only this subtree (gutter + text + find-minimap) and the status bar
    /// — never the sidebar / content tree. See `SourceViewChannel`.
    @ObservedObject var sourceView: SourceViewChannel
    let file: TextFile
    let tabID: UUID
    /// Perf Fix#1 (TSK-108): false for retained-but-inactive panes. Gates the
    /// find bar so only the visible pane shows it (no first-responder fight).
    let isActive: Bool

    /// TSK-263: 1-based source line under the pointer, or nil when the pointer
    /// is outside the text rows. Drives `SourceHoverHighlight`.
    @State private var hoveredSourceLine: Int?
    /// TSK-374: presents the find-match LIST popover (line + text per match).
    @State private var showFindMatchList = false

    var body: some View {
        let displayedInfo = model.displayedText(for: file)
        let displayed = displayedInfo.text
        let lang = effectiveLanguage()
        let runs = computeRuns(
            text: displayed,
            byteLength: displayedInfo.byteLength,
            modifiedTime: displayedInfo.modifiedTime,
            language: lang
        )
        VStack(spacing: 0) {
            if isActive && model.isSourceFindBarPresented {
                SourceFindBar(find: model.find, uiSize: model.uiSize)
            }
            HStack(spacing: 0) {
                SourceGutterView(
                    state: sourceView.sourceScrollState,
                    fontSize: model.effectiveContentFontSize,
                    theme: model.activeTheme,
                    diffMarks: model.sourceDiffMarks,
                    bookmarkedLines: model.bookmarkedLines(for: file.url)
                )
                ZStack(alignment: .topLeading) {
                    TextDisplayView(
                        text: displayed,
                        fontSize: model.effectiveContentFontSize,
                        fontName: model.sourceFontName,
                        language: lang,
                        runs: runs,
                        theme: model.activeTheme,
                        findState: TextDisplayView.FindState(
                            query: (isActive && model.isSourceFindBarPresented) ? model.sourceFindQuery : "",
                            caseSensitive: model.sourceFindCaseSensitive,
                            isRegex: model.sourceFindIsRegex,
                            nextNonce: model.sourceFindNextRequest,
                            prevNonce: model.sourceFindPrevRequest
                        ),
                        wordWrap: model.sourceWordWrap,
                        showInvisibles: model.showInvisibleChars,
                        isLargeReadOnly: file.isLargeReadOnly,
                        // TSK-889: key the warm-reopen cache by this tab's stable
                        // identity (not URL) so switch-back reuses the laid-out
                        // controller. No-op unless MDV_PRESERVE_RECENT_SOURCE_VIEWS.
                        tabID: tabID,
                        scrollLineRequest: TextDisplayView.ScrollLineRequest(
                            line: sourceView.sourceScrollLineTarget,
                            nonce: sourceView.sourceScrollLineNonce
                        ),
                        onFindSummary: { summary in
                            model.setSourceFindMatchSummary(summary)
                        },
                        onScrollChange: { state in
                            sourceView.sourceScrollState = state
                        },
                        onSelectionChange: { sel in
                            sourceView.sourceSelection = sel
                        },
                        onFindMatchesChange: { set in
                            model.setSourceFindMatches(
                                lines: set.lines, currentIndex: set.currentIndex
                            )
                        }
                    )
                    // TSK-263: mouse-over line hover highlight (distinct from the
                    // caret/selection current-line backdrop). A non-interactive
                    // sibling rect; the hover tracking is on the ZStack so it
                    // never blocks the NSTextView's clicks/selection.
                    SourceHoverHighlight(
                        state: sourceView.sourceScrollState,
                        caretLine: sourceView.sourceSelection.line,
                        hoveredLine: hoveredSourceLine,
                        theme: model.activeTheme
                    )
                    // TSK-364: readable "show invisibles" markers (·/→) drawn
                    // by a scroll-synced SwiftUI Canvas overlay — NOT the
                    // washed-out OS faint-grey (`NSLayoutManager.showsInvisible
                    // Characters`, which has no recolor API). Drawn AFTER the
                    // text + given its own layer above the source rows
                    // (`.compositingGroup().zIndex(1)`) so it never gets
                    // occluded by the NSTextView's CALayer (the sibling-blank
                    // class, LESSONS) in any layout branch.
                    if model.showInvisibleChars && !file.isLargeReadOnly {
                        SourceInvisiblesView(
                            state: sourceView.sourceScrollState,
                            text: displayed,
                            fontSize: model.effectiveContentFontSize,
                            fontName: model.sourceFontName,
                            theme: model.activeTheme
                        )
                        .compositingGroup()
                        .zIndex(1)
                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                               alignment: .topLeading)
                    }
                    // TSK-305: scaled document overview / minimap, top-right.
                    // Markdown only (it maps the heading structure). Drawn
                    // AFTER the text in the ZStack so its own layer sits above
                    // the source rows; .compositingGroup() guards against the
                    // sibling-occlusion class (LESSONS) in every layout branch.
                    if lang == .markdown && model.showMarkdownOverview {
                        let segments = MarkdownOverview.segments(in: displayed)
                        if !segments.isEmpty {
                            MarkdownOverviewView(
                                segments: segments,
                                topVisibleLine: sourceView.sourceScrollState.topVisibleLine,
                                visibleLineCount: Self.visibleLineCount(
                                    sourceView.sourceScrollState),
                                theme: model.activeTheme,
                                onClickLine: { line in
                                    model.scrollSource(toLine: line)
                                }
                            )
                            .compositingGroup()
                            .padding(.trailing, 2)
                            .frame(maxWidth: .infinity, maxHeight: .infinity,
                                   alignment: .topTrailing)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onContinuousHover { phase in
                    // TSK-736: `.onContinuousHover` fires per pointer-pixel, and a
                    // @State write always invalidates (SwiftUI doesn't dedupe equal
                    // values) — re-bodying SourceModeView + re-running the find-
                    // highlight repaint on EVERY pixel. Guard the write so only an
                    // actual LINE CHANGE re-bodies (per-pixel → per-line-crossing),
                    // which is the dominant lag on a big file with Find active.
                    switch phase {
                    case .active(let p):
                        let line = SourceHoverGeometry.lineAtPointer(
                            p.y, in: sourceView.sourceScrollState)
                        if line != hoveredSourceLine { hoveredSourceLine = line }
                    case .ended:
                        if hoveredSourceLine != nil { hoveredSourceLine = nil }
                    }
                }
                if model.isSourceFindBarPresented,
                   !model.sourceFindMatchLines.isEmpty {
                    VStack(spacing: 2) {
                        // TSK-374: open the full match LIST (line + text, click to
                        // jump) — the richer companion to the tick minimap below.
                        Button { showFindMatchList.toggle() } label: {
                            Image(systemName: "list.bullet")
                                .font(.system(size: model.uiSize(9)))
                                .frame(width: FindMatchMinimapView.stripWidth, height: 14)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Show all matches")
                        .accessibilityIdentifier("mdv.findMatchList.toggle")
                        .popover(isPresented: $showFindMatchList, arrowEdge: .leading) {
                            FindMatchListView(
                                rows: FindMatchList.rows(
                                    matchLines: model.sourceFindMatchLines,
                                    docText: model.displayText(for: file)),
                                currentMatchIndex: model.sourceFindCurrentMatchIndex,
                                onClickLine: { line in
                                    model.scrollSource(toLine: line)
                                    showFindMatchList = false
                                },
                                uiSize: { model.uiSize($0) })
                        }
                        FindMatchMinimapView(
                            matchLines: model.sourceFindMatchLines,
                            totalLines: max(1, sourceView.sourceScrollState.lineCount),
                            currentMatchIndex: model.sourceFindCurrentMatchIndex,
                            theme: model.activeTheme,
                            onClickLine: { line in
                                model.scrollSource(toLine: line)
                            }
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Effective language honors the manual override picked from the
    /// language dropdown in the ModeBar (per-tab).
    private func effectiveLanguage() -> HighlightLanguage {
        if let id = model.tabs.selected?.id {
            return model.effectiveLanguage(forTabID: id, url: file.url)
        }
        return HighlightLanguage.detect(from: file.url)
    }

    /// Estimate how many source lines fit in the viewport — drives the
    /// markdown overview's "you are here" marker height (TSK-305). Falls back
    /// to nil when the geometry isn't usable yet (pre-first-paint), so the
    /// marker degrades to a thin line at the top-visible line.
    static func visibleLineCount(_ state: SourceScrollState) -> Int? {
        guard state.lineHeight > 0, state.viewportHeight > 0 else { return nil }
        return max(1, Int((state.viewportHeight / state.lineHeight).rounded()))
    }

    /// Cache lookup via the per-tab actor. .diff/.patch use the
    /// hand-rolled per-line highlighter synchronously (no TreeSitter
    /// grammar; cost is O(n)). Everything else goes through the
    /// actor's `runsOrEnqueue` — returns cached runs immediately on
    /// hit, returns [] and kicks off the off-thread tokenize on miss.
    /// On completion the actor bumps `version`; SwiftUI re-evals this
    /// view and re-calls into `runsOrEnqueue` which now hits the cache.
    ///
    /// `byteLength` + `modifiedTime` are pre-computed by
    /// `DocumentModel.displayedText(for:)` — `byteLength` avoids an
    /// O(N) `utf8.count` walk per body re-eval (PERF-04), and
    /// `modifiedTime` joins the cache key so a same-byte reload
    /// invalidates instead of serving stale spans (RWC-1).
    private func computeRuns(
        text: String,
        byteLength: Int,
        modifiedTime: Date?,
        language: HighlightLanguage
    ) -> [HighlightRun] {
        // Read `version` so SwiftUI's dependency tracker registers
        // the dependency even when the cache is cold on first body.
        _ = highlightCache.version
        let ext = file.url.pathExtension.lowercased()
        if ext == "diff" || ext == "patch" {
            return DiffHighlighter.highlight(text)
        }
        guard language != .plainText else { return [] }
        let key = HighlightCacheKey(
            url: file.url,
            length: byteLength,
            language: language,
            modifiedTime: modifiedTime
        )
        return highlightCache.runsOrEnqueue(key: key, text: text)
    }
}

/// Shown for markdown documents whose source exceeds
/// `markdownRenderMaxBytes`. Rendering a multi-MB markdown through the
/// swift-markdown parser → HTMLRenderer → WKWebView pipeline allocates
/// a few multiples of input size transiently and can spike memory by
/// hundreds of MB. Above the cap we surface source view instead.
struct LargeMarkdownPlaceholderView: View {
    let file: TextFile
    @ObservedObject var model: DocumentModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.text")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Markdown too large to render")
                .font(.title3)
            Text("This file is \(ByteSize.mbString(file.byteCount)). " +
                 "Rendered mode is capped at \(ByteSize.mbString(markdownRenderMaxBytes)) " +
                 "to avoid multi-hundred-MB transient allocations through the " +
                 "parser → HTML → WebView pipeline.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Button("View as Source") {
                model.setCurrentViewMode(.source)
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

}

/// Shown for files that exceed `codeMirrorEditorMaxBytes` in editor
/// mode. The WKWebView path can technically render them but the JS
/// heap pressure (CM6 doc model + decoration set + LSP diagnostic
/// JSON push) compounds quickly. NSTextView TK1 in source mode reads
/// much larger files read-only — at ~1.5–2x file-size resident cost,
/// bounded by the loader's 512 MiB hard ceiling (NOT constant RAM; a
/// true bounded-RAM pager is a deferred follow-up) — so we route the
/// user there explicitly.
/// Design lock: `docs/CM6_INTEGRATION_DESIGN_2026-05-23.md` §17.5.
struct LargeEditorPlaceholderView: View {
    let file: TextFile
    @ObservedObject var model: DocumentModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.tertiary)
            Text("File too large for editor mode")
                .font(.title3)
            Text("This file is \(ByteSize.mbString(file.byteCount)). " +
                 "CodeMirror is capped at \(ByteSize.mbString(codeMirrorEditorMaxBytes)) " +
                 "to avoid JS-heap pressure in the WebView. Source view " +
                 "handles larger files read-only (high memory use above ~64 MB).")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            Button("View as Source") {
                model.setCurrentViewMode(.source)
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

}

struct ModeBar: View {
    @ObservedObject var model: DocumentModel

    var body: some View {
        HStack(spacing: 12) {
            // Unified mode picker. Every file gets Source + HEX at
            // minimum; markdown also gets Rendered; formatter-
            // supported files (JSON/XML/etc.) also get Formatted.
            let modes = ViewModeOptions.availableModes(for: model.currentURL)
            if modes.count > 1 {
                Picker("", selection: model.viewModeBinding) {
                    ForEach(modes, id: \.self) { mode in
                        Text(label(for: mode))
                            // Honor model.zoom so the picker labels
                            // grow with the rest of the UI. Default
                            // font for segmented controls is ~12pt;
                            // scale from that baseline.
                            .font(.system(size: model.uiSize(12)))
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                // Let the picker size to its intrinsic content so it
                // grows naturally with both label-string length and
                // zoom-driven font size. Previous hand-tuned width
                // formula (80 + 90 * (modes.count - 1)) ignored the
                // label length and at high zoom would push trailing
                // toggles past the right edge of the toolbar.
                .fixedSize()
                // Per-filename view-mode LOCK (TSK-811). Pins the chosen
                // lens for THIS file so reopening re-applies it. The glyph
                // reflects locked/unlocked; clicking toggles the override.
                lockButton
            }
            Spacer()
            // Source-view-only toggles. Both control rendering of the
            // open NSTextView so they make no sense in rendered / hex /
            // formatted modes — hide them in those.
            if showsSourceToggles {
                Toggle("Wrap", isOn: $model.sourceWordWrap)
                    .toggleStyle(.checkbox)
                    .controlSize(.mini)
                    .help("Soft-wrap long lines at the viewport edge")
                    .accessibilityIdentifier("mdv.wrapToggle")
                Toggle("¶", isOn: $model.showInvisibleChars)
                    .toggleStyle(.checkbox)
                    .controlSize(.mini)
                    .help("Show invisible characters (spaces · tabs → returns ¶)")
                    .accessibilityIdentifier("mdv.invisiblesToggle")
            }
            // PER-TAB JavaScript opt-in for raw-HTML rendered mode.
            // SECURITY: JS is DEFAULT-DENY; this is the ONLY way to turn
            // it on, and it's scoped to the current tab. Shown only for
            // `.html` files in rendered mode.
            if model.showsHTMLJavaScriptToggle {
                Toggle("Enable JS", isOn: Binding(
                    get: { model.currentHTMLJavaScriptEnabled },
                    set: { model.setHTMLJavaScriptEnabled(
                        $0, forTabID: model.tabs.selected?.id ?? UUID()
                    ) }
                ))
                .toggleStyle(.checkbox)
                .controlSize(.mini)
                .help("Run this HTML file's JavaScript (per-tab; off by "
                      + "default — untrusted HTML runs no scripts). Page "
                      + "scripts are still subject to the strict CSP and "
                      + "sanitizer; remote and file:// loads stay blocked.")
                .accessibilityIdentifier("mdv.htmlJSToggle")
            }
            // Universal "Open As…" chip (WAVE 2b item 6). Offers every
            // applicable viewer for ANY file, including binaries, so the
            // user can force a `.db` open as CSV, a `.png` as HEX, etc.
            if let url = model.currentURL {
                openAsMenu(url: url)
            }
            if let badge = languageBadgeText {
                Menu {
                    // "Auto" reverts to extension-based detection by
                    // setting the override back to the detected value.
                    if let url = model.currentURL {
                        let auto = HighlightLanguage.detect(from: url)
                        Button(action: { model.setCurrentLanguage(auto) }) {
                            HStack {
                                Text("Auto (\(auto.displayName))")
                                if !model.hasLanguageOverride { Image(systemName: "checkmark") }
                            }
                        }
                        Divider()
                    }
                    ForEach(HighlightLanguage.allCases, id: \.self) { lang in
                        Button(action: { model.setCurrentLanguage(lang) }) {
                            Text(lang.displayName)
                        }
                    }
                } label: {
                    HStack(spacing: 2) {
                        Text(badge)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7, weight: .bold))
                    }
                    .font(.system(size: model.uiSize(10), weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(model.hasLanguageOverride
                                  ? Color.accentColor.opacity(0.20)
                                  : Color.secondary.opacity(0.15))
                    )
                    .foregroundStyle(model.hasLanguageOverride
                                     ? Color.accentColor
                                     : .secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(model.hasLanguageOverride
                      ? "Language overridden — click to change or pick Auto"
                      : "Detected language — click to override")
                .accessibilityIdentifier("mdv.languageBadge")
            }
            // File path moved to the bottom status bar (cleaner UI;
            // matches how Xcode / VS Code split metadata from
            // mode-switch controls).
        }
        .frame(height: 22)
    }

    /// Per-filename view-mode lock toggle (TSK-811). A lock/unlock glyph next
    /// to the segmented mode picker: locked = the current file's view mode is
    /// pinned (reopening re-applies it), unlocked = transient per-tab. Clicking
    /// toggles the override (locks to the tab's current mode, or clears it).
    @ViewBuilder
    private var lockButton: some View {
        let locked = model.currentViewModeIsLocked
        Button(action: { model.toggleCurrentViewModeLock() }) {
            Image(systemName: locked ? "lock.fill" : "lock.open")
                .font(.system(size: model.uiSize(11)))
                .foregroundStyle(locked ? Color.accentColor : .secondary)
        }
        .buttonStyle(.borderless)
        .help(locked
              ? "View mode is locked for this file — click to unlock "
              + "(reopening will use the auto-detected default)"
              : "Lock this file to the current view mode — reopening will "
              + "re-apply it")
        .accessibilityIdentifier("mdv.viewModeLock")
    }

    /// The "Open As…" chip + dropdown (WAVE 2b item 6). Lists every
    /// applicable viewer for the current file (Source, Markdown, HTML,
    /// Image, SQLite, HEX, …) plus an "Auto" entry that clears the
    /// override. Reachable for ANY file, including binaries currently
    /// shown in HEX.
    @ViewBuilder
    private func openAsMenu(url: URL) -> some View {
        let overridden = model.hasCategoryOverride
        Menu {
            Button(action: { model.setCurrentCategoryOverride(nil) }) {
                HStack {
                    Text("Auto (\(Self.categoryLabel(FileTypeDetector.category(for: url))))")
                    if !overridden { Image(systemName: "checkmark") }
                }
            }
            Divider()
            ForEach(model.openAsCategories(for: url), id: \.self) { cat in
                Button(action: { model.setCurrentCategoryOverride(cat) }) {
                    HStack {
                        Text(Self.categoryLabel(cat))
                        if model.tabs.selected?.categoryOverride == cat {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "doc.viewfinder")
                    .font(.system(size: 8))
                Text("Open As")
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
            }
            .font(.system(size: model.uiSize(10), weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(overridden
                          ? Color.accentColor.opacity(0.20)
                          : Color.secondary.opacity(0.15))
            )
            .foregroundStyle(overridden ? Color.accentColor : .secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(overridden
              ? "Opened as an overridden type — click to change or pick Auto"
              : "Open this file as a different viewer (Source, SQLite, HEX, …)")
        .accessibilityIdentifier("mdv.openAs")
    }

    /// Human-readable label for an "Open As…" category entry.
    static func categoryLabel(_ cat: FileCategory) -> String {
        switch cat {
        case .markdown:  return "Markdown (rendered)"
        case .mermaid:   return "Mermaid"
        case .plainText: return "Plain Text / CSV"
        case .code:      return "Source / JSON"
        case .html:      return "HTML"
        case .image:     return "Image"
        case .audio:     return "Audio"
        case .video:     return "Video"
        case .pdf:       return "PDF"
        case .sqlite:    return "SQLite"
        case .archive:   return "Archive"
        case .binary:    return "HEX (raw bytes)"
        case .unknown:   return "Unknown"
        }
    }

    /// Bare type name (no "(rendered)" / "/CSV" qualifiers) — used where the
    /// category is the SUBJECT of a label ("Default view for Markdown"), not an
    /// Open-As lens choice. (TSK-671)
    static func categoryShortLabel(_ cat: FileCategory) -> String {
        switch cat {
        case .markdown:  return "Markdown"
        case .mermaid:   return "Mermaid"
        case .plainText: return "Plain Text"
        case .code:      return "Source code"
        case .html:      return "HTML"
        case .image:     return "Image"
        case .audio:     return "Audio"
        case .video:     return "Video"
        case .pdf:       return "PDF"
        case .sqlite:    return "SQLite"
        case .archive:   return "Archive"
        case .binary:    return "Binary"
        case .unknown:   return "Unknown"
        }
    }

    /// Short label for a view mode (single word). Static so menus outside the
    /// ModeBar (the BottomAttributesBar "Default view" section, TSK-671) share
    /// the exact wording.
    static func modeLabel(_ mode: ViewMode) -> String {
        switch mode {
        case .rendered:  return "Rendered"
        case .source:    return "Source"
        case .editor:    return "Editor"
        case .formatted: return "Format"
        case .table:     return "Table"
        case .diff:      return "Diff"
        case .preview:   return "Preview"
        case .hex:       return "HEX"
        }
    }

    private var showsSourceToggles: Bool {
        model.currentViewMode == .source || model.currentViewMode == .formatted
    }

    /// Short label for each view mode. The picker is tight, so we
    /// keep these to a single word.
    private func label(for mode: ViewMode) -> String { Self.modeLabel(mode) }

    /// Shown when source mode is active. Honors per-tab override so
    /// the chip reflects what's actually being highlighted, not the
    /// extension-based detection. Hidden in rendered-markdown mode
    /// (the mode picker already conveys context there).
    private var languageBadgeText: String? {
        guard let url = model.currentURL,
              let id = model.tabs.selected?.id else { return nil }
        let lang = model.effectiveLanguage(forTabID: id, url: url)
        // Plain text + no override = hide the chip (saves visual noise
        // on .txt files). When the user explicitly picked "Plain Text"
        // we still show the chip so they can pick a different language.
        if lang == .plainText && !model.hasLanguageOverride { return nil }
        if model.supportsViewModeToggle, model.currentViewMode == .rendered {
            return nil
        }
        // Hide the language chip while raw HTML is shown in rendered mode
        // (the mode picker already conveys context; the chip is for
        // source-side language overrides).
        if model.showsHTMLJavaScriptToggle { return nil }
        return lang.displayName
    }
}

/// Shown while a lazy tab is being materialized off-main. Short delay
/// before the spinner appears so a tiny file that loads in <100 ms
/// doesn't flash a spinner — the dominant case for everyday tabs.
struct LoadingStateView: View {
    let url: URL
    @State private var showSpinner = false

    var body: some View {
        VStack(spacing: 12) {
            if showSpinner {
                ProgressView()
                    .controlSize(.large)
                Text(url.lastPathComponent)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            showSpinner = true
        }
    }
}

struct EmptyStateView: View {
    @ObservedObject var model: DocumentModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.text")
                .resizable()
                .scaledToFit()
                .frame(width: 56, height: 56)
                .foregroundStyle(.secondary)
            Text("No file open")
                .font(.title2)
            HStack(spacing: 12) {
                // TSK-760: create a new editable text file straight from the
                // landing (folder if one is open, else a temp scratch the user
                // Saves-As from). ⌘N matches File → New File.
                Button("New File") {
                    model.newTextFileForLanding()
                }
                .keyboardShortcut("n", modifiers: [.command])
                .accessibilityIdentifier("mdv.emptyState.newFile")
                // TSK-1306: New Image opens the editor with a blank canvas
                // (BlankImageCreator via newBlankImageForLanding — host-tested).
                Button("New Image") {
                    model.newBlankImageForLanding()
                }
                .accessibilityIdentifier("mdv.emptyState.newImage")
                Button("Open File…") {
                    NSApp.sendAction(#selector(AppMenuActions.openDocument(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("o", modifiers: [.command])
                Button("Open Folder…") {
                    NSApp.sendAction(#selector(AppMenuActions.openFolder(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            // Group the action row as an AX container so its children (the
            // New File button incl.) surface to an out-of-process AX reader —
            // a bare `.accessibilityIdentifier` on a SwiftUI container is NOT
            // promoted to a readable AX element (proven on the VM lane; the
            // VM render-validation guard for TSK-760 depends on this).
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("mdv.emptyState.actions")
            // TSK-745: the new-tab landing surfaces recent files, click-to-open.
            // Capped (model.landingRecents) so the welcome screen stays a
            // glanceable launcher; the full scrollable list lives in the sidebar.
            if model.landingRecents.isEmpty {
                Text("Or press ⌘K to search recents.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                recentsLauncher
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var recentsLauncher: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Recent")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("mdv.emptyState.recentsHeader")
            ForEach(model.landingRecents) { entry in
                Button(action: { model.openPath(entry.url) }) {
                    HStack(spacing: 6) {
                        Image(systemName: entry.kind == .folder ? "folder" : "doc")
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        Text(entry.displayName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let folder = entry.parentFolderLabel {
                            Text(folder)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(entry.url.path)
                .accessibilityIdentifier("mdv.emptyState.recentRow")
            }
        }
        .frame(maxWidth: 360, alignment: .leading)
        .padding(.top, 4)
        // AX container so the launcher + its rows surface out-of-process (the
        // VM render-validation guard for TSK-745) — see the note on the action
        // row above; a bare identifier on a SwiftUI VStack isn't promoted.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mdv.emptyState.recents")
    }
}

struct ErrorView: View {
    let failure: DocumentState.LoadFailure
    @ObservedObject var model: DocumentModel

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .resizable()
                .scaledToFit()
                .frame(width: 44, height: 44)
                .foregroundStyle(Color(nsColor: .systemOrange))
            Text(failure.url.lastPathComponent)
                .font(.title3)
            Text(failure.message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            HStack(spacing: 12) {
                Button("Reload") {
                    model.reloadCurrentFile()
                }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([failure.url])
                }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Hidden observer view that consumes
/// `SessionsAppCoordinator.firstPaintGoToToken`. Lives as a child of
/// `ContentView.background(...)` so SwiftUI re-renders this view (and
/// fires its `.onChange`) whenever the coordinator publishes a new
/// token. The take-once semantics live in the coordinator's
/// `consumeFirstPaintGoTo()`.
private struct FirstPaintGoToBridge: View {
    @ObservedObject var model: DocumentModel
    @ObservedObject var sessionsApp: SessionsAppCoordinator

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: sessionsApp.firstPaintGoToToken) { _, token in
                guard token != nil else { return }
                if sessionsApp.consumeFirstPaintGoTo() {
                    // The gate only arms from the new-session entry
                    // points (`+` button / session.new command), so a
                    // folder confirm must spawn a session, not re-root
                    // the current one (TSK-600).
                    model.showGoToPath(newSessionIntent: true)
                }
            }
    }
}
