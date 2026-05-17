# Git features

What TextView surfaces about your repo, and how to reach each piece.
View-only by design — staging and commits still go through your terminal
or editor. TextView watches.

## Where to find it

Open a folder that's inside a git repo (or open any file inside a repo).
The sidebar grows a **GIT** accordion section below the search box.

The accordion shows the current branch + ahead/behind counts in its
header. Click anywhere in the header to collapse / expand.

**From the menu bar:** `View → Show Git Panel` (`⌘⌥B`) focuses the
section and selects the Status tab. Two related entries — `View → Show
File History` and `View → Show Repository History` — both jump to the
**Log** tab.

## The five sub-tabs

| Tab      | What it shows                                                    | Source command                |
|---       |---                                                               |---                            |
| Status   | Staged / unstaged / untracked files, grouped, with diff badges   | `git status --porcelain=v1`   |
| Log      | Topological commit graph: SHA, HEAD/branch chips, author, stats  | `git log --topo-order …`      |
| Stash    | All stashes with Apply / Pop / Show / Drop per row               | `git stash list / apply / …`  |
| Trees    | Linked worktrees; CURRENT / LOCKED / PRUNABLE chips              | `git worktree list --porcelain` |
| Remotes  | Each remote URL + last-fetch timestamp; click to open web view   | `git remote -v` + `.git/FETCH_HEAD` mtime |

The tab strip's count chips reflect the current data (Status `8` =
eight working-tree changes; Stash `3` = three stashes). Log has no
count because it's paginated.

## Status tab

Three sections — Staged / Unstaged / Untracked — each header shows
`name · count`. Click a row to open that file in the current tab.
Right-click for **Open File** / **Show Diff**.

**Show Diff** opens a new tab with the file's unified diff vs HEAD,
rendered by the structured DiffView (per-hunk colored, with old/new
line numbers and red/green row backgrounds).

## Log tab

Each row: SHA, HEAD/branch chips, message, author, file/insertion/
deletion counts, relative time. To the left, a topological graph
column shows lane lines + a dot per commit:

- **Filled accent dot** = HEAD
- **Purple dot** = merge commit (2+ parents)
- **Hollow dot** = ordinary commit

The graph caps at 4 concurrent lanes. Beyond that you'll see "graph
too wide — falling back to flat list" and the dots disappear (use
`tig` or `git log --graph` in the terminal for very wide histories).

Click a commit to open its full multi-file diff in a new tab.

Scrolling to the bottom auto-loads the next 200 commits, up to a hard
cap of 5000. Past that, refine your view in the terminal.

## Stash tab

Each row: stash ref (e.g. `stash@{0}`), age, message, and four
action chips:

- **Apply** — `git stash apply <ref>` (keeps the stash entry)
- **Pop** — `git stash pop <ref>` (removes the stash on success)
- **Show** — opens the stash's diff in a new tab
- **Drop** — `git stash drop <ref>`. **Confirms first** — destructive.

## Trees tab

Lists every linked worktree from `git worktree list --porcelain`.

- **CURRENT** chip = the tree TextView is currently looking at.
- **LOCKED** chip = `git worktree lock`ed; won't be auto-pruned.
- **PRUNABLE** chip = the directory was deleted; only metadata remains.
  Clicking the row is disabled for prunable entries.

Clicking a non-current row navigates the sidebar to that path. (True
"switch session to this worktree" needs more plumbing — coming later.)

## Remotes tab

Each remote shows its name (accent-colored, monospaced) and URL,
plus when `.git/FETCH_HEAD` was last touched (rough "last fetched"
signal — not per-remote).

Clicking opens the remote's web view in your default browser:

| Remote URL form                    | Opens                       |
|---                                 |---                          |
| `git@github.com:foo/bar.git`       | `https://github.com/foo/bar` |
| `https://gitlab.com/foo/bar.git`   | `https://gitlab.com/foo/bar` |
| `ssh://git@host/foo/bar.git`       | `https://host/foo/bar`      |

`file://` remotes return nil — no useful web view.

## Refresh policy

The panel refreshes the **currently-visible tab** on:

- Window regaining focus (e.g. you switched apps and came back)
- A 60-second repeating timer while the window is key
- The repo root changing (e.g. you opened a different folder)
- You click the ↻ button on the right of the tab strip (or `⌥⌘R`)

Switching to a stale tab also triggers a refresh — anything cached
longer than 60s is considered worth re-fetching.

## Keyboard shortcuts

| Shortcut      | Action                                           |
|---            |---                                               |
| `⌘⌥B`         | Focus Git Panel (Status tab)                     |
| `⌥⌘R`         | Refresh current Git panel tab                    |

Per-tab chords (e.g. `⌃G S` for Status) are not wired yet — chord
shortcuts aren't native to AppKit menus. Use mouse for tab switches
for now, or wire system-wide shortcuts via System Settings → Keyboard
→ App Shortcuts if you need them.

## Diff tab

Click any **Show Diff** action (Status row, commit in Log, stash
Show) and a new tab opens with the structured DiffView:

- One file block per affected file with M/A/D/R status badge
- Hunks separated visually with `@@ -10,3 +12,5 @@` coords
- Per-line rows with old# / new# / +/- gutter and red/green backgrounds
- Toggleable to Source mode via the mode picker to see raw unified-diff text

The default mode for `.diff` and `.patch` files is now this DiffView.

## What's deliberately not here

Things TextView does NOT do (by design — keep the surface tight):

- Staging (`git add`) / unstaging — use `git add -p` in your terminal
- Committing — use your editor / terminal
- Branch create / switch / merge / rebase — terminal
- Push / pull / fetch — terminal (auto-fetch is **off** by default;
  network calls would prompt for credentials)
- Conflict resolution — your merge tool

If you want a TextView UI for any of these, file a request; they'd
each be a small targeted feature, not a sprawling git client.

## Source-view gutter marks

Independent of the Git panel, the source view's left gutter shows
per-line marks for diff state of the currently open file:

- **Green stripe** = added line
- **Yellow stripe** = modified line
- **Red tick** (above the next line) = a removed line was here

These come from `git diff HEAD -- <path>` parsed by `DiffHunkParser`
and refresh whenever the file or HEAD changes.

## Bookmarks (line-level, line numbers)

Separate from git but related to navigation:

- `⌘D` — bookmark / unbookmark current tab (file-level)
- `⌘⌥D` — bookmark / unbookmark current line (line-level; needs the
  caret on the line you want to mark)
- Bookmarks appear in the sidebar BOOKMARKS section; clicking a line
  bookmark opens the file + scrolls to that line.

Today the current-cursor line has a faint backdrop in the source
view — that's the line `⌘⌥D` will operate on.
