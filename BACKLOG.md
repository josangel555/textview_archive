# Backlog — CHUNKED WORKLIST · reorganized 2026-07-09 (owner ask)

> Board (http://localhost:8787/) is the system of record for STATE; this file is the pre-sorted
> selector, grouped into CHUNKS meant to be worked TOGETHER in one tick. `task_get` any TSK before
> working it — the board moves, this file lags; a ticket already `fixed`/`review`/`done` is a skip.
> DONE history: `archive/BACKLOG_batches_2026-07-07.md` + `archive/BACKLOG_archive_2026-07-07.md`.
> Repo (canonical): `/Users/me/Documents/workspaces/claude/markdown_viewer`.
> ⚠️ If Desktop&Documents iCloud sync is EVER re-enabled, relocate the repo out of ~/Documents FIRST.

## ★ OWNER INTAKE 2026-08-01 — THE ACTIVE QUEUE (work top-down; board down → placeholder ids I-##)

Answers to the intake's six questions: `docs/INTAKE_ANSWERS_2026-08-01.md`. Governance: every
round = ONE user-facing improvement + one or more quality items, both named. Owner recal:
**don't limit to small-effort tasks** — big user-facing swings lead this queue. Reconcile
I-## → TSK-### when the tasked board reconnects.

**P0 — bugs the owner hit live (quality items, pair one per round):**
- ~~**I-01 (bug, find-it)**~~ **ROOT-CAUSED + FIXED (R6, 2026-08-01).** NOT a save-echo: the
  detector's (mtime, size) fingerprint is CONTENT-BLIND — any same-bytes rewrite (git
  checkout/stash, backup tooling) under a dirty buffer raised a FALSE banner;
  `ExternalEditReconciler` even classified it `.noExternalChange` but both call sites dropped
  that outcome on the floor. Fixed at all 3 layers (watcher classify → adopt stamp silently;
  Merge on a false conflict → clear banner + explain; ⌘S guard → content check before
  prompting). Pinned: watcher-tick, merge-escape, and save-through tests. Residue: hex tabs
  keep the content-blind stamp (binary read cost) — banner may still false-fire there (**S**);
  `.cleanReload` via the Merge button still dead-ends (rare tab-dirty/buffer-clean skew, **S**).
- ~~**I-02 (bug)**~~ **FIXED (R7, 2026-08-01)** — large-commit wedge: the proven mechanism
  was the UNBOUNDED body choking the diff WebView (the payload build was already off-main;
  git itself is subsecond). All three diff producers (commit / cumulative range / per-file
  status) now bound via `GitDiffBounds` (4 MB / 40k lines, whole-line cut, explicit
  "⚠ DIFF TRUNCATED" notice + `git show` escape hatch, toast). Pure suite + a seam-driven
  click test. RESIDUE (**S**): if the owner still FEELS a stall on huge commits, move the
  `git show` subprocess off-main — deferred because it flips `showCommit`/the script verbs
  async, which ripples through the sync automation contracts; measure first.
- ~~**I-03 (bug)**~~ **FOLDED INTO I-01** — "Merge did nothing" was the false-conflict
  dead-end (real divergence DOES open the 3-pane sheet; pinned by test). Fixed with I-01.
- **I-04 (bug)** — Indent guides render at 2-space pitch on a file detected as 4-space
  indent — the detected unit isn't plumbed into guide spacing. **S**

**P1 — user-facing queue (one leads each round; big swings welcome):**
- **I-05 — Git-status file-open experience** (the flagship): ~~(a) status-file clicks open
  as EPHEMERAL temp tabs~~ + ~~(b) Diff|Source toggle header~~ **DONE (R6, 2026-08-01)** —
  row clicks route through `GitStatusOpenMode.clickAction` (diff default, untracked→source,
  both ephemeral; permanent open stays on the context menu; toggle
  `mdv.git.openModeToggle` persisted). ~~(c) diff line backgrounds~~ **DONE (R7)** —
  diffweb.html row washes strengthened (0.22/0.18 light, 0.24/0.20 dark) + a 3px colored
  left edge bar per changed row (VS Code idiom); webview-lane pin
  (`test_changedRows_haveVisibleWash_andEdgeBar`). REMAINING: (d) evaluate an
  inline/side-by-side option (@codemirror/merge MergeView is bundled but unused). **S–M**
