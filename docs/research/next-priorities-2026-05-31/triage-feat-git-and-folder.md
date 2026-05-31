# Triage — feat:git-and-folder

I have everything verified. Key findings: `log()`/`graphLog()` emit only short SHAs (`%h`), no commit-range diff plumbing (`A..B`), no blame/numstat/shortlog, and no Cmd-click handling in the git tabs. ProcessRunner is cleanly reusable. The settings window is the precedent for a standalone window.

Here is the analysis.

---

### Git FILE-HISTORY window

**Status today**
- **Plumbing that exists.** `GitClient.log(forPath:maxEntries:)` (`Sources/ViewerCore/Git/GitClient.swift:211`) already returns per-file commits as `LogEntry { sha, author, date, subject }` — exactly the table columns asked for (changes/date/author). `fileDiff(path:atCommit:)` (`GitClient.swift:505`) emits `git diff <sha>~ <sha> -- <path>` (the per-commit delta). `commitDiff(sha:)` (`GitClient.swift:515`) emits a full `git show`. `DiffParser.parse` (`Sources/ViewerCore/Git/DiffParser.swift:67`) → `DiffView` (`Sources/ViewerUI/Git/DiffView.swift:9`) renders any unified-diff string per-hunk with old/new line numbers and red/green rows.
- **UI that exists to reuse.** `DiffView(text:doc:)` takes a raw diff string and renders it — directly reusable for all three diff panes. `GitLogTab.showCommit` (`Sources/ViewerUI/Git/GitLogTab.swift:167`) is the row→diff pattern (though it writes a temp `.diff` and opens a file-tab, not in-app DiffView). `SettingsWindowController` (`Sources/ViewerUI/SettingsView.swift:311`) is the proven standalone-window pattern: `NSWindow(contentViewController: NSHostingController(rootView:))` + `makeKeyAndOrderFront`, with `isReleasedWhenClosed = false` and a single cached window handle.
- **Entry points.** `model.showGitLog(forPath:scope:)` (`Sources/ViewerUI/DocumentModel.swift:1098`) currently renders file history as a **synthetic markdown table** written to `~/Library/Caches/.../git-log/` and opened as a tab (`DocumentModel.swift:1125-1150`). The sidebar context menu "Show File History" (`Sources/ViewerUI/SidebarView.swift:638`) routes here. The menu-bar "Show File History" (`Sources/MarkdownViewer/main.swift:1454`) instead just opens the Log *graph* tab.

**Root cause / gap**
- No **interactive table** — today it's a static rendered-markdown table (`showGitLog`) with non-functional SHAs; you can't click a row to load that state or diff it.
- No **commit-vs-commit diff**. `fileDiff` only diffs a commit against *its own parent*. There is no `git diff <A> <B> -- <path>` (range) and no `git show <sha>:<path>` (blob-at-commit) method — verified absent (`GitClient.swift` grep for `..`/`show :` returns nothing).
- **Short SHAs only.** `log()`/`graphLog()` use `%h` (`GitClient.swift:214,253`). Short SHAs are *usually* fine for `git diff`, but for a UI that lets the user select two arbitrary historical commits, abbreviation collisions are a real (if rare) correctness hazard; the file-history feature should carry `%H`.
- No **Cmd-click multi-select** anywhere in the git tabs (grep of `GitLogTab`/`GitStatusTab` for `modifierFlags`/`EventModifiers` → none).
- No "delta between selected state and current (working-tree/HEAD)" command — needs `git diff <sha> -- <path>` (the asked-for "this state vs current").

**Fix/build sketch**
1. **Core (S).** Add to `GitClient`:
   - `fileHistory(path:maxEntries:) -> [LogEntry]` using `%H` (full SHA) — or extend `LogEntry` with a `fullSHA` field and keep `%h` for display. Reuse the existing `run()` path verbatim.
   - `func diff(from: String, to: String = "HEAD"?, path: String) -> String` → `git diff <from> <to> -- <path>` for **commit-vs-current** and **commit-vs-commit**. One method covers both the "delta to current" and "Cmd-click two commits" cases.
   - All shell-outs reuse `ProcessRunner.run(... limits:maxOutputBytes:)` already wired in `runResult` (`GitClient.swift:573`) — protective `-c` flags and env-allowlist come for free. No new security surface.
