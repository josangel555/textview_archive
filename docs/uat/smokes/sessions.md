# UAT Smokes — Sessions (tabs-within-tabs / nested workspaces)

Area: **Window chrome / navigation — Session tab bar + per-session workspace persistence & restore.**

This file holds durable, re-runnable user-acceptance smokes for the *sessions*
feature: the top-most pill strip above the per-file `TabBar` (one pill per open
folder/project), session create / activate / rename / close, the LRU
re-activation rule, per-session workspace capture & restore, and the GLOBAL vs
per-session state split.

Each smoke deliberately **combines several features into one realistic flow** —
the bugs in this area (per-session tabs lost on switch, 998 MB bloated restore,
HOME re-root, split/sidebar leak across the shared `DocumentModel`,
GLOBAL-vs-per-session zoom) only surface when surfaces interact.

---

## App under test & how to drive it

- **Live app:** `dist/TextView.app` (Finder name TextView; bundle id
  `com.markdownviewer.MarkdownViewer`). Sessions UI only appears when the app is
  launched with the `sessionsApp` coordinator injected (the normal app launch).
- **Two equivalent driving surfaces** — every smoke below lists the **UI action**
  and, where it exists, the **script verb** that drives the identical
  `SessionsAppCoordinator` call (the script runner can't click the SwiftUI pills,
  so the VM/T4 harness uses verbs and asserts on the `model.sessions` dump):

  | Intent | UI action | Script verb | Keyboard |
  |---|---|---|---|
  | New session from a folder (reveal-or-create) | sidebar/bookmark folder ▸ "Open in New Session" | `session-open-folder <path>` | — |
  | New session, force distinct (worktree/symlink twin) | `+` then GoTo, or "Open in New Session" | `session-open-new <path>` | ⇧⌘N (arms GoTo) |
  | Activate session N (1-based) | click pill | `session-activate <N>` | ⌃1–9 |
  | Next / previous (wraps) | — | `session-next` / `session-prev` | ⌃⇥ / ⌃⇧⇥ |
  | Close active session | pill ×, or context ▸ Close Session | `session-close-active` | ⇧⌘W |
  | Rename active session | double-feel context ▸ Rename Session → inline field | `session-rename <name>` | — |
  | Close others | context ▸ Close Other Sessions | — | — |

- **A11y ids** (VM UI tests target these — keep in sync with `SessionTabBar.swift`):
  - `mdv.sessionTabBar` — the row container
  - `mdv.sessionTab.<uuid>` — each pill (click/select target)
  - `mdv.sessionTab.close.<uuid>` — the × button on a pill
  - `mdv.sessionTab.rename.<uuid>` — inline rename `TextField` (only while renaming)
  - `mdv.sessionTab.new` — the trailing `+` button