- ~~**I-06 — Git-status list polish**~~ **DONE (R6)**: gapless full-height hover fill,
  pointer + hover feedback on stage/unstage buttons.
- **I-07 — Pointer-cursor FULL AUDIT**: every interactable shows pointer/correct cursor,
  non-interactables don't lie. Ultracode-eligible sweep + fix pass. **M**
- **I-08 — Local History usability**: (a) "Apply this version/diff to file" action (today
  copy-out is manual); (b) copy UX — selecting version text must NOT grab line numbers /
  shoulder chrome. **M**
- **I-09 — Web-migrate wave (owner: "do it")**: CSV grid (1527) · read-only source →CM6
  (1530) · hex grid (1531) · log/transcript streams (1532) · git-log/blame (1533). Diff is
  already web. Sequence as its own rounds; each sub-item is one round's user-facing slot. **XL**
- **I-10 — Settings cleanup**: flat inline (keep), but reorder/regroup/label; screenshot
  before/after on the VM; kill the "mess" feel. **M**
- **I-11 — CM6 Find/Replace overhaul**: native-mac look (icons/symbols/spacing), panel scales
  with zoom level, match COUNT readout, scrollbar match ticks (Chrome-style), match highlight
  yellow→purple. **M–L**
- **I-12 — CM6 gutter/selection ergonomics**: line numbers unselectable; click/drag on gutter
  selects whole lines; no wasted shoulder space when nothing renders there; selection-match
  highlight LIVE during drag (not only after mouse-up). **M**
- **I-13 — Pretty-print** button beside the Editor|Hex group for eligible types (JSON first;
  also offered when manually switching type e.g. Plain Text→JSON). **S–M**
- **I-14 — AutoSave (opt-in)**: afterDelay + on-focus-loss modes on the existing save funnel.
  ORDER CONSTRAINT: after I-01 (autosave amplifies the false-conflict bug). **M**
- **I-15 — LSP occurrences**: caret/selection on a symbol highlights all instances
  (documentHighlight) + "Find References" in the editor context menu (palette-only today). **M**
- **I-16 — Tab & chrome UX overhaul** (slices, each independently shippable):
  (a) tab visuals — active = white bg / inactive grey, pointer cursor, drop the active
  underline; (b) strip placement — tabs start after the left nav, end before the right nav;
  (c) split panes get their OWN tab strips; (d) per-tab footer — tab-specific info moves off
  the global footer; (e) Wrap / Special-chars / Plain-Text(type) controls move beside the
  Editor|Hex group. **L total, S–M per slice**
- ~~**I-17 — Double recents limits**~~ **DONE (R6)**: store 20→40, Open Recent menu
  prefix 20→40, history 100→200.
- **I-18 — Crash-guard toast**: add a "Restore now" action to the "Starting fresh" toast
  (today the recovery is quit+relaunch, undiscoverable). **S**

**Already done (intake asks that turned out shipped):** third-party notices ARE bundled
(`build-app.sh:275` + missing-file hard fail); "Find References" exists in the palette
(the ergonomics gap is I-15); backup-mirror push realigned (SOP now pushes after each round).

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

## ⚠ OPEN FOLLOW-UPS (updated at the 2026-08-01 handoff — everything below is COMMITTED)

State: main @ f711c2b8 (17 commits landed 07-31..08-01: owner-queue drain + release pipeline +
AX tier + 5 paired rounds). The struck-through items in this section are the audit trail; the
LIVE open set is: VM tail triage (TSK-1247 = the big one; EBADF stragglers; gitPanelScene
quirk), Local History smarter retention (re-diff on eviction first), merge-sheet interactive
flows (AX-unblocked now), owner-side: mvd_dist zip refresh (7 features behind) + tasked-board
reconciliation on reconnect + math-typography eyeball. Exec size sits at 68 of 70 MB — the
TSK-1214/1098 reclaim is nearly due.