2. **UI (M).** New `FileHistoryView` (SwiftUI) = left `Table`/`List` of `LogEntry` rows (SHA·date·author·subject) + right pane hosting the existing `DiffView`. Selection model: single-click selects one commit → right pane shows `fileDiff(path:atCommit:)` (that commit's own change) **or** `diff(from: sha, to: nil, path:)` (vs current) toggled by a segmented control. `Cmd-click` arms a two-commit selection (track an ordered `[String]` of full SHAs, cap 2) → right pane shows `diff(from: a, to: b, path:)`.
3. **Window host (S).** `FileHistoryWindowController`, a near-copy of `SettingsWindowController` (`SettingsView.swift:311-339`) — cache by path so re-invoking on the same file refocuses rather than stacking. Wire from the sidebar context menu (replace/augment `showGitLog(forPath:scope:.file)` at `SidebarView.swift:638`) and optionally the menu bar.
4. Diff work must run off-main (the `Task.detached(priority: .utility)` pattern in `GitPanelModel.refreshCurrent` at `GitPanelModel.swift:191`), since `git diff`/`git show` block.

**Size: M.** Core is genuinely S (~3 small methods, all on the existing `run()` rail). The window + master-detail table + selection state machine (single vs Cmd-two-commit, vs-current toggle) is the bulk — a self-contained SwiftUI view of moderate complexity, but every renderer it needs (`DiffView`) and every git primitive (one new range-diff method) already exists. No new dependencies.

**Dependencies**
- `GitClient.diff(from:to:path:)` (new) must land first.
- Full-SHA (`%H`) on the history list — required for safe two-commit diffing.
- Reuses existing `DiffView`, `DiffParser`, `ProcessRunner`, and the `SettingsWindowController` window pattern; nothing else is a prerequisite.

**Risk/one-way-door note**
- **Low.** Read-only git, additive UI. One subtlety: the spec says *separate window* — given the existing tab system, an in-app tab (like `showCommit` does) is the lower-friction alternative and avoids multi-window lifecycle (the app is single-window today; `SESSIONS_DESIGN.md:1653` notes multi-window/tear-off is unbuilt). A standalone `NSWindow` works (Settings proves it) but you own its lifecycle, key-window git-refresh, and it won't participate in session save/restore. Not a one-way door, but pick window-vs-tab deliberately up front — retrofitting is annoying.
- Minor perf: `git diff` between two distant commits on a large file can be large; the 512 MB `maxOutputBytes` cap in `runResult` already backstops it, and `DiffView` uses `LazyVStack`, so it's bounded.

---

### Folder "stats" button (repo-stats summary sliding down from folder nav)

**Status today**
- **Plumbing that exists.** Very little of what a stats summary needs. `graphLog` (`GitClient.swift:248`) parses `--shortstat` per commit (files/insertions/deletions) — reusable shape but it's per-commit, not aggregated. `headInfo()` (`GitClient.swift:456`) gives branch + ahead/behind. `status()` gives working-tree counts. There is **no** `shortlog` (authors leaderboard), **no** `rev-list --count` (total commits), **no** `--numstat` aggregation, **no** `count-objects` (repo size), **no** blame — verified absent via grep across `Sources/`.
- **UI that exists to reuse.** The FILES panel header (`Sources/ViewerUI/SidebarView.swift:388` `filesHeader`) is the natural button host — it already carries a row of controls (sort menu `:421`, recency menu `:453`, lock toggle `:482`). The "slide down from within the folder nav" affordance maps cleanly onto the existing collapsible-section pattern (`isExpanded` + `withAnimation(.easeInOut)` at `SidebarView.swift:394`) used by every accordion section. `SidebarSectionHeaderLabel` / `sidebarHeaderRow()` give consistent chrome.
- The folder context menu (`SidebarView.swift:642`) already has "Show Folder History" → `showGitLog(scope:.folder)`, so folder-scoped git is an established entry point.

**Root cause / gap**
- **The aggregation layer doesn't exist.** "Repo-stats-like summary" (total commits, top authors, commit activity over time, churn, file-type breakdown, repo size) requires new `GitClient` methods. None of the current methods aggregate.
- No **collapsible inline panel anchored to the FILES header** — the accordion sections (Bookmarks/Git/etc.) live *below* FILES (`SidebarView.swift:231-248`), not inside the folder nav. A "slides down from within the folder nav" panel is a new, small inline disclosure attached to `filesHeader`.
- **Scope ambiguity.** "Folder stats" vs "repo stats" — the sidebar root may be a *subdirectory* of the repo. Decide whether stats are repo-wide (`GitClient.discoverRoot(from:)` → whole repo) or scoped to the folder (`git log -- <subdir>`, `git ls-files <subdir>`). This is a product decision that shapes the plumbing.

**Fix/build sketch**
1. **Core (M).** New `GitClient.repoStats(scope:) -> RepoStats` (Sendable struct), composed of a few cheap shell-outs, each on the existing `run()` rail:
   - `git rev-list --count HEAD [-- <path>]` → total commits.
   - `git shortlog -sne HEAD [-- <path>]` → author leaderboard (parse `count\tname <email>`).
   - `git log --format=%ct [-- <path>]` → first/last commit dates, commits-per-week sparkline (pure aggregation in Swift).
   - Optionally `git ls-files [<path>]` → tracked file count + extension histogram (pure-Swift bucketing — mirrors `FileIconClassifier` logic already in `ViewerCore`).
   - Repo on-disk size via `git count-objects -vH` (optional; slower).
   - Each method is a ~10-line parser; bundle them so the UI makes one off-main call returning one struct (the `Payload` pattern in `GitPanelModel.swift:172`).
2. **UI (M).** `FolderStatsView` — a compact summary card (commit count, date span, top-3 authors with bar widths, file-type breakdown, ahead/behind from existing `headInfo`). Host it as an inline disclosure under `filesHeader`: add a `chart.bar`/`info.circle` button next to the lock toggle (`SidebarView.swift:482`), a `@State private var statsExpanded` + `@State private var stats: RepoStats?`, and render the card with the same `withAnimation(.easeInOut(duration: 0.15))` slide the header collapse already uses (`SidebarView.swift:394`). Fetch lazily on first expand via `Task.detached(priority: .utility)`; cache + invalidate on `sidebar.rootURL` change (same trigger `RecentChangesSection.swift:35` and `GitPanelSection.swift:44` already use).
3. Hidden when the root isn't in a repo — reuse the `GitClient.discoverRoot(from:) != nil` guard (`RecentChangesSection.swift:116`, `GitPanelSection.swift:25`).

**Size: M.** ~5 new small core methods (each S individually, but as a set + the `RepoStats` struct + aggregation logic it's M) plus a self-contained summary card and one inline-disclosure wiring into `filesHeader`. The UI scaffolding (collapse animation, repo-presence gate, off-main fetch, root-change invalidation) is all copy-adaptable from `GitPanelSection`/`RecentChangesSection`. No new dependencies; ASCII/SwiftUI bar charts only (avoid pulling in a charts library — `Swift Charts` is stdlib-adjacent but per project rules confirm before adding even Apple frameworks).

**Dependencies**
- New `GitClient.repoStats(...)` aggregation methods must land first; nothing else blocks.
- Reuses `headInfo()`, `discoverRoot(from:)`, the section collapse-animation pattern, and the off-main refresh pattern — all present.
- **Decide scope (folder-subdir vs whole-repo)** before building the core — it changes the `-- <path>` argument threading on every method.

**Risk/one-way-door note**
- **Low correctness risk** (read-only git). **Performance is the real watch-item:** `git shortlog -sne` and `rev-list --count` walk the *entire* history — on a large monorepo that's seconds, not milliseconds. Must run off-main (it will, via `Task.detached`) and should carry a `statusTimeout` like the registry injects (`GitClient.swift:55`, the 5–10s caps) so a huge repo doesn't make the stats card hang. Cache aggressively (history changes rarely; invalidate on HEAD change, not on a timer). `git count-objects -vH` can be slow on huge packs — make repo-size opt-in or compute it lazily/separately so it never blocks the first paint of the card.
- No one-way door — purely additive UI + core methods.

---

**Cross-cutting note for both:** the only genuinely *new* git primitive needed across both features is one range/blob diff method (`diff(from:to:path:)`) and the stats-aggregation set. Everything else (DiffView, DiffParser, ProcessRunner hardening, off-main refresh pattern, standalone-window pattern, repo-presence gating, collapse animation) is already in the tree and directly reusable. Both are **M**; neither requires new dependencies.