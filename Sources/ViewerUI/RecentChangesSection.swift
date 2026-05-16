import SwiftUI
import ViewerCore

/// Sidebar widget showing files changed in the current git repo's
/// working tree. Lives next to Bookmarks + Search. Reads `git status
/// --porcelain` on demand + on tab change. No background daemon —
/// updates when the user clicks the refresh icon or switches files.
///
/// Hidden when the sidebar root isn't inside a git repository.
struct RecentChangesSection: View {
    @ObservedObject var model: DocumentModel
    @State private var isExpanded = true
    @State private var entries: [GitClient.StatusEntry] = []
    @State private var repoRoot: URL?
    @State private var refreshTask: Task<Void, Never>?

    var body: some View {
        Group {
            if repoRoot != nil {
                VStack(spacing: 0) {
                    header
                    if isExpanded { list }
                }
            } else {
                EmptyView()
            }
        }
        .onAppear { refresh() }
        .onChange(of: model.sidebar.rootURL) { _, _ in refresh() }
        // Also re-discover when the current file changes — opening a
        // file inside a different repo (or a file with no folder root
        // set) should still light up the section.
        .onChange(of: model.currentURL) { _, _ in refresh() }
        .accessibilityIdentifier("mdv.recentChanges")
    }

    private var header: some View {
        HStack(spacing: 4) {
            Button(action: { isExpanded.toggle() }) {
                HStack(spacing: 4) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 10)
                    Text("CHANGED")
                        .font(.system(size: model.uiSize(10), weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !entries.isEmpty {
                        Text("\(entries.count)")
                            .font(.system(size: model.uiSize(10), weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                    Button(action: { refresh() }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Refresh")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if entries.isEmpty {
                    Text("Working tree clean")
                        .font(.system(size: model.uiSize(11)))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                } else {
                    ForEach(entries, id: \.path) { entry in
                        row(entry)
                    }
                }
            }
        }
        .frame(maxHeight: 220)
    }

    private func row(_ entry: GitClient.StatusEntry) -> some View {
        Button(action: { openEntry(entry) }) {
            HStack(spacing: 6) {
                Text(statusBadge(entry))
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(statusColor(entry))
                    .frame(width: 18, alignment: .center)
                Text(entry.path)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(entry.path)
    }

    private func statusBadge(_ e: GitClient.StatusEntry) -> String {
        if e.isUntracked { return "?" }
        // Index column wins for display when both are set.
        switch e.indexStatus {
        case "M": return "M"
        case "A": return "A"
        case "D": return "D"
        case "R": return "R"
        case "C": return "C"
        default:
            switch e.workingStatus {
            case "M": return "M"
            case "D": return "D"
            default: return "•"
            }
        }
    }

    private func statusColor(_ e: GitClient.StatusEntry) -> Color {
        if e.isUntracked { return .gray }
        switch e.indexStatus {
        case "A": return .green
        case "D": return .red
        case "M": return .yellow
        default:
            switch e.workingStatus {
            case "M": return .yellow
            case "D": return .red
            default: return .secondary
            }
        }
    }

    private func openEntry(_ e: GitClient.StatusEntry) {
        guard let root = repoRoot else { return }
        let url = root.appendingPathComponent(e.path)
        if FileManager.default.fileExists(atPath: url.path) {
            model.openPath(url)
        }
    }

    private func refresh() {
        refreshTask?.cancel()
        // Discover repo root from whichever signal we have. Sidebar
        // root takes precedence (matches the user's "current folder"
        // intent); fall back to the open file's directory so a
        // file-only open inside a repo still lights up.
        let probe = model.sidebar.rootURL
            ?? model.currentURL?.deletingLastPathComponent()
        repoRoot = probe.flatMap(GitClient.discoverRoot(from:))
        guard let root = repoRoot else {
            entries = []
            return
        }
        refreshTask = Task.detached(priority: .utility) {
            let client = GitClient(repoRoot: root)
            let status = client.status()
            await MainActor.run { self.entries = status }
        }
    }
}
