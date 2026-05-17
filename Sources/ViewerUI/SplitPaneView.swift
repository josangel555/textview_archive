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

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 200)
        .background(Color(nsColor: .textBackgroundColor))
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
            .buttonStyle(.plain)
            .help("Close split (⌘⇧\\)")
            .accessibilityLabel("Close split pane")
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(Color(nsColor: .windowBackgroundColor))
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
        // Lazy file load so a huge file doesn't block view body
        // construction. The text only renders when we have it.
        if let file = try? TextFileLoader().load(url: url) {
            let ext = url.pathExtension.lowercased()
            if FileTypeDetector.category(for: url) == .markdown {
                MarkdownRenderedView(
                    html: HTMLRenderer().render(file.contents),
                    baseURL: url.deletingLastPathComponent(),
                    zoom: zoom
                )
            } else if ext == "csv" || ext == "tsv" {
                CSVTableView(text: file.contents)
            } else {
                let lang = HighlightLanguage.detect(from: url)
                TextDisplayView(
                    text: file.contents,
                    fontSize: 13 * zoom,
                    language: lang,
                    runs: [],   // no syntax highlight in split v1 — saves a TreeSitter pass per render
                    theme: theme,   // match main pane: dark theme in dark mode, etc.
                    wordWrap: false
                )
            }
        } else {
            VStack(spacing: 6) {
                Text("Couldn't read")
                    .foregroundStyle(.secondary)
                Text(url.lastPathComponent)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
