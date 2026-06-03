# UAT smokes — Sidebar file tree & bookmarks

**Area:** `sidebar-filetree-and-bookmarks`
**App under test:** `dist/TextView.app` (Finder name TextView.app, bundle id `com.markdownviewer.MarkdownViewer`)
**Last authored:** 2026-06-03

Durable, maintainable user-acceptance smokes for the left-hand sidebar — FILES
file tree, shoulder rails (panel toggles), the accordion panel container, and
the file- / line-level bookmarks system. Each smoke deliberately **combines
multiple features into one realistic flow** rather than testing a control in
isolation, so a single run exercises the seams between the tree, the rails, the
bookmark store, the tabs, git, recency, and session persistence.

## How to drive these

Smokes are written as concrete app actions. Where a script-verb exists it is
named inline; otherwise the action is a direct UI gesture (click / drag / key).
Mix-and-match is expected — drive via:

- **Live UI** (default for UAT): real clicks/keys against `dist/TextView.app`.
- **Script verbs** (`--script`): `sidebar-set-root <path>`, `sidebar-select-next`,
  `sidebar-select-prev`, `sidebar-walk-up`, `toggle-sidebar`, `toggle-bookmark`,
  `folder-stats on|off`, `open <path>`, `session-open-new <path>`,
  `set-open-as <cat>`, `snapshot`.
- **MCP tools** (`--mcp-stdio`): `open_path`, `toggle_bookmark`, `list_bookmarks`,
  `current_state`, `snapshot_window`, `select_tab`, `set_view_mode`.

**A11y ids** in play (assert against these): `mdv.sidebar`,
`mdv.sidebar.sort`, `mdv.sidebar.recencyMode`, `mdv.sidebar.folderStats`,
`mdv.sidebar.followActiveTab`, `mdv.sidebar.fileRow.recencyStripe.<tier>`,
`mdv.sidebar.accordionScroll`, `mdv.sidebar.resizeHandle`, `mdv.rail.<edge>`,
`mdv.rail.<edge>.<kind>`, `mdv.bookmarks`, `mdv.bookmarks.sort`,
`mdv.bookmarks.chip.<file|directory|line>`.

**Scratch data rule:** never write under `~/Documents`, `~/Desktop`,
`~/Downloads`. Use `FileManager.temporaryDirectory` (`/var/folders/...`) for
fixture trees. A git fixture means `git init` + a commit + some
staged/unstaged/untracked churn so badges have something to show.

---

## SFB-01 — Open a folder, navigate the tree, open files into tabs, follow-active-tab re-roots

**Combines:** FILES tree virtualization · single-click file → current tab ·
folder expand/collapse vs double-click-as-root · `..` parent entry ·
follow-active-tab pin · sidebar↔tab coupling · FSEvents repaint.

**Preconditions**
- App launched with no folder open (or `MDV_SKIP_WORKSPACE_RESTORE=1` for a
  clean room).
- A scratch tree under tmp: `root/{a.md, b.txt, sub/{c.json, d.csv}, sub2/e.png}`,
  not necessarily a git repo.

**Steps**
1. Open the folder as sidebar root (`sidebar-set-root <root>` or File ▸ Open
   Folder… ⇧⌘O). → FILES section appears, `mdv.sidebar` present; folders
   sorted first then files; `No folder open` placeholder gone.
2. Single-click `a.md`. → opens in the **current** tab (no new tab); row name
   goes bold (current); StatusBar shows the path. Tab title = `a.md`.
3. Single-click the `sub` folder row (not double). → expands in place
   (chevron 0°→90°), revealing `c.json`, `d.csv`; **no** re-root, `..` not
   shown yet.
4. Single-click `c.json`. → opens in current tab, replacing `a.md` (still one
   tab). The tree keeps `sub` expanded.
5. Toggle the follow-active-tab pin ON (`mdv.sidebar.followActiveTab`). Open a
   file from a *different* branch, e.g. via `open <root>/sub2/e.png`. → sidebar
   auto-roots to the containing folder / expands ancestors and selects the
   target row (unless Files-lock is on).
