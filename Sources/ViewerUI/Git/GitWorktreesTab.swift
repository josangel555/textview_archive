import SwiftUI
import ViewerCore

/// Trees sub-tab: worktree manager. Click a non-current row to open its
/// path in the sidebar (switching active session would need more
/// plumbing; v1 just navigates the file tree).
///
/// TSK-716: the action surface (Add / Remove / Prune) is driven by
/// `WorktreeManagerModel` (ViewerCore), which folds the UX logic the raw
/// `GitClient` lacks — path validation, default-name derivation, and
/// safe-vs-force removal classification — over the existing CRUD. The view
/// constructs the model per-action from the panel's repo root (mirroring the
/// stash tab's `GitClient(repoRoot:)` pattern); the *logic* lives in the
/// host-tested model, not here.
struct GitWorktreesTab: View {
    @ObservedObject var model: GitPanelModel
    @ObservedObject var doc: DocumentModel
    @Environment(\.sidebarSectionBodyHeight) private var bodyHeight

    @State private var pendingRemove: GitClient.WorktreeEntry?
    @State private var showAddSheet = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .sidebarSectionBodyFrame()
        .alert(item: $pendingRemove) { entry in
            removeAlert(for: entry)
        }
        .sheet(isPresented: $showAddSheet) {
            AddWorktreeSheet(model: model, doc: doc)
        }
    }

    // MARK: - toolbar (Add / Prune)

    private var toolbar: some View {
        HStack(spacing: 8) {
            toolbarButton("Add Worktree…", systemImage: "plus") {
                showAddSheet = true
            }
            .disabled(model.repoRoot == nil)

            toolbarButton("Prune", systemImage: "trash") {
                guard let mgr = makeManager() else { return }
                _ = mgr.prune()
                model.refreshCurrent()
            }
            .disabled(!canPrune)
            .help("Remove administrative entries for worktrees whose directories are gone.")

            Spacer()
        }
        .padding(.horizontal, doc.uiSize(10))
        .padding(.vertical, doc.uiSize(5))
    }

    private func toolbarButton(_ label: String, systemImage: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: systemImage)
                .font(.system(size: doc.uiSize(11)))
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    /// Whether any worktree directory is gone (a prune would do work). Cheap:
    /// classify the already-loaded entries rather than re-spawning git.
    private var canPrune: Bool {
        guard let root = model.repoRoot else { return false }
        let rows = WorktreePlanner.classify(model.worktreeEntries, mainRepoRoot: root)
        return !WorktreePlanner.pruneCandidates(rows).isEmpty
    }

    // MARK: - rows

    @ViewBuilder
    private var content: some View {
        if model.worktreeEntries.isEmpty {
            ScrollView {
                SidebarEmptyPlaceholder(message: "No additional worktrees.")
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.worktreeEntries, id: \.path) { row($0) }
                }
            }
        }
    }

    private func row(_ w: GitClient.WorktreeEntry) -> some View {
        let isCurrent = isCurrentWorktree(w)
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Button(action: { open(w) }) {
                    HStack(spacing: 6) {
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: doc.uiSize(10)))
                            .foregroundStyle(.tertiary)
                        Text(displayPath(w.path))
                            .font(.system(size: doc.uiSize(12), design: .monospaced))
                            .foregroundStyle(isCurrent ? .primary : .secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer(minLength: 4)
                chip(for: w.state)
                if !isCurrent {
                    Button(action: { pendingRemove = w }) {
                        Image(systemName: "xmark.circle")
                            .font(.system(size: doc.uiSize(10)))
                            .foregroundStyle(.red.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .help("Remove this worktree.")
                }
            }
            if let branch = w.branch {
                Text("⎇ \(branch)")
                    .font(.system(size: doc.uiSize(10)))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 18)
            } else {
                Text("(detached \(w.head))")
                    .font(.system(size: doc.uiSize(10), design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 18)
            }
            // TSK-1604 (owner ask): last commit — id · relative time · subject,
            // so "how stale is this worktree, and what's on it?" reads without
            // opening it. Metadata is batch-loaded with the tab.
            lastCommitLine(w)
                .padding(.leading, 18)
        }
        .padding(.horizontal, doc.uiSize(10))
        .padding(.vertical, doc.uiSize(4))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isCurrent ? Color.accentColor.opacity(0.10) : .clear)
        .help(w.path.path)
    }

    /// TSK-1604 — "abc1234 · 2h ago · subject" for the worktree's HEAD.
    /// Degrades to the bare sha when metadata hasn't loaded (or the head is
    /// unreachable), never to an empty row.
    @ViewBuilder
    private func lastCommitLine(_ w: GitClient.WorktreeEntry) -> some View {
        let meta = model.worktreeHeadMetas[w.head]
        HStack(spacing: 5) {
            Text(meta?.sha ?? w.head)
                .font(.system(size: doc.uiSize(9), design: .monospaced))
                .foregroundStyle(.secondary)
            if let meta {
                Text("·").font(.system(size: doc.uiSize(9))).foregroundStyle(.quaternary)
                Text(GitRelativeTime.format(unix: meta.timestamp))
                    .font(.system(size: doc.uiSize(9)))
                    .foregroundStyle(.secondary)
                Text(meta.subject)
                    .font(.system(size: doc.uiSize(9)))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .accessibilityIdentifier("mdv.git.worktree.lastCommit")
    }

    @ViewBuilder
    private func chip(for state: GitClient.WorktreeEntry.State) -> some View {
        switch state {
        case .current:
            chipText("CURRENT", color: .accentColor)
        case .locked:
            chipText("LOCKED", color: .orange)
        case .prunable:
            chipText("PRUNABLE", color: .red)
        case .normal:
            EmptyView()
        }
    }

    private func chipText(_ s: String, color: Color) -> some View {
        Text(s)
            .font(.system(size: doc.uiSize(8), weight: .heavy))
            .tracking(0.5)
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 2))
    }

    // MARK: - remove

    private func removeAlert(for entry: GitClient.WorktreeEntry) -> Alert {
        let needsForce = entry.state == .locked || entry.state == .prunable
        let detail = needsForce
            ? "This worktree is \(entry.state == .locked ? "locked" : "no longer on disk"); removing it uses --force."
            : "This removes the linked worktree's working directory. Commits are unaffected."
        return Alert(
            title: Text("Remove \(displayPath(entry.path))?"),
            message: Text(detail),
            primaryButton: .destructive(Text("Remove")) { remove(entry) },
            secondaryButton: .cancel()
        )
    }

    private func remove(_ entry: GitClient.WorktreeEntry) {
        guard let mgr = makeManager() else { return }
        let rows = mgr.refresh()
        guard let row = rows.first(where: {
            $0.path.standardizedFileURL.path == entry.path.standardizedFileURL.path
        }) else { return }
        _ = mgr.removeRow(row)
        model.refreshCurrent()
    }

    // MARK: - helpers

    private func makeManager() -> WorktreeManagerModel? {
        guard let root = model.repoRoot else { return nil }
        return WorktreeManagerModel(git: GitClient(repoRoot: root))
    }

    private func isCurrentWorktree(_ w: GitClient.WorktreeEntry) -> Bool {
        guard let root = model.repoRoot else { return w.state == .current }
        return w.path.standardizedFileURL.path == root.standardizedFileURL.path
            || w.state == .current
    }

    private func displayPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let p = url.path
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }

    private func open(_ w: GitClient.WorktreeEntry) {
        guard w.state != .prunable else { return }
        doc.openPath(w.path)
    }
}

