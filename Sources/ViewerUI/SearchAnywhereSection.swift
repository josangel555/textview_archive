import AppKit
import SwiftUI
import ViewerCore
import ViewerKit

/// Sidebar widget that searches across every file under the current
/// sidebar root. Lives next to BookmarksSection — collapsible, no
/// modal popup. Reuses `CrossFileSearch` so we don't reinvent the
/// scanner; the existing search-panel modal (#56) can be removed
/// later once this proves itself.
///
/// UX:
///   - Header with title + result-count chip; collapsible
///   - Search field that runs the search live on each keystroke
///   - Scope row: shows the folder being searched (basename;
///     tooltip = full path) with a menu picker to switch to
///     "Sidebar Folder" or a one-off "Pick Folder…" via
///     NSOpenPanel. Mirrors the modal `CrossSearchPanel`'s scope
///     picker — same `SearchScope` value type + resolver.
///   - Result list: file path + each match line; click a match to
///     open the file at that line
///   - Empty state: prompt to type
///
/// Divider audit (2026-05): the body intentionally contains
/// **zero** `Divider()` calls. The only visible horizontal line
/// below this section is the `ResizableSectionDivider` injected by
/// `SidebarView` between this section and the next — that lives
/// outside the section. An old inner `Divider()` between the
/// search field and the result list was the spurious "extra line
/// under SEARCH ANYWHERE" the user reported; it's gone. If a new
/// `Divider()` is reintroduced here, `SearchAnywhereSectionLayoutTests`
/// will fail and steer the change toward an explicit decision.
struct SearchAnywhereSection: View {
    @ObservedObject var model: DocumentModel
    /// PERF #1: observe sidebar directly. The section body reads
    /// `sidebar.rootURL` from the scope picker (disable state +
    /// fallback resolution + label); without this, sidebar-driven
    /// re-renders would have required the (removed) DocumentModel-
    /// wide objectWillChange forwarding.
    @ObservedObject var sidebar: SidebarModel
    @State private var isExpanded = true
    @State private var query: String = ""
    @State private var caseSensitive: Bool = false
    @State private var results: [CrossFileSearch.FileMatches] = []
    @State private var isRunning: Bool = false
    @State private var searchTask: Task<Void, Never>?
    @Environment(\.sidebarSectionBodyHeight) private var bodyHeight

    // MARK: - Scope picker
    //
    // Mirrors the modal `CrossSearchPanel`'s scope picker so the
    // side-pane widget shows which folder it's searching and lets
    // the user point it elsewhere without opening the modal. Default
    // is `.activeFolder` (the sidebar root); the user can Pick
    // Folder… via NSOpenPanel for a one-off search elsewhere.
    @State private var scope: SearchScope = .activeFolder

    var body: some View {
        VStack(spacing: 0) {
            header
            if isExpanded {
                searchField
                scopeRow
                resultList
            }
        }
        .sidebarSectionContainer()
        .accessibilityIdentifier("mdv.searchAnywhere")
    }

