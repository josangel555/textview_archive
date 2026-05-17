import SwiftUI
import ViewerCore

/// Log sub-tab: chronological / topological commit list. v1 is a flat
/// list with the head/branch chips called out; task #130 lands the
/// topological graph renderer.
struct GitLogTab: View {
    @ObservedObject var model: GitPanelModel
    @ObservedObject var doc: DocumentModel

    /// Computed layout — recomputed when logEntries change. Returns nil
    /// when the graph would need >4 lanes; the body falls back to a
    /// dotless flat list in that case (matches spec).
    private var layout: GraphLayout.Layout? {
        GraphLayout.layout(model.logEntries, maxLanes: 4)
    }

    var body: some View {
        if model.logEntries.isEmpty {
            Text("No commits in this repository yet.")
                .font(.system(size: doc.uiSize(11)))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        } else {
            let lay = layout
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if lay == nil {
                        Text("graph too wide — falling back to flat list")
                            .font(.system(size: doc.uiSize(9)))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 10)
                            .padding(.top, 4)
                    }
                    ForEach(Array(model.logEntries.enumerated()), id: \.offset) { idx, c in
                        row(c, layoutRow: lay?.rows[idx], maxLane: lay?.maxLane ?? -1)
                            .onAppear {
                                if c.sha == model.logEntries.last?.sha {
                                    model.loadMoreLog()
                                }
                            }
                    }
                    if model.logLoadedCount >= model.logHardCap {
                        Text("Showing first \(model.logHardCap) commits — use the terminal for the full history.")
                            .font(.system(size: doc.uiSize(10)))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                    }
                }
            }
            .frame(maxHeight: 320)
        }
    }

    private func row(_ c: GitClient.GraphCommit,
                     layoutRow: GraphLayout.Row?,
                     maxLane: Int) -> some View {
        Button(action: { showCommit(c) }) {
            HStack(alignment: .top, spacing: 8) {
                if let r = layoutRow {
                    GitGraphColumn(row: r, maxLane: maxLane, isHead: isHead(c))
                        .frame(minHeight: 38)
                }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(c.sha)
                            .font(.system(size: doc.uiSize(10), design: .monospaced))
                            .foregroundStyle(Color.accentColor)
                        if isHead(c) {
                            chip("HEAD", color: .accentColor)
                        }
                        ForEach(branchRefs(c), id: \.self) { ref in
                            Text("⎇ \(ref)")
                                .font(.system(size: doc.uiSize(9)))
                                .foregroundStyle(Color.accentColor)
                        }
                        Spacer(minLength: 4)
                        Text(relativeTime(c.timestamp))
                            .font(.system(size: doc.uiSize(9)))
                            .foregroundStyle(.tertiary)
                    }
                    Text(c.subject)
                        .font(.system(size: doc.uiSize(12),
                                      weight: c.isMerge ? .regular : .medium))
                        .foregroundStyle(c.isMerge ? Color.secondary : Color.primary)
                        .lineLimit(2)
                    Text(authorLine(c))
                        .font(.system(size: doc.uiSize(10)))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(c.sha) — \(c.subject)")
    }

    private func chip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: doc.uiSize(8), weight: .heavy))
            .tracking(0.5)
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 2))
    }

    // MARK: - HEAD / branch detection

    private func isHead(_ c: GitClient.GraphCommit) -> Bool {
        guard let head = model.head else { return false }
        return c.sha == head.sha
    }

    /// Decoration refs minus "HEAD" itself.
    private func branchRefs(_ c: GitClient.GraphCommit) -> [String] {
        c.refs.compactMap { ref -> String? in
            if ref == "HEAD" { return nil }
            if ref.hasPrefix("HEAD -> ") { return String(ref.dropFirst("HEAD -> ".count)) }
            if ref.hasPrefix("tag: ") { return ref }
            return ref
        }
    }

    // MARK: - Formatting

    private func authorLine(_ c: GitClient.GraphCommit) -> String {
        var parts = [c.author]
        if c.filesChanged > 0 {
            parts.append("\(c.filesChanged) file\(c.filesChanged == 1 ? "" : "s")")
        }
        if c.insertions + c.deletions > 0 {
            parts.append("+\(c.insertions) −\(c.deletions)")
        }
        return parts.joined(separator: " · ")
    }

    private func relativeTime(_ unix: Int) -> String {
        let then = Date(timeIntervalSince1970: TimeInterval(unix))
        let diff = Date().timeIntervalSince(then)
        switch diff {
        case ..<60:        return "just now"
        case ..<3600:      return "\(Int(diff / 60)) min ago"
        case ..<86_400:    return "\(Int(diff / 3600)) h ago"
        case ..<604_800:   return "\(Int(diff / 86_400)) d ago"
        default:           return "\(Int(diff / 604_800)) wk ago"
        }
    }

    /// Show a synthetic commit-diff tab. v1: writes `git show` output
    /// to a .diff file (same trick as Status tab). Task #131 replaces
    /// this with a proper in-app DiffView.
    private func showCommit(_ c: GitClient.GraphCommit) {
        guard let root = model.repoRoot else { return }
        let client = GitClient(repoRoot: root)
        let body = client.commitDiff(sha: c.sha)
        let cache = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = cache.appendingPathComponent("MarkdownViewer/diffs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent("\(c.sha).diff")
        try? body.write(to: out, atomically: true, encoding: .utf8)
        doc.openInNewTab(out)
    }
}
