import SwiftUI

/// SwiftUI find bar for the markdown rendered view. Mirrors the
/// macOS-native NSTextView find bar (magnifying-glass icon, query
/// field, prev/next chevrons, case-sensitive toggle, close ×) but
/// driven by `DocumentModel.rendered*` state.
///
/// Activation: Cmd+F from rendered mode (handled by AppDelegate's
/// `findInRenderedMode(_:)` action). Dismiss: Esc.
struct MarkdownFindBar: View {
    @ObservedObject var model: DocumentModel
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find in rendered markdown…", text: $model.renderedFindQuery)
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                .onSubmit { model.renderedFindNext() }

            // Aa toggle for case sensitivity.
            Toggle(isOn: $model.renderedFindCaseSensitive) {
                Text("Aa")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(model.renderedFindCaseSensitive ? .primary : .secondary)
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help("Match case")

            Button {
                model.renderedFindPrev()
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.plain)
            .help("Previous match (Shift+Return)")
            .keyboardShortcut(.return, modifiers: [.shift])

            Button {
                model.renderedFindNext()
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.plain)
            .help("Next match (Return)")

            Button {
                model.dismissRenderedFindBar()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            .help("Close find bar (Esc)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.thinMaterial)
        .overlay(alignment: .bottom) {
            Divider()
        }
        .onAppear { fieldFocused = true }
        .accessibilityIdentifier("mdv.renderedFindBar")
    }
}
