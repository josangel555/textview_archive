<!-- CLAUDE-HANDOFF v1 -->
# Handoff — scroll fix FULLY VALIDATED (editor done via in-process WebView test)  (2026-06-23)

**Session:** claude-mdv (autonomous ~5min cron + owner interaction)  ·  **cwd:** `/Users/me/Documents/workspaces/claude/markdown_viewer`  ·  **branch:** `main` @ `d1a1c36e` (verify `git log -1`).

## Mission
Immediate: make the session/tab-switch **scroll-reset fix (TSK-1046)** validated + reproducible for UAT/smoke on BOTH surfaces (rendered preview AND CM6 editor). **DONE.** Broader autonomous mission: drain the `tasked` board toward `done` (BACKLOG.md is the curated selector; board is system of record).

## Current state
- **DONE — scroll fix has full, correctly-shaped coverage:**
  - RENDERED preview: on-screen green via spawned-app UAT (`ScrollRestoreUATTests` SCROLL01 tab-switch + SCROLL02 session-switch).
  - EDITOR (CM6): live-CM6 green **in-process** — `EditorScrollRestoreWebViewTests.test_restoreSeed_scrollsLiveCM6_toSavedLine_notTop` (commit `d1a1c36e`, green on VM run `bp75y4deg`). Wired into `run_webview_tests` (test-in-vm.sh) + `nightly-vm.yml`.
  - MODEL/seed: host-tested (`editorMountSelectionSeed`) + **owner manually confirmed fixed on-screen**.
  - This arc's commits (all on main): `155b61a0` (new test + lane wiring) → `4cb35015` (`;true` attempt) → `a3ebdf9a` (completion-handler bridge) → `d1a1c36e` (drop flaky sibling + LESSONS). Working tree clean (untracked `OwnerWishlist.md`/`Untitled.txt` are NOT mine).
- **DONE earlier this session:** TSK-1243 viaOpen UAT-harness env-delivery + `didFinishLaunching` fallback (unblocks the keystroke/`--script` UAT class); prod (release) build re-installed to `/Applications`; crons stopped (owner asked).
- **In flight:** nothing mid-edit. This `/handoff` is the wrap-up (a compaction fired mid-handoff; this doc is the corrected, current handoff — the prior on-disk one was stale at `f37f8ed2`).
- **Next action (autonomous loop):** TSK-1046 sits at `review` for the owner to close → `done`. For new work: pull the next BACKLOG.md item — section B (render/VM tails) or the board's groomed pools. TSK-1047 (editor warm-cache, perf) is the natural follow-on but is VM-blocked (see below).

## Key decisions & rationale
- **Editor scroll-restore validated via an IN-PROCESS `WebViewTestCase`, not the spawned-app `--script` UAT.** The owner's redirect ("why grind headless, why not a proper test?") was the unlock. The spawned-app GUI-lane UAT cannot validate CM6 — its WebContent is jetsam-killed (`none-NotVisible` → idle-kill). In-process mounts CM6 in the test process (no spawned app → no jetsam); the sibling Fold/Blame/MultiCursor/EditorReplace/PaneScrollRestore WebViewTests all pass in-process on the VM, proving CM6 survives there.
- **Dropped the `scrollToLine`-puts-line-at-TOP sibling test** rather than leave a flaky red: `applyScrollToLine` needs a measured viewport/rAF cycle a HEADLESS in-process WKWebView doesn't run. The restore path uses `scrollIntoView` (works headless), so `test_restoreSeed` is the reliable validation; `scrollToLine` is exercised by the `editor-scroll-to-line` verb elsewhere.
- **All test JS reads go through the completion-handler `evaluateJavaScript` + `withCheckedContinuation`**, not the async `try await` variant (which throws WKError-5 flakily even for Number/Bool).

## Gotchas / lessons (also in LESSONS.md — 5 new dated entries)
- **CM6 can't be UAT'd via the spawned-app GUI lane** — WebContent jetsam (`NotVisible`). Use in-process WebViewTestCase. NOT memory (purge → 2.5GB free, still died).
- **async `try await webView.evaluateJavaScript` throws WKError-5 ("unsupported type") flakily** even for a Number/Bool result — use the completion-handler API via `withCheckedContinuation`, extract the Sendable value INSIDE the handler.
- **rsync -a preserves mtimes → SwiftPM skips recompiling on the VM → stale test/dist.** `touch` changed `Sources/`+`Tests/` files on the VM before `swift build`/`test`; watch for `Compiling <file>` in the log. Bit me 3× this session (looked like "my fix didn't work").
- **A `#192`-gated in-process WebView suite runs ONLY via `run_webview_tests`** (test-in-vm.sh `quick`/`all`). `test --filter X` STRIPS `MDV_RUN_WEBVIEW_TESTS` → self-skips (instant 0.003s). New suites MUST be added to the filter list in BOTH `run_webview_tests()` AND `nightly-vm.yml` or they run nowhere (false green).

