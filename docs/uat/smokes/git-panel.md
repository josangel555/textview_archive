# UAT smokes — Git panel (status / log / stash / trees / remotes / diff)

**Area:** `git-panel`
**App under test:** `dist/TextView.app` (Finder name TextView.app, bundle id `com.markdownviewer.MarkdownViewer`)
**Last authored:** 2026-06-03

Durable, maintainable user-acceptance smokes for the read-only, tabbed **GIT**
sidebar panel — the STATUS / LOG / STASH / TREES / REMOTES (+ REVIEW) tab strip,
the multi-repo picker, the on-focus / 60 s refresh policy, the structured
DiffView those tabs feed into, and the master-detail File / Folder / Repository
History views. Each smoke deliberately **combines multiple features into one
realistic flow** rather than testing one control in isolation, so a single run
exercises the seams between the panel tabs, `GitClient` shell-outs, the
diff-to-tab trick, the sidebar/session focus tracking, and the chrome.

The panel is **VIEW-ONLY by design**: there is no stage/commit/branch/push/
pull/merge/checkout from this UI, and auto-fetch is OFF by default. Do **not**
author a smoke that expects to mutate repo state from the panel — the only
write-ish actions are stash Apply/Pop/Drop (which DO mutate the working tree /
stash list) and that is the deliberate exception.

## How to drive these

Smokes are written as concrete app actions. Where a script-verb / a11y-id
exists it is named inline; otherwise the action is a direct UI gesture
(click / key). Mix-and-match is expected — drive via:

- **Live UI** (default for UAT): real clicks/keys against `dist/TextView.app`.
- **Menus / keys:** View ▸ **Show Git Panel** (`⌥⌘B`, focuses Status), the tab
  strip buttons, **Refresh** (`⌥⌘R` while the panel is focused), View ▸
  **Show File History** / **Show Repository History**, and the repo picker menu.
- **Script verbs** (`--script`): `open <path>`, `session-open-new <path>`,
  `file-history <path>` (opens the in-app FileHistoryView), `snapshot`. Note:
  there is **no** dedicated `git-*` script verb — drive tab selection and
  refresh through the live UI / a11y ids below.
- **MCP tools** (`--mcp-stdio`): `open_path`, `current_state`, `snapshot_window`,
  `select_tab`, `set_view_mode` — useful to assert that a diff/commit/stash
  opened as a tab and routed to the Diff view mode.

**A11y ids** in play (assert against these): `mdv.gitPanel` (section wrapper),
`mdv.gitpanel.tab.status` / `.log` / `.stash` / `.trees` / `.remotes` /
`.review` (the six tab buttons; raw values match `GitPanelModel.Tab`),
`mdv.gitpanel.repoPicker` (header repo picker, shown only when >1 repo tracked).
The Git rail toggle lives at `mdv.rail.left.git` and the section header carries
the branch + ahead/behind (`↑N` / `↓N`) summary.

**Scratch data rule:** never write under `~/Documents`, `~/Desktop`,
`~/Downloads`. Build git fixtures under `FileManager.temporaryDirectory`
(`/var/folders/...`). A useful fixture is `git init` + an initial commit + a few
more commits, then deliberate churn: one **staged-modified** file
(`git add` after edit), one **unstaged-modified** file, one **untracked** file.
For branch/ahead-behind state, create a local branch and a fake upstream
(`git branch --set-upstream-to`) or a bare clone you can advance independently.

---

## GP-01 — Open a repo, walk every tab, verify counts/badges/empty-states and the on-switch refresh

**Combines:** repo discovery via focused root · 6-tab strip + per-tab count
badges + accent underline · branch + `↑/↓` ahead-behind header · per-tab
empty-state placeholders · `selectTab` stale-cache (>60 s) refresh · refresh
spinner.

