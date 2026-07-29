<!-- CLAUDE-HANDOFF v1 -->
# Handoff — UI/perf session: web diff, editor defaults, git graph, save beachball (2026-07-27)

**cwd:** /Users/me/Documents/workspaces/claude/markdown_viewer · **branch/SHA: main @ 3536dfa8**
(~94 dirty paths — ALL of this session's work is UNCOMMITTED) · backup rsync →
/Users/me/Local_Docs/local_workspace/markdown_viewer/

## Mission
Owner-driven UI/UX + perf hardening of the live app, one report at a time. Owner runs
`/Applications/TextView.app` daily and reports symptoms; each is diagnosed to root cause, fixed,
host-gate-verified, and installed. **Owner has NOT authorized commits** — every change sits dirty
on `main` awaiting their word.

## Current state

**Done + installed** (`/Applications` binary 2026-07-26 18:31; host gate PASSED after each):
- **Source lens = CM6** (TSK-1530): `WebSourceViewGate` ships ON; NSTextView survives only as a
  >16 MiB fallback. Source find-bar wired into CM6.
- **Rendered-markdown staleness** (TSK-1587): DOM-patch apply is now VERIFIED (JS returns
  post-apply block count; error/mismatch → real `loadHTMLString` fallback) + `documentReady` guard.
- **Text opens EDITABLE** (TSK-1588): `canonicalDefaultLens` → `.editor` for plainText/code
  (View-Only OFF); html stays Source; >CM6-cap coerced to `.source` at 3 open paths.
- **Keyboard/layout** (1589–1592): ⇧⌘G reaches the menu from CM6; lone sidebar tool window fills
  the band; ⌃Tab/⌃⇧Tab/⌘]/⌘[ tab nav; palette Esc dismisses in `#`/`@` modes.
- **Git diff = WebView** (1594–1599): `diffweb.html` + vendored **`@codemirror/merge@6.12.2`
  (OWNER-APPROVED dep)**. Ephemeral preview tabs, wrap toggle, changed-files tree (patch-ordered,
  collapsible, scrollspy), Line|Word|Char granularity, syntax highlighting, commit summary,
  per-file Old|New|Current buttons, Compare-with-Clipboard (editor right-click).
- **Git log** (1600–1604): multi-field search (sha/branch/worktree prefix + subject instant, body
  via `--grep`, two-phase w/ `logSearchIsSettled`); per-kind ref colors + symbols; **All refs**
  toggle = multi-worktree divergence graph; graph edges/branchID/curves/hover; worktree last-commit.
- **New File asks the filename** (TSK-1605) at all 4 entry points; no more `Untitled.txt`.
- **CM6** (1606/1607): hover line gated on real pointer movement; indent guides PAINT (no longer
  add spacing); CSS `tab-size` follows the setting.
- **⌘S beachball FIXED** (TSK-1608): snapshot-on-save moved off-main → **220 ms → 0.14 ms**.
- **Fold log noise** (TSK-1609): "unsupported language 'plain'" is a quiet empty result, not a
  DEGRADED alarm; real bridge faults still degrade loudly.

**In flight:** nothing half-written. Tree is buildable, gate-green, installed.

**Next action:** ask the owner whether to **commit** (one commit per ticket, rebase + ff-only). Do
not commit unprompted.

## Key decisions & rationale
- **Web diff replaces SwiftUI `DiffView` for all READ-ONLY surfaces**; `DiffView` kept ONLY as the
  review-mode renderer (comment threads) + `MDV_WEB_DIFF=0` kill-switch. Owner: *"no plans to
  maintain the existing NSTextView based diff"*; review port is the agreed follow-up.
- **Snapshot-on-save off-main, not optimized in place** — it is best-effort BY CONTRACT, so it
  never belonged on ⌘S's critical path. Serial queue prevents interleaved history writes.
- **Name-first New File** sidesteps the unreproduced rename bugs rather than guessing at them.
- **Guards satisfied, never bypassed:** color ratchet → switched to system colors; WebView
  allowlist → registered with real-render coverage; VM-lane coverage → suite added to BOTH lanes;
  source-wiring pins → updated to the NEW contract (and strengthened), not weakened.

## Gotchas / lessons (full text in LESSONS.md 2026-07-24..27)
- ⌘S beachball = snapshot-on-save on main (~220 ms measured, grows with history depth).
- Indent guides "not matching" = the guide WIDGET added layout width → doubled indents. Guides must
  PAINT (`Decoration.line` + background), with `background-origin: content-box`.
- CM6 `tabSize` FACET ≠ CSS `tab-size` PROPERTY. Only the latter sets a literal `\t`'s width.
- Bare CSS `:hover` follows the pointer's position, so scroll/Enter lights the wrong line.
- `GraphLayout` dropped the edge when a parent was already pending → branch lines just stopped.
- **`/var/folders` is an APFS firmlink** — `resolvingSymlinksInPath()` is a no-op there; a whole
  URL-mismatch hypothesis died on that. Write the repro FIRST.

## Files that matter
- `Sources/ViewerUI/Resources/codemirror/diffweb.html` — web diff page (render/granularity/nav/
  wrap/highlight/version buttons). Swift contract documented in its header.
- `Sources/ViewerUI/DiffWebView.swift` — WKWebView host + `WebDiffPane` toolbar + verified render.
- `Sources/ViewerCore/WebDiffGate.swift` — gate, `DiffGranularity`, `DiffViewPrefs`, payload wire.
- `Sources/ViewerUI/Resources/codemirror/codemirror.{html,css}` — hover gate, indent guides, tab-size.
- `Sources/ViewerCore/LocalHistoryStore.swift:183+` — `snapshotInBackground` + drain seam.
- `Sources/ViewerCore/Git/{GraphLayout,GitRefKind,GitLogSearchQuery,GitLogPrefs}.swift` — git-log core.
- `scripts/codemirror-build/{package.json,entry.js}` — CM bundle; **re-run `npm run build` after
  editing entry.js**, output is the vendored `codemirror.js`.

## Open questions / blockers
- **Commit authorization** — the only true blocker.
- **ON-SCREEN UNVERIFIED**: every WebView/SwiftUI pixel change this session (web diff, CM6 hover +
  guides, git graph curves/hover). Host gate green ≠ pixels correct.
- **VM rung owed**: `DiffWebPageTests` is registered in both VM lanes but was never RUN.
- Rename bugs (TSK-1605) never reproduced — see BACKLOG for the detail needed if it recurs.
- Owner call: Tab inserts a literal `\t` (their earlier design) — want spaces instead?

## Tracker
**THE tasked BOARD IS DOWN** (`localhost:8787` unreachable; `mcp__tasked__*` tools disconnected all
session). Nothing was recorded there after TSK-1593.
- **Confirmed REAL board ids** (created while it was up): 1586 greenfield corpus (review), 1587 DOM
  patch (fixed), 1588 editor-default (reported→implemented), 1589–1592 (fixed), 1593 markdown-links
  (reported, NOT implemented).
- **⚠️ TSK-1594 … TSK-1609 are PLACEHOLDER ids I chose while the board was down.** They appear in
  code comments + test names but are **unverified against the board — expect collisions**. On
  resume: bring the board up, create the real tickets, and reconcile the numbering.

## How to resume
1. `cd /Users/me/Documents/workspaces/claude/markdown_viewer && git status --short | wc -l`
   (expect ~94) and `git log --oneline -1` (expect `3536dfa8`).
2. Read `BACKLOG.md` top section "⚠ OPEN FROM THE 2026-07-24..27 UI/PERF SESSION".
3. If the owner says **commit**: group by ticket, one commit each, `Claude-Session:` trailer,
   rebase + `--ff-only`. Verify with `bash scripts/test-headless-gate.sh` (read the rc; wrapper
   exit alone lies) BEFORE and after.
4. If the owner reports a NEW symptom: write the repro/measurement FIRST (see
   `Tests/ViewerCoreTests/LocalHistorySnapshotCostTests.swift` for the cost-harness pattern).
5. Build+install loop used all session:
   `bash scripts/test-headless-gate.sh` → `bash scripts/build-app.sh debug --install` → tell the
   owner to **relaunch** (a running app keeps the old binary).
6. Board work: start `tasked` at `localhost:8787`, then reconcile the placeholder ids above.