## Files that matter
- `Tests/ViewerUITests/EditorScrollRestoreWebViewTests.swift` — the NEW in-process editor scroll-restore test (the deliverable). Pattern source: `Tests/ViewerUITests/BlameGutterWebViewTests.swift`.
- `scripts/test-in-vm.sh` — `run_webview_tests()` (~line 237) has the hardcoded `--filter` list (EditorScrollRestore added); `quick`/`all` modes invoke it; `test` mode strips the env (TSK-1236). Output → `/tmp/mdv-webview-output.txt`.
- `.github/workflows/nightly-vm.yml` — the WebView-lane `--filter` list (EditorScrollRestore added).
- `Sources/ViewerUI/DocumentModel.swift:3235` — `editorMountSelectionSeed` (the seed-belt the test validates). `Sources/ViewerUI/Resources/codemirror/codemirror.html:1446` — `applySetSelection` (the seed → `scrollIntoView`).
- `Sources/MarkdownViewer/main.swift` / `ScriptRunner.swift` — the TSK-1243 viaOpen launch-config + async-eval bridge + diag scaffolding (committed earlier, harmless).
- `LESSONS.md` (top) — the 5 new entries. `BACKLOG.md` (TSK-1046 line) — updated to validated.

## Open questions / blockers
- **TSK-1047 (editor warm-WebView cache, PERF) is VM-blocked.** Its `WarmEditorWebViewCache` (branch `worktree-agent-a7b9fc7b...`, commits `e25fc38f`/`539eb8f0`/`3c80a3c7`) FAILED on the VM (SCROLL03/04 still reset); DEBUG probes added (`EditorWarmCacheProbe`, `capture-editor-scroll` verb, `liveEditorTopLine` dump field). Needs the VM `[WARMCACHE-PROBE]` trace to pinpoint where park→re-attach breaks (6 hypotheses listed on the ticket). NOTE: validate it IN-PROCESS, not via the spawned-app UAT.
- TSK-1046 → `done` is the owner's close (render-path agent ceiling = review).

## Tracker (tasked, localhost:8787, agent claude-mdv)
- **TSK-1046** — `review`. Full-coverage resolution recorded (rendered + editor in-process + model). Ready for owner to close to `done`.
- **TSK-1047** — `progress` (blocker: live-validation). Handoff note added: seed-belt validated (TSK-1046); warm-cache (this ticket's scope) still failing on VM, needs the probe trace.
- **TSK-1243** — viaOpen UAT harness env-delivery + lifecycle fixed earlier (keystroke/script UAT class unblocked).

## How to resume
1. Read this file, then `git log -1` (expect `d1a1c36e` on `main`) + `git status` (expect clean).
2. The scroll fix is DONE — nothing to re-run unless re-validating. To re-run the editor test on the VM:
   `rsync -az --delete --exclude='.build/' --exclude='.swiftpm/' --exclude='dist/' --exclude='.git/objects/pack/' /Users/me/Documents/workspaces/claude/markdown_viewer/ macOS15:markdown_viewer/`
   then `ssh macOS15 'cd markdown_viewer && touch Tests/ViewerUITests/EditorScrollRestoreWebViewTests.swift && export MDV_VM_GUI_SESSION=1 MDV_VM_SUDO_PASS=<vm-sudo-password> && bash scripts/test-in-vm.sh quick'` — grep `/tmp/mdv-webview-output.txt` for `EditorScrollRestoreWebViewTests test.*passed`. (`touch` dodges the stale-mtime trap; `quick` runs the WebView lane.)
3. For NEW autonomous work: read `docs/TASK_WORKFLOW.md` + `BACKLOG.md`; pick the next actionable item (TSK-1047 warm-cache needs VM diagnosis; or section-B render/VM tails; or the board's groomed pools). Host gate: `bash scripts/test-headless-gate.sh`.
4. VM creds: host `macOS15`, user `vm-tester@<vm-ip>`, sudo `<vm-sudo-password>`. NEVER `killall MarkdownViewer`. UI/live tiers VM-only.
