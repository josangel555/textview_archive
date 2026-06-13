<!-- CLAUDE-HANDOFF v1 -->
# Handoff — RUST-CORE Stage B (twin deletion) is the active lane; #1 indent done  (2026-06-13)

**Session:** claude-mdv (autonomous loop)  ·  **cwd:** `/Users/me/Documents/workspaces/claude/markdown_viewer`  ·  **branch/SHA:** `main` @ `008518a` (+ a docs commit). Recent ticks: render-health VM pass (18/18); `set-theme` verb (unblocks 641 chrome T5); `lsp-rename` verb (unblocks 640 rename UAT). Both verbs are automation/UAT enablers for the two remaining user-facing UI tails.

## ⚠️ The remaining fixed-lane work is user-facing UI tails — each a dedicated build tick
The cheap drains are done. What's left needs a focused SwiftUI/T5 effort (don't expect a quick re-run drain):
- **641 chrome → a T5 chrome-pixel test.** Unblocked by the `set-theme <id>` verb. Build: an app launch
  env-seam (e.g. `MDV_FORCE_THEME`) OR drive `set-theme` via `--script`; spawn the app with a folder (sidebar
  visible) + theme=xcode-dark; `screencapture` the sidebar; assert the themed dark color (compute expected
  from the theme def, or A/B vs xcode-light). Mirror `SourceViewVisualRegressionTests` (PixelTestCase). Wire
  into `test-in-vm.sh run_webview_tests`/equivalent + `nightly-vm.yml`. Needs `dist/` built on the VM (heavy)
  + the screencapture run + teeth (revert chrome fix → red). Closes 641's 4th surface → validated.
- **640 rename → the interactive UI.** Unblocked by the `lsp-rename` verb (engine + automation host-tested).
  Build: `lsp.rename` command + Edit-menu "Rename Symbol…" + a rename prompt sheet (GoTo-prompt pattern) whose
  submit calls the verb's action; + a code-action picker. Host-test the command/enablement/submit-wiring; the
  sheet render holds at review (VM). Delivers user-reachable rename (owner re-raised, P8).
- **NOTE on cadence:** the last 2 ticks landed automation-verb seams (set-theme, lsp-rename). Don't do a 3rd
  verb-only tick — the next THEMING/LSP tick should build one of the two UI tails above (real user value), or
  pick a genuinely-headless NEW item from the `[WISH][minor-feature]` bucket (745 recents, 757 shortcut catalog).

## ⭐ NEW CAPABILITY (2026-06-13): the VM live-validation drain is AGENT-RUNNABLE — proven
The big `fixed`-lane pool (~15 items) is gated on `live-validation` (WebView/render). I proved the VM lane
works end-to-end with NO owner clicks. **Recipe (rsync first, then):**
```
rsync -az --delete --exclude='.build/' --exclude='.swiftpm/' --exclude='dist/' --exclude='.git/objects/pack/' \
  /Users/me/Documents/workspaces/claude/markdown_viewer/ macOS15:markdown_viewer/
ssh macOS15 'cd markdown_viewer && MDV_RUN_WEBVIEW_TESTS=1 MDV_VM_GUI_SESSION=1 MDV_VM_SUDO_PASS=<vm-sudo-password> \
  bash scripts/test-in-vm.sh test --filter ViewerUITests.<Suite>'
```
- `MDV_RUN_WEBVIEW_TESTS=1` is forwarded into the `launchctl asuser` GUI session → the `#192` WebView suites
  RUN (not skip — confirm "Executed N tests", not "0 tests"). 6.3 toolchain auto-selected. Warm builds 4-35s.
- This is the §1.5 drain done right: re-run the host guard + the VM lane the ticket claims, then `task_validate`.
- **Validated this way last tick: TSK-650** (mermaid render bug — host MermaidBundleLoadTests + VM
  MermaidRenderProbeTests) **and TSK-638** (Print/PDF — host PrintExportModelTests + VM PDFExportWebViewTests;
  the ⌘P modal panel is the lone un-automatable atom, acknowledged not pixel-claimed).
- **WebView-clean drains are EXHAUSTED** (650/638 closed; a fresh 18/18 WebView-lane pass confirms render
  health on current main). The remaining live-validation `fixed` items each need a DEDICATED effort, not a
  quick re-run:
  - **641 chrome → build a T5 chrome-pixel test (NEXT, now unblocked).** 3 of 4 theme surfaces are
    VM-confirmed (syntax/rendered-CSS/editor via EditorThemeParityTests); only the SwiftUI CHROME pixels
    remain (a T5 PixelTestCase, NOT WebView). The `set-theme <id>` script verb (commit 06e0c94) is the entry:
    a T5 test launches the app, drives `set-theme xcode-dark`, screencaptures the sidebar, asserts the themed
    color ≠ system. T5 lane is proven (screencapture TCC granted, GUI session). Mirror an existing
    `*VisualRegressionTests` (PixelTestCase) + the `MDV_UI_SCENE` scene mechanism. Closing 641 unblocks 642.
  - **640 LSP rename → build the interactive UI** (command + Edit-menu item + rename prompt sheet, GoToPrompt
    pattern + a code-action picker). The engine (renameActiveEditorSymbolViaLSP / applyCodeAction) is fully
    host-tested; only the user trigger is unbuilt. Model/command layer host-testable; the prompt render → VM.
  - **468 → a VM T4 menu-contents check** (dead-UI removal; nothing host-assertable) — low value, defer.