**Preconditions**
- A scratch git repo under tmp with: ≥3 commits, one staged-modified, one
  unstaged-modified, one untracked file, ≥1 stash, ≥1 remote. No extra
  worktrees yet (so Trees shows only the main one).
- Open a file from inside the repo (`open <repo>/README.md`) so the focused
  root resolves to the repo and the GIT section appears.

**Steps**
1. Confirm the **GIT** accordion section is present (`mdv.gitPanel`); its header
   shows the branch name and, if an upstream is set, `↑N` / `↓N` chips. → The
   six-tab strip is visible; **STATUS** is selected by default (accent text +
   2pt underline).
2. Read the count badges on the strip. → STATUS shows the changed-file count,
   STASH the stash count, TREES the worktree count, REMOTES the remote count.
   **LOG has no badge** (paginated counts would mislead); REVIEW badges only the
   unresolved-comment count (likely none → no badge).
3. Click **LOG** (`mdv.gitpanel.tab.log`). → switches; if its cache was never
   loaded or is >60 s stale, the refresh spinner (`arrow.triangle.2.circlepath`)
   appears briefly and the commit list populates.
4. Click **STASH** (`.stash`), **TREES** (`.trees`), **REMOTES** (`.remotes`)
   in turn. → each renders its rows; clicking a tab whose cache is fresh
   (<60 s) does **not** re-spin.
5. Click back to **STATUS**. → no spurious refresh on the no-op-ish reselect;
   the staged / unstaged / untracked groups render with pinned section headers.

**Expected end state**
- All six tabs reachable; counts match `git status` / `git stash list` /
  `git worktree list` / `git remote`; the active-tab underline tracks selection.

**Variations / edge states**
- **Clean tree:** with no changes, STATUS shows `Working tree clean.` in a
  **fixed-height** envelope (the accordion does NOT visibly shrink).
- **Empty placeholders:** no stashes → `No stashes.`; no extra worktrees →
  `No additional worktrees.`; no remotes → `No remotes.`; no commits →
  `No commits in this repository yet.`
- **Outside any repo:** root a plain folder → the GIT section is hidden
  entirely (`EmptyView`) unless force-shown via the rail.
- **Force-shown but no repo:** toggle `mdv.rail.left.git` on a non-repo root →
  `Not a git repository.` placeholder (bug4 fix — the toggle must visibly do
  something, not silently no-op).

---

## GP-02 — Status tab: grouping, click-to-open, Show Diff → structured DiffView, badge colors

**Combines:** STAGED / UNSTAGED / UNTRACKED bucketing (porcelain X/Y columns) ·
status-letter badge + color · click row → open file in current tab · row
context menu Open File / Show Diff · `git diff` → hashed `.diff` cache file →
opens as a tab routed to the **Diff** view mode · DiffView hunk/line rendering.

**Preconditions**
- The GP-01 repo, STATUS tab selected, with one staged-modified, one
  unstaged-modified, and one untracked file. Bonus: a file modified in **both**
  index and worktree (so it appears in BOTH staged and unstaged groups).

**Steps**
1. Inspect the three pinned group headers. → **Staged** lists index-changed
   files (X column ≠ space), **Unstaged** lists worktree-changed (Y column ≠
   space), **Untracked** lists `??` rows. A both-modified file appears under
   **both** Staged and Unstaged.
2. Read the per-row badge + color. → `A` green (added), `D` red (deleted), `M`
   yellow (modified), `U` gray for untracked; the dimmed `dir/` prefix +
   bright filename split renders, middle-truncated.
3. Single-click a status row. → the file opens in the **current** tab
   (only if it still exists on disk); StatusBar updates to its path.
4. Right-click a row → **Show Diff**. → `git diff -- <path>` is written to a
   hashed file under `…/Caches/MarkdownViewer/diffs/<name>-<hash>.diff` and
   **opens as a new tab**. That tab defaults to the **Diff** view mode — assert
   the structured DiffView: per-file rounded block, file header with status
   badge + `+adds −dels`, `@@ -old,N +new,N @@` hunk banners, green added / red
   removed line rows with old#/new# cells.