6. Double-click the `sub` folder row. → enters `sub` **as root**; header root
   name = `sub`; a `..` parent entry now shows at top.
7. Click `..`. → walks up to `root`; expansion state restored sanely.

**Expected end state**
- Exactly the tabs you opened (no accidental dupes); current row bold; sidebar
  rooted where follow-mode left it.

**Variations / edge states**
- **Deep/large tree:** point root at a directory with thousands of entries →
  LazyVStack stays responsive (no multi-second hang); `childrenCache` LRU
  capped 256 dirs.
- **Unreadable/missing dir:** root a dir then delete a child externally →
  `children()` returns `[]` gracefully, no crash; FSEvents repaints.
- **Files-lock ON:** with the Files lock toggle on, opening a file in another
  tree must **not** re-root the sidebar even in follow mode.
- **Filesystem root `/`:** rooting at `/` hides the up-arrow (no parent).
- **Double-tap regression guard:** a *single* click on a folder must expand it
  — historically `.onTapGesture(count:2)` swallowed first clicks (fixed).

---

## SFB-02 — Keyboard-only tree navigation with auto-scroll and collapse/expand

**Combines:** SidebarKeyMonitor arrow nav · Up/Down move · Left
collapse-or-focus-parent · Right expand-or-focus-child · Return open/toggle ·
auto-scroll-into-view · `⌃⌘S` toggle sidebar.

**Preconditions**
- A nested scratch tree rooted in the sidebar (reuse SFB-01 `root`), sidebar
  visible and focused.

**Steps**
1. Press Down repeatedly (`sidebar-select-next`). → selection moves row-by-row,
   folders-first ordering; selected row scrolls into view near edges.
2. On a collapsed folder, press Right. → folder expands (children appear); a
   second Right focuses the first child.
3. Press Left on a child. → focus moves to parent (`sidebar-walk-up`); Left on
   an expanded folder collapses it first.
4. Press Up several times (`sidebar-select-prev`) past the top. → selection
   clamps / wraps sanely (no out-of-range crash).
5. With a file selected, press Return. → file opens in current tab. With a
   folder selected, Return toggles expand/collapse.
6. Press `⌃⌘S` (toggle sidebar, `toggle-sidebar`). → sidebar hides; left rail
   hidden too (master switch). Press again → restored with prior selection.

**Expected**
- Arrow nav never selects an off-screen row without scrolling it visible;
  selection survives the sidebar hide/show cycle.

**Variations / edge states**
- **Hidden sidebar + key:** with sidebar hidden, arrow keys must be inert (no
  phantom selection mutation).
- **Single-row tree:** Up/Down on a one-entry tree is a no-op, not a crash.
- **Show-hidden toggle mid-nav:** flip Show-hidden — dotfiles appear/disappear
  and the selection index stays valid (pruned/clamped, not dangling).

---

## SFB-03 — Bookmark a file from the tree and from the tab; verify mirror across FILES, BOOKMARKS, palette, status

**Combines:** ⌘D file bookmark · tree context-menu Bookmark · `star.fill`
mirror in FILES tree + tab + BOOKMARKS section · BookmarksStore JSON persist ·
command-palette bookmark rows · O(1) `contains` lookup.

**Preconditions**
- A folder rooted in the sidebar with ≥3 files; at least one file open in a tab.
- `bookmarks.json` may pre-exist; note count before.

**Steps**
1. With `a.md` the active tab, press ⌘D (`toggle-bookmark`). → tab gains a
   yellow `star.fill`; the `a.md` row in FILES shows a star; a BOOKMARKS
   section row appears (file kind), bold because it's the current file.
2. Open BOOKMARKS section (`mdv.bookmarks`). → shown/total count badge
   increments by 1; the row shows FileIconView + name + relative-date metadata
   (`just now`), full-path tooltip.
3. Right-click a *different* tree row → **Bookmark** from the file context
   menu. → that file's row + a new BOOKMARKS row gain stars without opening it.
