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
    @StateObject var walkthrough: WalkthroughPlayerController
    /// App-level sessions coordinator. Optional so SwiftUI previews
    /// and host-side unit tests that construct a bare `ContentView`
    /// don't need to spin up the full SessionStore stack — the
    /// session tab row is simply hidden when nil.
    var sessionsApp: SessionsAppCoordinator?
    @State private var isDropTargeted = false
    private let renderer = HTMLRenderer()
    private let stylesheet: String

    public init(model: DocumentModel, sessionsApp: SessionsAppCoordinator? = nil) {
        self.model = model
        self.sidebar = model.sidebar
        self.find = model.find
        self.panelLayout = model.panelLayout
        self.sessionsApp = sessionsApp
        self.stylesheet = MarkdownStylesheet.load()
        // Persist the controller across body re-evals. The controller
        // owns the engine, delegate, and auto-advance scheduler — all
        // of which hold weak refs that would dangle if the controller
        // were rebuilt per body call.
        _walkthrough = StateObject(
            wrappedValue: WalkthroughPlayerController(model: model)
        )
    }

    /// Public accessor for `main.swift` to drive the player from CLI
    /// args / future external transports.
    public var walkthroughController: WalkthroughPlayerController {
        walkthrough
    }

    public var body: some View {
        ZStack {
            VStack(spacing: 0) {
                if let sessionsApp {
                    SessionTabBar(sessionsApp: sessionsApp)
                    Divider()
                }
                TabBar(model: model)
                    .accessibilityIdentifier("mdv.tabbar")
                Divider()
                ModeBar(model: model)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .accessibilityIdentifier("mdv.modebar")
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
                            model: model
                        )
                        Divider()
                    }
                    // Center column: body row over the bottom rail.
                    VStack(spacing: 0) {
                        bodyRow
                        Divider()
                        // BOTTOM rail: independent of the master switch;
                        // empty strip today (frame for future bottom-
                        // docked panels).
                        ShoulderRailView(
                            edge: .bottom,
                            panelLayout: panelLayout,
                            sidebar: sidebar,
                            model: model
                        )
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    // RIGHT rail: independent of the master switch;
                    // empty strip today.
                    ShoulderRailView(
                        edge: .right,
                        panelLayout: panelLayout,
                        sidebar: sidebar,
                        model: model
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if model.currentURL != nil {
                    StatusBar(model: model)
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
        }
        // First-paint GoTo: when a brand-new session is requested
        // (SessionTabBar `+`, or openFolder(forceNew:)), the
        // SessionsAppCoordinator bumps `firstPaintGoToToken`. We
        // observe the bump, consume the gate, and present the prompt.
        .background(firstPaintGoToBridge)
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
    private var bodyRow: some View {
        HStack(spacing: 0) {
            if leftContainerVisible {
                DraggableSidebar(model: model)
                    .accessibilityIdentifier("mdv.sidebar")
                Divider()
            }
            VStack(spacing: 0) {
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
            if let splitURL = model.splitURL {
                Divider()
                SplitPaneView(
                    url: splitURL,
                    zoom: model.zoom,
                    theme: model.activeTheme,
                    onClose: { model.closeSplit() },
                    model: model
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
                claudeHasTranscripts: sidebar.claudeHasTranscripts
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
        switch model.currentState {
        case .empty:
            EmptyStateView()
        case .loading(let url):
            LoadingStateView(url: url)
        case .loaded(let file):
            loadedView(for: file)
        case .binary(let binary):
            // For binaries (HEX mode) we always show the byte grid;
            // the metadata panel pairs naturally with .preview state
            // below.
            HexView(file: binary,
                    fontSize: 12 * model.zoom,
                    tabID: model.tabs.selected?.id ?? UUID(),
                    model: model)
        case .error(let failure):
            ErrorView(failure: failure, model: model)
        case .preview(let url, let cat):
            HStack(spacing: 0) {
                MediaPreviewView(
                    url: url, category: cat,
                    onOpenSibling: { sibling in model.open(url: sibling) },
                    uiScale: CGFloat(model.zoom)
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                MetadataPanel(url: url, category: cat)
            }
        }
    }

    @ViewBuilder
    private func loadedView(for file: TextFile) -> some View {
        let category = FileTypeDetector.category(for: file.url)
        if model.currentViewMode == .table {
            // Per-tab CSV filter state lives on DocumentModel keyed by
            // tab id; pass the active tab id so state persists across
            // tab switches.
            let tid = model.tabs.selected?.id ?? UUID()
            CSVTableView(text: file.contents, model: model, tabID: tid)
        } else if model.currentViewMode == .editor {
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
            let tid = model.tabs.selected?.id ?? UUID()
            let _ = { model.ensureEditorBuffer(for: file, tabID: tid) }()
            let buf = model.editorBuffer(forTabID: tid)
            let lang = model.effectiveLanguage(forTabID: tid, url: file.url)
            let diags = model.pendingEditorDiagnostics[tid] ?? []
            let gutter = model.pendingEditorGutterMarkers[tid] ?? []
            let seed = model.editorCursorByTab[tid].map {
                CMSelectionSeed(anchor: $0.head, head: $0.head, scroll: true)
            }
            VStack(spacing: 0) {
                if model.isEditorFindBarPresented {
                    EditorFindBar(find: model.find)
                }
                CodeMirrorEditorView(
                    text: buf?.text ?? file.contents,
                    fontSize: 13 * model.zoom,
                    language: lang,
                    isDarkTheme: model.activeTheme.name == .xcodeDark,
                    wordWrap: model.sourceWordWrap,
                    lineNumbers: true,
                    indentation: model.editorIndentation,
                    gotoLineRequest: model.editorGotoLine,
                    showInvisibles: model.showInvisibleChars,
                    gutterMarkers: gutter,
                    diagnostics: diags,
                    findQuery: model.isEditorFindBarPresented ? model.editorFindQuery : "",
                    findCaseSensitive: model.editorFindCaseSensitive,
                    findRegex: model.editorFindIsRegex,
                    findNextRequest: model.editorFindNextRequest,
                    findPrevRequest: model.editorFindPrevRequest,
                    initialSelection: seed,
                    onTextChange: { newText in
                        model.updateEditorText(newText, forTabID: tid)
                    },
                    onSaveRequested: {
                        _ = model.saveActiveEditor()
                    },
                    onCursorChange: { pos in
                        model.recordEditorCursor(pos, forTabID: tid)
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
        } else if model.currentViewMode == .diff {
            DiffView(text: file.contents, doc: model)
        } else if (category == .markdown && model.currentViewMode == .rendered)
                    || (category == .mermaid && model.currentViewMode == .rendered) {
            // Soft cap on rendered-markdown size. The parser → HTML →
            // WKWebView pipeline transiently allocates a few multiples
            // of input size (AST + emitted HTML + DOM in the WebContent
            // process). On a 50 MB markdown that's hundreds of MB. Above
            // the cap, fall back to a placeholder that points the user
            // at source mode (still navigable, no rendering attempted).
            if file.byteCount > markdownRenderMaxBytes {
                LargeMarkdownPlaceholderView(file: file, model: model)
            } else {
                renderedMarkdownView(for: file, category: category)
            }
        } else {
            // PERF #5: source view subtree extracted into
            // `SourceModeView` so it can observe the per-tab
            // `HighlightCacheActor` via `@ObservedObject`. The actor
            // bumps its `version` when a tokenize completes, which
            // re-evals only this subtree (not ContentView and not
            // every sibling).
            let tabID = model.tabs.selected?.id
                ?? UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0))
            SourceModeView(
                model: model,
                highlightCache: model.highlightCacheActor(forTabID: tabID),
                find: model.find,
                file: file,
                tabID: tabID
            )
        }
    }

    /// Rendered-markdown branch extracted so the size-cap fork stays
    /// readable. Mermaid standalone files synthesize a single-fence
    /// markdown document, then ride the same WebView path.
    @ViewBuilder
    private func renderedMarkdownView(
        for file: TextFile, category: FileCategory
    ) -> some View {
        let renderedContents: String = {
            if category == .mermaid {
                return "```mermaid\n\(file.contents)\n```\n"
            }
            return file.contents
        }()
        // tabID is the cache identity. We're inside the loaded-tab
        // branch so `tabs.selected` is non-nil in practice; fall back
        // to a zero UUID for the theoretical case where the body
        // re-evals between a selectTab and an updateDerived (the
        // cache entry would then be orphaned, evicted by LRU).
        let tabID = model.tabs.selected?.id ?? UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0))
        VStack(spacing: 0) {
            if model.isRenderedFindBarPresented {
                MarkdownFindBar(find: model.find)
            }
            MarkdownRenderedView(
                html: model.renderedHTML(
                    forTabID: tabID,
                    file: file,
                    contents: renderedContents,
                    renderer: renderer,
                    stylesheet: stylesheet
                ),
                baseURL: file.url.deletingLastPathComponent(),
                zoom: model.zoom,
                findQuery: model.renderedFindQuery,
                findCaseSensitive: model.renderedFindCaseSensitive,
                findNextNonce: model.renderedFindNextRequest,
                findPrevNonce: model.renderedFindPrevRequest,
                onFindResult: { matched in
                    Task { @MainActor in model.renderedFindMatched = matched }
                },
                onFindSummary: { summary in
                    Task { @MainActor in model.setRenderedFindMatchSummary(summary) }
                }
            )
        }
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
    let file: TextFile
    let tabID: UUID

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
            if model.isSourceFindBarPresented {
                SourceFindBar(find: model.find)
            }
            HStack(spacing: 0) {
                SourceGutterView(
                    state: model.sourceScrollState,
                    fontSize: 13 * model.zoom,
                    theme: model.activeTheme,
                    diffMarks: model.sourceDiffMarks,
                    bookmarkedLines: model.bookmarkedLines(for: file.url)
                )
                TextDisplayView(
                    text: displayed,
                    fontSize: 13 * model.zoom,
                    language: lang,
                    runs: runs,
                    theme: model.activeTheme,
                    findState: TextDisplayView.FindState(
                        query: model.isSourceFindBarPresented ? model.sourceFindQuery : "",
                        caseSensitive: model.sourceFindCaseSensitive,
                        isRegex: model.sourceFindIsRegex,
                        nextNonce: model.sourceFindNextRequest,
                        prevNonce: model.sourceFindPrevRequest
                    ),
                    wordWrap: model.sourceWordWrap,
                    showInvisibles: model.showInvisibleChars,
                    isLargeReadOnly: file.isLargeReadOnly,
                    scrollLineRequest: TextDisplayView.ScrollLineRequest(
                        line: model.sourceScrollLineTarget,
                        nonce: model.sourceScrollLineNonce
                    ),
                    onFindSummary: { summary in
                        model.setSourceFindMatchSummary(summary)
                    },
                    onScrollChange: { state in
                        model.sourceScrollState = state
                    },
                    onSelectionChange: { sel in
                        model.sourceSelection = sel
                    },
                    onFindMatchesChange: { set in
                        model.setSourceFindMatches(
                            lines: set.lines, currentIndex: set.currentIndex
                        )
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if model.isSourceFindBarPresented,
                   !model.sourceFindMatchLines.isEmpty {
                    FindMatchMinimapView(
                        matchLines: model.sourceFindMatchLines,
                        totalLines: max(1, model.sourceScrollState.lineCount),
                        currentMatchIndex: model.sourceFindCurrentMatchIndex,
                        theme: model.activeTheme,
                        onClickLine: { line in
                            model.scrollSource(toLine: line)
                        }
                    )
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
            Text("This file is \(byteString(file.byteCount)). " +
                 "Rendered mode is capped at \(byteString(markdownRenderMaxBytes)) " +
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

    private func byteString(_ bytes: Int) -> String {
        let mb = Double(bytes) / 1_048_576.0
        return String(format: "%.1f MB", mb)
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
            Text("This file is \(byteString(file.byteCount)). " +
                 "CodeMirror is capped at \(byteString(codeMirrorEditorMaxBytes)) " +
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

    private func byteString(_ bytes: Int) -> String {
        let mb = Double(bytes) / 1_048_576.0
        return String(format: "%.1f MB", mb)
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

    private var showsSourceToggles: Bool {
        model.currentViewMode == .source || model.currentViewMode == .formatted
    }

    /// Short label for each view mode. The picker is tight, so we
    /// keep these to a single word.
    private func label(for mode: ViewMode) -> String {
        switch mode {
        case .rendered:  return "Rendered"
        case .source:    return "Source"
        case .editor:    return "Editor"
        case .formatted: return "Format"
        case .table:     return "Table"
        case .diff:      return "Diff"
        case .hex:       return "HEX"
        }
    }

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
                Button("Open File…") {
                    NSApp.sendAction(NSSelectorFromString("openDocument:"), to: nil, from: nil)
                }
                .keyboardShortcut("o", modifiers: [.command])
                Button("Open Folder…") {
                    NSApp.sendAction(NSSelectorFromString("openFolder:"), to: nil, from: nil)
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            Text("Or press ⌘K to search recents.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    model.showGoToPath()
                }
            }
    }
}