5. On the Diff tab, switch the view-mode picker to **Source**. → the raw unified
   diff text shows (Source is the secondary lens; `.diff`/`.patch` use the
   synchronous per-line DiffHighlighter, no TreeSitter).

**Expected**
- Grouping follows porcelain X/Y exactly; Show Diff round-trips through the
  cache file into a real Diff-mode tab; the DiffView parses hunks correctly.

**Variations / edge states**
- **Untracked Show Diff:** untracked file has no `git diff` output → the cache
  file gets the `(no diff output — file may be unchanged at HEAD or untracked…)`
  body and DiffView shows `No diff content.` + the unchanged/untracked/binary
  hint.
- **Binary file:** stage a binary change → DiffView shows
  `Binary file — no textual diff.` for that file block.
- **Deleted file:** a `D`-status row whose file no longer exists → clicking the
  row is a no-op (existence-guarded); Show Diff still works (pure-deletion file
  falls back to its `oldPath`).
- **Pure rename:** an `R` row → still opens and diffs against the right path.
- **Big status output:** a repo with >64 KB of `git status` output must NOT
  deadlock (concurrent DispatchGroup pipe drain in GitClient) — the tab still
  populates.

---

## GP-03 — Log tab: commit graph, HEAD/branch/tag chips, lazy pagination, commit → diff tab, hard cap

**Combines:** GitGraphColumn ≤4-lane canvas · short SHA + HEAD chip + `⎇ branch`
/ `tag:` refs + relative time + author·N files·+ins−del line · merge-commit
de-emphasis · lazy `+200` pagination (init 100, hard cap 5000) · graph-too-wide
flat-list fallback · commit click → `git show` → `.diff` tab.

**Preconditions**
- A repo with enough history to exercise pagination (≥150 commits ideal; a
  shallow fixture of ~120 also works), at least one merge commit, and at least
  one tag. Open a file inside it and select the **LOG** tab.

**Steps**
1. Read the LOG rows. → each shows the GitGraphColumn (capped at 4 lanes), the
   accent-colored short SHA, the **HEAD** chip on the tip commit, any `⎇ branch`
   / `tag:` decoration refs, relative time, and the
   `author · N files · +ins −del` line. Merge commits render lighter (secondary
   color, regular weight).
2. Scroll to the bottom of the list. → when the last row appears, `loadMoreLog`
   fetches the next `+200` page (skip = current count) and appends; the list
   keeps scrolling without a full reload.
3. Click a commit row. → `git show <sha>` is written to
   `…/Caches/MarkdownViewer/diffs/<sha>.diff` and opens as a **Diff**-mode tab
   (same structured DiffView as GP-02, but for the whole commit).
4. Verify HEAD detection. → the row whose `sha == head.sha` (from `headInfo`)
   carries the HEAD chip; non-HEAD commits do not.

**Expected**
- The graph renders with HEAD/branch/tag chips; pagination appends pages
  on-demand; clicking a commit yields a full commit-diff tab.

**Variations / edge states**
- **Graph too wide (>4 lanes):** when `GraphLayout.layout(…, maxLanes: 4)`
  returns nil, a `graph too wide — falling back to flat list` notice shows and
  rows render without the lane canvas (flat list).
- **Hard cap:** in a repo with >5000 commits, after paginating to the cap a
  `Showing first 5000 commits — use the terminal for the full history.` footer
  appears and no further pages load.
- **Empty repo:** a freshly `git init`'d repo with zero commits → LOG shows
  `No commits in this repository yet.` (and `layout` is cleared to nil).
- **Detached HEAD:** check out a commit directly → the header branch is nil
  (detached); LOG still renders; HEAD chip still lands on the right commit.
- **Relative-time buckets:** commits seconds / minutes / hours / days / weeks
  old format as `just now` / `N min ago` / `N h ago` / `N d ago` / `N wk ago`.