extension GitClient.WorktreeEntry: Identifiable {
    public var id: String { path.path }
}

/// Add-worktree sheet: a branch name + a path (pre-filled from the branch via
/// the model's default-path derivation), with inline validation feedback. The
/// "Create new branch" toggle maps to `git worktree add -b`.
private struct AddWorktreeSheet: View {
    @ObservedObject var model: GitPanelModel
    @ObservedObject var doc: DocumentModel
    @Environment(\.dismiss) private var dismiss

    @State private var branch = ""
    @State private var path = ""
    @State private var createBranch = false
    @State private var errorMessage: String?
    // Tracks whether the user has hand-edited the path; until then we keep it
    // synced to the branch-derived default.
    @State private var pathEdited = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Worktree")
                .font(.system(size: doc.uiSize(15), weight: .semibold))

            field("Branch") {
                TextField("branch name", text: $branch)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: branch) { _, newBranch in
                        if !pathEdited, let mgr = makeManager() {
                            path = mgr.suggestedPath(forBranch: newBranch).path
                        }
                    }
            }

            Toggle("Create new branch", isOn: $createBranch)
                .font(.system(size: doc.uiSize(12)))

            field("Path") {
                TextField("/path/to/worktree", text: $path)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: path) { _, _ in pathEdited = true }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: doc.uiSize(11)))
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(path.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    private func field<Content: View>(_ label: String,
                                      @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: doc.uiSize(11), weight: .medium))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func makeManager() -> WorktreeManagerModel? {
        guard let root = model.repoRoot else { return nil }
        return WorktreeManagerModel(git: GitClient(repoRoot: root))
    }

    private func add() {
        guard let mgr = makeManager() else {
            errorMessage = "No repository selected."
            return
        }
        mgr.refresh()
        let trimmedBranch = branch.trimmingCharacters(in: .whitespaces)
        let branchArg = trimmedBranch.isEmpty ? nil : trimmedBranch
        let result = mgr.addWorktree(
            rawPath: path,
            branch: branchArg,
            createBranch: createBranch && branchArg != nil
        )
        switch result {
        case .added:
            model.refreshCurrent()
            dismiss()
        case .invalid(let validation):
            errorMessage = validation.message
        case .gitFailed:
            errorMessage = "git could not create the worktree (branch already checked out elsewhere, or an unborn HEAD)."
        }
    }
}