4. Open Command Palette (⌘K). → both bookmarks appear as `star.fill` rows
   (bookmarks-then-recents ordering); fuzzy-filter by name highlights matched
   chars.
5. Press ⌘D again on `a.md` (toggle off). → star clears in tab, FILES row, and
   BOOKMARKS section simultaneously; count decrements.
6. Verify persistence: relaunch the app (or read `bookmarks.json`). → the
   remaining bookmark survives; deleted one is gone.

**Expected**
- The star state is **consistent across all four surfaces** at every step (tab,
  tree, BOOKMARKS section, palette).

**Variations / edge states**
- **MCP path:** drive via `toggle_bookmark` + `list_bookmarks` and confirm the
  count/paths match the UI.
- **Store cap:** with 200 bookmarks already present, adding the 201st drops the
  oldest (cap=200); UI count stays ≤200.
- **Deleted target:** bookmark a file, delete it on disk → row still shown
  (resolved at add time), opening it routes to ErrorView (keeps other tabs).
- **Filtered-empty:** turn on a filter chip that excludes the only bookmark →
  `No bookmarks match this filter.` (panel keeps its envelope height).

---

## SFB-04 — Line-level bookmarks: set, mirror to gutter, jump back, filter by kind

**Combines:** ⌥⌘D line bookmark · `:<line>` chip in BOOKMARKS · gutter dot in
Source view · click-to-open-at-line · F/D/L filter chips · BOOKMARKS sort menu.

**Preconditions**
- A multi-line text file (e.g. a 200-line `.md` or `.swift`) open in **Source**
  view so the gutter and Ln/Col are live.

**Steps**
1. Click into the source at line 42 (or `goto-line`), press ⌥⌘D. → a line
   bookmark is created; a gutter dot appears at line 42; a BOOKMARKS row shows
   `<file>:42` chip + relative date.
2. Scroll away, then click the `<file>:42` BOOKMARKS row. → re-opens / focuses
   the file and **scrolls to line 42**; gutter dot visible.
3. Add a *file* bookmark on the same file (⌘D). → BOOKMARKS now has a file-kind
   row AND a line-kind row for the same path.
4. Toggle the **L** filter chip (`mdv.bookmarks.chip.line`) on, **F** off. →
   only line bookmarks remain visible; chip is accent-tinted; count badge
   reflects shown/total.
5. Toggle **F** back on, **L** off → only file bookmarks; then both on.
6. Change BOOKMARKS sort (`mdv.bookmarks.sort`) Recent → Name → Created. → row
   order changes accordingly (Name case-insensitive; Created = addedAt asc).

**Expected**
- Line bookmark round-trips: set → gutter dot → jump scrolls to the exact line.
- F/D/L chips filter independently and the count badge tracks shown/total.

**Variations / edge states**
- **⌥⌘D toggle-off:** ⌥⌘D again on the same line removes the line bookmark and
  its gutter dot.
- **Editor mode:** repeat the jump after switching the tab to Editor (CM6) —
  line targeting still scrolls correctly.
- **Malformed entry tolerance:** a stored entry with a bad `addedAt` shows
  `just now`; a missing `line` falls back to a file bookmark (no crash).
- **Directory bookmark (D chip):** bookmark a *folder* via tree context menu;
  the **D** chip then has something to filter; folder-ness is FS-stat cached.

---

## SFB-05 — Shoulder rail panel toggles drive the accordion; data-presence dims/fills icons

**Combines:** left shoulder rail PanelRailButtons · per-kind toggle
(`mdv.rail.left.<kind>`) · accordion panel show/hide · SidebarDataPresence
fill/unfill · Recents-has-data fix · panel placeholder envelopes ·
divider gating (no bunched hairlines).

**Preconditions**
- A folder rooted (so FILES has data). Ideally a git repo so the Git rail can
  fill. At least one file opened (so Recents has data).

**Steps**
1. Observe the left rail (`mdv.rail.left`). → one SF-symbol button per
   `SidebarPanelKind` (Files / Bookmarks / Search / Git / Claude / LSP-Outline /
   References / Problems / Recent / Plugins). Buttons whose panel has data are
   filled; empty ones are faint.
