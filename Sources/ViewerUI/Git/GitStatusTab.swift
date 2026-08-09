import SwiftUI
import ViewerCore

/// Status sub-tab: staged / unstaged / untracked, grouped, with the standard
/// interactive index loop (TSK-1443): per-row stage/unstage, a commit bar, and
/// a discard-with-confirmation (destructive actions never run silently — the
/// confirm-gate lives in the host-tested `GitStageOp`). Mutations route through
/// `GitPanelModel` → `GitClient` → a toast + refresh.
struct GitStatusTab: View {
    @ObservedObject var model: GitPanelModel
    @ObservedObject var doc: DocumentModel

    /// `Self.group(...)` runs an O(entries) classification + bucket
    /// allocation. As an inline `let` inside body it ran on every
    /// re-eval (panel-tab switch, sidebar redraw, repo refresh that
    /// produced identical entries because of the value-blind
    /// @Published before we guarded GitPanelModel.apply). Cached in
    /// @State, recomputed only when statusEntries actually change.
    @State private var grouped: Groups = Groups()
    @Environment(\.sidebarSectionBodyHeight) private var bodyHeight

    /// I-05 (owner intake 2026-08-01): what a row click opens — the file's
    /// DIFF (default) or its SOURCE — both into the ephemeral preview slot.
    /// Persisted so the choice survives relaunch; routing is the pure
    /// `GitStatusOpenMode.clickAction` (host-tested).
    @AppStorage(GitStatusOpenMode.defaultsKey)
    private var openModeRaw: String = GitStatusOpenMode.diff.rawValue
    private var openMode: GitStatusOpenMode {
        GitStatusOpenMode(rawValue: openModeRaw) ?? .diff
    }

    /// Which group a row is rendered in — determines its primary action
    /// (stage vs unstage) and whether discard applies (TSK-1443).
    enum RowGroup { case staged, unstaged, untracked }

    var body: some View {
        VStack(spacing: 0) {
            openModeHeader
            if model.statusEntries.isEmpty {
                empty
            } else {
                statusList
            }
            // The commit bar stays mounted (even on a clean tree) so the commit
            // affordance is discoverable; Commit is disabled with nothing staged.
            commitBar
        }
        // 2026-08-01: a BARE container id implicitly combines loose pure-SwiftUI
        // descendants and (as the git-panel scene capture showed) the container
        // itself never materialized out-of-process. `.contain` makes the id a
        // real AX element AND keeps the rows/toggle addressable (LESSONS rule).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mdv.git.statusTab")
        // Destructive discard NEVER runs without this confirmation
        // (GitStageOp.discard.requiresConfirm) — the model only reverts the file
        // from confirmDiscard(), reached solely through this dialog.
        .confirmationDialog(
            discardCopy?.title ?? "Discard changes?",
            isPresented: discardPresented,
            titleVisibility: .visible
        ) {
            Button(discardCopy?.verb ?? "Discard Changes", role: .destructive) {
                model.confirmDiscard()
            }
            .accessibilityIdentifier("mdv.git.discardConfirm")
            Button("Cancel", role: .cancel) { model.cancelDiscard() }
        } message: {
            if let copy = discardCopy { Text(copy.message) }
        }
    }

