import SwiftUI
import UniformTypeIdentifiers
import ViewerKit
import ViewerCore

public struct ContentView: View {
    @ObservedObject var model: DocumentModel
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
                HStack(spacing: 0) {
                    if model.sidebar.isVisible {
                        DraggableSidebar(model: model)
                            .accessibilityIdentifier("mdv.sidebar")
                        Divider()
                    }
                    VStack(spacing: 0) {
                        content
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .accessibilityIdentifier("mdv.content")
                            .overlay(
                                // Window-root overlay scoped to the
                                // content pane. Lives above the source
                                // view so highlight stripes and
                                // floating popovers align with the
                                // editor, not the whole window.
                                WalkthroughOverlay(model: model)
                                    .allowsHitTesting(
                                        model.walkthroughBridge.popover != nil
                                    )
                            )
                        if walkthrough.isActive {
                            // Docked at the bottom of the right pane.
                            // Only present when a walkthrough is
                            // running (per user decision §1).
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
                CrossSearchPanel(model: model)
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
        // Collect every dropped URL into an ordered array, then open
        // them on the main actor in drag order. The previous version
        // fired model.openPath per loadObject completion, which:
        //   - silently dropped missing files (didn't even show an
        //     error tab — inconsistent with openPath's intent)
        //   - opened multi-file drops in non-deterministic order
        //     (loadObject is async, completions race)
        let total = providers.count
        var collected: [URL?] = Array(repeating: nil, count: total)
        let lock = NSLock()
        var completed = 0
        for (i, provider) in providers.enumerated() {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                lock.lock()
                collected[i] = url
                completed += 1
                let done = completed
                // Snapshot under the lock so the Task closure captures a
                // value-typed copy instead of the outer `var collected`,
                // which otherwise warns under strict-concurrency about
                // concurrent var capture.
                let snapshot: [URL?]? = (done == total) ? collected : nil
                lock.unlock()
                if let urls = snapshot {
                    Task { @MainActor in
                        // Lazy multi-open: only the last file is read
                        // into memory + becomes the focused tab. Tabs
                        // for the rest are appended with state = .empty
                        // and materialize when the user clicks them.
                        let resolved = urls.compactMap { $0 }
                        model.openMultiple(resolved)
                    }
                }
            }
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
            HexView(file: binary, fontSize: 12 * model.zoom)
        case .error(let failure):
            ErrorView(failure: failure, model: model)
        case .preview(let url, let cat):
            HStack(spacing: 0) {
                MediaPreviewView(
                    url: url, category: cat,
                    onOpenSibling: { sibling in model.open(url: sibling) }
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
            // Editor mode: editable in-memory buffer. The buffer is
            // owned by `DocumentModel.editorBuffers` keyed by tab id;
            // we seed it lazily here (idempotent) so re-entering the
            // mode for a freshly-loaded tab gets a real backing buffer.
            let tid = model.tabs.selected?.id ?? UUID()
            let _ = { model.ensureEditorBuffer(for: file, tabID: tid) }()
            let buf = model.editorBuffer(forTabID: tid)
            EditorTextDisplayView(
                text: buf?.text ?? file.contents,
                fontSize: 13 * model.zoom,
                onTextChange: { newText in
                    model.updateEditorText(newText, forTabID: tid)
                }
            )
            .accessibilityIdentifier("mdv.editor")
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
            let displayed = model.displayText(for: file)
            // Effective language honors the manual override picked
            // from the language dropdown in the ModeBar (per-tab).
            let lang: HighlightLanguage = {
                if let id = model.tabs.selected?.id {
                    return model.effectiveLanguage(forTabID: id, url: file.url)
                }
                return HighlightLanguage.detect(from: file.url)
            }()
            VStack(spacing: 0) {
                if model.isSourceFindBarPresented {
                    SourceFindBar(model: model)
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
                        runs: model.highlightRuns(forURL: file.url, text: displayed, language: lang),
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
                        }
                    )
                    // Force the NSViewControllerRepresentable to claim
                    // the full HStack width. Without this, the inner
                    // NSScrollView's intrinsicContentSize (driven by
                    // the text-document width) wins over the outer
                    // VStack frame and the source pane collapses to a
                    // narrow centered strip. Putting the frame on the
                    // outer VStack alone is not enough — SwiftUI sizes
                    // the AppKit child to its intrinsic and pads the
                    // remainder.
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        VStack(spacing: 0) {
            if model.isRenderedFindBarPresented {
                MarkdownFindBar(model: model)
            }
            MarkdownRenderedView(
                html: model.renderedHTML(
                    forURL: file.url,
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
