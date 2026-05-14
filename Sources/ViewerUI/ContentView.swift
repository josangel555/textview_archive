import SwiftUI
import ViewerKit
import ViewerCore

public struct ContentView: View {
    @ObservedObject var model: DocumentModel
    private let renderer = HTMLRenderer()
    private let stylesheet: String

    public init(model: DocumentModel) {
        self.model = model
        self.stylesheet = MarkdownStylesheet.load()
    }

    public var body: some View {
        VStack(spacing: 0) {
            TabBar(model: model)
            Divider()
            ModeBar(model: model)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 600, minHeight: 360)
    }

    @ViewBuilder
    private var content: some View {
        switch model.currentState {
        case .empty:
            EmptyStateView()
        case .loaded(let file):
            loadedView(for: file)
        case .error(let failure):
            ErrorView(failure: failure)
        }
    }

    @ViewBuilder
    private func loadedView(for file: TextFile) -> some View {
        let category = FileTypeDetector.category(for: file.url)
        if category == .markdown && model.currentViewMode == .rendered {
            MarkdownRenderedView(
                html: renderer.renderPage(file.contents, stylesheet: stylesheet),
                baseURL: file.url.deletingLastPathComponent()
            )
        } else {
            TextDisplayView(text: file.contents)
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
            Spacer()
            Text(model.windowTitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(height: 22)
    }
}

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text")
                .resizable()
                .scaledToFit()
                .frame(width: 56, height: 56)
                .foregroundStyle(.secondary)
            Text("No file open")
                .font(.title2)
            Text("Press ⌘O or ⌘T, or pass a path on the command line.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ErrorView: View {
    let failure: DocumentState.LoadFailure
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .resizable()
                .scaledToFit()
                .frame(width: 44, height: 44)
                .foregroundStyle(.orange)
            Text(failure.url.lastPathComponent)
                .font(.title3)
            Text(failure.message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