    /// I-05: slim header band with the Diff | Source open-mode toggle. Rendered
    /// above BOTH the populated list and the clean-tree placeholder so the
    /// control never vanishes with the content.
    private var openModeHeader: some View {
        HStack(spacing: doc.uiSize(6)) {
            Text("Open as")
                .font(.system(size: doc.uiSize(10)))
                .foregroundStyle(.secondary)
            Picker("Open as", selection: $openModeRaw) {
                Text("Diff").tag(GitStatusOpenMode.diff.rawValue)
                Text("Source").tag(GitStatusOpenMode.source.rawValue)
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .labelsHidden()
            .frame(width: doc.uiSize(120))
            .accessibilityIdentifier("mdv.git.openModeToggle")
            .help("What clicking a changed file opens: its diff or its source")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, doc.uiSize(10))
        .padding(.vertical, doc.uiSize(4))
        .background(.background.secondary)
    }

    private var statusList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                if !grouped.staged.isEmpty {
                    sectionHeader("Staged", count: grouped.staged.count)
                    ForEach(grouped.staged, id: \.path) { row($0, group: .staged) }
                }
                if !grouped.unstaged.isEmpty {
                    sectionHeader("Unstaged", count: grouped.unstaged.count)
                    ForEach(grouped.unstaged, id: \.path) { row($0, group: .unstaged) }
                }
                if !grouped.untracked.isEmpty {
                    sectionHeader("Untracked", count: grouped.untracked.count)
                    ForEach(grouped.untracked, id: \.path) { row($0, group: .untracked) }
                }
            }
        }
        .sidebarSectionBodyFrame()
        .onAppear { grouped = Self.group(model.statusEntries) }
        .onChange(of: model.statusEntries) { _, new in
            grouped = Self.group(new)
        }
    }

    /// Resolved discard-confirmation copy for the path currently pending, or nil.
    private var discardCopy: (title: String, message: String, verb: String)? {
        model.pendingDiscard.flatMap { GitStageOp.discard.confirmation(path: $0) }
    }

    /// Bridges the model's `pendingDiscard: String?` to the dialog's Bool
    /// binding; dismissing (set false) cancels the pending discard.
    private var discardPresented: Binding<Bool> {
        Binding(
            get: { model.pendingDiscard != nil },
            set: { if !$0 { model.cancelDiscard() } })
    }

    /// Bottom commit bar: message field + Commit. Commit is disabled with an
    /// empty message, nothing staged, or a mutation in flight.
    private var commitBar: some View {
        VStack(spacing: doc.uiSize(4)) {
            Divider()
            TextField("Commit message", text: $model.commitMessage, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...3)
                .font(.system(size: doc.uiSize(11)))
                .padding(doc.uiSize(6))
                .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator, lineWidth: 1))
                .accessibilityIdentifier("mdv.git.commitMessage")
            HStack(spacing: doc.uiSize(6)) {
                Text(grouped.staged.isEmpty ? "Nothing staged"
                        : "\(grouped.staged.count) staged")
                    .font(.system(size: doc.uiSize(10)))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Commit") { model.commit() }
                    .controlSize(.small)
                    .disabled(commitDisabled)
                    .accessibilityIdentifier("mdv.git.commitButton")
            }
        }
        .padding(.horizontal, doc.uiSize(8))
        .padding(.vertical, doc.uiSize(6))
    }

    private var commitDisabled: Bool {
        model.isMutating
            || grouped.staged.isEmpty
            || model.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var empty: some View {
        // Fixed envelope to match the populated case — without the
        // frame the section's overall height collapses when the tree
        // is clean and the resizable accordion looks like it shrunk.
        ScrollView {
            SidebarEmptyPlaceholder(message: "Working tree clean.")
        }
        .sidebarSectionBodyFrame()
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: doc.uiSize(10), weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            Text("·")
                .foregroundStyle(.tertiary)
            Text("\(count)")
                .font(.system(size: doc.uiSize(10)))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, doc.uiSize(10))
        .padding(.vertical, doc.uiSize(4))
        .background(.background.secondary)
    }

    private func row(_ entry: GitClient.StatusEntry, group: RowGroup) -> some View {
        // I-06 (owner intake 2026-08-01): the hover fill must be GAPLESS — it
        // spans the row's full 20pt height and reaches the leading edge. The
        // horizontal inset therefore lives INSIDE the button label (part of
        // the fill), and the label stretches to the row height; previously
        // the fill hugged the text and left bands between hovered rows.
        HStack(spacing: doc.uiSize(6)) {
            // The path area opens diff/source per the header toggle
            // (UIRESP-05 hover background + pointing-hand cursor).
            Button(action: { rowClick(entry) }) {
                HStack(spacing: doc.uiSize(6)) {
                    Text(badge(entry))
                        .font(.system(size: doc.uiSize(9), weight: .bold, design: .monospaced))
                        .foregroundStyle(color(entry))
                        .frame(width: doc.uiSize(16), alignment: .center)
                    pathView(entry.path)
                    Spacer(minLength: 0)
                }
                .padding(.leading, doc.uiSize(10))
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(RowHoverButtonStyle(cornerRadius: 0))
            .help(entry.path)

            // Trailing primary index action: stage (+) for unstaged/untracked,
            // unstage (−) for staged. The full set (incl. destructive discard)
            // is on the row's context menu.
            primaryAction(entry, group: group)
                .padding(.trailing, doc.uiSize(10))
        }
        .frame(height: doc.uiSize(20))
        .contextMenu {
            Button("Open File") { open(entry) }
            Button("Show Diff") { showDiff(entry) }
            Divider()
            rowIndexActions(entry, group: group)
        }
    }

    @ViewBuilder
    private func primaryAction(_ entry: GitClient.StatusEntry, group: RowGroup) -> some View {
        switch group {
        case .staged:
            actionButton("minus.circle", help: "Unstage \(entry.path)", id: "unstage") {
                model.unstage(path: entry.path)
            }
        case .unstaged, .untracked:
            actionButton("plus.circle", help: "Stage \(entry.path)", id: "stage") {
                model.stage(path: entry.path)
            }
        }
    }

    private func actionButton(
        _ symbol: String, help: String, id: String, _ action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: doc.uiSize(12)))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
        }
        // I-06: pointer + hover feedback on the stage/unstage control too —
        // `.plain` left it visually inert with an arrow cursor.
        .buttonStyle(IconHoverButtonStyle(cornerRadius: 3))
        .help(help)
        .disabled(model.isMutating)
        .accessibilityIdentifier("mdv.git.row.\(id)")
    }

    /// Context-menu index actions per group. Untracked files have no tracked
    /// state to discard (deleting them is a separate, non-git action).
    @ViewBuilder
    private func rowIndexActions(_ entry: GitClient.StatusEntry, group: RowGroup) -> some View {
        switch group {
        case .staged:
            Button("Unstage") { model.unstage(path: entry.path) }
        case .unstaged:
            Button("Stage") { model.stage(path: entry.path) }
            Button("Discard Changes…", role: .destructive) {
                model.requestDiscard(path: entry.path)
            }
        case .untracked:
            Button("Stage") { model.stage(path: entry.path) }
        }
    }

    /// Split `dir/sub/name.ext` into a dim "dir/sub/" + bright "name.ext"
    /// so paths scan visually at a glance. Native Swift split avoids
    /// the `(path as NSString).pathComponents` bridge that was firing
    /// per row per body re-eval (one full UTF-16 materialization per
    /// row × every panel redraw).
    private func pathView(_ path: String) -> some View {
        let dir: String
        let name: String
        if let slash = path.lastIndex(of: "/") {
            dir = String(path[..<slash])
            name = String(path[path.index(after: slash)...])
        } else {
            dir = ""
            name = path
        }
        return HStack(spacing: 0) {
            if !dir.isEmpty {
                Text(dir + "/")
                    .font(.system(size: doc.uiSize(11), design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Text(name)
                .font(.system(size: doc.uiSize(11), design: .monospaced))
                .foregroundStyle(.primary)
        }
        .lineLimit(1)
        .truncationMode(.middle)
    }

    private func badge(_ e: GitClient.StatusEntry) -> String {
        if e.isUntracked { return "U" }
        let i = String(e.indexStatus).trimmingCharacters(in: .whitespaces)
        let w = String(e.workingStatus).trimmingCharacters(in: .whitespaces)
        if !i.isEmpty { return i }
        if !w.isEmpty { return w }
        return "•"
    }

    private func color(_ e: GitClient.StatusEntry) -> Color {
        if e.isUntracked { return .gray }
        switch e.indexStatus {
        case "A": return .green
        case "D": return .red
        case "M": return .yellow
        default:
            switch e.workingStatus {
            case "M": return .yellow
            case "D": return .red
            default:  return .secondary
            }
        }
    }

    /// Row click — routed by the header toggle (pure rule:
    /// `GitStatusOpenMode.clickAction`). Both destinations are the EPHEMERAL
    /// preview slot (TSK-1594): clicking through a changeset reuses one temp
    /// tab; a second click on the same file promotes it to permanent. The
    /// explicit permanent open stays on the context menu.
    private func rowClick(_ e: GitClient.StatusEntry) {
        switch GitStatusOpenMode.clickAction(mode: openMode, isUntracked: e.isUntracked) {
        case .showDiff:
            showDiff(e)
        case .previewSource:
            guard let root = model.repoRoot else { return }
            let url = root.appendingPathComponent(e.path)
            if FileManager.default.fileExists(atPath: url.path) {
                doc.openPreview(url: url)
            }
        }
    }

    /// Context-menu "Open File": a deliberate, PERMANENT open.
    private func open(_ e: GitClient.StatusEntry) {
        guard let root = model.repoRoot else { return }
        let url = root.appendingPathComponent(e.path)
        if FileManager.default.fileExists(atPath: url.path) {
            doc.openPath(url)
        }
    }

    /// For now defer to the same diff-to-tmp behavior the old
    /// `RecentChangesSection` used. Task #131 swaps this for a proper
    /// in-app diff view tab.
    private func showDiff(_ e: GitClient.StatusEntry) {
        guard let root = model.repoRoot else { return }
        let client = GitClient(repoRoot: root)
        // I-02: bounded like the log-side diffs — a single huge file's diff
        // chokes the renderer the same way a docs-corpora commit does.
        let diff = GitDiffBounds.bound(
            client.diff(forPath: e.path),
            commandHint: "git diff -- \(e.path)").text
        let cache = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = cache.appendingPathComponent("MarkdownViewer/diffs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var hasher = Hasher()
        hasher.combine(e.path)
        let hashHex = String(UInt(bitPattern: hasher.finalize()), radix: 16)
            .padding(toLength: 8, withPad: "0", startingAt: 0)
            .prefix(8)
        let base = (e.path as NSString).lastPathComponent
        let out = dir.appendingPathComponent("\(base)-\(hashHex).diff")
        let body = diff.isEmpty
            ? "(no diff output — file may be unchanged at HEAD or untracked. Path: \(e.path))\n"
            : diff
        try? body.write(to: out, atomically: true, encoding: .utf8)
        // TSK-1594: ephemeral preview slot (VSCode-style) — clicking through
        // changed files reuses one tab; a second click on the same file
        // (double-click) promotes it to permanent.
        doc.openPreview(url: out)
    }

    // MARK: - Grouping

    struct Groups {
        var staged: [GitClient.StatusEntry] = []
        var unstaged: [GitClient.StatusEntry] = []
        var untracked: [GitClient.StatusEntry] = []
    }

    /// Bucket porcelain entries into the three sidebar groups. Pure +
    /// internal so the rules are unit-testable.
    static func group(_ entries: [GitClient.StatusEntry]) -> Groups {
        var g = Groups()
        for e in entries {
            if e.isUntracked {
                g.untracked.append(e)
            } else {
                // X column = index (staged), Y column = worktree (unstaged).
                // A file modified in both lands in BOTH groups.
                if e.indexStatus != " " { g.staged.append(e) }
                if e.workingStatus != " " { g.unstaged.append(e) }
            }
        }
        return g
    }
}
