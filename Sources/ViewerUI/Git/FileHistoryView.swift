import SwiftUI
import ViewerCore

/// In-app File History view (PRIORITIZED_PLAN item 14, decision #6:
/// **in-app tab**, session-aware — NOT a standalone window). Master-
/// detail: a left `Table` of per-file commits (short SHA · date ·
/// author · subject), a right pane reusing the existing `DiffView`.
///
/// Selection state machine (`FileHistoryModel.SelectionMode`):
///   - **single** commit: right pane shows EITHER that commit's own
///     change (`diff <sha>~ <sha>`) OR the commit vs the working tree
///     (`diff <sha> -- path`), toggled by the segmented control.
///   - **range** (Cmd-click a second commit): right pane shows
///     `diff <a> <b> -- path` between the two selected commits, using
///     full SHAs so abbreviation collisions can't pick the wrong commit.
///
/// All git work (history load + diff) runs off-main via the model's
/// `Task.detached`; the view only renders. No `objectWillChange`
/// wholesale subscription — the model exposes narrow `@Published`
/// fields the view observes.
struct FileHistoryView: View {
    @ObservedObject var doc: DocumentModel
    @StateObject private var model: FileHistoryModel

    /// `repoRoot` is the repository working-tree root; `relativePath` is
    /// the file's path RELATIVE to that root (what `git log -- <path>`
    /// expects). `displayName` is the leaf shown in the header.
    init(doc: DocumentModel, repoRoot: URL, relativePath: String, displayName: String) {
        self.doc = doc
        _model = StateObject(wrappedValue: FileHistoryModel(
            repoRoot: repoRoot, relativePath: relativePath, displayName: displayName))
    }

    var body: some View {
        HSplitView {
            commitList
                .frame(minWidth: 260, idealWidth: 320, maxWidth: 480)
            detail
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { model.loadIfNeeded() }
    }

    // MARK: - Left: commit list

    private var commitList: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if model.isLoadingHistory {
                centeredPlaceholder("Loading history…")
            } else if model.commits.isEmpty {
                centeredPlaceholder("No history for this file.")
            } else {
                List(selection: Binding(
                    get: { model.primarySelection },
                    set: { if let sha = $0 { model.click(sha: sha, command: false) } }
                )) {
                    ForEach(model.commits, id: \.fullSHA) { commit in
                        commitRow(commit)
                            .tag(commit.fullSHA)
                    }
                }
                .listStyle(.inset)
            }
        }
        .background(Palette.textBackground)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: doc.uiSize(11)))
                    .foregroundStyle(.secondary)
                Text(model.displayName)
                    .font(.system(size: doc.uiSize(12), weight: .semibold,
                                  design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text("\(model.commits.count) commit\(model.commits.count == 1 ? "" : "s")")
                .font(.system(size: doc.uiSize(10)))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func commitRow(_ commit: GitClient.LogEntry) -> some View {
        // A row is highlighted as a range endpoint when it's one of the
        // two Cmd-selected SHAs.
        let isRangeEndpoint = model.rangeSelection.contains(commit.fullSHA)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(commit.sha)
                    .font(.system(size: doc.uiSize(10), design: .monospaced))
                    .foregroundStyle(Color.accentColor)
                if isRangeEndpoint {
                    Image(systemName: "circle.fill")
                        .font(.system(size: doc.uiSize(6)))
                        .foregroundStyle(Color.accentColor)
                }
                Spacer(minLength: 4)
                Text(Self.shortDate(commit.date))
                    .font(.system(size: doc.uiSize(9)))
                    .foregroundStyle(.tertiary)
            }
            Text(commit.subject)
                .font(.system(size: doc.uiSize(12)))
                .lineLimit(2)
            Text(commit.author)
                .font(.system(size: doc.uiSize(10)))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        // Cmd-click arms / extends the two-commit range selection.
        .modifier(CommandClickModifier { command in
            model.click(sha: commit.fullSHA, command: command)
        })
        .help("\(commit.sha) — \(commit.subject)\nCmd-click to compare two commits")
    }

    // MARK: - Right: detail pane

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            detailToolbar
            Divider()
            if model.isLoadingDiff {
                centeredPlaceholder("Loading diff…")
            } else if WebDiffGate.isEnabled() {
                // TSK-1596: web diff renderer (kill-switch MDV_WEB_DIFF=0).
                WebDiffPane(text: model.diffText, doc: doc, navAvailable: false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                DiffView(text: model.diffText, doc: doc)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private var detailToolbar: some View {
        HStack(spacing: 10) {
            switch model.selectionMode {
            case .none:
                Text("Select a commit — Cmd-click a second to compare two.")
                    .font(.system(size: doc.uiSize(11)))
                    .foregroundStyle(.secondary)
            case .single:
                Picker("", selection: Binding(
                    get: { model.singleCompareMode },
                    set: { model.setSingleCompareMode($0) }
                )) {
                    Text("This commit").tag(FileHistoryModel.SingleCompareMode.commit)
                    Text("vs Working Tree").tag(FileHistoryModel.SingleCompareMode.vsWorkingTree)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)
            case .range:
                HStack(spacing: 6) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: doc.uiSize(10)))
                        .foregroundStyle(.secondary)
                    Text(model.rangeLabel)
                        .font(.system(size: doc.uiSize(11), design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Clear") { model.clearRange() }
                        .font(.system(size: doc.uiSize(10)))
                        .buttonStyle(.borderless)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Helpers

    private func centeredPlaceholder(_ message: String) -> some View {
        VStack {
            Spacer()
            Text(message)
                .font(.system(size: doc.uiSize(12)))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// `%ai` is "2026-05-31 08:12:03 -0700"; show just the date + time
    /// prefix for the compact list cell.
    static func shortDate(_ iso: String) -> String {
        // Take up to the timezone offset; keep "YYYY-MM-DD HH:MM".
        let parts = iso.split(separator: " ")
        guard parts.count >= 2 else { return iso }
        let date = parts[0]
        let time = parts[1].split(separator: ":").prefix(2).joined(separator: ":")
        return "\(date) \(time)"
    }
}

// `CommandClickModifier` / `CommandClickCatcher` moved to
// `CommandClickModifier.swift` so both `FileHistoryView` and the unified
// `UnifiedHistoryView` share the one implementation.
