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
    /// Whether to render the `.*` regex toggle. The rendered (WKWebView)
    /// bar omits it: WKWebView find can't do regex, so the toggle would
    /// be a dead control bound to a constant. Source/editor bars show it.
    var showsRegexToggle: Bool = true
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
            // The "Aa" glyph carries no meaning to VoiceOver; give it
            // an explicit role + on/off value so the toggle reads as
            // "Match case, on/off" rather than just "Aa, button".
            .accessibilityLabel("Match case")
            .accessibilityValue(caseSensitive ? "On" : "Off")

            if showsRegexToggle {
                Toggle(isOn: $isRegex) {
                    Text(".*")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(isRegex ? .primary : .secondary)
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help("Regular expression")
                .accessibilityLabel("Use regular expression")
                .accessibilityValue(isRegex ? "On" : "Off")
            }

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
        // A11Y-15: VoiceOver users get no signal that a search came up
        // empty — the orange "No results" text is purely visual. Post
        // a polite announcement on the no→results transition so the
        // failure is spoken once (not on every keystroke). Gated on the
        // computed `hasNoResults` so we only announce a real transition.
        .onChange(of: hasNoResults) { _, nowEmpty in
            if nowEmpty {
                AccessibilityAnnouncer.announce("No results")
            }
        }
        .accessibilityIdentifier(accessibilityID)
    }

    /// True when the bar is in its visible "No results" state. Mirrors
    /// the rendering condition in `body` so the announcement fires for
    /// exactly the cases that paint the orange label.
    private var hasNoResults: Bool {
        guard !query.isEmpty else { return false }
        switch noResultsMode {
        case .boolean(let matched):
            return matched == false
        case .countOnly:
            return matchSummary.isEmpty
        }
    }
}

/// Rendered-mode find bar. Observes `FindCoordinator` directly so
/// typing into the field doesn't re-render any DocumentModel observer
/// (TabBar, Sidebar, etc.) — the keystroke only ticks `find.
/// objectWillChange`, leaving the rest of the model untouched.
struct MarkdownFindBar: View {
    @ObservedObject var find: FindCoordinator

    var body: some View {
        FindBar(
            placeholder: "Find in rendered markdown…",
            query: $find.renderedQuery,
            caseSensitive: $find.renderedCaseSensitive,
            isRegex: .constant(false),  // WKWebView find can't regex; toggle omitted via showsRegexToggle, state unused
            showsRegexToggle: false,
            // Rendered now supports proper count via JS injection
            // (Coordinator.findScript). Show n/N just like source.
            matchSummary: $find.renderedMatchSummary,
            noResultsMode: .countOnly,
            focusRequest: find.renderedFocusRequest,
            onNext: { find.renderedNext() },
            onPrev: { find.renderedPrev() },
            onDismiss: { find.dismissRenderedBar() },
            accessibilityID: "mdv.renderedFindBar"
        )
    }
}

/// CM6 editor-mode find bar. Drives CodeMirror's built-in search
/// through the v1 bridge (`setSearchQuery` / `findNext` / `findPrev`)
/// rather than opening CM's panel. Same visual surface as the source
/// find bar — single mental model for the user across modes.
struct EditorFindBar: View {
    @ObservedObject var find: FindCoordinator

    var body: some View {
        FindBar(
            placeholder: "Find in editor…",
            query: $find.editorQuery,
            caseSensitive: $find.editorCaseSensitive,
            isRegex: $find.editorIsRegex,
            matchSummary: $find.editorMatchSummary,
            noResultsMode: .countOnly,
            focusRequest: find.editorFocusRequest,
            onNext: { find.editorNext() },
            onPrev: { find.editorPrev() },
            onDismiss: { find.dismissEditorBar() },
            accessibilityID: "mdv.editorFindBar"
        )
    }
}

/// Source-mode find bar. Surfaces the match count [n/N] that
/// TextDisplayView publishes via its `onFindSummary` callback.
struct SourceFindBar: View {
    @ObservedObject var find: FindCoordinator

    var body: some View {
        FindBar(
            placeholder: "Find in source…",
            query: $find.sourceQuery,
            caseSensitive: $find.sourceCaseSensitive,
            isRegex: $find.sourceIsRegex,
            matchSummary: $find.sourceMatchSummary,
            noResultsMode: .countOnly,
            focusRequest: find.sourceFocusRequest,
            onNext: { find.sourceNext() },
            onPrev: { find.sourcePrev() },
            onDismiss: { find.dismissSourceBar() },
            accessibilityID: "mdv.sourceFindBar"
        )
    }
}
