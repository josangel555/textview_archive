import SwiftUI

/// Find bar used across the rendered, source, and editor view modes.
/// Styled to read as a native macOS find bar: a rounded
/// `NSSearchField`-style query field with a leading magnifier, standard
/// segmented prev/next stepper, button-style option toggles, and a
/// `.bar`-material backdrop. The same surface appears in every mode;
/// only the bound state and the available affordances differ.
///
/// - Match count "n/N" comes from the owning coordinator (source +
///   editor + rendered all publish it now).
/// - The `.*` regex toggle is shown only where the engine supports it
///   (source / editor); the rendered WKWebView bar omits it.
/// - The replace row (find-and-replace) is shown only for the editable
///   editor surface — see `replace` below. Rendered and source are
///   read-only, so they pass `replace: nil`.
///
/// All fonts and control metrics scale through `uiSize`, the same
/// `model.uiSize(_:)` zoom factor the rest of the chrome uses, so the
/// bar matches the surrounding UI at every zoom level.
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
    /// Scale a base point size by the app UI zoom factor
    /// (`model.uiSize(_:)`). Passed in rather than reading the model so
    /// `FindBar` stays decoupled from `DocumentModel`; the mount sites
    /// thread `model.uiSize` through.
    var uiSize: (CGFloat) -> CGFloat = { $0 }
    /// Find-and-replace configuration. `nil` on read-only surfaces
    /// (rendered / source) — the replace row is then omitted entirely.
    /// Present (editor) → the disclosure + replace row are shown.
    var replace: ReplaceConfig? = nil
    /// Forward document-scroll keys (PageUp/PageDown/arrows) pressed while the
    /// find field holds focus, so the underlying document still scrolls instead
    /// of the keys dying in the text field (TSK-1271). nil on surfaces that
    /// manage their own scrolling (source NSTextView / CM6); the rendered bar
    /// sets it. These keys have no useful single-line-field action, so
    /// repurposing them to scroll is safe.
    var onScrollKey: ((ScrollKey) -> Void)? = nil

    @FocusState private var focusedField: Field?

    private enum Field { case find, replace }

    /// Document-scroll keys the find field forwards to `onScrollKey` (TSK-1271).
    enum ScrollKey { case pageDown, pageUp, lineDown, lineUp }

    enum NoResultsMode {
        /// Rendered view: WKWebView returns a bool — we know "no
        /// results" but not how many. Show "No results" when last
        /// search failed.
        case boolean(matched: Bool?)
        /// Source view: we have the full match list. Just show count
        /// or nothing.
        case countOnly
    }

    /// Bindings + actions for the find-and-replace row. Grouped into a
    /// single optional so the whole replace feature is one decision at
    /// the call site (editor passes it, others pass `nil`). Holds plain
    /// `Binding`s (not `@Binding` wrappers) so the bindings can be read
    /// straight off the config value without projected-value access.
    struct ReplaceConfig {
        let replacement: Binding<String>
        let isVisible: Binding<Bool>
        let onReplaceNext: () -> Void
        let onReplaceAll: () -> Void
    }

    var body: some View {
        VStack(alignment: .leading, spacing: uiSize(5)) {
            findRow
            if let replace, replace.isVisible.wrappedValue {
                replaceRow(replace)
            }
        }
        .padding(.horizontal, uiSize(10))
        .padding(.vertical, uiSize(6))
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .onAppear { focusedField = .find }
        .onChange(of: focusRequest) { _, _ in focusedField = .find }
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

    // MARK: - Find row

    @ViewBuilder
    private var findRow: some View {
        HStack(spacing: uiSize(8)) {
            if let replace {
                disclosureButton(replace)
            }

            searchField

            countLabel

            HStack(spacing: uiSize(4)) {
                Toggle(isOn: $caseSensitive) {
                    Text("Aa")
                        .font(.system(size: uiSize(11), weight: .medium))
                        .foregroundStyle(caseSensitive ? .primary : .secondary)
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .helpInfo(title: "Match case",
                          description: "Find only exact-case matches of the query")
                // The "Aa" glyph carries no meaning to VoiceOver; give it
                // an explicit role + on/off value so the toggle reads as
                // "Match case, on/off" rather than just "Aa, button".
                .accessibilityLabel("Match case")
                .accessibilityValue(caseSensitive ? "On" : "Off")

                if showsRegexToggle {
                    Toggle(isOn: $isRegex) {
                        Text(".*")
                            .font(.system(size: uiSize(11), weight: .medium, design: .monospaced))
                            .foregroundStyle(isRegex ? .primary : .secondary)
                    }
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .helpInfo(title: "Regular expression",
                              description: "Treat the query as a regex pattern")
                    .accessibilityLabel("Use regular expression")
                    .accessibilityValue(isRegex ? "On" : "Off")
                }
            }

            // Native find bars use a segmented prev/next stepper.
            stepper

            Button(action: onDismiss) {
                Text("Done")
                    .font(.system(size: uiSize(12)))
            }
            .controlSize(.small)
            .keyboardShortcut(.escape, modifiers: [])
            .helpInfo(title: "Done", description: "Close the find bar (Esc)")
            .accessibilityLabel("Close find bar")
        }
    }

    /// NSSearchField-style field: rounded border, leading magnifier,
    /// clear button when non-empty. `.roundedBorder` + the inline
    /// magnifier reproduces the system look without dropping to an
    /// `NSViewRepresentable` (which would lose the SwiftUI focus / submit
    /// wiring the bar relies on).
    private var searchField: some View {
        HStack(spacing: uiSize(5)) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: uiSize(11)))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: uiSize(12)))
                .focused($focusedField, equals: .find)
                .onSubmit { onNext() }
                // TSK-1271: scroll keys would otherwise die in the focused find
                // field; forward them so the document still scrolls.
                .onKeyPress(.pageDown) { forwardScroll(.pageDown) }
                .onKeyPress(.pageUp) { forwardScroll(.pageUp) }
                .onKeyPress(.downArrow) { forwardScroll(.lineDown) }
                .onKeyPress(.upArrow) { forwardScroll(.lineUp) }
            if !query.isEmpty {
                Button {
                    query = ""
                    focusedField = .find
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: uiSize(11)))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(IconHoverButtonStyle(cornerRadius: uiSize(8)))
                .helpInfo(title: "Clear", description: "Clear the search field")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, uiSize(7))
        .padding(.vertical, uiSize(4))
        .background(
            RoundedRectangle(cornerRadius: uiSize(6), style: .continuous)
                .fill(Palette.textBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: uiSize(6), style: .continuous)
                .strokeBorder(Palette.separator, lineWidth: 1)
        )
        .frame(minWidth: uiSize(160), idealWidth: uiSize(220))
        .accessibilityIdentifier("\(accessibilityID).field")
    }

    @ViewBuilder
    private var countLabel: some View {
        switch noResultsMode {
        case .boolean(let matched):
            if !query.isEmpty, matched == false {
                Text("No results")
                    .font(.system(size: uiSize(11)))
                    .foregroundStyle(Color(nsColor: .systemOrange))
                    .accessibilityIdentifier("\(accessibilityID).noResults")
            }
        case .countOnly:
            if !matchSummary.isEmpty {
                Text(matchSummary)
                    .font(.system(size: uiSize(11)).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("\(accessibilityID).count")
            } else if !query.isEmpty {
                Text("No results")
                    .font(.system(size: uiSize(11)))
                    .foregroundStyle(Color(nsColor: .systemOrange))
                    .accessibilityIdentifier("\(accessibilityID).noResults")
            }
        }
    }

    /// Segmented previous/next stepper — the conventional macOS find-bar
    /// control. Return = next, Shift+Return = previous.
    private var stepper: some View {
        HStack(spacing: 0) {
            Button(action: onPrev) {
                Image(systemName: "chevron.left")
                    .font(.system(size: uiSize(11), weight: .semibold))
                    .frame(minWidth: uiSize(22))
            }
            .helpInfo(title: "Previous match", description: "Jump to the previous match (Shift+Return)")
            .keyboardShortcut(.return, modifiers: [.shift])
            .accessibilityLabel("Previous match")

            Divider().frame(height: uiSize(14))

            Button(action: onNext) {
                Image(systemName: "chevron.right")
                    .font(.system(size: uiSize(11), weight: .semibold))
                    .frame(minWidth: uiSize(22))
            }
            .helpInfo(title: "Next match", description: "Jump to the next match (Return)")
            .accessibilityLabel("Next match")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    // MARK: - Replace row

    private func disclosureButton(_ replace: ReplaceConfig) -> some View {
        let expanded = replace.isVisible.wrappedValue
        return Button {
            withAnimation(.easeInOut(duration: 0.12)) {
                replace.isVisible.wrappedValue.toggle()
            }
        } label: {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.system(size: uiSize(10), weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: uiSize(14))
        }
        .buttonStyle(IconHoverButtonStyle(cornerRadius: uiSize(4)))
        .helpInfo(title: expanded ? "Hide replace" : "Show replace",
                  description: "Toggle the replace row")
        .accessibilityLabel("Toggle replace row")
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        .accessibilityIdentifier("\(accessibilityID).replaceDisclosure")
    }

    private func replaceRow(_ replace: ReplaceConfig) -> some View {
        HStack(spacing: uiSize(8)) {
            // Spacer aligns the replace field's leading edge under the
            // search field's (accounting for the disclosure chevron).
            Color.clear.frame(width: uiSize(14), height: 1)

            replaceField(replace)

            Button {
                replace.onReplaceNext()
            } label: {
                Text("Replace")
                    .font(.system(size: uiSize(12)))
            }
            .controlSize(.small)
            .disabled(query.isEmpty)
            .helpInfo(title: "Replace", description: "Replace the current match")
            .accessibilityLabel("Replace")
            .accessibilityIdentifier("\(accessibilityID).replaceButton")

            Button {
                replace.onReplaceAll()
            } label: {
                Text("All")
                    .font(.system(size: uiSize(12)))
            }
            .controlSize(.small)
            .disabled(query.isEmpty)
            .helpInfo(title: "Replace all", description: "Replace every match")
            .accessibilityLabel("Replace all")
            .accessibilityIdentifier("\(accessibilityID).replaceAllButton")

            Spacer(minLength: 0)
        }
    }

    private func replaceField(_ replace: ReplaceConfig) -> some View {
        HStack(spacing: uiSize(5)) {
            Image(systemName: "arrow.2.squarepath")
                .font(.system(size: uiSize(11)))
                .foregroundStyle(.secondary)
            TextField("Replace with…", text: replace.replacement)
                .textFieldStyle(.plain)
                .font(.system(size: uiSize(12)))
                .focused($focusedField, equals: .replace)
                .onSubmit { replace.onReplaceNext() }
        }
        .padding(.horizontal, uiSize(7))
        .padding(.vertical, uiSize(4))
        .background(
            RoundedRectangle(cornerRadius: uiSize(6), style: .continuous)
                .fill(Palette.textBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: uiSize(6), style: .continuous)
                .strokeBorder(Palette.separator, lineWidth: 1)
        )
        .frame(minWidth: uiSize(160), idealWidth: uiSize(220))
        .accessibilityIdentifier("\(accessibilityID).replaceField")
    }

    /// True when the bar is in its visible "No results" state. Mirrors
    /// the rendering condition in `body` so the announcement fires for
    /// exactly the cases that paint the orange label.
    /// Forward a document-scroll key to `onScrollKey` (TSK-1271). Returns
    /// `.handled` only when a consumer is wired (the rendered bar); otherwise
    /// `.ignored`, so the key keeps its normal text-field behavior on surfaces
    /// that don't forward (source / editor).
    private func forwardScroll(_ key: ScrollKey) -> KeyPress.Result {
        guard let onScrollKey else { return .ignored }
        onScrollKey(key)
        return .handled
    }

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
    /// Zoom-scale function (`model.uiSize`). Defaults to identity so
    /// previews / tests can mount the bar without a model.
    var uiSize: (CGFloat) -> CGFloat = { $0 }

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
            accessibilityID: "mdv.renderedFindBar",
            uiSize: uiSize,
            // No `replace`: rendered markdown is read-only.
            // TSK-1271: forward scroll keys to the rendered webview so the user
            // can scroll the document while the find bar holds focus.
            onScrollKey: { key in
                switch key {
                case .pageDown: find.renderedScroll(.pageDown)
                case .pageUp: find.renderedScroll(.pageUp)
                case .lineDown: find.renderedScroll(.lineDown)
                case .lineUp: find.renderedScroll(.lineUp)
                }
            }
        )
    }
}