- **Latent flake (LESSONS):** theme tests share `ThemeStore.shared` under `--parallel` → rare cross-class
  race; re-run a lone theme/gate flake before chasing.

## Mission
Owner away until ~noon 2026-06-13; autonomous chipping. USER-FACING bugs are drained; the wishlist
minor-feature wave is in flight (748/763 at review). **HIGHEST-VALUE LANE RIGHT NOW: TSK-649 Stage B — the
owner-approved Swift-twin DELETION endgame ("deprecate swift core").** Validate across the pyramid (human not
in loop); keep `main` headless-gate-green; land per item on the linear trunk. Read `docs/TASK_WORKFLOW.md`
every firing (§0.5 spike/design autonomy + chipping order; §1.5 validation-drain outranks new work).

## ⭐ ACTIVE LANE: TSK-649 Stage B — delete the Swift engine twins (owner-approved 2026-06-13)
The owner resolved TSK-649's park: **"Approve policy + batch 1-4 (indent/hexSearch/hex/diff); review 5-9
individually."** Stage A (all 10 caps default-ON) is done + soaked. Stage B deletes the now-dead twins per
`docs/STAGE_B_DELETION_PLAN.md`, one package per engine.
- **#1 indent — DONE + VALIDATED (TSK-808, `1e2b557`).** The clean template.
- **#4 diff — DONE + VALIDATED (TSK-809, `954f1d8`).** Also clean (twins adapter-only, fully deleted).
  Bigger blast radius (12 test files): A/B → golden snapshots, 8 fixture suites retargeted to the adapter,
  twin tests + bypass audit retired, seam/obs tests reparented to `.csv`.
- **#2 hexSearch · #3 hex — PARKED (TSK-810, owner-decision).** NOT clean: the Swift engine has a live
  non-gated consumer (hexSearch click-highlight `HexSearchEngine.find(pattern:)`; hex un-ported windowed
  `HexDumpBuilder`), so the "delete twin / no fallback" model can't apply as-is. 3 options framed; recommend
  (A) keep-fallback + retire-gate. **Do NOT start #2/#3 until the owner answers** — the call sets the pattern.
- **#5-9 (csv/fuzzy/find/transcript/markdown) — each needs individual owner review** + a named caveat (csv
  DocId, fuzzy FileTreeFilter per-node, find ICU-fallback REMOVAL = behavior change, transcript
  ClaudeSessionIndex helpers, markdown sanitizer/mermaid/TS spans stay) — several share #2/#3's carve-out shape.
