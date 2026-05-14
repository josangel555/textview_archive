import SwiftUI
import ViewerCore

public struct ContentView: View {
    @ObservedObject var model: DocumentModel

    public init(model: DocumentModel) {
        self.model = model
    }

    public var body: some View {
        Group {
            switch model.state {
            case .empty:
                EmptyStateView()
            case .loaded(let file):
                TextDisplayView(text: file.contents)
            case .error(let failure):
                ErrorView(failure: failure)
            }
        }
        .frame(minWidth: 480, minHeight: 320)
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
            Text("Press ⌘O or pass a path on the command line.")
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
