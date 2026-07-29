import AppKit
import SwiftUI
import ViewerKit
import ViewerCore

/// Right-hand secondary pane for split-view mode (Phase 2.5). Reads
/// the file at `url` and renders it in the most reasonable view for
/// its type — markdown rendered, code as source with highlights,
/// images / PDF / audio / video via the existing MediaPreviewView,
/// binaries via HexView, CSV via CSVTableView.
///
/// v1 limitations (documented; not bugs):
/// - No tab bar, find bar, or per-pane mode picker. The split pane
///   just shows one file. Tabs / find / mode all stay on the
///   primary (left) pane.
/// - No drag-resize between panes. Uses the native `HSplitView`
///   resize behavior in `ContentView`.
/// - State is recomputed on every render (no caching). Files in the
///   split pane reload from disk each time the URL changes —
///   matches the user's mental model ("I dropped a different file
///   in") and is fast for typical viewer-sized files.
struct SplitPaneView: View {
    let url: URL
    let zoom: Double
    let theme: SyntaxTheme
    let onClose: () -> Void
    @ObservedObject var model: DocumentModel
    /// TSK-806: the split source text comes from the live editor buffer
    /// (`model.splitPaneText`), which is owned by `tabCoordinator` and is
    /// deliberately NOT forwarded into `DocumentModel.objectWillChange`
    /// (PERF #1 severed that to kill a republish storm). Observing the
    /// coordinator DIRECTLY re-bodies the split on each keystroke so unsaved
    /// edits appear here — the same narrow-observation pattern StatusBar uses.
    @ObservedObject var tabs: TabCoordinator

    /// Per-instance pseudo-tab-id for CSV filter state. @State keeps
    /// it stable across body re-renders for this SplitPaneView
    /// lifetime; cleared on `.onDisappear` so the model's filter-state
    /// map doesn't grow by 1 every time the user opens/closes splits.
    /// Was a `static let UUID()` — that carried filter across files
    /// and never freed.
    @State private var splitCSVTabID: UUID = UUID()

    /// TSK-922: the split file's on-disk content, loaded OFF-MAIN once per URL
    /// (was a synchronous `TextFileLoader().load` INSIDE `body` that re-read the
    /// whole file on every SwiftUI invalidation → main-thread stalls = "slow").
    /// `.loading` shows a spinner; `.failed` the "Couldn't read" placeholder;
    /// `.loaded` renders. Re-loads on URL change via `.task(id: url)`.
    @State private var diskLoad: DiskLoad = .loading
    private enum DiskLoad: Equatable, Sendable { case loading, loaded(String), failed }

    /// True when the split-pane file is large enough that a synchronous
    /// in-`body` read would stall the main thread. Media categories
    /// don't read bytes into Swift memory, so this only matters for the
    /// text/markdown/CSV path. Uses the loader's soft watermark so the
    /// split-pane guard and the main-pane large-read tagging agree.
    private var isSplitFileTooLargeForSyncRead: Bool {
        let bytes = (try? FileManager.default
            .attributesOfItem(atPath: url.path)[.size]) as? Int
        return Self.isTooLargeForSyncRead(
            category: FileTypeDetector.category(for: url),
            byteCount: bytes,
            softWarnBytes: TextFileLoader().softWarnBytes)
    }

    /// TSK-922 (host-testable, pure): the size-gate. Media categories never read
    /// bytes into Swift memory (false); everything else routes to a placeholder
    /// above the loader's soft watermark so the split guard + main-pane large-read
    /// tagging agree. Missing/unreadable size ⇒ false (let the load try).
    nonisolated static func isTooLargeForSyncRead(
        category: FileCategory, byteCount: Int?, softWarnBytes: Int
    ) -> Bool {
        switch category {
        case .image, .audio, .video, .pdf, .sqlite:
            return false
        default:
            break
        }
        guard let byteCount else { return false }
        return byteCount > softWarnBytes
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 200)
        .background(Palette.textBackground)
        .onDisappear {
            // Free the CSV filter slot keyed on this pane's pseudo-tab.
            model.clearCsvFilterState(forTabID: splitCSVTabID)
        }
        .task(id: url) {
            // TSK-922: load the split file OFF-MAIN once per URL (was a per-body
            // synchronous read). The too-large case shows a placeholder without
            // reading any bytes (stat-only guard). Re-runs on URL change.
            guard !isSplitFileTooLargeForSyncRead else { return }
            diskLoad = .loading
            let u = url
            diskLoad = await Task.detached(priority: .userInitiated) { () -> DiskLoad in
                if let f = try? TextFileLoader().load(url: u) { return .loaded(f.contents) }
                return .failed
            }.value
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            FileIconView(url: url, isDirectory: false, size: .tree)
                .frame(width: 14, height: 14)
            Text(url.lastPathComponent)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(IconHoverButtonStyle())
            .helpInfo(title: "Close split", description: "Close the split pane (⌘⇧\\)")
            .accessibilityLabel("Close split pane")
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(Palette.windowBackground)
    }

