import SwiftUI

/// Find bar used in both rendered and source view modes. Same UI in
/// both; only the underlying state bindings differ. The rendered variant
/// can't currently produce a match count (WKFindConfiguration doesn't
/// expose one); the source variant does, via TextDisplayView's
/// `onFindSummary` callback writing to the model.
///
/// Activation: Cmd+F. Dismiss: Esc.
struct FindBar: View {
    let placeholder: String
    @Binding var query: String
    @Binding var caseSensitive: Bool
    @Binding var isRegex: Bool
    @Binding var matchSummary: String  // e.g. "3/12"; empty when unknown
    let noResultsMode: NoResultsMode
    let focusRequest: Int
    let onNext: () -> Void
    let onPrev: () -> Void
    let onDismiss: () -> Void
    let accessibilityID: String

    @FocusState private var fieldFocused: Bool

    enum NoResultsMode {
        /// Rendered view: WKWebView returns a bool — we know "no
        /// results" but not how many. Show "No results" when last
        /// search failed.
        case boolean(matched: Bool?)
        /// Source view: we have the full match list. Just show count
        /// or nothing.
        case countOnly
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $query)
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                .onSubmit { onNext() }

            switch noResultsMode {
            case .boolean(let matched):
                if !query.isEmpty, matched == false {
                    Text("No results")
                        .font(.caption)
                        .foregroundStyle(Color(nsColor: .systemOrange))
                        .accessibilityIdentifier("\(accessibilityID).noResults")
                }
            case .countOnly:
                if !matchSummary.isEmpty {
                    Text(matchSummary)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("\(accessibilityID).count")
                } else if !query.isEmpty {
                    Text("No results")
                        .font(.caption)
                        .foregroundStyle(Color(nsColor: .systemOrange))
                        .accessibilityIdentifier("\(accessibilityID).noResults")
                }
            }

            Toggle(isOn: $caseSensitive) {
                Text("Aa")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(caseSensitive ? .primary : .secondary)
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help("Match case")

            Toggle(isOn: $isRegex) {
                Text(".*")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(isRegex ? .primary : .secondary)
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help("Regular expression")

            Button(action: onPrev) {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.plain)
            .help("Previous match (Shift+Return)")
            .keyboardShortcut(.return, modifiers: [.shift])
            .accessibilityLabel("Previous match")

            Button(action: onNext) {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.plain)
            .help("Next match (Return)")
            .accessibilityLabel("Next match")

            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            .help("Close find bar (Esc)")
            .accessibilityLabel("Close find bar")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.thinMaterial)
        .overlay(alignment: .bottom) { Divider() }
        .onAppear { fieldFocused = true }
        .onChange(of: focusRequest) { _, _ in fieldFocused = true }
        .accessibilityIdentifier(accessibilityID)
    }
}

/// Backwards-compat shim: rendered find bar from before the FindBar
/// refactor. ContentView consumed `MarkdownFindBar(model:)` directly.
struct MarkdownFindBar: View {
    @ObservedObject var model: DocumentModel

    var body: some View {
        FindBar(
            placeholder: "Find in rendered markdown…",
            query: $model.renderedFindQuery,
            caseSensitive: $model.renderedFindCaseSensitive,
            isRegex: .constant(false),  // WKWebView find can't regex; toggle is hidden visually but state is unused
            // Rendered now supports proper count via JS injection
            // (Coordinator.findScript). Show n/N just like source.
            matchSummary: $model.renderedFindMatchSummary,
            noResultsMode: .countOnly,
            focusRequest: model.renderedFindFocusRequest,
            onNext: { model.renderedFindNext() },
            onPrev: { model.renderedFindPrev() },
            onDismiss: { model.dismissRenderedFindBar() },
            accessibilityID: "mdv.renderedFindBar"
        )
    }
}

/// Source-mode find bar. Surfaces the match count [n/N] that
/// TextDisplayView publishes via its `onFindSummary` callback.
struct SourceFindBar: View {
    @ObservedObject var model: DocumentModel

    var body: some View {
        FindBar(
            placeholder: "Find in source…",
            query: $model.sourceFindQuery,
            caseSensitive: $model.sourceFindCaseSensitive,
            isRegex: $model.sourceFindIsRegex,
            matchSummary: $model.sourceFindMatchSummary,
            noResultsMode: .countOnly,
            focusRequest: model.sourceFindFocusRequest,
            onNext: { model.sourceFindNext() },
            onPrev: { model.sourceFindPrev() },
            onDismiss: { model.dismissSourceFindBar() },
            accessibilityID: "mdv.sourceFindBar"
        )
    }
}