- **Owner-directed, next in queue:** ~~tab-drag-onto-session-pill~~ (LANDED 2026-07-31:
  `TabSessionDropChannel` + `StripExternalTarget`, pill highlight pixel-verified, negative-control
  teeth); ~~markdown gap-closures~~ (LANDED 2026-07-31: footnotes/alerts/def-lists/sup+sub/heading
  attrs, option+writer-arms together, rust+FFI+webview-paint tiers; **wikilinks deferred** — needs
  a link-resolution policy call: what does `[[page]]` resolve to in a folder session?);
  ~~save/retrieve-session~~ (LANDED 2026-07-31 as NAMED SAVE POINTS: `SessionStore` `saved/`
  shelf + coordinator save/restore/delete + context-menu & +-menu surfaces; save flushes live
  state incl. unsaved buffers; restore = new session, point survives; 12 host tests + isolation
  pin vs the TSK-438 recovery scan). ~~wikilinks~~ (LANDED 2026-08-01: `[[page]]`/pothole →
  `mdv-wikilink` anchors; host-side `WikiLinkResolver` ladder — beside-file → `.md` → bare-name
  at workspace root; the interception also un-deadened ORDINARY relative file links, which
  `decide` had been cancelling; rust+resolver+paint tests green). Queue fully drained. **M each**
- **AX tests for new UI work (owner policy shift, 2026-07-29).** ~~L bootstrap~~ **BOOTSTRAPPED
  2026-07-31**: `AXInteractionTestCase` tier (GUI-lane + `AXIsProcessTrusted` gated) +
  `AXChromeInteractionTests` green on the VM (find-by-`mdv.*`-id with real frames; HID click at
  AX frame → GoTo panel appears — the full real-event round-trip). Mechanism truths in LESSONS
  (AXPress accepted-not-dispatched; postToPid not hit-tested; HID-tap works). Per-feature
  rollout now unblocked — ~~(a) drag rung~~ (DONE 07-31, `AXStripDragTests`); ~~(c) palette
  AX ids~~ (DONE 08-01: `mdv.palette.*` vocabulary + pin test + AX round-trip green; the fix
  also surfaced the implicit-combine container rule — LESSONS). Remaining: **(b)**
  inner-control AX frame fidelity (a `.contain` parent's children can report the parent's
  frame — the tab close button does; fix or offset-click before targeting small controls),
  **(d)** fold the suites into the nightly `all` lane notes + grow `AXIdentifierCatalog`.
  ~~(b) child-frame fidelity~~ (RESOLVED-AS-DOCUMENTED 2026-08-01: structural bridge behavior,
  modifier order can't fix it; drivers derive small-control positions from the parent frame —
  the tab × close-by-click test passes that way, and a pinned equality tripwire flips if
  SwiftUI ever fixes child frames). Remaining: **(d)** fold the AX suites into the nightly
  lane notes + grow `AXIdentifierCatalog`. **S per feature**
- ~~Delete the dead `ModeBar` struct~~ **DONE 2026-08-01**: ~300 lines removed; the three
  still-live label statics rehomed to `LensLabels`; the two chrome-harness tests now mirror
  the real `ContentToolbar` band (same height math, green).
- **Math typography eyeball on the OWNER's machine.** WebKit MathML geometry is proven (VM
  webview lane green); the capture lane cannot show WebView content (TSK-1247), so the visual-
  quality check is one open of a math file on the host. If rough → KaTeX-CSS fallback talk. **XS**
- **Tab tear-off drag (deliberate re-add, do NOT do it with a bare `.onDrag`).** A real tear-off
  = `NSDraggingSource` that reorders in-strip and promotes to a file drag on leaving — a bare
  `.onDrag` reinstates the window-opens-the-file bug and is blocked by a regression pin in
  `FileDragProviderTests`. **M**
- ~~Pointer-drag interaction rung for tab reorder~~ **DONE 2026-07-31**: `AXStripDragTests`
  (VM-green) — a HID-synthesized drag drives the real `DragGesture` for BOTH strip drags:
  reorder (frame-sorted id order flips) and tab-onto-session-pill (the file moves sessions).
  `AXClickExecutor.drag(from:to:)` is the shared substrate.