    private var header: some View {
        Button(action: { isExpanded.toggle() }) {
            HStack(spacing: 4) {
                SidebarSectionHeaderLabel(
                    title: "Search",
                    isExpanded: isExpanded,
                    uiSize: model.uiSize
                )
                Spacer()
                if isRunning {
                    ProgressView().controlSize(.mini)
                } else if !results.isEmpty {
                    Text("\(totalMatchCount)")
                        .font(.system(size: model.uiSize(10), weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sidebarHeaderRow()
    }

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: model.uiSize(11)))
                .foregroundStyle(.secondary)
            TextField("Search files…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: model.uiSize(12)))
                .onChange(of: query) { _, new in runSearch(new) }
                .onChange(of: caseSensitive) { _, _ in runSearch(query) }
            if !query.isEmpty {
                Button(action: { query = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: model.uiSize(11)))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
            Toggle(isOn: $caseSensitive) {
                Text("Aa")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(caseSensitive ? .primary : .secondary)
            }
            .toggleStyle(.button)
            .controlSize(.mini)
            .help("Match case")
            .accessibilityLabel("Match case")
            .accessibilityValue(caseSensitive ? "On" : "Off")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    // MARK: - Scope picker UI
    //
    // One-line "scope: <path> [▼]" row sitting between the search
    // field and the result list. The label is the resolved URL
    // (basename for compactness; the full path is the tooltip);
    // the menu picker mirrors the modal panel's options minus
    // file-shaped scopes (this section only runs folder grep).

    /// Resolved URL the engine runs against. Same resolution rules
    /// as the modal `CrossSearchPanel` — folder-shaped scopes only
    /// (a single-file scope falls back to the sidebar root, since
    /// this section's engine is folder grep).
    private var resolvedScopeURL: URL? {
        if SearchScopeResolver.needsFolderFallback(
            scope: scope,
            modeRequiresFolder: true
        ) {
            return sidebar.rootURL
        }
        return SearchScopeResolver.resolve(
            scope,
            activeFile: model.currentURL,
            activeFolder: sidebar.rootURL
        )
    }

    private var scopeDisplayName: String {
        if let url = resolvedScopeURL {
            return url.lastPathComponent
        }
        return "No folder"
    }

    private var scopeRow: some View {
        HStack(spacing: 4) {
            Image(systemName: "folder")
                .font(.system(size: model.uiSize(10)))
                .foregroundStyle(.secondary)
            Text(scopeDisplayName)
                .font(.system(size: model.uiSize(11), design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(resolvedScopeURL?.path ?? "No folder selected")
                .accessibilityIdentifier("mdv.searchAnywhere.scopeLabel")
            Spacer(minLength: 4)
            Menu {
                Button {
                    scope = .activeFolder
                } label: {
                    Label("Sidebar Folder", systemImage: "folder")
                }
                .disabled(sidebar.rootURL == nil)
                .accessibilityIdentifier("mdv.searchAnywhere.scope.activeFolder")

                Button {
                    pickFolder()
                } label: {
                    Label("Pick Folder…", systemImage: "folder.badge.plus")
                }
                .accessibilityIdentifier("mdv.searchAnywhere.scope.pickFolder")

                // "Clear Picked Folder" appears only when a custom
                // folder is selected; collapses back to the sidebar
                // folder. No `Divider()` inside this menu — the
                // section's pin-test enforces zero `Divider()` calls
                // in the file (see header comment + the layout test).
                if case .pickedFolder = scope {
                    Button {
                        scope = .activeFolder
                    } label: {
                        Label("Clear Picked Folder", systemImage: "arrow.uturn.backward")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: model.uiSize(11)))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Change search scope")
            .accessibilityIdentifier("mdv.searchAnywhere.scopePicker")
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
        .onChange(of: scope) { _, _ in runSearch(query) }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Pick folder to search"
        if panel.runModal() == .OK, let url = panel.url {
            scope = .pickedFolder(url)
        }
    }

    private var resultList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if results.isEmpty && !isRunning {
                    SidebarEmptyPlaceholder(
                        message: query.trimmingCharacters(in: .whitespaces).count >= 2
                            ? "No matches."
                            : "Type to search files…"
                    )
                }
                ForEach(results) { file in
                    fileGroup(file)
                }
            }
        }
        // Fixed envelope — short matches and "type to search" empty
        // state both occupy the same height as a populated list.
        .frame(height: bodyHeight)
    }

    @ViewBuilder
    private func fileGroup(_ file: CrossFileSearch.FileMatches) -> some View {
        Text(highlighted(
            file.url.lastPathComponent,
            baseColor: .primary
        ))
            .font(.system(size: model.uiSize(11), weight: .semibold))
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .help(file.url.path)
        ForEach(file.matches.indices, id: \.self) { idx in
            let m = file.matches[idx]
            // MARK: - Search result jump (jump-wiring agent)
            // Click a match row: open the file AND scroll/select the
            // matched 1-based line. Routes through `openPath(_:atLine:)`
            // which handles the rendered→source mode coercion plus the
            // editor-vs-source dispatch.
            Button(action: { open(file.url, line: m.lineNumber) }) {
                HStack(alignment: .top, spacing: 6) {
                    Text("\(m.lineNumber)")
                        .font(.system(size: model.uiSize(10), design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .frame(width: 32, alignment: .trailing)
                    Text(highlighted(
                        m.line.trimmingCharacters(in: .whitespaces),
                        baseColor: .secondary
                    ))
                        .font(.system(size: model.uiSize(11), design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            // UIRESP-11: search-result rows read as clickable (open the
            // file at the matched line) with hover + pointing-hand cursor.
            .buttonStyle(RowHoverButtonStyle(cornerRadius: 0))
            .accessibilityLabel("\(file.url.lastPathComponent) line \(m.lineNumber): \(m.line)")
        }
    }

    private var totalMatchCount: Int {
        results.reduce(0) { $0 + $1.matches.count }
    }

    private func open(_ url: URL) {
        model.openPath(url)
    }

    /// Open the file and jump to a specific 1-based line. Used by the
    /// per-match rows so the editor lands directly on the matched line.
    private func open(_ url: URL, line: Int) {
        model.openPath(url, atLine: line)
    }

    /// Wraps `HighlightedText.ranges` and applies the same accent
    /// emphasis used by the command palette's match treatment: matched
    /// substrings switch to `Color.accentColor` + semibold weight, on
    /// top of `baseColor` for unmatched text. Honors the section's
    /// case-sensitivity toggle.
    private func highlighted(_ text: String, baseColor: Color) -> AttributedString {
        var attr = AttributedString(text)
        attr.foregroundColor = baseColor
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, !text.isEmpty else { return attr }
        let ranges = HighlightedText.ranges(
            in: text,
            query: query,
            mode: .literal(caseSensitive: caseSensitive)
        )
        guard !ranges.isEmpty else { return attr }
        for r in ranges {
            // Map String.Index → AttributedString.Index via UTF-8
            // offsets. AttributedString indexes by character but
            // exposes `index(_:offsetByCharacters:)` on character
            // counts — and our ranges come from a Swift String, where
            // `distance(from:to:)` returns Character counts. That's
            // the same unit, so the offset hops are 1:1.
            let lowerDist = text.distance(from: text.startIndex, to: r.lowerBound)
            let upperDist = text.distance(from: text.startIndex, to: r.upperBound)
            let lo = attr.index(attr.startIndex, offsetByCharacters: lowerDist)
            let hi = attr.index(attr.startIndex, offsetByCharacters: upperDist)
            attr[lo..<hi].foregroundColor = .accentColor
            attr[lo..<hi].font = .system(size: model.uiSize(11), weight: .semibold)
        }
        return attr
    }

    /// Debounced async scan via CrossFileSearch. The throttle prevents
    /// running a fresh scan on every keystroke for typing-speed input.
    private func runSearch(_ q: String) {
        searchTask?.cancel()
        guard q.trimmingCharacters(in: .whitespaces).count >= 2 else {
            results = []
            isRunning = false
            return
        }
        guard let root = resolvedScopeURL else { return }
        let caseSensitive = self.caseSensitive
        isRunning = true
        searchTask = Task.detached(priority: .userInitiated) {
            // 200ms debounce window.
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }
            let opts = CrossFileSearch.Options(caseSensitive: caseSensitive)
            let found = CrossFileSearch.search(root: root, query: q, options: opts)
            if Task.isCancelled { return }
            await MainActor.run {
                self.results = found
                self.isRunning = false
            }
        }
    }
}
