import SwiftUI
import UniformTypeIdentifiers
import ViewerKit
import ViewerCore

public struct ContentView: View {
    @ObservedObject var model: DocumentModel
    @State private var isDropTargeted = false
    private let renderer = HTMLRenderer()
    private let stylesheet: String

    public init(model: DocumentModel) {
        self.model = model
        self.stylesheet = MarkdownStylesheet.load()
    }

    public var body: some View {
        ZStack {
            VStack(spacing: 0) {
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
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier("mdv.content")
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
                lock.unlock()
                if done == total {
                    let urls = collected
                    Task { @MainActor in
                        for case let url? in urls {
                            // Always route through openPath — it shows
                            // an .error tab for missing files, which is
                            // more useful than silent dismissal.
                            model.openPath(url)
                        }
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
        case .loaded(let file):
            loadedView(for: file)
        case .binary(let binary):
            HexView(file: binary, fontSize: 12 * model.zoom)
        case .error(let failure):
            ErrorView(failure: failure, model: model)
        }
    }

    @ViewBuilder
    private func loadedView(for file: TextFile) -> some View {
        let category = FileTypeDetector.category(for: file.url)
        if category == .markdown && model.currentViewMode == .rendered {
            VStack(spacing: 0) {
                if model.isRenderedFindBarPresented {
                    MarkdownFindBar(model: model)
                }
                MarkdownRenderedView(
                    html: model.renderedHTML(
                        forURL: file.url,
                        contents: file.contents,
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
                    }
                )
            }
        } else {
            let displayed = model.displayText(for: file)
            let lang = HighlightLanguage.detect(from: file.url)
            VStack(spacing: 0) {
                if model.isSourceFindBarPresented {
                    SourceFindBar(model: model)
                }
                HStack(spacing: 0) {
                    SourceGutterView(
                        state: model.sourceScrollState,
                        fontSize: 13 * model.zoom,
                        theme: model.activeTheme
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
                            nextNonce: model.sourceFindNextRequest,
                            prevNonce: model.sourceFindPrevRequest
                        ),
                        wordWrap: model.sourceWordWrap,
                        onFindSummary: { summary in
                            model.sourceFindMatchSummary = summary
                        },
                        onScrollChange: { state in
                            model.sourceScrollState = state
                        }
                    )
                }
            }
        }
    }
}

struct ModeBar: View {
    @ObservedObject var model: DocumentModel

    var body: some View {
        HStack(spacing: 12) {
            if model.supportsViewModeToggle {
                Picker("", selection: model.viewModeBinding) {
                    Text("Rendered").tag(ViewMode.rendered)
                    Text("Source").tag(ViewMode.source)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
            }
            if model.supportsFormatToggle {
                Toggle(isOn: Binding(
                    get: { model.isCurrentTabFormatted },
                    set: { _ in model.toggleFormat() }
                )) {
                    Label("Format", systemImage: "text.alignleft")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 11))
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help("Pretty-print this file (Cmd+Opt+F)")
                .accessibilityIdentifier("mdv.formatToggle")
            }
            Spacer()
            if let badge = languageBadgeText {
                Text(badge)
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.secondary.opacity(0.15))
                    )
                    .foregroundStyle(.secondary)
                    .help("Detected language for syntax highlighting")
                    .accessibilityIdentifier("mdv.languageBadge")
            }
            // File path moved to the bottom status bar (cleaner UI;
            // matches how Xcode / VS Code split metadata from
            // mode-switch controls).
        }
        .frame(height: 22)
    }

    /// Shown when source mode is active AND the file's language was
    /// detected as something other than plain text. Hidden for markdown
    /// rendered mode (where the picker already conveys context).
    private var languageBadgeText: String? {
        guard let url = model.currentURL else { return nil }
        let lang = HighlightLanguage.detect(from: url)
        guard lang != .plainText else { return nil }
        if model.supportsViewModeToggle, model.currentViewMode == .rendered {
            return nil
        }
        return lang.displayName
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
                    NSApp.sendAction(Selector(("openDocument:")), to: nil, from: nil)
                }
                .keyboardShortcut("o", modifiers: [.command])
                Button("Open Folder…") {
                    NSApp.sendAction(Selector(("openFolder:")), to: nil, from: nil)
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
