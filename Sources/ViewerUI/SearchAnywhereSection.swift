import SwiftUI
import ViewerCore

/// Sidebar widget that searches across every file under the current
/// sidebar root. Lives next to BookmarksSection — collapsible, no
/// modal popup. Reuses `CrossFileSearch` so we don't reinvent the
/// scanner; the existing search-panel modal (#56) can be removed
/// later once this proves itself.
///
/// UX:
///   - Header with title + result-count chip; collapsible
///   - Search field that runs the search live on each keystroke
///   - Result list: file path + each match line; click a match to
///     open the file at that line
///   - Empty state: prompt to type
struct SearchAnywhereSection: View {
    @ObservedObject var model: DocumentModel
    @State private var isExpanded = true
    @State private var query: String = ""
    @State private var caseSensitive: Bool = false
    @State private var results: [CrossFileSearch.FileMatches] = []
    @State private var isRunning: Bool = false
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            header
            if isExpanded {
                searchField
                if !results.isEmpty || isRunning {
                    Divider()
                    resultList
                }
            }
        }
        .accessibilityIdentifier("mdv.searchAnywhere")
    }

    private var header: some View {
        Button(action: { isExpanded.toggle() }) {
            HStack(spacing: 4) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 10)
                Text("SEARCH")
                    .font(.system(size: model.uiSize(10), weight: .semibold))
                    .foregroundStyle(.secondary)
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
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
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
                }.buttonStyle(.plain)
            }
            Toggle(isOn: $caseSensitive) {
                Text("Aa")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(caseSensitive ? .primary : .secondary)
            }
            .toggleStyle(.button)
            .controlSize(.mini)
            .help("Match case")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private var resultList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(results) { file in
                    fileGroup(file)
                }
            }
        }
        .frame(height: SidebarConstants.sectionBodyHeight)
    }

    @ViewBuilder
    private func fileGroup(_ file: CrossFileSearch.FileMatches) -> some View {
        Text(file.url.lastPathComponent)
            .font(.system(size: model.uiSize(11), weight: .semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .help(file.url.path)
        ForEach(file.matches.indices, id: \.self) { idx in
            let m = file.matches[idx]
            Button(action: { open(file.url) }) {
                HStack(alignment: .top, spacing: 6) {
                    Text("\(m.lineNumber)")
                        .font(.system(size: model.uiSize(10), design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .frame(width: 32, alignment: .trailing)
                    Text(m.line.trimmingCharacters(in: .whitespaces))
                        .font(.system(size: model.uiSize(11), design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var totalMatchCount: Int {
        results.reduce(0) { $0 + $1.matches.count }
    }

    private func open(_ url: URL) {
        model.openPath(url)
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
        guard let root = model.sidebar.rootURL else { return }
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