---

## GP-04 — Stash tab: Apply / Pop / Show / Drop (destructive confirm) with live working-tree mutation

**Combines:** stash row (ref · relative time · subject) · Apply / Pop / Show
chips · **Drop** destructive confirmation alert · stash Show → `.diff` tab ·
`refreshCurrent()` re-read after each mutating action · count-badge update.

**Preconditions**
- A scratch repo where you can safely mutate the working tree. Create ≥2 stashes
  with distinct subjects (`git stash push -m "WIP A"`, edit again,
  `git stash push -m "WIP B"`). Select the **STASH** tab.

> This smoke MUTATES the fixture repo (Pop/Apply/Drop are the deliberate
> write exception). Use a throwaway tmp repo, never a real one.

**Steps**
1. Read the stash rows. → each shows `stash@{N}` (accent monospaced) + relative
   time + subject (≤2 lines) + the four chips: **Apply**, **Pop**, **Show**,
   **Drop** (Drop is red). The STASH tab badge equals the stash count.
2. Click **Show** on a stash. → `git stash show -p stash@{N}` is written to
   `…/Caches/MarkdownViewer/diffs/<safe-ref>.diff` (the `@{}` chars sanitized)
   and opens as a **Diff**-mode tab.
3. Click **Apply** on a stash. → its changes apply to the working tree; the
   panel refreshes (`refreshCurrent`); the stash list is unchanged (apply keeps
   the stash). STATUS now shows the applied changes if you switch tabs.
4. Click **Drop** on the OTHER stash. → a confirmation alert
   `Drop stash@{N}?` with the subject as message; **Cancel** leaves it,
   **Drop** (destructive) removes it and the list + count badge shrink by one.
5. Click **Pop** on the remaining stash. → it applies AND is removed from the
   list; the badge drops to nil/0 and the tab shows `No stashes.` if it was the
   last one.

**Expected**
- Each chip invokes the matching `GitClient` stash verb; Drop is gated behind a
  confirm; the list + badge re-read after every mutation.

**Variations / edge states**
- **Apply/Pop conflict:** if applying a stash conflicts with the working tree,
  the panel still refreshes (the conflict surfaces in STATUS as `U` rows) — the
  panel itself reports no explicit error state, by design.
- **Drop Cancel:** choosing Cancel in the alert is a no-op (stash retained).
- **Last stash popped:** popping the final stash → `No stashes.` placeholder in
  its fixed-height envelope.
- **Show on empty stash:** a stash with no textual diff → the `.diff` tab opens
  with empty/whitespace content → DiffView `No diff content.`

---

## GP-05 — Trees tab: worktree rows, CURRENT / LOCKED / PRUNABLE chips, click-to-navigate (prunable disabled)

**Combines:** worktree rows (`square.grid.2x2` glyph + `~`-shortened path +
`⎇ branch` or `(detached <head>)`) · CURRENT (accent) / LOCKED (orange) /
PRUNABLE (red) state chips · current-row accent backdrop · click a non-current
row → `openPath` navigates the sidebar · prunable rows non-clickable.

**Preconditions**
- A repo with extra worktrees: `git worktree add ../wt-feature feature` (a
  normal one on a branch), `git worktree add --detach ../wt-detached <sha>`
  (a detached one), and one locked (`git worktree lock`). Optionally create a
  prunable one (add a worktree, then delete its directory without `git worktree
  prune`). Select the **TREES** tab.

**Steps**
1. Read the rows. → the main worktree row carries the **CURRENT** chip (accent)
   and a faint accent-tinted backdrop; its path is `~`-shortened, primary color.
   Other worktrees render in secondary color.
2. Verify branch vs detached. → branch worktrees show `⎇ <branch>`; the detached
   one shows `(detached <short-head>)` in monospaced tertiary text.
