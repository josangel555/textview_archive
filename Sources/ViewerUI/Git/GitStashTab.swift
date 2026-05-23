import SwiftUI
import ViewerCore

/// Stash sub-tab: read-only stash browser with per-row Apply / Pop /
/// Show / Drop. Drop confirms before invoking.
struct GitStashTab: View {
    @ObservedObject var model: GitPanelModel
    @ObservedObject var doc: DocumentModel
    @State private var pendingDrop: GitClient.StashEntry?
    @Environment(\.sidebarSectionBodyHeight) private var bodyHeight

    var body: some View {
        if model.stashEntries.isEmpty {
            Text("No stashes.")
                .font(.system(size: doc.uiSize(11)))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.stashEntries, id: \.ref) { row($0) }
                }
            }
            .frame(height: bodyHeight)
            .alert(item: $pendingDrop) { entry in
                Alert(
                    title: Text("Drop \(entry.ref)?"),
                    message: Text(entry.subject),
                    primaryButton: .destructive(Text("Drop")) {
                        guard let root = model.repoRoot else { return }
                        _ = GitClient(repoRoot: root).stashDrop(entry.ref)
                        model.refreshCurrent()
                    },
                    secondaryButton: .cancel()
                )
            }
        }
    }

    private func row(_ s: GitClient.StashEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(s.ref)
                    .font(.system(size: doc.uiSize(11), design: .monospaced))
                    .foregroundStyle(Color.accentColor)
                Spacer(minLength: 4)
                Text(relativeTime(s.timestamp))
                    .font(.system(size: doc.uiSize(9)))
                    .foregroundStyle(.tertiary)
            }
            Text(s.subject)
                .font(.system(size: doc.uiSize(12)))
                .foregroundStyle(.primary)
                .lineLimit(2)
            HStack(spacing: 6) {
                actionChip("Apply") { apply(s) }
                actionChip("Pop")   { pop(s) }
                actionChip("Show")  { show(s) }
                actionChip("Drop", danger: true) { pendingDrop = s }
                Spacer()
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func actionChip(_ label: String, danger: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: doc.uiSize(10), weight: .medium))
                .foregroundStyle(danger ? Color.red : .secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 2))
        }
        .buttonStyle(.plain)
    }

    private func apply(_ s: GitClient.StashEntry) {
        guard let root = model.repoRoot else { return }
        _ = GitClient(repoRoot: root).stashApply(s.ref)
        model.refreshCurrent()
    }

    private func pop(_ s: GitClient.StashEntry) {
        guard let root = model.repoRoot else { return }
        _ = GitClient(repoRoot: root).stashPop(s.ref)
        model.refreshCurrent()
    }

    private func show(_ s: GitClient.StashEntry) {
        guard let root = model.repoRoot else { return }
        let body = GitClient(repoRoot: root).stashShow(s.ref)
        let cache = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = cache.appendingPathComponent("MarkdownViewer/diffs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safeRef = s.ref.replacingOccurrences(of: "@", with: "-")
            .replacingOccurrences(of: "{", with: "")
            .replacingOccurrences(of: "}", with: "")
        let out = dir.appendingPathComponent("\(safeRef).diff")
        try? body.write(to: out, atomically: true, encoding: .utf8)
        doc.openInNewTab(out)
    }

    private func relativeTime(_ unix: Int) -> String {
        let then = Date(timeIntervalSince1970: TimeInterval(unix))
        let diff = Date().timeIntervalSince(then)
        switch diff {
        case ..<60:        return "just now"
        case ..<3600:      return "\(Int(diff / 60)) min ago"
        case ..<86_400:    return "\(Int(diff / 3600)) h ago"
        case ..<604_800:   return "yesterday"
        default:           return "\(Int(diff / 604_800)) wk ago"
        }
    }
}

extension GitClient.StashEntry: Identifiable {
    public var id: String { ref }
}