- **Local History: smarter retention beyond gap-thinning (owner ask 2026-07-29).** Today: 100 MB/
  file budget, no age expiry, over-budget drops the interior version leaving the smallest time gap
  (first + newest never dropped), and small edits store as diffs against the nearest full anchor.
  Smarter follow-ups, roughly in value order: (a) **re-diff on eviction** — when a FULL snapshot is
  the thinning victim, re-encode its neighbours as diffs against a surviving anchor instead of
  deleting outright (keep the version, shrink the bytes); (b) **tiered density targets** — e.g.
  keep every version <1h old, hourly to a week, daily beyond, applied per-file; (c) **cross-version
  compression** (zstd the record payloads — they're plain UTF-8 today); (d) surface per-file
  history size + a "compact now" action in the Local History UI. **M–L**
- ~~Recently Closed is NOT persisted across launches~~ **DONE 2026-08-01**:
  `recently-closed.json` beside `history.json` (coalescing JSONFileStore queue), deleted-since
  files filtered at load, `AppCacheReset` `.recents` wired, injectable nil-URL in-memory mode
  for tests; 4 persistence tests + the 10 semantics tests green. Still ONE list for the whole
  app (the store lives on the shared `DocumentModel`) — fine unless the owner wants per-session
  lists.

- **Disk-conflict follow-ups (from the 2026-07-29 fix).** The banner + save-prompt paths now
  preserve every discarded side and never pick silently. ~~viewDiff no-op stub~~ (WIRED
  2026-08-01: unified buffer-vs-disk diff into the ephemeral preview slot, identical-text
  conflicts self-explain; `SaveConflictViewDiffTests`). ~~Overwrite/Reload toast-after~~
  (UNIFIED 2026-08-01 on the banner's pre-confirm — `confirmDiscardIsPreserved` gate in
  EditorCoordinator, 3 tests; the shared apply-funnel keeps a belt-and-braces reporter since
  its callers pre-confirm upstream). Conflict family: no known gaps.
- **[VERIFIED 2026-07-30] Merge sheet** — seen on real pixels via the `conflict-merge` scene:
  banner + three labeled panes + per-conflict picker + Apply gating all correct.
  ~~hex hot-exit~~ (CLOSED 2026-08-01: dirty hex rides `TabSnapshot.unsavedHexBase64` —
  capture at every text-capture boundary, restore at materialize re-stashes + marks dirty,
  the hex view seeds from the stash so seen==saved; 512 KB inline cap with a told-not-silent
  refusal; 4 tests + round-trip. Crash-window note: covered by the same autosave cadence as
  text — the debounced snapshot rides `$tabs` ticks). Remaining in the family: the
  interactive merge-sheet flows (pick → Apply) are AX-lane. **S**

### VM lane findings — git-panel scene capture 2026-08-01 (R6 render rung)

- **GOOD: the git-panel scene's fixture now yields statuses on the VM** (staged/unstaged/
  untracked all render — the 07-31 "no statuses" quirk is gone; capture:
  `tmp/git-panel-r6.png`). The R6 header toggle + rows + commit bar confirmed on pixels.
- **`vm-uitest.sh`'s AX reader dumps ONLY the menu-bar tree for the git-panel scene** — the
  `.ax` file holds Apple-menu selectors + traffic-light buttons, ZERO window-content ids
  (not just the new ones; `mdv.git.statusTab` with `.contain` applied is absent too, and so
  is every other `mdv.*`). So the scene's a11y assertion can't pass for ANY expectation —
  reader permission/attachment/timing issue, not a view materialization bug. TSK-1577 tail:
  fix the reader (compare against the scenes where the a11y gate DOES pass), then re-arm
  `git-panel`'s expected-ids. **S–M**

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
- ~~[TEST BUG] `FileTabStripVisualRegressionTests` separator detector~~ **FIXED 2026-08-01**:
  exactly the predicted cause — the 3pt cluster window split one separator's two edges (7px at
  2x under 110% zoom) into two "separators" and the gap sanity check rejected them. Calibrated
  to 5pt (~20× under min tab width) with the capture data in the comment; suite green on the
  VM, crowded/plus-button tests unaffected. (Reminder that survives: don't trust heavy-tier
  results taken under host CPU contention.)
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
3. **NO inline full gate (owner 2026-08-01)** — per commit run only the TARGETED
   `swift test --filter` suites for what changed. The **standing CI loop** (`scripts/ci-loop.sh`
   in the permanent worktree `../markdown_viewer-ci`, armed as a persistent Monitor) re-runs
   the central gate on every new committed HEAD and reports `CI <sha> GATE rc=<n>`; a red
   line = triage now (bench-only failures under load: re-run quiet, TSK-1499). Run the gate
   inline only if the loop is down. (+ `scripts/rust-core-gate.sh` targeted if rust touched.)
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