3. Verify the state chips. → the locked worktree shows **LOCKED** (orange);
   a prunable one shows **PRUNABLE** (red); normal worktrees show no chip.
4. Click a **normal** (non-current) worktree row. → `doc.openPath(<worktree
   path>)` fires, navigating the sidebar/file tree into that worktree directory
   (v1 navigates the tree only — it does NOT switch the active session).
5. Click the **CURRENT** row. → also `openPath`s its own path (harmless;
   already the current tree).

**Expected**
- Rows accurately reflect `git worktree list`; chips map to state; clicking
  navigates the file tree; the prunable row is inert.

**Variations / edge states**
- **Prunable disabled:** clicking a **PRUNABLE** row is a no-op (`open` guards
  `state != .prunable`) — no navigation, no crash.
- **Single worktree:** a repo with only the main checkout → `No additional
  worktrees.` placeholder.
- **Path shortening:** a worktree outside `$HOME` shows its absolute path (no
  `~` prefix); the `help` tooltip always shows the full path.

---

## GP-06 — Remotes tab: name / URL / last-fetch, ssh→https translation, web-open, file:// no-op

**Combines:** remote rows (name · URL · last-fetch from FETCH_HEAD mtime) ·
relative `fetched …` / `never fetched` label · click → open web URL in default
browser · `git@`/`ssh://` → `https://` translation · `.git` suffix strip ·
non-standard / `file://` remote click silent no-op.

**Preconditions**
- A repo with multiple remotes of varied URL shapes:
  `origin = git@github.com:owner/repo.git`,
  `mirror = https://gitlab.com/owner/repo.git`,
  `ssh = ssh://git@example.com/owner/repo.git`,
  and (edge) `local = file:///tmp/somebare.git`. Fetch at least one remote so
  `FETCH_HEAD` exists. Select the **REMOTES** tab.

**Steps**
1. Read the rows. → each shows the `arrow.triangle.2.circlepath` glyph, the
   accent monospaced remote **name**, the last-fetch label on the right, and the
   middle-truncated URL on the second line.
2. Verify the fetch labels. → a fetched remote shows `fetched Nm/h/d/w ago`; a
   never-fetched remote (or one whose FETCH_HEAD is absent) shows
   `never fetched`.
3. Click the `origin` (git@) row. → `GitRemotesTab.webURL` translates
   `git@github.com:owner/repo.git` → `https://github.com/owner/repo`, the
   `.git` is stripped, and the default browser opens it (live UI only).
4. Click the `ssh://` row. → translated to `https://example.com/owner/repo`
   (user@ stripped, `.git` stripped) and opened.
5. Click the `https://` `mirror` row. → opened as-is (with `.git` stripped),
   no translation needed.

**Expected**
- URL translation is correct for git@ / ssh:// / http(s)://; clicking opens the
  web view in the system browser.

**Variations / edge states**
- **file:// remote:** clicking the `local` (file://) row is a **silent no-op**
  (`webURL` returns nil → no browser open); the row still renders its URL.
- **Self-hosted / non-standard scheme:** any URL `webURL` can't parse →
  click no-op (known limitation, do not fail the smoke on a missing browser).
- **No remotes:** a repo with no remotes → `No remotes.` placeholder.
- **REMOTES tab key-chord caveat:** the Remotes tab's internal key chord is
  `r`, which also collides with the Refresh `⌥⌘R` — drive selection via the tab
  button (`mdv.gitpanel.tab.remotes`), not the chord, to avoid ambiguity.

---

## GP-07 — Multi-repo: header repo picker, focus-follow, explicit pin, and pin release on focus-move

**Combines:** `TrackedReposChannel` multi-repo registry · header repo picker
shown only when >1 repo tracked (`mdv.gitpanel.repoPicker`) · `pickRepoRoot`
explicit pin · `followFocus` (selected tab's repo → sidebar folder's repo →
single tracked) · pin held until focus moves to a DIFFERENT tracked repo · cache
clear on repo change.

