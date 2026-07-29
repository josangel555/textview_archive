import AppKit
import SwiftUI
import ViewerCore

/// Log sub-tab: chronological / topological commit list. v1 is a flat
/// list with the head/branch chips called out; task #130 lands the
/// topological graph renderer.
struct GitLogTab: View {
    @ObservedObject var model: GitPanelModel
    @ObservedObject var doc: DocumentModel

    /// Cached layout — `GraphLayout.layout` is O(commits × lanes) and
    /// allocates fresh rows + lane assignments per call. As a computed
    /// property it ran on every body re-eval (panel tab switch, zoom,
    /// repo refresh that didn't actually change). Now @State + .onChange
    /// keyed on the logEntries identity.
    @State private var layout: GraphLayout.Layout? = nil
    /// TSK-1603 — branch run under the pointer: hovering a row dims every
    /// other branch in the graph and tints that branch's rows, answering
    /// "which commits and lines belong to this branch?".
    @State private var hoveredBranchID: Int? = nil
    @Environment(\.sidebarSectionBodyHeight) private var bodyHeight

    /// The rows the tab renders — search match set while a search is
    /// active (TSK-596), the normal paged log otherwise.
    private var entries: [GitClient.GraphCommit] { model.displayedLogEntries }

    var body: some View {
        // TSK-596: the search field stays pinned above the list; the
        // VStack owns the section's fixed height so adding the field
        // doesn't overflow the accordion slot.
        VStack(spacing: 0) {
            searchField
            if model.selectedLogSHAs.count > 1 {
                selectionBar
            }
            listContent
        }
        .frame(height: bodyHeight)
    }