/// CM6 editor-mode find bar. Drives CodeMirror's built-in search
/// through the v1 bridge (`setSearchQuery` / `findNext` / `findPrev` /
/// `replaceNext` / `replaceAll`) rather than opening CM's panel. This
/// is the only editable surface, so it's the only bar that offers the
/// find-and-replace row.
struct EditorFindBar: View {
    @ObservedObject var find: FindCoordinator
    var uiSize: (CGFloat) -> CGFloat = { $0 }

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
            accessibilityID: "mdv.editorFindBar",
            uiSize: uiSize,
            replace: FindBar.ReplaceConfig(
                replacement: $find.editorReplacement,
                isVisible: $find.editorReplaceVisible,
                onReplaceNext: { find.editorReplaceNext() },
                onReplaceAll: { find.editorReplaceAll() }
            )
        )
    }
}

/// Source-mode find bar. Surfaces the match count [n/N] that
/// TextDisplayView publishes via its `onFindSummary` callback. The
/// source view is read-only, so no replace row.
struct SourceFindBar: View {
    @ObservedObject var find: FindCoordinator
    var uiSize: (CGFloat) -> CGFloat = { $0 }

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
            accessibilityID: "mdv.sourceFindBar",
            uiSize: uiSize
            // No `replace`: source view is read-only.
        )
    }
}