- **On-disk state:** `~/Library/Application Support/com.markdownviewer.MarkdownViewer/Sessions/index.json`
  (the list + `lastActiveID`) plus one `Sessions/<uuid>.json` per session. Closed
  sessions are staged under `Sessions/trash/` for a 30-day recovery window
  (GC'd ~one beat after launch).
- **Clean-room launch:** set `MDV_SKIP_WORKSPACE_RESTORE=1` to start with an empty
  strip regardless of on-disk state (use this to make restore assertions
  deterministic — open exactly the sessions the smoke needs, quit, relaunch
  *without* the flag to observe restore).

### Test scratch — never touch real user folders

All fixture folders/files MUST live under `FileManager.default.temporaryDirectory`
(`/var/folders/...`). **Never** seed sessions rooted at `~/Documents`, `~/Desktop`,
`~/Downloads` — those are TCC-protected, and touching the real user's folders
from a smoke is forbidden hygiene-wise. Note the policy since TSK-599
(2026-06-10): an **explicit** `openFolder` (context menu / open panel / script
verb) DOES open + persist a session under those roots — the user's gesture is
the opt-in; only the **implicit** launch-time paths (`bootstrap()` prefs seed,
`restorePreviousFolderIfAvailable`) still refuse them
(`isUnderTCCProtectedRoot`). A smoke must still never point there — it would
enumerate the real folder and can trigger a TCC prompt on the runner.

> NOTE — `/var/folders` is a symlink twin of `/private/var/folders`. The
> coordinator standardizes + resolves symlinks for its session-dedup key, so
> create fixtures with `mktemp -d` and use the path as-returned; expect the
> persisted `sidebarRootPath` to be the **resolved** path.

---

## SESS-01 — Create two sessions, each keeps its own tabs across a switch

**Combines:** new-session create (reveal-or-create) · per-file tabs inside a
session · session switch (detach→snapshot→mount) · per-session tab capture &
re-hydrate · session pill selection/active styling.

This is the headline regression guard for "my tabs disappeared when I switched
session" (#184 / `makeSnapshot` hard-coded nils).

**Preconditions**
- Clean-room launch (`MDV_SKIP_WORKSPACE_RESTORE=1`), empty session strip.
- Two fixture folders under temp: `projA/` (with `a1.md`, `a2.txt`) and
  `projB/` (with `b1.json`, `b2.csv`, `b3.md`).

| # | Action | Expected result |
|---|---|---|
| 1 | `session-open-folder <tmp>/projA` (or sidebar folder ▸ Open in New Session) | One pill appears in `mdv.sessionTabBar`, label `projA`, accent-tinted + semibold (active). Sidebar roots at `projA`. |
| 2 | Open `a1.md` then `a2.txt` (sidebar single-click) | `TabBar` shows 2 file tabs; `a2.txt` focused. Status bar shows the file path. |
| 3 | `session-open-folder <tmp>/projB` | A **second** pill `projB` appears and becomes active; `projA` pill goes dim/regular. The per-file `TabBar` now shows projB's tabs only (empty until step 4). Sidebar re-roots to `projB`. |
| 4 | Open `b1.json`, `b2.csv`, `b3.md` | projB tab strip shows 3 tabs. |
| 5 | Click the `projA` pill (`session-activate 1`) | projA reactivates; **the per-file TabBar shows projA's 2 tabs again, with `a2.txt` re-selected** — NOT empty, NOT projB's tabs. Sidebar re-roots to projA. |
| 6 | Click the `projB` pill (`session-activate 2`) | projB reactivates; its 3 tabs return with `b3.md` selected. |

**Expected end state:** two pills, switching restores each session's exact tab
list + selected tab + sidebar root. No tab leakage between sessions.

**Variations / edge-states**
- **Re-open same folder, no force:** `session-open-folder <tmp>/projA` while projA
  already exists → does NOT create a duplicate pill; it just **reveals/activates**
  the existing projA (resolved-path match).
- **Symlink twin:** create `projA-link` → `projA` via `ln -s`; `session-open-folder`
  on the link collapses onto the existing projA pill (resolved path dedup), no
  second pill.
- **Worktree / genuine duplicate:** `session-open-new <tmp>/projA` (force) **does**
  create a second pill over the same realpath — two pills, same root.
- **Selected-tab edge:** in step 5, if projA's previously-selected tab's file was
  deleted between switches, expect the first surviving tab selected (graceful
  fallback), not a crash or blank pane.

---

## SESS-02 — `+` button → Go-to-path prompt → new session (the empty-entry flow)

**Combines:** `mdv.sessionTab.new` button · first-paint GoTo gate arm · GoToPath
prompt (`mdv.goto.*`) · "Open in New Session" routing · session create from a
typed path · NSOpenPanel fallback.

The `+` button intentionally does NOT pop NSOpenPanel directly — it arms a
one-shot gate that the content view consumes to present `GoToPathPrompt`, giving
the new session an explicit entry point instead of a blank window.

**Preconditions**
- App running with ≥1 existing session (so the strip + `+` are visible).
- Fixture folder `<tmp>/projC` exists; one fixture **file** `<tmp>/loose.md` exists.

| # | Action | Expected result |
|---|---|---|
| 1 | Click `mdv.sessionTab.new` (the `+`) | The `GoToPathPrompt` panel (`mdv.goto.panel`) appears centered over a scrim; path field (`mdv.goto.field`) autofocused. No session created yet. |
| 2 | Type `<tmp>/projC` (absolute) and click **Open in New Session** (`mdv.goto.openNewSessionButton`) — or Shift+Return | Prompt dismisses; a new `projC` pill appears, becomes active, sidebar roots to projC. |
| 3 | Click `+` again, then **Open System Dialog…** (`mdv.goto.systemDialogButton`) and pick `<tmp>/projC` again | Reveals the existing projC pill (no duplicate); panel dismisses. |

**Expected end state:** session count incremented by exactly 1 (projC); the
system-dialog pick of an already-open folder reveals rather than duplicates.

**Variations / edge-states**
- **File path, not folder:** in step 1, type `<tmp>/loose.md`. The **Open in New
  Session** button is disabled (`canOpenInNewSession == false`) — a session must be
  a folder. Plain **Open** still opens the file (in the active session).
- **Relative / non-absolute path:** typing `projC` (no leading `/` or `~`) shows
  inline error `Path must be absolute…` (`mdv.goto.error`); no session created.
- **Nonexistent path:** typing `<tmp>/does-not-exist` → `No file or folder at that
  path.`; Open disabled-or-no-op.
- **Esc / Cancel / tap scrim** dismisses the prompt and leaves the gate consumed —
  clicking `+` again re-arms and re-presents (token bumps; not stuck).
- **Empty field** → Open button disabled.

---

## SESS-03 — Rename a session inline; persists and survives relaunch

**Combines:** context menu ▸ Rename Session · inline `TextField`
(`mdv.sessionTab.rename.<uuid>`) commit/cancel · empty/whitespace/no-op guards ·
coalesced persistence · restore of the renamed displayName.

**Preconditions**
- App running; one session `projA` active (label currently `projA`).

| # | Action | Expected result |
|---|---|---|
| 1 | Right-click the `projA` pill ▸ **Rename Session** | The label is replaced by an inline `TextField`, pre-filled with `projA`, focused, text selected-ish. |
| 2 | Replace with `Backend API` and press **Return** | Field commits; pill now reads `Backend API` (middle-truncated if >32 chars). The persisted snapshot + `index.json` entry update via the coalescing queue. |
| 3 | Right-click ▸ Rename, clear the field entirely, press Return | **No-op** — the empty/whitespace name is rejected by the guard; pill stays `Backend API`. |
| 4 | Quit (⌘Q) and relaunch (no skip flag) | The session restores with displayName `Backend API` (not the folder leaf). |

**Expected end state:** display name `Backend API` round-trips through disk;
empty rename never clobbers.

**Variations / edge-states**
- **Esc mid-rename** (`onExitCommand`) → cancels, original name retained, no write.
- **Whitespace-only** (`"   "`) → trimmed to empty → rejected (no-op).
- **Unchanged name** committed → equality guard makes it a no-op (no spurious write).
- **Very long name** (>32 chars) → pill shows a middle-ellipsis
  (`SessionTabLabel.truncated`), e.g. `Long head…tail`; full name in the tooltip.
- **Script-verb form:** `session-rename Backend API` renames the *active* session
  (same guards).

---

## SESS-04 — LRU re-activation: closing the active session selects most-recently-used, not adjacent

**Combines:** ⌃1–9 / pill activation order · `lastActiveAt` LRU bump on BOTH
outgoing and incoming · close-active flow · trash staging · next-active selection
by LRU (not list position) · empty-state when last closed.

This guards the "A→B→A, close A re-activates B even though I just used A" bug
(both endpoints' `lastActiveAt` now bump).

**Preconditions**
- Clean-room launch. Three fixture folders `projA`, `projB`, `projC`.

| # | Action | Expected result |
|---|---|---|
| 1 | Open projA, then projB, then projC (in that order) | Three pills in creation order A, B, C; C active. |
| 2 | Activate projB (`session-activate 2` / ⌃2), then activate projC (⌃3), then activate projA (⌃1) | Active is now projA. LRU order (most→least recent): A, C, B. |
| 3 | Close the active session (projA) via pill ×, context ▸ Close Session, ⇧⌘W, or `session-close-active` | projA pill disappears; **projC** becomes active (most-recently-used remaining), NOT projB (the list-adjacent neighbor). |
| 4 | Close projC | projB becomes active (only one left). |
| 5 | Close projB | Strip drops to its **empty state** — only the `+` button remains; `activeID` cleared. |

**Expected end state:** closes always re-activate by recency; closing the last
leaves an empty strip with `+`.

**Variations / edge-states**
- **Close a NON-active session** (× on an inactive pill) → it's removed, active
  session unchanged, no re-activation churn.
- **Close Other Sessions** (context menu) on projC when A/B/C open → A and B close
  (each through the full close pipeline: trash + persist), projC remains sole
  active pill. "Close Other Sessions" is **disabled when ≤1 session**.
- **Recovery window:** a closed session's `<uuid>.json` is moved to `Sessions/trash/`
  (not deleted) — verify the file exists there immediately after close. (No
  in-app recovery UI exists yet; this is a disk-level assertion.)
- **next/prev wrap:** with A,B,C and B active, `session-next` twice → C then A
  (wraps); `session-prev` from A → C.

---

## SESS-05 — Per-session split pane, sidebar expansion & include-hidden are captured per session (no leak through the shared model)

**Combines:** Open in Split (⌘\) · sidebar tree expansion · Show-hidden toggle ·
session switch · FAÇADE LEAK GUARD (Phase-1 shares one `DocumentModel`, so a
switch must RESET split/sidebar/hidden, not leak A's into B).

**Preconditions**
- Clean-room launch. `projA` (a folder with a subdir `projA/sub/` containing
  `nested.md`, plus a dotfile `projA/.hidden.md`) and `projB` (plain, no split,
  no hidden, collapsed).

| # | Action | Expected result |
|---|---|---|
| 1 | Open projA; expand the `sub/` folder in the sidebar; toggle **Show hidden** ON (so `.hidden.md` is visible) | Sidebar shows `sub/` expanded and `.hidden.md` listed. |
| 2 | Open `sub/nested.md`, then Open in Split (⌘\) a second file so a split pane is showing | Two viewer panes side-by-side; projA has a live split. |
| 3 | Open projB (new session) | projB active; **split pane is CLOSED** (projB has none — not leaked from projA); sidebar shows projB collapsed; Show-hidden is **OFF** (reset, not leaked). |
| 4 | Switch back to projA | projA's split pane returns; `sub/` is expanded again; Show-hidden is back ON; `.hidden.md` visible. |
| 5 | Quit + relaunch (no skip flag) | projA restores with split pane + expanded `sub/` + hidden-shown; projB restores collapsed, no split, hidden-off. |

**Expected end state:** split / expansion / include-hidden are strictly
per-session both across a live switch and across relaunch; switching to a session
that lacks a given state RESETS it rather than inheriting the previous session's.

**Variations / edge-states**
- **Dangling split on restore:** if projA's split file is deleted before relaunch,
  restore opens projA with NO split (the missing split URL is skipped, no error
  pane).
- **Expanded path deleted:** if `sub/` is deleted before relaunch, projA restores
  with that expansion silently dropped (no crash).
- **Sidebar width / zoom are NOT per-session** — see SESS-06; don't assert them here.

---

## SESS-06 — GLOBAL zoom / word-wrap / theme are app-wide, NOT per-session

**Combines:** ⌘= / ⌘- / ⌘0 zoom · Wrap toggle (⌥⌘W) · theme override ·
session switch · the #184 owner-LOCKED decision that zoom/wrap/theme are GLOBAL.

The snapshot deliberately writes `nil` for these and hydrate skips them — a
session switch must NOT yank the app's zoom/wrap/theme to whatever a project last
had.

**Preconditions**
- App running; two sessions `projA`, `projB`. A text file open in each.

| # | Action | Expected result |
|---|---|---|
| 1 | In projA, zoom in twice (⌘= ⌘=) so the readout shows ~120% | Content + chrome scale up; readout ~120%. |
| 2 | Toggle Word-Wrap ON (⌥⌘W) in projA's source view | Long lines wrap. |
| 3 | Switch to projB | Zoom **stays ~120%** and wrap **stays ON** in projB — the global setting is preserved across the switch (NOT reset to projB's old value, because there is no per-session value). |
| 4 | In projB, zoom to actual size (⌘0) | Readout 100%. |
| 5 | Switch back to projA | projA also shows **100%** now — zoom is a single global value shared by all sessions, not restored per session. |
| 6 | Quit + relaunch | Zoom restores to the last GLOBAL value (from `PreferencesStore`), identical for every session. |

**Expected end state:** zoom/wrap/theme are one app-wide value; changing them in
any session changes them everywhere; relaunch restores the global value, not a
per-session one.

**Variations / edge-states**
- **Pre-#184 on-disk file:** a legacy snapshot that *did* persist a per-session
  `zoom`/`wordWrap`/`themeOverride` must decode without crashing and those fields
  must be **ignored** on hydrate (downgrade-safe additive-optional).
- **Theme:** flipping Settings ▸ Appearance theme applies app-wide and is not
  scoped to the active session (note: theme override is in-memory and not
  persisted today — verify it applies across sessions in the same launch).

---

## SESS-07 — Restore on relaunch: skip unreadable / missing-root sessions, never re-root at HOME, heal bloat

**Combines:** quit→relaunch restore · `index.json` + per-session file read ·
skip-corrupt-snapshot · skip-empty-root (PERSIST-10 HOME re-root guard) ·
missing-folder tolerance · `lastError` notice surfacing · dedup + 200-tab cap
(998 MB → 55 MB heal) · lazy tab materialization.

**Preconditions**
- Clean-room launch. Create 3 sessions: `projA` (2 real files open), `projB`
  (root folder will be deleted before relaunch), `projC` (good). Quit to flush
  `index.json` + snapshots.

| # | Action | Expected result |
|---|---|---|
| 1 | After clean quit, confirm `Sessions/index.json` and three `<uuid>.json` files exist | On-disk state present; `lastActiveID` = whichever was active at quit. |
| 2 | Delete projB's root folder on disk (simulate a removed external drive); relaunch (no skip flag) | App restores projA + projC pills. projB: a non-empty-but-currently-missing root is **still restored** as a pill (recovers if the folder reappears) — it does NOT re-root at HOME and does NOT crash. |
| 3 | Inspect the active session's tabs after relaunch | Only the **focused** tab's file is read at launch (lazy); other tabs appear as lazy/empty until selected — launch is fast, not 15 synchronous reads. |
| 4 | Select a previously-open tab in projA | The file materializes and renders; selection restores by **path** (not stale index). |

**Expected end state:** good sessions restore; a missing-folder session restores
harmlessly; nothing silently re-roots at `$HOME`.

**Variations / edge-states**
- **Empty/nil sidebarRoot snapshot:** hand-craft a `<uuid>.json` whose
  `sidebarRootPath` is empty → on restore it is **dropped from the live list** (file
  stays on disk, non-destructive) and `lastError` carries a "Skipped N session(s)
  whose folder is missing." notice. This is the HOME-re-root guard (PERSIST-10).
- **Corrupt snapshot:** truncate one `<uuid>.json` to garbage → that session is
  skipped + counted in `lastError` ("Skipped N unreadable session snapshot(s)."),
  the rest restore.
- **Newer-schema index (downgrade):** bump `index.json` `version` past the build's
  `currentSchema` → live list is empty, `indexWriteBlocked` true (the index is NOT
  overwritten so the newer build's fields survive), `lastError` explains the
  version mismatch. Per-session snapshot writes stay safe.
- **Bloat heal:** seed a snapshot with ~2000 tab entries referencing ~35 unique
  files (a pre-fix bloated file). Relaunch → tabs deduped to the unique set and
  clamped to `maxRestoredTabs = 200`; launch footprint sane (~tens of MB, not ~1
  GB); the next clean snapshot write persists the healed list.
- **Missing tab files:** a restored session referencing files that no longer exist
  drops those tabs with a notice but keeps the session; selection falls back to the
  first surviving tab.

---

## SESS-08 — Inactive-session watcher is paused; active session auto-reloads; no cross-session stale events

**Combines:** detach pauses `FileWatcher` (mount/detach lifecycle) · active session
auto-reload on external file change · session switch resume · boundURL guard
(a stale watcher event must not corrupt the wrong session's tab).

**Preconditions**
- App running; two sessions projA, projB. In projA, `a1.md` is open and focused.
  In projB, `b1.md` is open and focused.

| # | Action | Expected result |
|---|---|---|
| 1 | With projA active, externally edit `a1.md` on disk (append a line) | projA's view auto-reloads within ~1s (active session watcher live); status bar reflects new size. |
| 2 | Switch to projB (projA detaches → its watcher pauses) | projB active, `b1.md` shown. |
| 3 | Externally edit `a1.md` again while projB is active | projA is detached, so **no reload churn / no flash on the visible projB view**; projB's `b1.md` is untouched (no cross-session event bleed). |
| 4 | Switch back to projA | projA mounts → watcher resumes; the file reconciles to current disk contents on/after re-mount (no stale truncated state). |

**Expected end state:** only the active session watches+reloads; switching pauses
the old watcher and resumes the new; an edit to a detached session's file never
mutates the visible session.

**Variations / edge-states**
- **Editor-style atomic write** (rename-over) of `a1.md` while projA active →
  watcher reattaches and reload still fires (atomic-write reattach path).
- **Delete `a1.md` while projA active** → tab flips to the stale/red "Modified"
  status-bar affordance (or error pane), not a crash.
- **Rapid A↔B switching** while a file changes → no orphaned watcher fires into the
  wrong tab (boundURL check), no duplicate reload storms.

---

## SESS-09 — Per-session shoulder-rail panel layout: seed-once per kind, then user edits win, persisted per session

**Combines:** shoulder-rail panel toggles (`mdv.rail.*`) · per-session
`panelLayout` capture · SEED-ONCE per-kind default · FAÇADE LEAK GUARD (switch
resets layout, doesn't leak) · restore of panel layout.

Note: today every UI-created session is `.project` (the `SessionKind` picker is
not yet exposed), so the seed-once default for `.project` is the identity (empty)
layout — the meaningful assertion is **user panel edits persist per session and
don't leak across a switch**.

**Preconditions**
- App running; two sessions projA (a git repo so GIT/Problems panels are
  meaningful) and projB (plain folder, not a repo).

| # | Action | Expected result |
|---|---|---|
| 1 | In projA, click left shoulder-rail buttons to show **Git** and **Bookmarks** panels (toggle them visible) | Those accordion panels appear; the rail buttons show their active (filled) state. |
| 2 | Switch to projB | projB shows its OWN (default) panel layout — projA's Git+Bookmarks visibility does **not** leak in. (Equality-guarded `apply` of the default layout resets the shared model's rails.) |
| 3 | In projB, show the **Search** panel only | projB has Search visible. |
| 4 | Switch back to projA | projA's Git+Bookmarks return; Search (projB's choice) is gone. |
| 5 | Quit + relaunch | Each session restores its own last panel layout (projA: Git+Bookmarks; projB: Search). |

**Expected end state:** panel layout is per-session, captured + restored, and does
not bleed across a live switch on the shared `DocumentModel`.

**Variations / edge-states**
- **Forced-shown panel with no data:** in projB (non-repo), force-show the Git
  panel → it renders the `Not a git repository.` placeholder rather than vanishing
  or leaking projA's git data.
- **Unseeded legacy session:** a pre-#184 snapshot with `panelLayout == nil` →
  hydrate applies the empty/default layout (downgrade-safe), no crash.

---

## SESS-10 — Crash-recovery autosave: last ~500 ms of live state survives a SIGKILL between switches

**Combines:** debounced autosave (narrow `@Published` subscriptions:
`tabCoordinator.$tabs`, `sidebar.$rootURL`, `$zoom`, `$sourceWordWrap`,
`$themeOverride`) · equality-guard (no-op ticks don't write) · SIGKILL recovery ·
detach-time authoritative write.

This guards the original gap: state used to persist only at session-switch and
clean-quit, so a crash between them lost everything since the last switch.

**Preconditions**
- App running; one session projA active with a couple of tabs open.

| # | Action | Expected result |
|---|---|---|
| 1 | Open a new tab in projA (a `@published $tabs` change) and wait ~1s (past the ~500 ms debounce) | Autosave fires once (coalesced); `Sessions/<projA>.json` now reflects the new tab list. |
| 2 | SIGKILL the app (`kill -9`) — simulate a crash, NO clean quit | Process dies; no clean `flushForTermination`. |
| 3 | Relaunch (no skip flag) | projA restores **including the tab opened in step 1** — recovered from the debounced autosave, not lost. |

**Expected end state:** a crash loses at most ~500 ms of edits; tab/sidebar/zoom
changes made well before the crash are on disk.

**Variations / edge-states**
- **Equality guard:** a burst of no-op re-publishes (e.g. selecting the same tab,
  an equal-value zoom set) must NOT spam writes — the snapshot equals the baseline
  and `fireAutosave` returns early. (Assert via write-count instrumentation if
  available, else by `savedAt` not advancing on a no-op.)
- **Typing storm collapses to one write:** rapid changes within the debounce
  window coalesce to a single disk write per window (token-bumped reschedule).
- **Switch supersedes pending timer:** switching sessions mid-debounce
  (`disarmAutosave`) does the authoritative detach-time write for the outgoing
  session; the stale timer does not fire into the new session's file
  (`autosaveBoundSessionID` guard).

---

## SESS-11 — Jump-to-Session menu, ⌃1–9 shortcuts, and Window/Session menu reflect live state

**Combines:** Session menu (New ⇧⌘N, Next/Prev ⌃⇥/⌃⇧⇥, Jump submenu ⌃1–9, Close
⇧⌘W) · active-session checkmark · lazy menu rebuild on open · ≤9 shortcut cap.

**Preconditions**
- App running; create 10 sessions (more than the 1–9 shortcut range).

| # | Action | Expected result |
|---|---|---|
| 1 | Open the **Session** menu | Items: New Session (⇧⌘N), Next/Previous, **Jump to Session** submenu, Close Session (⇧⌘W). |
| 2 | Open **Jump to Session** submenu | One item per session in list order; the active session carries a checkmark (`.on`). Items 1–9 show ⌃1–⌃9 shortcuts; the 10th has **no** shortcut (cap is first 9). |
| 3 | Press ⌃3 | Activates the 3rd session; its pill becomes active; the checkmark in the submenu moves to it on next open (rebuilt lazily). |
| 4 | ⌃⇥ then ⌃⇧⇥ | Next then previous session (wrapping at the ends); active pill follows. |
| 5 | With ≥2 sessions, ⇧⌘W | Closes the active session (LRU re-activation per SESS-04). |

**Expected end state:** menu state tracks the live session list + active pointer;
⌃1–9 covers only the first 9.

**Variations / edge-states**
- **Empty strip:** with zero sessions the Jump submenu shows `(no sessions)`
  disabled; Next/Prev/Close are no-ops.
- **Single session:** Next/Prev are no-ops (wrap onto self); Close Other Sessions
  disabled.
- **⇧⌘N** arms the GoTo new-session flow (same as the `+` button, SESS-02) — it does
  NOT immediately pop NSOpenPanel.
- **Shortcut-collision note (known issue):** ⌃-number is session-jump; ⌘-number is
  per-file-tab select — verify they don't cross-fire (⌘3 selects file tab 3 within
  the active session, ⌃3 jumps to session 3).

---

## SESS-12 — Single-session layout: the session strip is absent until a second dimension exists

**Combines:** window chrome assembly (SessionTabBar + Divider only when
`sessionsApp` present and meaningful) · single-session vs multi-session strip ·
context-menu disable rules at count==1.

**Preconditions**
- Clean-room launch.

| # | Action | Expected result |
|---|---|---|
| 1 | Launch with zero sessions | Strip shows only the `+` button (empty state). The per-file TabBar/ModeBar/StatusBar assemble normally below. |
| 2 | Open one folder as a session | One pill + `+`. Context menu on the pill: **Close Other Sessions** is **disabled** (≤1). |
| 3 | Right-click the sole pill | Rename / Close Session enabled; Close Other Sessions disabled; Copy Path + Reveal in Finder present (because the session has a root path). |
| 4 | Open a second folder | Now 2 pills + a `Divider` between them; Close Other Sessions becomes enabled. |

**Expected end state:** strip presence + context-menu affordances scale correctly
with session count; copy-path / reveal hidden when a session has no root.

**Variations / edge-states**
- **No-root session** (theoretical/legacy): Copy Path + Reveal in Finder are hidden
  for a pill whose `sidebarRootPath` is empty.
- **Many sessions:** the strip scrolls horizontally (no cap); long names
  middle-ellipsize within minWidth 110 / ideal 180 / max 240.
- **Tooltip:** hovering a pill shows `displayName — <root path>` (or just the name
  when no root).

---

## Cross-cutting assertions (apply to every smoke)

- **No tab/state leakage** between sessions on the shared Phase-1 `DocumentModel`
  (split, sidebar root, expansion, include-hidden, panel layout all reset-or-restore
  on switch).
- **Resolved-path dedup**: same physical folder = one session unless `forceNew`.
- **TCC-safe**: no *implicit* (launch-time) path ever re-roots or persists
  anything under `~/Documents`/`~/Desktop`/`~/Downloads`. Explicit user
  gestures (context menu, open panel, script verbs) may — that's the user's
  opt-in (TSK-599, 2026-06-10).
- **Persistence is best-effort + non-destructive**: corrupt/newer-schema/missing
  inputs degrade to skip+notice, never crash, never clobber a newer on-disk schema.
- **No window opens during headless gate runs** — these are live-app (T4) smokes;
  run them on the VM lane, not the host merge gate.