    /// TSK-522: shown while ≥2 commits are multi-selected (Cmd/Shift-
    /// click). Offers the cumulative diff and warns when the selection
    /// has gaps — the base..tip patch necessarily sweeps the unselected
    /// in-between commits in.
    private var selectionBar: some View {
        HStack(spacing: 6) {
            Text("\(model.selectedLogSHAs.count) selected")
                .font(.system(size: doc.uiSize(10), weight: .medium))
            if let range = model.cumulativeLogSelectionRange, !range.isContiguous {
                Text("+\(range.spannedCount - range.selectedCount) in-between")
                    .font(.system(size: doc.uiSize(9)))
                    .foregroundStyle(.orange)
                    .help("The selection has gaps — the cumulative diff spans \(range.spannedCount) commits including unselected ones in between.")
                    .accessibilityIdentifier("mdv.gitLog.nonContiguousBanner")
            }
            Spacer(minLength: 4)
            Button(action: { showCumulativeDiff() }) {
                Text("View Diff")
                    .font(.system(size: doc.uiSize(10), weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("mdv.gitLog.viewCumulativeDiff")
            Button(action: { model.clearLogSelection() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: doc.uiSize(10)))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("mdv.gitLog.selectionClear")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(Color.accentColor.opacity(0.08))
        .overlay(alignment: .bottom) { Divider() }
    }

    /// Full-message search over commit messages + descriptions —
    /// git-backed (`git log --grep`), so it covers bodies and history
    /// beyond the loaded pages.
    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: doc.uiSize(9)))
                .foregroundStyle(.secondary)
            // TSK-1600: the query matches a commit-id / branch / worktree
            // PREFIX, the subject, or (git-backed) the message body.
            TextField("sha · branch · worktree · message", text: $model.logSearchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: doc.uiSize(11)))
                .onChange(of: model.logSearchQuery) { _, q in
                    model.runLogSearch(q)
                }
                .help("Search by commit-id prefix, branch/tag/remote prefix, "
                      + "worktree prefix, subject, or message body")
                .accessibilityIdentifier("mdv.gitLog.searchField")
            // TSK-1602: ALL-REFS graph — every worktree's branch tips in one
            // topo-ordered graph, so divergence points are visible without
            // switching worktrees. Prominent once a sibling worktree exists.
            Toggle("All refs", isOn: Binding(
                get: { model.showAllRefs },
                set: { model.showAllRefs = $0 }))
                .toggleStyle(.checkbox)
                .font(.system(size: doc.uiSize(10)))
                .help(model.worktreeEntries.count > 1
                      ? "Show every branch — including the \(model.worktreeEntries.count - 1) "
                        + "other worktree(s) — in one graph"
                      : "Show all branches and tags in one graph, not just the current branch")
                .accessibilityIdentifier("mdv.gitLog.allRefsToggle")
            if model.isLogSearchActive {
                Text("\(entries.count)")
                    .font(.system(size: doc.uiSize(9), design: .monospaced))
                    .foregroundStyle(.secondary)
                Button(action: { model.clearLogSearch() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: doc.uiSize(10)))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("mdv.gitLog.searchClear")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Palette.windowBackground.opacity(0.3))
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder
    private var listContent: some View {
        if entries.isEmpty {
            ScrollView {
                SidebarEmptyPlaceholder(message: model.isLogSearchActive
                    ? "No commits match \u{201C}\(model.logSearchQuery)\u{201D}."
                    : "No commits in this repository yet.")
            }
            .frame(maxHeight: .infinity)
            .onAppear { layout = nil }
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
                    ForEach(Array(entries.enumerated()), id: \.offset) { idx, c in
                        // `lay` is a cached @State layout that can momentarily
                        // lag `model.logEntries` on append/refresh: SwiftUI
                        // evaluates this body (with the NEW entries) BEFORE the
                        // `.onChange` recompute fires, so `lay.rows[idx]` can be
                        // out of range and hard-trap (EXC_BREAKPOINT — the
                        // 2026-06-04 03:04 crash). Guard the subscript; a stale
                        // row renders flat (nil) until the layout catches up.
                        let layoutRow = lay.flatMap { idx < $0.rows.count ? $0.rows[idx] : nil }
                        row(c, layoutRow: layoutRow, maxLane: lay?.maxLane ?? -1)
                            .onAppear {
                                // Pagination only applies to the normal
                                // log — the search match set is complete.
                                if !model.isLogSearchActive,
                                   c.sha == entries.last?.sha {
                                    model.loadMoreLog()
                                }
                            }
                    }
                    if !model.isLogSearchActive, model.logLoadedCount >= model.logHardCap {
                        Text("Showing first \(model.logHardCap) commits — use the terminal for the full history.")
                            .font(.system(size: doc.uiSize(10)))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .onAppear { recomputeLayout() }
            .onChange(of: entries.count) { _, _ in recomputeLayout() }
            .onChange(of: entries.first?.sha) { _, _ in recomputeLayout() }
            .onChange(of: model.isLogSearchActive) { _, _ in recomputeLayout() }
        }
    }

    private func recomputeLayout() {
        layout = GraphLayout.layout(entries, maxLanes: 4)
    }

    private func row(_ c: GitClient.GraphCommit,
                     layoutRow: GraphLayout.Row?,
                     maxLane: Int) -> some View {
        Button(action: { rowClicked(c) }) {
            GitLogRowLabel(
                commit: c,
                layoutRow: layoutRow,
                maxLane: maxLane,
                isHead: isHead(c),
                branchRefs: branchRefs(c),
                authorLine: authorLine(c),
                isSelected: model.selectedLogSHAs.contains(c.sha)
                    || c.sha == model.selectedLogSHA,
                uiSize: doc.uiSize,
                // TSK-1601: typed decorations → per-kind chip colors, with a
                // sibling worktree's branch called out by name.
                typedRefs: GitRefKind.classifyAll(
                    c.refs,
                    remoteNames: model.remoteNamesForRefs,
                    worktreeBranches: model.worktreeBranchMap),
                hoveredBranchID: hoveredBranchID)
        }
        .buttonStyle(.plain)
        // TSK-1603: hovering a row lights up its whole branch run.
        .onHover { inside in
            hoveredBranchID = inside ? layoutRow?.branchID : nil
        }
        .help("\(c.sha) — \(c.subject)")
        // TSK-523: start (or reopen) a commit-scoped review — inline
        // structured diff with the add-comment affordance, in the Review tab.
        .contextMenu {
            Button("Review Commit…") { model.openCommitReview(sha: c.sha) }
            // TSK-909: lazy list of reviews that include this commit — the
            // closure (and its ReviewStore read) runs only when the submenu
            // opens, so it never touches the right-click hot path.
            Menu("Reviews") {
                let reviews = model.reviewsForCommit(c.sha)
                if reviews.isEmpty {
                    Button("No reviews for this commit") {}.disabled(true)
                } else {
                    ForEach(reviews) { r in
                        Button(r.title) { model.openReview(id: r.id) }
                    }
                }
            }
            // TSK-908: common commit copy actions (the menu was review-only).
            Divider()
            Button("Copy SHA") { Pasteboard.copy(c.sha) }
            Button("Copy Short SHA") { Pasteboard.copy(CommitClipboard.shortSHA(c.sha)) }
            Button("Copy Subject") { Pasteboard.copy(c.subject) }
            Button("Copy Reference") {
                Pasteboard.copy(CommitClipboard.reference(sha: c.sha, subject: c.subject))
            }
        }
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

    /// TSK-522: route a row click by the live modifier flags. Cmd/Shift
    /// go to the model's multi-select state machine (headless-tested via
    /// `logRowClicked` — the exact closure this calls); a plain click
    /// keeps the single-commit diff behavior.
    // The actual behaviors live in `GitLogDiffActions` so the `--script`
    // harness verbs (`git-log-click` / `git-log-cmd-click` /
    // `git-log-shift-click` / `git-log-cumulative-diff`) exercise the
    // IDENTICAL closures these buttons call (exact-closure rule). The
    // view's only residue is reading the modifier flags off the event.
    private func rowClicked(_ c: GitClient.GraphCommit) {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        GitLogDiffActions.rowClicked(
            sha: c.sha,
            command: flags.contains(.command),
            shift: flags.contains(.shift),
            panel: model, doc: doc)
    }

    private func showCumulativeDiff() {
        GitLogDiffActions.showCumulativeDiff(panel: model, doc: doc)
    }
}