- **The template pattern** (proven on #1): delete twin source → collapse adapter to a direct `mdvCore*` call
  with a safe degraded value + loud `Obs.error` (no Swift fallback) → retire the `RustCoreCapability` gate
  case + env var + Settings toggle (KEEP the ABI bit in `CoreCapabilities` — bits are ABI) → freeze the A/B
  suite to a GOLDEN suite (frozen values, no Swift oracle) + retarget/retire the twin's unit tests → headless
  gate + golden teeth. `RustCoreSeamTests` `allCases` loops adapt automatically to a removed gate case.

## Standing directives (2026-06-13)
- **Spike + design AUTO-APPROVED** (TASK_WORKFLOW §0.5 / memory `feedback_spike_design_autonomy`): never
  `task_park` just because something needs design/an-approach-decision. Re-surface ONLY a genuine dep
  approval / true undifferentiated ambiguity / hard blocker, post-spike.
- **Chipping order:** regressions → bugs → minor-features(no-design) → epics(spike→design→ship) → very-large.
- **Per-tick cadence:** land 1–2 items per tick with teeth; keep `main` green; commit + log each.
- **Validation split:** model/pure-logic → self-validate (host). Render/event/concurrency (SwiftUI pixels,
  AppKit key routing, off-main) → host-test the LOGIC, hold at `review` for the VM. Don't over-claim validated.

## DONE this session (minor-feature wave — 2 items, 4 commits)
- **TSK-748 → review** (3 commits): file-info **multi-algo checksums** + responsive copy button.
  - `2e1d345` ENGINE: `FileChecksum` generalized to `ChecksumAlgorithm` (CRC-32/MD5/SHA-1/SHA-256/SHA-512)
    — generic CryptoKit fold + hand-rolled streaming CRC32 (no new dep). Pinned to published vectors.
  - `2c43d0a` MODEL: `MetadataChecksumModel` algorithm-parameterized, (url,algorithm) stale-completion
    guard; `metadata-set-checksum-algorithm` verb + `algorithm` in dump projection; Picker + dynamic labels.
  - `d3a469b` COPY FEEDBACK: `copyHash()` via injectable `PasteboardIO`, transient `justCopied` → green
    "Copied!" self-clears 1.2s. 13 model + 8 engine host tests, teeth on 3 paths.
  - **(c) "metadata for all formats" SPLIT OUT → TSK-807** (needs a FileCategory coverage-inventory spike).
- **TSK-763 → review** (`885cb7b`): recents grey containing-folder hint. `HistoryEntry.parentFolderLabel`
  (home→~, root→/, nil for bare name) rendered tertiary-grey in `RecentRow`. 4 host tests, teeth shown.

## Earlier this session (pre-minor-feature)
Wishlist bug bucket FULLY DRAINED (TSK-728..744, 14 fixes; 8 validated, 6 in the VM review queue, 743 awaiting
owner A/B). Wishlist intake via ultracode workflow (184 lines → 136 tickets). VM FULLY UNBLOCKED (owner's 6GiB
+ Screen-Recording; TSK-451 closed). Spike docs + intake triage committed `babbe31`
(`docs/research/*-2026-06-13/`). rust-core: TSK-572/570 validated.

## VM REVIEW QUEUE for the owner's noon pass (one UI/live session validates all)
Render/event/concurrency items held at `review` — `task_list {project:tasked, state:review}`:
- Bug bucket (6): **734·728·730·738·736·741**.
- Minor-feature (2 new): **748** (checksum Picker shows 5 algos · switch clears hash · per-algo digest ·
  Copy→green "Copied!" reverts ~1.2s) · **763** (recent row shows grey folder; same-named files differ).

## Owner decisions waiting at noon (`task_list {waiting:human}` + below)
- **743 A/B**: scroll "preserve" — independent-scroll done; "remember-on-return" needs a per-URL store
  (recommend confirming interpretation). Sibling filed: TSK-806 (split-pane).
- **Migration plan §6** (`docs/research/rust-migration-plan-2026-06-13/PLAN.md`) — 3 calls (TSK-775).
- **Terminal Tier-D** (TSK-781). **Dep approvals**: 584/585/587/399.

## How to resume
1. Read `docs/TASK_WORKFLOW.md`. Stage B's CLEAN packages are done (#1 indent TSK-808, #4 diff TSK-809,
   both validated). **#2 hexSearch + #3 hex are PARKED on TSK-810 (owner-decision) — do NOT start them until
   the owner answers** (the carve-out fallback model). #5-9 also need owner review. So Stage B is owner-gated
   for now → **pick another lane** (don't idle). Good headless picks: the `[WISH][minor-feature]` bucket
   (TSK-745 new-tab recents · TSK-757/678 shortcut catalog · TSK-770 Find-bar Replace/ReplaceAll), or the
   `fixed`-lane validation drain (§1.5) for any host-validatable ticket. Template for a clean Stage B engine
   (when unblocked): `TSK-808`/`TSK-809`.
2. **Secondary: the `[WISH][minor-feature]` bucket** (when Stage B 1-4 is done or you want variety). Headless
   picks: **TSK-745** (new-tab recents — `model.recents` exists), **TSK-757/678** (shortcut catalog + Help),
   **TSK-770** (Find bar Replace/ReplaceAll), **TSK-724** (Recent Locations). TSK-573 (web palette → core)
   is triaged but its honest fix is a large CSS var() refactor that needs VM pixel proof — deprioritized.
3. Gates: `bash scripts/test-headless-gate.sh` (host, one at a time) · `bash scripts/rust-core-gate.sh`
   (only if `rust-core/` source changed — Stage B twin deletions are Swift-side, so the headless gate covers
   the golden suites). VM: rsync + `bash scripts/test-in-vm.sh test --filter <Suite>` (headless) /
   `MDV_VM_GUI_SESSION=1 MDV_VM_SUDO_PASS=<vm-sudo-password> ... --filter <T5 suite>` (pixel).

## Gotchas / lessons (also in LESSONS.md)
- The MetadataChecksumModel state machine is the host pixel-equivalent seam: a script verb +
  dump-projection lets the T4 UAT assert the compute/algorithm/copy outcome cross-process without rendering.
  Pattern to reuse for any live-gated UI feature with a model behind it.
- `task_advance` walks reported→…→target but takes NO commits param — attach the SHA via a `task_comment`
  after, or `task_record` (with commits) before advancing. The triage step needs a `note`; progress→fixed→
  review needs a `summary`.
- AUTONOMOUS_PROGRESS.md LOG entries are NOT strictly monotonic on disk (a +318..+325 block sits below the
  +350 region). Find the max with `grep -oE '^## LOG \+[0-9]+' | sort -n | tail` and prepend the new entry
  directly above the current max.
- Demonstrate teeth every fix: mutate→red (confirm the mutant COMPILED: grep `Compiling <module>`)→restore.

## Tracker
- tasked / TSK-748 (review, 3 commits) · TSK-763 (review, 885cb7b) · TSK-807 (reported, new split for metadata-all-formats).