    @ViewBuilder
    private var content: some View {
        let category = FileTypeDetector.category(for: url)
        switch category {
        case .image, .audio, .video, .pdf:
            MediaPreviewView(url: url, category: category)
        case .sqlite:
            // No SQLite UI in split for v1 — show a placeholder.
            Text("Open SQLite files in the main pane.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            textContent
        }
    }

    @ViewBuilder
    private var textContent: some View {
        // Large-file guard for the SPLIT pane. This read is synchronous
        // and runs inside `body` — it re-reads the whole file on every
        // SwiftUI invalidation. For a few-hundred-MB file that is a
        // per-body main-thread stall (far worse than the main pane's
        // single off-main read). The split pane is a secondary surface;
        // route the user to open the file in the MAIN pane, which has
        // the proper off-main load + read-only degradation. Stat is
        // cheap and never reads the bytes.
        if isSplitFileTooLargeForSyncRead {
            VStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("File too large for split view")
                    .font(.callout)
                Text("Open it in the main pane to view large files.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        } else if case .loaded(let diskText) = diskLoad {
            let ext = url.pathExtension.lowercased()
            let cat = FileTypeDetector.category(for: url)
            // TSK-806: show the file's UNSAVED edits, not stale on-disk text,
            // when this file is open in a (dirty) editor tab. Keyed by the split
            // file's URL — the split can show a different file than the active
            // tab — so it can't reuse the selected-tab `displayedText(for:)`.
            // TSK-922: `diskText` is the off-main-loaded on-disk content (fallback
            // when the file isn't an open, dirty editor buffer).
            let sourceText = model.splitPaneText(for: url, fallback: diskText)
            if cat == .markdown || cat == .mermaid {
                // Rendered OFF-MAIN with a debounce (SplitMarkdownRenderModel)
                // — this used to render the whole document synchronously in
                // body, on the main thread, per keystroke (audit THEME 6).
                SplitMarkdownPane(
                    text: sourceText,
                    isMermaid: cat == .mermaid,
                    baseURL: url.deletingLastPathComponent(),
                    zoom: zoom
                )
            } else if ext == "csv" || ext == "tsv" {
                CSVTableView(text: sourceText,
                             model: model,
                             tabID: splitCSVTabID)
            } else {
                let lang = HighlightLanguage.detect(from: url)
                TextDisplayView(
                    text: sourceText,
                    fontSize: 13 * zoom,
                    fontName: model.sourceFontName,   // TSK-732: match the main View's font (was nil → always SF Mono)
                    language: lang,
                    runs: [],   // no syntax highlight in split v1 — saves a TreeSitter pass per render
                    theme: theme,   // match main pane: dark theme in dark mode, etc.
                    wordWrap: false
                )
            }
        } else if case .failed = diskLoad {
            VStack(spacing: 6) {
                Text("Couldn't read")
                    .foregroundStyle(.secondary)
                Text(url.lastPathComponent)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // TSK-922: .loading — the off-main read is in flight (replaces the
            // old per-body synchronous read that stalled the main thread).
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Markdown/mermaid half of the split, backed by the debounced off-main
/// renderer. A separate leaf view so the render model rides `@StateObject`
/// (allocated once per pane) — a fresh-object `@State` here would cost the
/// parent SwiftUI's body-skip (LESSONS 2026-07-27).
private struct SplitMarkdownPane: View {
    let text: String
    let isMermaid: Bool
    let baseURL: URL
    let zoom: Double

    @StateObject private var render = SplitMarkdownRenderModel()

    var body: some View {
        Group {
            if let html = render.html {
                MarkdownRenderedView(html: html, baseURL: baseURL, zoom: zoom)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { render.schedule(text: text, isMermaid: isMermaid) }
        .onChange(of: text) { _, new in render.schedule(text: new, isMermaid: isMermaid) }
    }
}