2. Click the **Bookmarks** rail button (`mdv.rail.left.bookmarks`). → toggles
   the BOOKMARKS accordion panel visibility; icon shows accent fill when
   visible. Click again → hides; **no leftover divider hairline** below it.
3. Click **Git** (`mdv.rail.left.git`) in a repo. → Git panel appears with
   data; in a *non-repo* root, force-showing it renders the
   `Not a git repository.` placeholder (fixed envelope, not a collapse).
4. Click **Recent** (`mdv.rail.left.recent`). → after having opened ≥1 file the
   Recents button is **filled** (regression: it used to be permanently
   no-data); panel lists recents.
5. Force-show several panels at once (Files + Bookmarks + Git + Claude +
   Outline + Problems + Recent). → the accordion **scrolls** inside
   `mdv.sidebar.accordionScroll` past its window-derived ceiling; StatusBar
   stays on screen (does NOT get pushed past the window bottom).

**Expected**
- Each rail button toggles exactly its own panel; hidden panels drop both
  themselves and their trailing divider (no stacked hairlines below GIT).
- Over-subscription is bounded + clipped, not chrome-destroying (P1 fix).

**Variations / edge states**
- **Sidebar hidden:** with `⌃⌘S` off, the entire left rail is hidden (master
  switch) — no orphan buttons.
- **Forced-shown empty panels:** force-show Outline on a `.md` file →
  `No language server for this file.`; Claude with no transcripts →
  `No Claude activity`; each keeps a fixed-height envelope.
- **Rail contrast:** rail must be white (`Palette.textBackground`) with the
  1.5pt inner separator — icons full-strength, not vanished against white.

---

## SFB-06 — Resize the sidebar and individual accordion panels; persistence across relaunch

**Combines:** drag right-edge resize (`mdv.sidebar.resizeHandle`) · width
persist · ResizableSectionDivider per-panel resize · per-panel @AppStorage
persist · ~120px floor · BoundedAccordionScroll · narrow-header icon-only
collapse.

**Preconditions**
- A folder rooted; ≥2 accordion panels visible (e.g. FILES + BOOKMARKS + GIT).

**Steps**
1. Drag the sidebar's right edge wider, then narrower. → tree reflows live
   (no jank — implicit animations disabled); width persists at drag-end.
2. Drag the sidebar narrow, below ~248pt. → header menu value labels collapse
   to **icon-only** (sort / recency / folder-stats menus), footer metrics
   truncate cleanly.
