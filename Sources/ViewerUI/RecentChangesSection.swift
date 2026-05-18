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
                // File-type icon for visual parity with the sidebar.
                // Cheap — FileIconView caches by extension internally.
                FileIconView(
                    url: resolvedURL(for: entry),
                    isDirectory: false,
                    size: .tree
                )
                .frame(width: 14, height: 14)
                Text(entry.path)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                // Right-side button: open the unified diff for this
                // path in a new tab. Hidden until hover so the row
                // stays clean.
                Button(action: { showDiff(entry) }) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Show diff")
            }
            .padding(.horizontal, 10)
            .frame(height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(entry.path)
        .contextMenu {
            Button("Open File") { openEntry(entry) }
            Button("Show Diff") { showDiff(entry) }
        }
    }

    /// Pure repo discovery: sidebar root takes precedence (matches the
    /// "current folder" intent); fall back to the open file's directory
    /// so a file-only open inside a repo still lights up. Extracted so
    /// the rule is unit-testable without spinning up a SwiftUI view.
    internal static func discoverRepo(sidebarRoot: URL?, currentURL: URL?) -> URL? {
        let probe = sidebarRoot ?? currentURL?.deletingLastPathComponent()
        return probe.flatMap(GitClient.discoverRoot(from:))
    }

    /// Write the unified diff for `entry.path` to a tmp file and open
    /// it as a tab. Lives under ~/Library/Caches so the cleaner reaps
    /// it; safe to overwrite per session.
    ///
    /// Filename: `<basename>-<hex-hash>.diff`. The hash defeats the
    /// `a/b` ↔ `a_b` collision the old `replacingOccurrences("/", "_")`
    /// approach allowed; the basename keeps the tab title legible.
    private func showDiff(_ entry: GitClient.StatusEntry) {
        guard let root = repoRoot else { return }
        let client = GitClient(repoRoot: root)
        let diff = client.diff(forPath: entry.path)
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = cache.appendingPathComponent("MarkdownViewer/diffs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Hash the full repo-relative path so distinct paths can't
        // collide on the cache filesystem. 8 hex chars is plenty for
        // an in-cache uniqueness guarantee.
        var hasher = Hasher()
        hasher.combine(entry.path)
        let hashHex = String(UInt(bitPattern: hasher.finalize()), radix: 16)
            .padding(toLength: 8, withPad: "0", startingAt: 0)
            .prefix(8)
        let base = (entry.path as NSString).lastPathComponent
        let out = dir.appendingPathComponent("\(base)-\(hashHex).diff")
        // Empty diff → still write the file so the tab opens with a
        // placeholder; otherwise the user clicks "Show Diff" and
        // nothing visibly happens.
        let body: String
        if diff.isEmpty {
            body = "(no diff output — file may be unchanged at HEAD or " +
                   "untracked. Path: \(entry.path))\n"
        } else {
            body = diff
        }
        try? body.write(to: out, atomically: true, encoding: .utf8)
        model.openInNewTab(out)
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

    /// URL to derive the file-type icon from. Synthesizes one from the
    /// path even when the repo root isn't resolved yet — FileIconView
    /// only uses the lastPathComponent extension, so a non-existent
    /// URL is fine for the icon lookup.
    private func resolvedURL(for e: GitClient.StatusEntry) -> URL {
        if let root = repoRoot {
            return root.appendingPathComponent(e.path)
        }
        return URL(fileURLWithPath: e.path)
    }

    private func refresh() {
        refreshTask?.cancel()
        repoRoot = Self.discoverRepo(
            sidebarRoot: model.sidebar.rootURL,
            currentURL: model.currentURL
        )
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
