<!-- CLAUDE-HANDOFF v1 -->
# Handoff — VM back; validation drain in flight (stage 2b re-running vs fresh dist/)  (2026-06-15 00:30)

**Session:** claude-mdv (autonomous loop)  ·  **cwd:** `/Users/me/Documents/workspaces/claude/markdown_viewer`  ·  **branch/SHA:** `main` @ `e6033e9`

## Mission
Autonomous loop. Right now: the UTM VM is BACK after ~15 ticks down, so the top lever — the VM
render-validation drain of the ~70-item `review` pile → `done` — is finally running. Land it, then resume
WORK_QUEUE / groomed-pool work.

## Current state
- **Done + verified this session:** **VM stage 1 (headless) = 5813 tests / 0 failures** on Swift 6.3
  (`test-in-vm.sh test`) — current `main` is fully forward-compat; Rust path solid (CSV 0.50×). Earlier
  in the day shipped 12 commits (find-menu, file-nav, CLI, palette-parity, content-detect, terminal-
  favorites, bench fix, secret-scan script) — all at `review`/`validated`, gate-green.
- **🔴 IN FLIGHT — VM stage 2b is running in the background** (`bzglu8tx3`):
  `MDV_VM_GUI_SESSION=1 MDV_VM_SUDO_PASS=<vm-sudo-password> MDV_RUN_WEBVIEW_TESTS=1 bash scripts/test-in-vm.sh all`
  → output on the VM at `/tmp/mdv-stage2b.log`, JUnit at `/tmp/mdv-test-results.xml`. `all` rebuilds
  `dist/` FRESH (`build_all`) then runs the full GUI pyramid vs current `main`. ~25 min. **Wait for it.**
- **Why stage 2b:** stage 2 (first GUI run) showed 54 UAT "failures" — but they were against a STALE
  `dist/` (May 16 binary; rsync excludes `dist/`, `test` mode doesn't rebuild it). NOT real regressions
  (headless save tests pass on current `main`). See the stale-dist lesson below. Stage 2b is the
  CORRECT re-run vs a freshly-built bundle.

## Next action (when stage 2b completes)
1. Read `bzglu8tx3` output / the VM `/tmp/mdv-stage2b.log` + parse `/tmp/mdv-test-results.xml` for failing
   testcases (grep `<testcase ...><failure`). Note JUnit only says "see swift test output" — the real
   assertions are in the stdout log (full, not tail).
2. If the live-app/UAT/pixel tiers are now GREEN vs fresh `dist/` → the 54 were stale-bundle false
   failures. Then DRAIN: drive `review` items whose dedicated VM render test passed → `validated`
   (`task_validate` with the VM checks artifact); list owner-glance-only items for the owner's `done`.
3. If some UAT still FAIL vs fresh `dist/` → those are REAL regressions from ~15 days of un-VM-validated
   UI features. Re-run each failing class in isolation, read the assertion, file a board bug + fix.

## Key decisions & rationale
- Ran the VM drain in stages (headless `test` first, then GUI `all`) to de-risk — a build/forward-compat
  failure would waste the heavy lane. Stage 1 green confirmed the VM validates current `main`.
- Did NOT alarm the owner about "editor-save data-loss" — checked `dist/` freshness first and found the
  stale bundle. Homework before escalation.
- Did NOT override the parked TSK-810 (option C) — a pending human decision; respect the gate.

## Gotchas / lessons (also in LESSONS.md + CLAUDE.md VM workflow)
- **STALE-`dist/` TRAP:** VM render/UAT validation MUST use `test-in-vm.sh all` (rebuilds `dist/`), NOT
  `test` (spawns whatever `dist/` was last built on the VM — can be a month stale → false UAT failures).
  Verify: `ssh macOS15 'stat -f "%Sm" markdown_viewer/dist/TextView.app/Contents/MacOS/MarkdownViewer'`
  vs `git log -1`.
- VM JUnit `<failure>` only says "see swift test output" — capture FULL VM stdout, never `… | tail -N`.
- 0-headless → N-GUI failure jump = suspect env/stale before concluding N regressions; isolate one class.

## Files that matter
- `scripts/test-in-vm.sh` — `test` (headless) vs `all` (build_all rebuilds dist/ + full suite); GUI lane
  via `MDV_VM_GUI_SESSION=1 MDV_VM_SUDO_PASS=<vm-sudo-password>`, WebView via `MDV_RUN_WEBVIEW_TESTS=1`.
- `scripts/check-no-secrets.sh` — new this session (pre-public-release committed-secret scan, TSK-859).
- VM mirror: `macOS15:~/markdown_viewer` (rsync target; excludes `.build/`/`dist/`/`.swiftpm/`).

## Open questions / blockers
- **🔴 TSK-810** (Stage-B hex carve-out) — owner-decision, still `waiting:human`. Agent rec **A** (keep
  the Swift fallback for the two un-deletable hex paths, retire only the gate/toggle). + green-light the
  **#5-9** Swift-twin deletion packages (csv/fuzzy/find/transcript/markdown). This is the only thing the
  VM drain can't unblock — the "deprecate Swift core" endgame.

## Tracker (`tasked`, agent claude-mdv)
- ~70 items at `review` (the drain target — pending stage-2b classification; do NOT mass-validate until the
  fresh-`dist/` render result is in).
- TSK-901, TSK-952 → `validated` (host-testable, self-validated earlier).
- TSK-810 → `waiting:human` (owner decision). TSK-564 → reconciled comment (perf zombie, body-copy already shipped).

## How to resume
1. Read this, then check stage-2b: `cat <task bzglu8tx3 output>` or
   `ssh macOS15 'tail -40 /tmp/mdv-stage2b.log; echo; stat -f "%Sm" markdown_viewer/dist/TextView.app/Contents/MacOS/MarkdownViewer'`.
2. Parse failures from the VM JUnit (`/tmp/mdv-test-results.xml`) + the full stdout log.
3. Execute the Next-action decision tree above (drain on green / file regressions on red).
4. `git -C <repo> log --oneline -5`; tree clean except the 2 untracked non-ours files
   (`archive/Untitled.txt`, `untitled2.md`).
</content>