3. Grab a section divider (`mdv.sidebar.resizeHandle`) between FILES and
   BOOKMARKS and drag down. → the panel above grows; clamped at a ~120px floor
   (won't collapse into the divider).
4. Quit and relaunch (preserve workspace). → sidebar width AND per-panel
   heights are restored from `@AppStorage` / PreferencesStore.

**Expected**
- Resize is smooth and the geometry survives relaunch.

**Variations / edge states**
- **Min-width clamp:** drag the sidebar to its minimum — tree stays usable, no
  negative/zero-width body pass; first-paint with width=0 shows full labels
  then settles.
- **Reset window state:** Settings ▸ Advanced ▸ Reset window state → on next
  launch the sidebar width returns to default (the persisted key is actually
  removed now, not a no-op).

---

## SFB-07 — Sort & recency-color modes; recency heatmap stripe reflects file age

**Combines:** sort menu (Name/Size/Recent/Added) · recency-color menu
(Modified/Added/Created) · 3px left-edge recency stripe
(`mdv.sidebar.fileRow.recencyStripe.<tier>`) · @AppStorage persist ·
clock-skew clamp.

**Preconditions**
- A scratch tree where files have **distinct, controlled mtimes**: one touched
  now (today), one ~3 days old (week), one ~20 days (month), one ~80 days
  (quarter), one ~1 year (older).

**Steps**
1. Open the sort menu (`mdv.sidebar.sort`), pick **Recent**. → rows reorder
   most-recently-modified first; folders still grouped first.
2. Switch sort to **Name**, then **Size**, then **Added**. → ordering changes
   each time; selection/expansion preserved.
3. Open recency-color menu (`mdv.sidebar.recencyMode`), keep **Modified**. →
   each row's 3px left stripe colors by tier; assert distinct
   `mdv.sidebar.fileRow.recencyStripe.today/week/month/quarter/older` ids match
   the controlled mtimes.
4. Switch recency mode to **Created**, then **Added**. → stripe tiers recompute
   against the new timestamp source.

**Expected**
- Sort and recency modes persist across relaunch; stripes correctly bucket the
  controlled-age fixtures.

**Variations / edge states**
- **Future-dated file:** `touch` a file with an mtime in the future → its tier
  clamps to `.today` (no negative-age tier).
- **First paint:** before `onAppear` stats land, stripes default to `.older`
  then correct — should not flicker through wrong tiers persistently.
- **Recency cache bound:** large tree → recency-attr cache bounded (2048),
  coldest evicted, no unbounded growth.

---

## SFB-08 — Git-aware sidebar: status badges, repo-root glyphs, folder-stats panel

**Combines:** git status badges in FILES (M/A/D/R/C/U/I/conflict) · repo-root
folder glyph variants · tracked accent dot · folder-stats slide-down
(`mdv.sidebar.folderStats`, `folder-stats on`) · FSEvents + git-status
re-list · memoized git-root (no FS-walk per body).

**Preconditions**
- A scratch **git repo** rooted in the sidebar with deliberate churn: one
  **modified-staged** file, one **modified-unstaged**, one **untracked**, one
  clean. A nested submodule or sub-repo optional for glyph variety.

**Steps**
1. Root the repo. → tracked files show colored status-letter badges (M for
   modified, U/I/A as appropriate); the repo-root folder glyph reflects tracked
   state (gearshape-badge top-level, filled accent dot when tracked/live).
2. Toggle folder-stats (`mdv.sidebar.folderStats` / `folder-stats on`). → a
   slide-down panel under the FILES header shows repo aggregates.
3. Externally `git add` the unstaged file (or edit a tracked file). → within
   ~1s FSEvents triggers a re-list and the badge updates (M→A etc.) **without**
   manual refresh.
4. Toggle folder-stats off (`folder-stats off`). → panel collapses; FILES
   header returns to compact layout.

**Expected**
- Badges accurately reflect git status and update live; folder-stats toggle is
  only offered inside a repo.

**Variations / edge states**
- **Non-repo root:** root a plain folder → **no** badges/glyphs/tracked dot,
  and the folder-stats toggle is hidden (repo-only).
- **Perf guard:** rooting a repo must NOT walk ~64 `fileExists` toward `/` per
  body pass (git-root is memoized on SidebarModel; recompute only on
  root/.git change).
- **Conflict/rename:** create a merge-conflict or rename → C / R badge renders
  with its distinct color.
- **Big-output git:** a repo with >64KB `git status` output must not deadlock
  (concurrent pipe drain) — sidebar still populates.

---

## SFB-09 — File context menu: Open in New Tab / Split / Open As… / Copy Path / Reveal / File History

**Combines:** file-row right-click menu · Open / Open in New Tab / Open in
Split · Open As… submenu (forces a viewer) · Bookmark-or-Remove · Copy Path /
Copy Relative Path · Reveal in Finder · File History (disabled when untracked).

**Preconditions**
- A git repo rooted (so File History enables) with a tracked `.json` and an
  untracked binary (e.g. `.png`).

**Steps**
1. Right-click the tracked `.json` row. → context menu lists Open / Open in New
   Tab / Open in Split / Open As… / Bookmark / Copy Path / Copy Relative Path /
   Reveal in Finder / File History.
2. Choose **Open in New Tab**. → a new tab opens (existing tab preserved).
3. Right-click the `.png`, choose **Open As… ▸ HEX** (or
   `set-open-as hex` / `open-as binary <path>`). → opens forced into HEX; the
   Open-As chip shows accent-tinted (override active).
4. Choose **Copy Relative Path** on the `.json`. → clipboard holds the
   repo-relative path (verify via paste / `current_state`).
5. Choose **File History** on the tracked file. → File History view opens; on
   the **untracked** `.png` it is **disabled**. The *gating on repo membership*
   is this smoke's concern — the master-detail commit Table / single-vs-range
   diff *view* itself is owned by `git-panel.md` **GP-09** (do not re-walk it).
6. Choose **Reveal in Finder**. → Finder opens with the file selected (live UI
   only).

**Expected**
- Menu items act on the right-clicked row regardless of current selection;
  File History gating tracks repo membership.

**Variations / edge states**
- **Open in Split** on a >64MiB file → split shows `File too large for split
  view` placeholder.
- **Open As… SQLite in split:** unsupported → `Open SQLite files in the main
  pane.`
- **Copy Path vs Copy Relative Path** outside a repo: relative path may fall
  back to the absolute (no crash).

---

## SFB-10 — Folder context menu: Open in New Session, Set as Git Root, Search in Folder, Open in Terminal

**Combines:** folder-row right-click menu · Open Folder (re-root) · Open in New
Session (`session-open-new`) · Pin/Unpin Repo · Set as Git Root · Search in
Folder (pre-seeds Search Anywhere scope) · Open in Terminal · Show Folder
History.

> **Scope note (dedup):** this smoke owns the **folder context-menu entry
> points**. The *destinations* are owned elsewhere and only checked here for
> "the item launches the right thing": Open-in-New-Session session
> create/switch/restore → `sessions.md` **SESS-01/05**; Set-as-Git-Root /
> Show-Folder-History panel behavior → `git-panel.md` **GP-07/GP-10**; Search-in-
> Folder scope seeding → `search.md` **SMK-SEARCH-03/04**. Don't re-walk those.

**Preconditions**
- A git repo with subfolders rooted in the sidebar; SessionsApp present
  (session tab bar visible).

**Steps**
1. Right-click a subfolder. → folder context menu lists Expand/Collapse / Open
   Folder / Open in New Session / Bookmark / Set as Git Root / Copy Path / Copy
   Relative Path / Reveal in Finder / Open in Terminal / Search in Folder /
   Show Folder History (tracked).
2. Choose **Open in New Session** (`session-open-new <subfolder>`). → a new
   session pill appears in the session tab bar rooted at that subfolder; the
   prior session is preserved.
3. Switch back to the original session. → its sidebar root, tabs, and expansion
   state are restored (per-session snapshot).
4. On the original session, right-click a folder → **Search in Folder**. → the
   Search Anywhere section opens with that folder pre-set as scope.
5. Right-click a repo-root folder → **Set as Git Root**. → the Git panel /
   badges re-anchor to that root.

**Expected**
- Open in New Session spawns an independent session; switching sessions
  restores each one's sidebar/tab state.

**Variations / edge states**
- **No SessionsApp:** in a single-session build the `Open in New Session` item
  is absent (no session tab bar).
- **Open in Terminal:** opens Terminal at the folder (live UI only).
- **Bookmark a folder:** folder bookmark shows under the D chip; right-click in
  BOOKMARKS offers `Open in New Session` for it.

---

## SFB-11 — Reveal-in-Sidebar from a tab, with Files-lock interplay

**Combines:** TabBar / tab context-menu **Reveal in Sidebar** · auto-root
switch + ancestor expand + select · Files-lock toggle blocking re-root ·
follow-active-tab.

**Preconditions**
- Two folders under tmp, each with files; sidebar rooted at folder **A**; a tab
  open for a file inside folder **B** (e.g. opened via `open <B>/x.md` or ⌘O).

**Steps**
1. With the folder-B file active, invoke **Reveal in Sidebar** from the tab
   context menu. → sidebar switches root to folder **B** (since the file is
   outside A), expands ancestors, and selects the target row.
2. Turn the **Files lock** toggle ON. Switch to a tab inside folder **A** and
   invoke Reveal in Sidebar. → with lock on, the root does **not** change
   (reveal is suppressed / no re-root); selection only updates if the target is
   already within the current root.
3. Turn Files lock OFF; repeat Reveal. → re-root works again.

**Expected**
- Reveal re-roots only when needed and only when Files-lock permits it.

**Variations / edge states**
- **Target already in current root:** Reveal just expands + selects, no re-root.
- **`/var` vs `/private/var` twin:** a file under a symlinked tmp path resolves
  to the same node — Reveal selects it, no dedup asymmetry.
- **Deleted target:** Reveal on a tab whose file was deleted → graceful no-op /
  error tab, sidebar unchanged.

---

## SFB-12 — Show-hidden, sort, recency, bookmarks all persist per-session across relaunch

**Combines:** Show-hidden checkbox · sort + recency @AppStorage · sidebar
expansion set persist · per-session restore (root/tabs/expansion/include-hidden/
split/panel-layout) · BookmarksStore persist · 30-day session trash recovery
(observational).

> **Scope note (dedup):** this smoke owns the **sidebar-preferences** survival
> (show-hidden, sort, recency, expansion, bookmarks) across relaunch. The
> *session-machinery* edges it touches — per-session capture/leak-guard,
> bloated-snapshot dedup+`maxRestoredTabs=200` clamp, schema-downgrade refusal,
> TCC-root restore skip, missing-file drop, global-vs-per-session split — are
> owned by `sessions.md` **SESS-05/06/07** with deeper assertions; they appear
> here only to confirm sidebar prefs ride the per-session snapshot correctly.

**Preconditions**
- A git repo with dotfiles rooted; a couple of files open; one file + one line
  bookmark set; Show-hidden ON; sort = Recent; a couple of folders expanded.

**Steps**
1. Establish state: Show-hidden ON (dotfiles visible), sort Recent, expand
   `sub` and `sub2`, bookmark `a.md` (⌘D) and a line in `b.txt` (⌥⌘D).
2. Quit the app (⌘Q) and relaunch. → workspace restores: same root, same open
   tabs (lazy: focused materializes), **Show-hidden still ON**, sort still
   Recent, `sub`/`sub2` still expanded, both bookmarks present with stars.
3. Open the BOOKMARKS section. → file + line bookmarks intact; line bookmark
   still jumps to its line; gutter dot present.
4. Open a **second session** on another folder, set Show-hidden OFF there,
   switch back. → each session keeps its own include-hidden / expansion / root
   (per-session snapshot); global zoom/wrap/theme are shared (NOT per-session).

**Expected**
- All sidebar prefs + bookmarks survive relaunch; per-session sidebar state is
  independent while zoom/wrap/theme stay global.

**Variations / edge states**
- **Missing files on restore:** if a restored tab references a deleted file,
  it's dropped with a notice; sidebar still roots fine.
- **TCC-protected root:** if the persisted root is under
  `~/Documents`/`~/Desktop`/`~/Downloads`, restore skips re-rooting there (no
  TCC prompt, never writes there).
- **Bloated snapshot:** a snapshot with thousands of restored tabs is deduped +
  clamped (maxRestoredTabs=200) — relaunch footprint stays bounded, sidebar
  still usable.
- **Schema downgrade:** a future-schema `_last.json` is refused (not silently
  destroyed); sidebar falls back to a clean empty session.

---

## Notes for the runner

- The bare `swift test` headless gate does NOT open a live window; these smokes
  are the **T4 LiveAppTestCase / VM** lane. Run against installed
  `dist/TextView.app`, occluded, single-threaded.
- macOS 15 Sequoia "Screen Capture Privacy" redacts `screencapture(1)` of
  launchctl-asuser windows on the VM — `snapshot_window` / `snapshot` may come
  back blank/censored there; eyeball the UTM display or assert on
  `current_state` / model dumps instead of pixels for those steps.
- Bookmark TOCTOU (symlink swap after add) is a known **unaddressed** gap — do
  not author a smoke that depends on it being defended.
- Manual-drag bookmark reorder is **not user-reachable** (BookmarksStore.move()
  exists but the section doesn't wire `.onMove`/`.draggable`) — skip any
  reorder-by-drag step.
