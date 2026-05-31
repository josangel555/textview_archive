import SwiftUI
import ViewerCore

/// Folder / repo statistics card (PRIORITIZED_PLAN item 15). Compact
/// summary intended to slide down inline under the FILES header
/// (`SidebarView.filesHeader` — wiring owned by stage 2b). Shows commit
/// count, active date span, a top-N author leaderboard with proportional
/// bars, and a tracked-file extension breakdown. No charts library —
/// the bars are plain `Capsule`s sized by `GeometryReader`-free
/// fractional widths.
///
/// Fetch is lazy (first appear), off-main, HEAD-invalidate-cached via
/// the shared `RepoStatsCache`. The host passes a fresh `scope` /
/// `repoRoot`; on change the view reloads. Hidden-when-not-a-repo gating
/// is the HOST's job (mirror `GitClient.discoverRoot(from:) != nil`),
/// kept out of this view so it stays a pure renderer.
struct FolderStatsView: View {
    @ObservedObject var doc: DocumentModel
    @StateObject private var model: FolderStatsModel

    /// `repoRoot` is the discovered repository root; `scope` selects
    /// whole-repo vs folder-subdir aggregation; `cache` is the shared
    /// HEAD-invalidated cache (host owns its lifetime so it survives
    /// across reopens). `title` is the label shown in the card header.
    init(
        doc: DocumentModel,
        repoRoot: URL,
        scope: GitClient.RepoStatsScope,
        cache: RepoStatsCache,
        title: String
    ) {
        self.doc = doc
        _model = StateObject(wrappedValue: FolderStatsModel(
            repoRoot: repoRoot, scope: scope, cache: cache, title: title))
    }

    /// How many authors / extensions to surface in the card.
    private let topAuthors = 5
    private let topExtensions = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.isLoading {
                loadingRow
            } else if let stats = model.stats {
                content(stats)
            } else {
                Text("No statistics available.")
                    .font(.system(size: doc.uiSize(11)))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { model.loadIfNeeded() }
        // Host may swap the scope/root for the same view instance.
        .onChange(of: model.scopeKey) { _, _ in model.reload() }
    }

    private var loadingRow: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("Computing statistics…")
                .font(.system(size: doc.uiSize(11)))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func content(_ stats: GitClient.RepoStats) -> some View {
        header(stats)

        if !stats.authors.isEmpty {
            sectionTitle("Top authors")
            let maxCount = stats.authors.first?.commitCount ?? 1
            ForEach(Array(stats.authors.prefix(topAuthors)), id: \.email) { author in
                authorRow(author, maxCount: max(maxCount, 1))
            }
        }

        if !stats.extensions.isEmpty {
            sectionTitle("File types")
            let maxFiles = stats.extensions.first?.fileCount ?? 1
            ForEach(Array(stats.extensions.prefix(topExtensions)), id: \.ext) { ext in
                extensionRow(ext, maxFiles: max(maxFiles, 1))
            }
        }
    }

    // MARK: - Header (commit count + date span + file count)

    private func header(_ stats: GitClient.RepoStats) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                metric("\(stats.totalCommits)", "commit\(stats.totalCommits == 1 ? "" : "s")")
                metric("\(stats.trackedFileCount)", "file\(stats.trackedFileCount == 1 ? "" : "s")")
                metric("\(stats.authors.count)", "author\(stats.authors.count == 1 ? "" : "s")")
            }
            if let span = dateSpan(stats) {
                Text(span)
                    .font(.system(size: doc.uiSize(9)))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(.system(size: doc.uiSize(15), weight: .semibold,
                              design: .rounded))
            Text(label)
                .font(.system(size: doc.uiSize(8)))
                .textCase(.uppercase)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Author leaderboard

    private func authorRow(_ author: GitClient.AuthorStat, maxCount: Int) -> some View {
        let fraction = CGFloat(author.commitCount) / CGFloat(maxCount)
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(author.name.isEmpty ? author.email : author.name)
                    .font(.system(size: doc.uiSize(10)))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text("\(author.commitCount)")
                    .font(.system(size: doc.uiSize(10), design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            proportionBar(fraction: fraction, color: .accentColor)
        }
    }

    // MARK: - Extension histogram

    private func extensionRow(_ ext: GitClient.ExtensionStat, maxFiles: Int) -> some View {
        let fraction = CGFloat(ext.fileCount) / CGFloat(maxFiles)
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(ext.ext.isEmpty ? "(no ext)" : ".\(ext.ext)")
                    .font(.system(size: doc.uiSize(10), design: .monospaced))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(ext.fileCount)")
                    .font(.system(size: doc.uiSize(10), design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            proportionBar(fraction: fraction, color: .secondary)
        }
    }

    // MARK: - Shared bits

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: doc.uiSize(9), weight: .semibold))
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
            .padding(.top, 2)
    }

    /// A proportional bar without `GeometryReader` — an outer fixed-track
    /// `Capsule` with a fractional-width fill overlaid, clamped to a sane
    /// minimum so a 1-commit author still shows a sliver.
    private func proportionBar(fraction: CGFloat, color: Color) -> some View {
        let clamped = min(max(fraction, 0), 1)
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(color.opacity(0.12))
                Capsule()
                    .fill(color.opacity(0.55))
                    .frame(width: max(geo.size.width * clamped, 2))
            }
        }
        .frame(height: 4)
    }

    // MARK: - Formatting

    private func dateSpan(_ stats: GitClient.RepoStats) -> String? {
        guard let first = stats.firstCommitDate, let last = stats.lastCommitDate else {
            return nil
        }
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .none
        let a = fmt.string(from: first)
        let b = fmt.string(from: last)
        return a == b ? a : "\(a) – \(b)"
    }
}

/// View-model for `FolderStatsView`. Lazy off-main fetch through the
/// shared `RepoStatsCache` (HEAD-invalidated). Narrow `@Published`
/// surface; cancels a prior load before starting a new one.
@MainActor
final class FolderStatsModel: ObservableObject {
    let repoRoot: URL
    let scope: GitClient.RepoStatsScope
    let title: String
    private let cache: RepoStatsCache

    @Published private(set) var stats: GitClient.RepoStats?
    @Published private(set) var isLoading = false

    /// Stable identity for the current (root, scope) so the view can
    /// `.onChange` to detect a host-driven swap.
    let scopeKey: String

    private var loadTask: Task<Void, Never>?
    private var loaded = false

    init(repoRoot: URL, scope: GitClient.RepoStatsScope, cache: RepoStatsCache, title: String) {
        self.repoRoot = repoRoot
        self.scope = scope
        self.cache = cache
        self.title = title
        switch scope {
        case .repo:
            self.scopeKey = repoRoot.path + "|repo"
        case .folder(let rel):
            self.scopeKey = repoRoot.path + "|" + rel
        }
    }

    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        reload()
    }

    func reload() {
        loadTask?.cancel()
        isLoading = true
        let root = repoRoot
        let scope = scope
        let cache = cache
        loadTask = Task { @MainActor [weak self] in
            let result = await cache.stats(repoRoot: root, scope: scope)
            guard let self, !Task.isCancelled else { return }
            self.stats = result
            self.isLoading = false
        }
    }
}
