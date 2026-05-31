# WAVE 2 queue — deferred from WAVE 1 (2026-05-31)

> WAVE 1 (`wf_2ae76847-7e3`) is landing the foundations + quick-win bugs (see
> `PRIORITIZED_PLAN.md` Tier 0 + Tier 1, plus a few safe Tier 2). This file
> captures everything deferred, the decisions baked as **defaults** for the
> queued run, and the launch trigger. Full grounded detail per item is in
> `PRIORITIZED_PLAN.md` §3 + the `triage-*.md` files.

## Launch trigger
**Do NOT run until WAVE 1 is merged + host-verified.** The prepared (un-launched)
stage-2a workflow script is at:
`…/80ad52ff-…/workflows/scripts/pre-poc-impl-wave2a-DRAFT.js`
On launch: **first reconcile** the draft against what WAVE 1 *actually* landed
(read the WAVE 1 agent `notes` / `itemsDeferred` — agents that ran low on budget
may have pushed STRETCH items here), then launch. Worktrees branch off the
post-WAVE-1 `main` tip automatically.

## Structure (same hot-file reality as WAVE 1)
Every feature with a UI entry point touches the hot files (`DocumentModel`,
`SidebarView`, `TabBar`, `ContentView`, `StatusBar`, panel registry). So WAVE 2
splits:

- **Stage 2a (prepared, launchable — disjoint, new-file-heavy):** git-history
  core + view, diagnostic window, instrumentation logs/metrics UI. These produce
  mostly NEW files (use Swift **extensions in new files** to avoid editing the
  hot files). Merge 2a → then run 2b off the merged tip.
- **Stage 2b (run after 2a merges — the hot-zone, sequential one agent):** the
  feature WIRING (git-history entry point, diagnostic menu, instrumentation
  tool-window registration) + SQLite category-override (item 10) + tab
  shrink-then-overflow (item 12) + ModeBar-into-content-pane (item 13, **VM-only
  verification**). Owns `DocumentModel`/`SidebarView`/`TabBar`/`ContentView`.

## Decisions — baked as DEFAULTS (override before launch to change)
| # | Decision | Default for the queued run | Source |
|---|----------|----------------------------|--------|
| 1 | Instrumentation scope | Ship logs UI + `os_signpost` spans + metrics UI. **Memory: app `phys_footprint` + a separate "WebKit helpers" line + per-tab content-byte proxy** — never a fabricated per-tab RSS. Skip the in-app profiler (use Instruments). | plan §4.1 |
| 6 | Git file-history: window vs tab | **In-app tab** (session-aware, lower-friction) unless it must float over sessions. | plan §4.6 |
| — | Folder-stats scope | **Folder-scoped** (the right-clicked dir), `-- <path>` threaded. | plan §6 |
| 7 | Walkthrough verb schema | Already bumped to **v2 + `UnsupportedSchemaError`** in WAVE 1; `close` verb still **deferred** (destructive-verb policy unconfirmed). | plan §4.7 |
| — | Diagnostic window | Debug-build / `MDV_ENABLE_DIAGNOSTICS=1` only; **cut "open ports"** → fds + temp-files-we-own only (`proc_pidinfo`); redact content + abs paths; **NEVER** in the MCP catalog. | plan §6 |

## Deferred OUT of the auto-queue (need explicit go / supervision)
- **Session independence + per-session panel storage + session types (items 18–21)** —
  the big `DocumentModel` refactor (multi-day, L). **SUPERVISED, not auto-queued.**
  Blocked on decision #5 below (one-way schema fork). This is its own planning +
  human-in-the-loop execution — do **not** fire it unattended.
  - **Decision #5 (resolve before this ships):** `SessionSnapshot` zoom/wrap/theme
    — per-session or global? They persist per-session today (`SessionSnapshot.swift:56-58`)
    but the design doc rules them global (§1.4). **Recommended: per-session override
    with a "use-global" sentinel** (keeps existing on-disk data, more flexible).
    Whichever — decide before per-session panel state ships, because `<uuid>.json`
    files accrue immediately.
- **Terminal tool window (item 22, xterm.js)** — owed first: dependency approval
  (you said "xterm.js is fine" — that's the choice; the *bundle-budget measurement*
  against the 37/16 MB caps + a **terminal threat model** are still owed), then a
  `TerminalBackend` protocol in ViewerCore (swappable for your parallel native-PTY
  effort). Not auto-queued.
- **Compressed-as-folder** — security-gated (zip-bomb / zip-slip / symlink); build
  as a lazy `ArchiveEntrySource` VFS, never extract to disk. PoC-territory.
- **HTML rendering** — security-gated (XSS / local-file-read); default-deny JS +
  no remote + no `file://`, through `HTMLSanitizer`. PoC-territory.
- **Walkthrough deeplinks** — de-scoped this round (per owner); keep the seam
  dormant, no URL-scheme handler.

## Open questions to confirm at launch
- Diagnostic "ports" → confirmed cut to fds + temp-files? (recommend yes)
- Disk-staleness default (WAVE 1 0d shipped the signal additively): keep
  auto-reload as default, flag-instead-of-reload as opt-in pref? (recommend yes)
- "Double-click session tab → default to ~": blank `Tab()`, home-rooted open, or
  GoTo prefilled with `~`? (needs intent before building — folded into 2b tabs work)