**Preconditions**
- Two distinct scratch git repos under tmp, **repoA** and **repoB**, each with
  its own branch and some churn. Open a file from repoA and a file from repoB
  (so both get tracked). SessionsApp may or may not be present.

**Steps**
1. With both repos tracked, confirm the header **repo picker** appears
   (`mdv.gitpanel.repoPicker`) — it is hidden when ≤1 repo is tracked. The
   picker label shows the current root's `lastPathComponent`.
2. Open the picker menu. → it lists each tracked root as `name (branch)` (branch
   from the registry's HEAD snapshot), with a checkmark on the currently
   followed root.
3. Focus a tab belonging to **repoA** (click its file tab). → the panel follows
   focus and shows repoA's branch/status (caches cleared on the repo change).
4. **Explicitly pick repoB** from the picker (`pickRepoRoot`). → the panel pins
   to repoB and stays there even if you re-focus repoA's tab momentarily,
   AS LONG AS focus hasn't moved to a different tracked repo's tab.
5. Now focus a tab in **repoA** such that `repoFocus.focusedRoot` resolves to
   repoA (the focus genuinely moved to a different tracked repo). → the explicit
   pin is **released** (`userPinnedPanelRoot` cleared) and follow resumes on
   repoA.

**Expected**
- Picker appears only with >1 repo; an explicit pick overrides focus-follow
  until focus moves to a different tracked repo, then follow resumes.

**Variations / edge states**
- **Pinned root untracked:** if the pinned repo drops out of the tracked set
  (folder closed / un-touched), the pin is released and follow resumes on the
  focused root.
- **Re-pick same root:** picking the already-followed root just re-asserts the
  pin without churning caches (`setRepoRoot` no-op guard).
- **Single repo:** with only one repo tracked, the picker is absent and the
  panel simply follows that root.
- **Cache isolation:** switching repos must fully clear status/log/stash/trees/
  remotes/head caches (no repoA rows bleeding into repoB's view).

---

## GP-08 — Refresh policy: on-window-focus, 60 s timer, manual ⌥⌘R, equality-guarded no-op

**Combines:** `windowDidBecomeKey` on-focus refresh · 60 s repeating timer
(RunLoop.common) · manual Refresh button / `⌥⌘R` · `selectTab` stale-cache
refresh · equality-guarded `apply` (identical results don't republish) · refresh
spinner symbolEffect.

**Preconditions**
- The GP-01 repo open, STATUS tab selected, panel visible and started
  (`start()` runs on appear).

**Steps**
1. Note the current STATUS rows. Externally make a change in the repo (e.g.
   `echo x >> tracked.txt`). Click the **Refresh** button (or press `⌥⌘R` with
   the panel focused). → the spinner icon swaps to
   `arrow.triangle.2.circlepath` and rotates while refreshing; STATUS updates to
   reflect the new change.
2. Make another external change, then **deactivate and re-activate** the window
   (click another app, click back). → `windowDidBecomeKey` fires
   `refreshCurrent()` and the visible tab re-reads.
3. Without changing anything, click Refresh again. → the spinner shows briefly,
   but because `apply` is equality-guarded, identical results do NOT trigger a
   full sidebar+panel republish (no flicker / no spurious re-body).
4. Leave the panel idle ~60 s on a tab. → the repeating timer fires
   `refreshCurrent()` on the visible tab only (background `git` work stays
   proportional to what's on screen).

**Expected**
- Refresh fires on focus-regain, on the 60 s timer, and on manual `⌥⌘R`; only
  the visible tab refreshes; identical results are a republish no-op.

**Variations / edge states**
- **Stale-tab switch:** switch to a tab whose cache is >60 s old → it refreshes
  automatically; switching to a fresh (<60 s) tab does not.
- **Refresh cancellation:** a new refresh cancels the prior in-flight task
  (`refreshTask?.cancel()`); a cancelled task never applies its (stale) payload.
- **headInfo timeout:** if `git` is slow and trips `statusTimeout`, the snapshot
  freezes on the last good values — the UI surfaces NO explicit timeout/error
  state (known gap; don't assert an error banner).
- **Panel disappear:** collapsing the section / hiding the sidebar calls
  `stop()` (timer invalidated, task cancelled) — no background polling on a
  hidden panel.

---

## GP-09 — File History: master-detail commits, single-commit modes, Cmd-click range compare

**Combines:** View ▸ Show File History / tab + sidebar context **File History**
/ `file-history <path>` verb · HSplitView commit Table + DiffView detail · single
selection (this-commit vs vs-working-tree segmented control) · Cmd-click second
commit → range `diff <a> <b> -- path` (full SHAs) · loading / empty placeholders.

**Preconditions**
- A repo with a file that has **≥3 commits** touching it. Open that file in a
  tab. (File History is **disabled** for untracked files — see GP-10.)

**Steps**
1. Invoke **Show File History** (View menu, tab context menu, sidebar file
   context, or `file-history <repo>/<file>`). → an in-app FileHistoryView opens:
   left a commit `Table` (short SHA · date · author · subject ≤2 lines), right a
   diff detail pane. Header shows the clock glyph + file name + `N commits`.
2. Single-click a commit. → the detail pane shows that commit's own change
   (`diff <sha>~ <sha>`); the segmented control offers **This commit** /
   **vs Working Tree**.
3. Toggle to **vs Working Tree**. → the detail re-diffs the selected commit
   against the current working tree (`diff <sha> -- path`).
4. **Cmd-click** a second commit. → selection enters **range** mode; the detail
   shows `diff <a> <b> -- path` between the two selected commits (using full
   SHAs so abbreviation collisions can't pick the wrong commit). A range label +
   **Clear** affordance appears.
5. Click **Clear**. → exits range mode back to single selection.

**Expected**
- Single-mode toggles between this-commit and vs-working-tree; Cmd-click arms a
  two-commit range diff; all git work runs off-main (no UI freeze).

**Variations / edge states**
- **Loading states:** while history / a diff loads → `Loading history…` /
  `Loading diff…` placeholders.
- **No history:** a tracked-but-uncommitted file → `No history for this file.`
- **No selection yet:** before picking a commit →
  `Select a commit — Cmd-click a second to compare two.`
- **Diff routing:** the right pane reuses the same structured DiffView (binary /
  no-hunks / empty handled identically to GP-02).

---

## GP-10 — Folder & Repository History; File History gating on tracked-ness

**Combines:** View ▸ Show Repository History · sidebar folder **Show Folder
History** · synthetic-markdown git-log tab (capped 200) · File History
**disabled** for untracked files / outside a repo · TabBar / sidebar context
menu enable/disable validation.

**Preconditions**
- A git repo rooted in the sidebar with subfolders, plus at least one
  **untracked** file and (separately) a file open from **outside** any repo.

**Steps**
1. Invoke **Show Repository History** (View menu). → a synthetic-markdown tab of
   the repo's `git log` opens, capped at 200 entries. (`_No commits._` if the
   repo is empty.)
2. Right-click a tracked subfolder in the sidebar → **Show Folder History**. →
   a synthetic-markdown folder-scoped git-log tab opens (also capped 200).
3. Right-click an **untracked** file (sidebar or tab context menu) → the **File
   History** item is **disabled** (`canShowFileHistory` false).
4. Open a file from a directory that is **not** a git repo → File History items
   are disabled there too; Repository / Folder History are unavailable.

**Expected**
- Repository / Folder History render as capped synthetic-markdown log tabs;
  File History is correctly gated on the file being tracked inside a repo.

**Variations / edge states**
- **Empty folder history:** a tracked folder with no commits touching it →
  `_No commits._`
- **200 cap:** a folder/repo with >200 commits → the synthetic tab shows the
  first 200 (use File History or the terminal for more).
- **Menu re-validation:** `validateMenuItem` greys File History dynamically as
  the active tab changes between tracked and untracked files.

---

## GP-11 — Menu / rail entry points and section collapse interplay

**Combines:** View ▸ **Show Git Panel** (`⌥⌘B`, focuses Status) · rail toggle
`mdv.rail.left.git` · section collapse/expand chevron · menu-triggered tab
focus (`gitPanelFocusRequest` / `gitPanelDesiredTab`) · section header branch +
ahead/behind summary · `@AppStorage` expanded-state persist.

**Preconditions**
- The GP-01 repo open; the GIT section currently collapsed (chevron closed).

**Steps**
1. Press `⌥⌘B` (View ▸ Show Git Panel). → the GIT section **expands** and
   focuses the **STATUS** tab (the menu request sets `gitPanelDesiredTab` and
   bumps `gitPanelFocusRequest`, which the section observes).
2. Collapse the section via its header chevron, then toggle
   `mdv.rail.left.git`. → the rail button reflects panel
   visibility/data-presence (filled when the repo has data) and toggles the
   section open/closed.
3. Read the section header. → branch name (monospaced tertiary, middle-
   truncated) + `↑N` (ahead) and/or `↓N` (behind) chips when an upstream is set
   and divergent.
4. Quit and relaunch (preserve workspace). → the GIT section's expanded/
   collapsed state is restored from `@AppStorage`
   (`MarkdownViewer.sidebar.gitExpanded`).

**Expected**
- `⌥⌘B` reliably surfaces the Status tab; the rail toggle and header chevron are
  consistent; expanded-state persists.

**Variations / edge states**
- **No upstream:** a branch with no tracking upstream → no `↑/↓` chips (ahead /
  behind both 0).
- **Force-show on non-repo:** `mdv.rail.left.git` on a non-repo root →
  `Not a git repository.` placeholder (rail toggle visibly works — bug4).
- **Detached HEAD header:** detached HEAD → no branch name in the header (nil
  branch), panel still functions.

---

## Notes for the runner

- The bare `swift test` headless gate does NOT open a live window; these smokes
  are the **T4 LiveAppTestCase / VM** lane. Run against installed
  `dist/TextView.app`, occluded, single-threaded.
- The panel is **VIEW-ONLY** except stash Apply/Pop/Drop. Always run mutating
  stash steps (GP-04) against a **throwaway tmp repo** — never a real one — and
  never under `~/Documents`/`~/Desktop`/`~/Downloads`.
- Status / Log / Stash / File-History diffs still go through the
  **diff-as-`.diff`-file-tab** trick (write to `…/Caches/MarkdownViewer/diffs/`,
  open as a tab, route to Diff mode). Task #131 plans an in-app DiffView swap —
  if/when it lands, GP-02/03/04 steps that assert a cache file path must be
  re-pointed at the in-place DiffView surface.
- There is **no** dedicated `git-*` script verb; only `file-history <path>` is
  scripted. Drive tab selection / refresh through the live UI a11y ids
  (`mdv.gitpanel.tab.<tab>`, the Refresh button / `⌥⌘R`).
- macOS 15 Sequoia "Screen Capture Privacy" redacts `screencapture(1)` of
  launchctl-asuser windows on the VM — `snapshot_window` / `snapshot` may come
  back blank/censored there; assert on `current_state` / model dumps instead of
  pixels for those steps.
- `headInfo` timeout freezes the snapshot with **no explicit error/timeout UI**
  — do not author a step that expects an error banner on slow git.
- The REMOTES tab key chord `r` collides with Refresh `⌥⌘R`, and the panel's
  Move-Tab-Left/Right shortcuts collide with Fold All/Unfold All elsewhere in
  the app — drive tab selection via the tab buttons, not chords, to keep smokes
  deterministic.
