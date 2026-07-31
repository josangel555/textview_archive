# Backlog — CHUNKED WORKLIST · reorganized 2026-07-09 (owner ask)

> Board (http://localhost:8787/) is the system of record for STATE; this file is the pre-sorted
> selector, grouped into CHUNKS meant to be worked TOGETHER in one tick. `task_get` any TSK before
> working it — the board moves, this file lags; a ticket already `fixed`/`review`/`done` is a skip.
> DONE history: `archive/BACKLOG_batches_2026-07-07.md` + `archive/BACKLOG_archive_2026-07-07.md`.
> Repo (canonical): `/Users/me/Documents/workspaces/claude/markdown_viewer`.
> ⚠️ If Desktop&Documents iCloud sync is EVER re-enabled, relocate the repo out of ~/Documents FIRST.

## ⏸ PRE-LAUNCH AUDIT — PAUSED (2026-07-10, resume after owner picks it up)

Multi-agent pre-launch audit workflow (`scripts/workflows/prelaunch-audit.js`, run
`wf_6a1bab45-3ab`) died a SECOND time on the **account session limit** (resets vary; check
`TZ=America/Toronto date`). Owner paused it — do NOT auto-resume; owner will pick it back up.

**What completed & is on disk** (`docs/research/prelaunch-audit-2026-07-09/`, ~30 dimension reports):
- Review WAVE 1 (~30 dims) ✅ written — accessibility, attack-surface, security-core, webview-bridge,
  ffi-boundary, concurrency, subprocess-safety, regressions, perf, ux/ui, deps, etc. (`.v2.md` = fresh-run
  siblings that didn't clobber the prior salvage). These are SUBSTANTIVE (real threat models, file:line
  evidence) but **UNVERIFIED** — the adversarial-verify phase never ran (0/~45 verifiers), and there is
  **no `MASTER_REPORT.md` / `NEEDS_OWNER.md`** (synthesis died). Treat every finding as "plausible, unconfirmed".
- Review WAVE 2 (~19 dims incl. the 8 per-module code-reviews), VERIFY, completeness-critic, SYNTHESIS,
  FIX phase → all ❌ never ran. `main` untouched at `3536dfa8`; no fix worktrees/branches.

**Signal quality: HIGH.** 27 of ~30 wave-1 reports carry findings with real threat models + file:line
evidence. No P0s (every report says so); the ceiling is P1. Triaged & deduped 2026-07-10 (3 read-only
Explore passes) into themes below. Most were UNVERIFIED (verify phase never ran) — **UPDATE 2026-07-11:
a bounded verification pass confirmed 11 of the load-bearing findings against main@3536dfa8**: THEME 1
items 1/2/3/5/6 CONFIRMED (item 4 PARTIAL — ReviewStore does check the Bool), THEME 3 MCP-socket +
run_verb-fence CONFIRMED, THEME 4 notices-not-bundled + notarization-unexercised + mermaid-11.4.1
CONFIRMED; THEME 5 "FormulaEngine dead" REFUTED (rust bridge live-wired via CSVTableView), 1171/1319
dead tails CONFIRMED. Evidence: `docs/research/greenfield-learnings-2026-07-11/aspects/VERIFICATION_*.md`.
Remaining findings stay "plausible, unconfirmed". Full reports in `docs/research/prelaunch-audit-2026-07-09/`.

**THEME 1 — DATA SAFETY / SILENT DATA LOSS (the biggest cluster; ~8 P1s, several corroborated):**
- CM6→Swift text sync is a 200ms debounce **never flushed at save/close/blur/quit** → ⌘S can persist a
  STALE mirror, dropping the last keystrokes (`codemirror.html:121`, `EditorCoordinator.swift:863`). editor-stability.
- Editable-HEX path has NO conflict/no-clobber machinery: dirty hex tab auto-reloaded over; ⌘S writes stale
  stash over external change; hex dirty bytes are in-memory only → **lost on quit/crash, no prompt**
  (`DocumentModel+EditableHex.swift`, `DocumentModel.swift:1828`). editor-stability + crash-analysis.
- Session-switch tab drain **deletes the hot-exit spill it just wrote** (`remove` before the `!isBulkDraining`
  guard) → unsaved 1–32 MiB edits lost (`DocumentModel.swift:3221`). read-write-consistency P1.
- Persistence write failures are silent end-to-end — every caller discards `JSONFileStore.write`'s `Bool`;
  disk-full quit loses sessions + hot-exit edits with no signal (`SessionStore.swift:414`). error-recovery P1.
- `BookmarksStore` strict-decodes → one malformed entry wipes ALL bookmarks, next toggle clobbers the file
  (should use `readLenientArray`) (`BookmarksStore.swift:242`). error-recovery P1.
- Disk-conflict **"Merge…" button silently = Keep Mine** then clobbers the external edit on next ⌘S
  (`.merge`→`.keepEdits`, `DiskConflictBanner.swift:40`). ux-best-practices P1 — SAME root as the 1171 dead-UI tail.

**THEME 2 — CRASH / STABILITY (uncatchable aborts on default-ON paths):**
- Rust formula parser: unbounded recursion → **stack-overflow abort `catch_unwind` can't catch**; `=((((…` in a
  CSV cell hard-crashes the app on auto-recalc (`rust-core/.../formula.rs:257`). crash-analysis P1.
- No crash-loop breaker: session restore is unconditional after unclean exit → a crash-on-open doc reopens every
  launch = permanent boot loop (`main.swift:483`). crash-analysis P1.
- `PluginSubprocessHost` `close()`s pipe handles under `availableData` readers → uncatchable
  `NSFileHandleOperationException` (the TSK-1552 class the MCP code already avoids) (`PluginSubprocessHost.swift:265`). hidden-gotchas P1.
- CRLF/CR files collapse to one line in `LSPPositionConverter` (matches `"\n"` Character; `\r\n` is one grapheme)
  → corrupts diagnostics/folds/formatter edits (`LSPPositionConverter.swift:55`). bugs-functional P1.

**THEME 3 — SECURITY / CONTROL SURFACE (corroborated across 4 reports):**
- **Unauthenticated always-on MCP socket** (`main.swift:225`, TSK-1544) — attack-surface, security-core,
  concurrency, automation-control, entitlements ALL flag it. `mcp.sock` 0600/same-user, no token/consent,
  exposes `run_task`(exec)/`move_file`(write)/`snapshot_window`(exfil); app unsandboxed w/ TCC grants →
  confused-deputy. **P1 — owner trust-model decision before public launch.**
- `run_task` = arbitrary code exec gated only by socket access (allowlist gates task id, not the shell body);
  `run_verb` open/save-copy **bypasses the home-jail fence** (no `validatedExistingURL`). automation-control P1.
- Task Runner runs repo build scripts with the app's **full unscrubbed env** (no trust gate) → leaks
  `*_TOKEN`/`*_SECRET` to hostile repos; git diff/blame run with external-diff/textconv ENABLED. subprocess-safety.
- Canvas WebView is the one unfenced WebView: **no CSP, no nav policy, unrestricted `<img src>`** → remote
  fetch/tracking-beacon on render (`canvas.html`, `CanvasWebViewHost.swift`). webview-bridge + privacy P1.

**THEME 4 — SHIP-BLOCKERS: LICENSING & PACKAGING (untested release path):**
- **`THIRD_PARTY_NOTICES.md` is NOT copied into the bundle** (generator claims a `cp` build-app.sh never does)
  → shipped `.app` redistributes MIT/Apache/BSD code with ZERO attribution. dependency-audit + license P1 ×2.
- **~30 statically-linked Rust crates + ~15 tree-sitter grammars ship UNATTRIBUTED** (the referenced "rust-core
  notices" file doesn't exist). license-compliance P1 ×2.
- Notarization pipeline has **never been run** (0 Developer ID identities; preflight dies) + no release lane;
  local `--options runtime` sign **breaks lazy-grammar `dlopen`** in `/Applications` (XML/JS/TS folding silently
  degrades); `entitlements.plist` `<false/>` opt-outs never applied (no `--entitlements` flag). packaging + entitlements P1 ×3.
- Vendored **Mermaid 11.4.1 has 6 published advisories (2 XSS sanitizer-bypass, 1 DoS)**; advisory-watch nightly
  never runs (no GH remote) → ~11mo unseen CVEs. dependency-audit P1.

**THEME 5 — REGRESSIONS & DEAD RENDER TAILS (features that read "shipped" but aren't wired):**
- Conflict-resolution 3-pane (1171), HTML network-consent grant UI (1203), dynamic content menu (1319) have
  **zero UI callers**. regressions P0×2. (1171 = same root as the THEME-1 "Merge…" clobber.)
- **838 DOM-patch flip discards its completion handler** → documented `loadHTMLString` fallback never fires on a
  failed apply; patched mermaid/math blocks render inert. Just-landed, default-ON. regressions.

**THEME 6 — PERF / UX / ARCHITECTURE (P1s, not ship-blockers):**
- Split-pane markdown renders **synchronously in `body` per keystroke, no size cap** → multi-second freezes on
  MB files (`SplitPaneView.swift:190`); source-view find is an undebounced O(doc) main-thread scan ungated to
  512 MiB (`TextDisplayView.swift:1318`). performance-optimization P1 ×2.
- Two live text engines for the same content (NSTextView `.source` vs CM6 `.editor`) with **divergent
  highlighting** (tree-sitter vs Lezer). dual-ui-refactor P1 ×2.
- Onboarding teaches a **dead shortcut** ("Press ⌘K" — unbound since TSK-709) (`FirstRunExperience.swift:69`);
  no Reopen-Closed-Tab / no session-trash restore UI. ux-best-practices P1 ×2.
- Inert nav rows (Markdown + LSP outline) + 33 files of plain buttons with no hover/press/cursor → "dead UI"
  perception. ui-liveliness P1 ×2.
- god-objects: `main.swift`/`AppDelegate` 4,435 LOC (`buildMenu()` alone ~1,300 LOC), `DocumentModel` ~10.7K LOC
  across 74 files / 90 `@Published`. code-quality P1 ×3 (+ tech-debt).

**To resume (owner's call):** `Workflow({scriptPath:"scripts/workflows/prelaunch-audit.js", resumeFromRunId:"wf_6a1bab45-3ab"})`
— 39/104 agents are resume-cached (replay instant; only the 65 dead ones re-run). NOTE: the verify fan-out
(3 verifiers × ~30 dims at once) is what burns the limit — thin the verify panel / cap concurrency before resuming.
Once `MASTER_REPORT.md` lands, file its findings as a board wave + spin fix worktrees.

## ⚠ OPEN FOLLOW-UPS (updated at the 2026-07-30 handoff — everything below is COMMITTED)

All prior "uncommitted / on-screen unverified" caveats are RESOLVED: the sessions' work is in 14
commits (081f1fc5..7b2fe687), and the partial-T6 rig (`PartialT6SceneCaptureTests` + scenes)
verified Split / merge-sheet / math on real pixels. Remaining:

- **Owner-directed, next in queue:** ~~tab-drag-onto-session-pill~~ (LANDED 2026-07-31:
  `TabSessionDropChannel` + `StripExternalTarget`, pill highlight pixel-verified, negative-control
  teeth); ~~markdown gap-closures~~ (LANDED 2026-07-31: footnotes/alerts/def-lists/sup+sub/heading
  attrs, option+writer-arms together, rust+FFI+webview-paint tiers; **wikilinks deferred** — needs
  a link-resolution policy call: what does `[[page]]` resolve to in a folder session?); remaining:
  save/retrieve-session design question (sessions already persist + 30-day trash — is the ask
  NAMED snapshots?). **M each**
- **AX tests for new UI work (owner policy shift, 2026-07-29).** Previously "AX tier
  off-limits"; the owner now WANTS AX tests for new UI. Needs the AX harness groundwork
  (TSK-1197-1199 family) before per-feature AX tests can land. **L bootstrap, then S/feature**
- **Delete the dead `ModeBar` struct** (ContentView ~1641) — never instantiated; the Split miss
  happened because it LOOKS live. Labeled LEGACY in-source; remove outright. **S**
- **Math typography eyeball on the OWNER's machine.** WebKit MathML geometry is proven (VM
  webview lane green); the capture lane cannot show WebView content (TSK-1247), so the visual-
  quality check is one open of a math file on the host. If rough → KaTeX-CSS fallback talk. **XS**
- **Tab tear-off drag (deliberate re-add, do NOT do it with a bare `.onDrag`).** A real tear-off
  = `NSDraggingSource` that reorders in-strip and promotes to a file drag on leaving — a bare
  `.onDrag` reinstates the window-opens-the-file bug and is blocked by a regression pin in
  `FileDragProviderTests`. **M**
- **Pointer-drag interaction rung for tab reorder** (caret + lifted-tab visuals need a REAL
  drag) — exactly the AX-lane item above. **M, blocked on AX bootstrap**

- **Local History: smarter retention beyond gap-thinning (owner ask 2026-07-29).** Today: 100 MB/
  file budget, no age expiry, over-budget drops the interior version leaving the smallest time gap
  (first + newest never dropped), and small edits store as diffs against the nearest full anchor.
  Smarter follow-ups, roughly in value order: (a) **re-diff on eviction** — when a FULL snapshot is
  the thinning victim, re-encode its neighbours as diffs against a surviving anchor instead of
  deleting outright (keep the version, shrink the bytes); (b) **tiered density targets** — e.g.
  keep every version <1h old, hourly to a week, daily beyond, applied per-file; (c) **cross-version
  compression** (zstd the record payloads — they're plain UTF-8 today); (d) surface per-file
  history size + a "compact now" action in the Local History UI. **M–L**
- **Recently Closed is NOT persisted across launches.** `RecentlyClosedStore` lives for the run of
  the app (deliberate: persisting adds an Application Support file plus `AppCacheReset` /
  `SettingsRelocation` wiring, and would resurrect entries pointing at files deleted since). If the
  owner wants ⇧⌘T to survive a relaunch, that's the follow-up. It is also PER-SESSION (each
  session's `DocumentModel` owns its own list) — arguably right, but worth confirming. **S**

- **Disk-conflict follow-ups (from the 2026-07-29 fix).** The banner + save-prompt paths now
  preserve every discarded side and never pick silently. Remaining gaps in the same family: the
  save-conflict prompt's **`viewDiff` branch is still a no-op stub** (`EditorCoordinator`
  `onViewSaveConflictDiff` has no handler) — it should open the web diff; and its Overwrite/Reload
  branches REPORT a failed capture via toast rather than pre-confirming like the banner does.
  Unify on the pre-confirm if you want one rule everywhere. **S–M**
- **[VERIFIED 2026-07-30] Merge sheet** — seen on real pixels via the `conflict-merge` scene:
  banner + three labeled panes + per-conflict picker + Apply gating all correct. Remaining in
  this family: hex dirty bytes still have NO hot-exit (lost on quit/crash — the clobber paths
  are closed, loss-on-crash is not), and the interactive sheet flows (pick → Apply) are
  AX-lane. **M**

### VM lane findings — full `all` run 2026-07-31 (release-ship sweep)

- **[TRIAGED 2026-07-31] The ~98-failure flood was EMFILE** (`ulimit -n` capped by
  `kern.maxfilesperproc`=10240 → the 16384 raise silently fell back to 8192). Fixed
  self-applyingly in `test-in-vm.sh` (05337de7); headless re-run: 98 → 6 failures.
  Remaining 6, none from the 07-31 commits: 4 × EBADF ("Bad file descriptor" — same fd
  family, host-green suites: `VMSmokePathGuardTests` ×3-ish, `ViewModeMatrixSmokeTests`,
  `ViewModesUATTests` VM_04; likely a shared fixture/helper holding a stale fd — chase the
  helper, not the suites) + `UISceneApplierTests.gitPanelScene` (the scene's git fixture
  yields no statuses on the VM — git config/sandbox quirk, host-green). **S–M**
- **VM system disk at 90% (1.2 GiB free)** — reclaim before it starts failing builds/IO
  (old dists, /var/folders cross-user temp, logs). **S**

### VM lane findings — full `all` run 2026-07-27 (first since the 07-24..27 session)

VM_RC=1, ~29 failing cases. The lane had NOT been run against that session's uncommitted work, so
most of these are its untested tail, NOT the tab-reorder change (verified: the reorder change was
reverted to HEAD and re-run, see below).

- **[FIXED 2026-07-29] Web diff nav jump + scrollspy** — two mechanisms, both measured on the VM
  (diagnostic eval, not guessed): (1) only 24px of tail below the last file, so a trailing file
  could never scroll to the top (`scrollTo` clamps at max-scroll — landed 19px short even after a
  first `100vh - 120px` attempt; now `100vh - 24px`, pinnable down to a bare header); (2) the
  scrollspy was rAF-throttled and **rAF never ticks in an unparented/occluded WKWebView** — the
  spy simply never ran. Now a 32ms trailing setTimeout. Lane re-run green.
- **[TEST BUG, not product] `FileTabStripVisualRegressionTests`** — `test_lastTab_hasVisibleRightBorder`
  fails with "Separator columns at [393, 400, 791, 798] (gap 3 pt) don't look like tab edges".
  IDENTICAL failure with the reorder change and with a pristine `HEAD` `TabBar`/`SessionTabBar`, so
  it is pre-existing. The captures (`MDV_PIXEL_DEBUG_DIR`, eyeballed) show the strip is CORRECT:
  separators after every tab including the last, `+` beside the last tab, and 14 tabs shrink
  instead of overflowing. The detector reports each separator TWICE (~3 pt apart — it's picking up
  both edges of the tab-background transition), so the "looks like tab edges" gap heuristic
  rejects it. Recalibrate the detector/band; do NOT chase a product bug. **S**
  (In the full sweep this suite showed 2 failures instead of 1 — that extra one did not reproduce
  in a targeted `pixel` run and coincided with host gates running on the machine that hosts the
  VM. Don't trust heavy-tier results taken under host CPU contention.)
- **[PRE-EXISTING, untriaged] ~27 further UAT/visual failures** across `ViewModesUATTests`,
  `Cm6EditorUATTests`, `LSPUATTests`, `PreviewsUATTests`, `PluginsAndMcpAutomationUATTests`,
  `WalkthroughAndCodeReviewUATTests`, `ScrollRestoreUATTests`, `TabsAndWindowChromeUATTests`,
  `ViewModeMatrixSmokeTests`, `SourceViewVisualRegressionTests`, `CanvasOverlayVisualRegressionTests`,
  `Canvas*WebViewTests`, `DiagnosticDumpTests`. Untriaged — needs a pass to separate real
  regressions from stale scene/band assumptions. Full log: `tmp/vm-reorder-all.log`. **L**
- Useful lane note: `test-in-vm.sh pixel --filter <Suite>` does `build_all` + a filtered run (~160 s)
  — use it instead of the ~48-minute `all` sweep when validating one heavy suite. T5 SKIPS under
  `test` mode (TCC), so it must be `pixel` or `all`. `MDV_PIXEL_DEBUG_DIR` only writes if the
  directory ALREADY EXISTS (the copy is a silent `try?`) — `mkdir -p` it on the VM first.
- **VM/WebView validation rung owed** for the web diff (`DiffWebPageTests` — registered in BOTH VM
  lanes but never RUN here), the CM6 hover-gate + indent guides (source-contract tests only; no live
  pixel test), and the git-graph curves/hover (host layout tests only). **M**
- **Review-mode diff port (owner said "plan a follow up for review").** The SwiftUI `DiffView`
  survives ONLY as the review renderer (comment threads/composer) + the `MDV_WEB_DIFF=0`
  kill-switch; everything read-only is the web view. Port threads → retire `DiffView`. **L**
- **Rename bugs NOT reproduced** (TSK-1605). Model chain tests green end-to-end; the name-first
  prompt removes the create-then-rename flow that triggered it. If it recurs, the missing detail is
  WHERE the rename starts (sidebar right-click vs F2) and whether the buffer was dirty. **M**
- **Tab inserts a literal `\t`** by earlier owner design; the CSS `tab-size` fix makes it RENDER at
  the configured width. If spaces-on-Tab is wanted instead, it's a one-line change in
  `literalTabBinding`. Owner call. **XS**
- **Background snapshot dropped on quit** (TSK-1608 tradeoff): a snapshot still in flight when the
  app quits is lost (the file itself is already saved). Flush-on-quit if the owner wants it. **S**
- **`indentDepthOf` counts a tab as ONE level** regardless of `tabSize`; mixed tabs/spaces files may
  render a guide depth that differs from the visual column. Correct fix is visual-column math. **S**
- **Editor-lens chrome re-body budget is unpinned.** `ChromeBodyEvalCountTests` fixtures were
  pinned to `.source` when the default lens flipped to `.editor` (TSK-1588); the editor lens's own
  re-body cost has no guard. **S**
- **Diff view: syntax highlighting skipped above 8k rows** (perf cap) and `@codemirror/merge`'s
  MergeView/side-by-side is exported but UNUSED — only the unified patch renderer ships. **M**

## ★ WORK-LOOP MANDATE (owner, 2026-07-09 — OVERLOADED TICKS)

Each tick takes ONE **CHUNK** below (a group of 3–5 related tickets) and ships the WHOLE chunk in
one pass. Related-by-design so context is shared and the tests overlap.

1. **Pick the next chunk** top-down from §1 (skip owner-gated/[dep]/[XL]-not-your-model items — take
   the next actionable one). Don't re-plan mid-tick.
2. **Implement ALL tickets in the chunk** — code + the full test pyramid per ticket (see below) +
   any evals — in ONE go. Only targeted `swift test --filter` checks BETWEEN tickets, not a gate.
3. **ONE full gate at the END of the whole chunk** — `bash scripts/test-headless-gate.sh` (+
   `scripts/rust-core-gate.sh` if rust touched). Read the `GATE_DONE` rc marker in `tmp/`, not the
   wrapper exit. Bench-only failures: re-run isolated (TSK-1499). NOT a gate per ticket.
4. **ONE commit for the whole chunk** — list EVERY TSK id in the subject/body + the
   `Claude-Session:` trailer. Fold the CHANGELOG/HANDOFF/LESSONS updates into it.
5. **VM/AX rung** (only if render behaviour changed AND the VM lane is up, TSK-1550): batch the
   higher-order tests for the chunk in one VM run; attach the shared evidence.
6. **Board**: walk each ticket in the chunk reported→ack→triaged→progress→fixed→review with ONE
   shared `checks` artifact for the chunk. **NEVER `task_validate`** (owner validates). Blocked
   ticket ⇒ `task_park` it (Need-me if owner), keep the rest of the chunk moving.
7. HANDOFF ≤12KB current-state; rsync backup to `/Users/me/Local_Docs/local_workspace/markdown_viewer/`.

**PURE AUTONOMY — NO INLINE QUESTIONS.** Every question/decision/approval = a BOARD "Need me" gate
(`task_park` with homework + recommendation), then MOVE ON.

**⛔ NO OVER-DECOMPOSITION (owner 2026-07-10).** A ticket = what a reasonable engineer ships in one
PR/commit, NOT each edit/file/step inside it. Don't file a sub-ticket per implementation step
(model → test → view → command are ONE ticket); the chunk already groups 3–5 RELATED tickets — don't
re-atomize below that. Legit splits: a different TIER/LANE that can't ship together (host core now vs
VM/AX render tail — the TSK-1578..1585 pattern), an independently-shippable epic slice, a real blocker.
Heuristic: if closing a sub-ticket alone leaves nothing a user or test can observe, it's a checklist
item — fold it into the parent body, don't file it. Full text: project `CLAUDE.md` §Task tracking.

### TEST PYRAMID PER TICKET (mandatory — full map in `docs/TEST_PYRAMID.md`)

Every ticket names + builds its required evidence classes; the gate refuses `fixed` without them:
- **Pure logic / model / parser / FFI** → a HOST unit test (Swift Testing for new pure-logic;
  XCTest for tier-based/existing). This tier is ALWAYS required and is the floor.
- **Wiring / command-path / state outcome** → a HOST integration/behavior test that pins the
  select/close/toggle/commit OUTCOME (so a logic regression fails the host gate).
- **Render / view (SwiftUI/WebView pixels)** → host model test PLUS a VM rung: in-process WebView
  DOM (`webview`), T4 `LiveAppTestCase`, or a `MDV_UI_SCENE` window-id capture (READ the PNG). If a
  surface is genuinely un-drivable (view-local `@StateObject`, T5-TCC-gated) flag "on-screen
  UNVERIFIED — needs VM" + file the enabler; don't fake a green.
- **Interaction (click/drag/keypress)** → an AX real-event test (VM) OR exercise the exact wired
  action closure. A faithful pointer-drag is NOT synthesizable in-process (TSK-1188) → that rung is
  VM/AX; the model closures it calls are host-tested.
- **Perf** → MEASURE on the VM (PerfSignpost/xctrace, `scripts/vm-profile.sh`); gate absolute
  budgets, skip wall-clock-ratio asserts under the parallel gate (TSK-1499).

---

## §1 — BUILD CHUNKS (take one whole chunk per tick)

Each line is `TSK — one-liner`. Confirm state with `task_get` first; skip anything not `reported`.

### CH-A · Image editor — paint & shape tools  [parent 1048/1455]
- 1055 — make paint strokes undoable + unify with the lossless op-list (P0 do-first)
- 1114 — wire selection UI (marquee/lasso tool + fill-selection action)
- 1088 — zoom tool + grid + rulers + status-bar coords/selection-size
- 1441 — image-editor FEEL: tool/cursor feedback, save-vs-copy clarity, in-editor zoom/pan
- 1574 — shape gallery freeform members (heart / lightning / callouts) + on-screen UAT

### CH-B · Image editor — advanced tools (2nd image chunk)  [parent 1048]
- 1083 curve tool · 1084 polygon tool · 1089 real text tool (draggable box) · 1086 AA shapes ·
  1087 brush gallery · 1090 layers panel + compositing

### CH-C · Editor & markdown power tools  [parent 1450/1453]
- 1170 — snippets: CM6 tab-stop nav wiring + management UI
- 1173 — sticky scroll: pinned-header overlay over CM6
- 1570 — markdown outline panel: scroll-highlight + preview-mode jump
- 1505 — widespread spelling verb + UI integration
- 1504 — cheap editor assists: off-main visible-range spell + cached word-index completion

### CH-D · Devtools & code review  [parent 1456]
- 1571 — mount the Claude Session Monitor as a menu item (CLI-flag-only today)
- 1577 — git-panel RENDER scene (VM-capture the Status tab on a fixture repo)
- 1482 — menu-bar audit (naming, order, enablement, no orphan items)
- 1191 — migrate Git File-History/GitLogTab onto UnifiedHistoryView
- 318 / 1108 — code-review agent Q&A UI + transport

### CH-E · Data & format viewers  [parent 1454]
- 1205 — extracted-doc viewer: read-only spreadsheet GRID + lens-forcing
- 1423 — hex search ignores UNSAVED edits (searches file.data, not the buffer) — bug
- 1269 — wire ExternalEditReconciler (3-way auto-merge) into the dirty-reload flow (data-safety)
- 1165 — external-edit reconciler into the editor external-edit flow (non-blocking merge UX)
- 1203 — trust-mode slice 3b: failure surfacing + consent-gated network

### CH-F · Chrome, first-run & file-nav  [parent 1460/1451]
- 1572 — new-tab launchpad: recent-folders/bookmarks sections + arrow-nav + git-clone/paste
- 1575 — first-run: Help ▸ Capabilities rendered page + walkthrough launch points
- 1573 — recover-deleted-file: full enumeration (path manifest) + version picker
- 1104 — multi-window: mount a real second NSWindow on the MultiWindowRegistry foundation
- 1111 — bookmarks "open in new view/window"

### CH-G · Viewing & felt-perf  [parent 1452]
- 1488 — render-FPS / jank instrumentation: flag <60fps + a felt-perf harness
- 891 — Page-Up jank trace + fix
- 1047 — extend warm-WebView cache to the CM6 editor pane (session-switch retention)
- 1180 / 1184 / 1185 — perf traces (result-scroll · hover-synth mode · commit-menu latency)
- 838 — rendered-MD persistent page + DOM patch (closes 598; owner re-feels the flip)

### CH-H · Notebooks, diagrams & dynamic content  [parent 1453/1157]
- 1172 — notebooks: wire NotebookCellListView + kernel execution/storage
- 1171 — 3-way merge conflict-resolution 3-pane UI
- 1157 — real PlantUML/D2 renderers wired into the markdown render path
- 1158 — profiling / flame-charts / memory-diffs viewer UI
- 1319 — dynamic content-specific menu (per-visible-tab actions)

### CH-I · Web-migrate — CM6 / web grids  [parent 1524]  (M1/M2 need @codemirror/merge → §2)
- 1530 M6 read-only source view → CM6 read-only (kills the NSTextView 1MB choke)
- 1527 M3 CSV grid → virtualized web grid (rust windowed snapshot)
- 1531 M7 hex view → virtualized web monospace grid
- 1532 M8 transcript/monitor + Logs → web streaming lists
- 1533 M9 git log / unified history / blame → web (CM6 blame gutter)
- (2nd web chunk: 1528 M4 xlsx · 1529 M5 docx)

### CH-J · Test-pyramid gaps & host-safe infra  [mandate]
- 1551 — real-render suites for the 4 uncovered lenses (formatted / hex / table-CSV / diff)
- 1567 — fix the EditorAssistToggleTests --parallel flake (shared UserDefaults race)
- 1538 — dark-theme scene paints zero pixel-diff vs light (T5 dark-chrome guard RED)
- 441–445 — tasked-tool/CI items · 1329 / 1330 — INT tracker-feedback tickets

### CH-K · Rust-core H-B ports (SPIKE 1117 FIRST, then slice)  [parent 1117/1524]
- 1509 LSP domain · 1510 Git domain · 1511 Sessions/persistence · 1512 Automation verb registry ·
  1513 roadmap doc revise. Spike-gated: run the 1117 stateful-core spike before slicing.

---

## §2 — OWNER-GATED (Need-me cards; do NOT build — `task_park` if surfaced)
Decisions: 470 zoom-split · 508 digraph-render · 810 hex carve-out · 1322 paste-repro · 1349 canvas
M7+ · 1414 finish-or-cut spikes · 1418 orphaned WIP views · 1426 paint persistence · 1449 surface
consolidation · 1468 spreadsheet formula-flip · 1471 log-patterns finish-or-cut · 1491 sessions-model
· 1492 git visualizer · 1497 far-future · 1540 WV-on-host · 1549 find-regex expressiveness · 1200
editor-scroll-verb.  Deps: 835 nextest · 852 CI cache · 831 index-dedup · 1137 cargo-mutants · 1287
crypto-hash · 1138 Tier-D plugin · 1525/1526 @codemirror/merge (M1/M2).  Supervised: 1520/1521 (S5/S6
cutovers). **MASTER UNLOCK still open: 1334 T5 Screen-Recording grant** (blocks ALL T5-pixel).

## §3 — DESIGN-FIRST EPICS (spike auto-approved; several XL/Fable-class)
590 owner bug-list · 537 CR epic · 691 agent-harness · 703/1155 action-history · 706/1156 richtext
[XL] · 713/1157 diagram renderers · 715/1158 profiling · 764 git-reconcile · 956 + 1091–1096 AU
hosting (live-val) · 1048 image-parity epic · 1164 language-coverage matrix · 1311 session
independence · 1342 canvas spike · 1450–1460 usability-epic umbrellas · 1523 S8 remote parity ·
1524 rendering-stack policy.

## §4 — INFRA / AX / FOREIGN
AX tier (owner-declared off-limits): 1197–1199 UAT framework · 1261/1263–1266 ElementRef · 1543 AX
matrix.  VM infra (agent-workable, VM up): 1239 fd exhaustion · 1247 webview-blank · 1336 mermaid
occlusion T5 · 1365 WebContent hardening · 1541 rust coverage · 1542 Sequoia nag.  Reconcile: 1503
(SHIPPED 92dec034 — board-reconcile, not build) · 1506 salvage-branch integration (verify vs main).

## Living analyses (pointers)
WebUI surface-sharing → 1507 · rendering-stack policy → 1524 · whole-core migration → 1117 +
`docs/research/stateful-core-spike-2026-07-04/DESIGN.md` · agent services →
`docs/AGENT_SERVICES_DESIGN_2026-07-07.md` · meta-analysis →
`docs/research/project-meta-analysis-2026-07-04/SYNTHESIS.md` · usability →
`docs/FEATURE_INVENTORY.md` · test pyramid → `docs/TEST_PYRAMID.md`.
