<!-- CLAUDE-HANDOFF v1 -->
# Handoff — host feature pool scraped; VM-down blocks the top lever  (2026-06-15)

**Session:** claude-mdv (autonomous loop)  ·  **cwd:** `/Users/me/Documents/workspaces/claude/markdown_viewer`  ·  **branch/SHA:** `main` @ `25cf469`

## Mission
Autonomous loop: drain `WORK_QUEUE.md` top-down, ship host-validated work (host-test the model, leave render at `review`), keep `main` headless-gate-green, commit per item, log. Fallback when the queue's host items drain: groomed pools (security/rust-core/parity/theming) → fixed-lane validation drain.

## Current state (READ THIS FIRST)
- **`WORK_QUEUE.md` host-buildable pool is DRAINED.** Every remaining unchecked item is one of: VM-render / first-responder (910, 905, 906, 893-896, 917, 921/922, 898, 924, 936-938, 947, 766, 704, 708, 463, 470, 495, 506, 668, 912), a perf **trace** (P0: 892, 887, 888, 889, 890/891/895, 908, 839, 838), an **epic** (670, 711, 679, 280, 318, 319, 677, 940-945), or **owner-input** (733, 791, 751, 709). Verified this tick by re-scan.
- **🔴 THE UTM VM IS DOWN (2 ticks running — `ssh macOS15` times out at <vm-ip>:22).** This is the dominant blocker: it gates BOTH the ~49-item `review` → `done` **validation drain** (the highest-leverage work) AND render-validation of any new VM-tail feature. **Shipping more VM-tail features while the VM is down just GROWS the unvalidatable review pile** — the bottleneck is VM validation, not feature-building.
- **rust-core epic (TSK-538) is drained** — almost all children `validated`; the open ones are excluded (perf-internal lane 543/564/574), dep-gated (584/585/587), front-end/last-resort (573), or large infra (586 golden-corpus, 588 perf-bench — host-validatable but P3/internal-quality, which the owner de-prioritizes).
- **Tree clean** except pre-existing untracked `archive/Untitled.txt` + `untitled2.md` (NOT ours).
- **Headless gate green** (~5800 tests). NOTE: the gate flakes on `CrossFileSearchBench` wall-clock under load — re-run before trusting a red; confirm the failure isn't bench-only.

## Recent ticks (all shipped → `review`, VM render-tail; host models tested + gated)
946/949 find-menu (⌘G/⌥⌘G router + ⌥⌘F gate) · 915/916/934 file-nav Refresh/Reload-from-Disk + breadcrumb context-menu · 926/927 CLI (LaunchArgs) + 950 LSP Find-References menu/palette · 951 palette-parity slice (view toggles + edit transforms) · **901 content-detect (JSON/CSV for misnamed files) — self-VALIDATED (host-tested, no VM tail)** · 769 Terminal Favorites slice.

## Next action (decision tree)
1. **Is the VM back?** `ssh -o ConnectTimeout=10 macOS15 'echo ok'`. If YES → **run the validation drain** (the top lever): `MDV_VM_GUI_SESSION=1 MDV_VM_SUDO_PASS=<vm-sudo-password> bash scripts/test-in-vm.sh` (+ `MDV_RUN_WEBVIEW_TESTS=1` for the #192 suites). Validate the ~49 `review` items' render-tails → drive to `validated`/`done`. This is worth far more than any new host slice.
2. **VM still down?** Re-scan WORK_QUEUE for any GENUINELY host-shippable item (don't assume empty — re-scan has surfaced work before). If only marginal-on-the-host slices remain, **don't manufacture them** (they grow the unvalidatable pile) — prefer a documented HOLD that keeps the blocker visible. Owner directive "don't HOLD, build VM-tail features" is satisfied here BECAUSE the buildable-with-real-host-value pool is empty + the bottleneck is external.
3. **Genuinely want host-validatable NON-VM work?** The rust-core infra items (586 golden corpus, 588 perf-floor bench) are host-validatable (rust-core gate, no VM) and serve the owner's Rust-core direction — but they're large/internal; slice carefully (spike auto-approved per §0.5).

## Open questions / blockers (DECISIONS NEEDED — also in docs/AUTONOMOUS_PROGRESS.md)
1. **🔴 Restore the UTM VM** — it's been unreachable 2 ticks; this unblocks the ~49-item `review` → `done` validation drain (the single highest-leverage action) + all render validation.
2. **TSK-698** — JS-over-JSON safe-exec model (SPI timeout / off-main+thread-leak / subprocess) — PARKED, owner pick.
3. **TSK-343** — local-history default ON vs opt-in + retention (the `LocalHistoryStore` is built; this gates the snapshot-on-save trigger + the revert feature) — PARKED.
4. **TSK-733** — session-switch save: silently preserve dirty buffers vs keep the prompt — PARKED (needs repro confirmation).
5. **TSK-751 / TSK-709** — menu reorg ("which menus feel wrong?") / ⌘K↔⌘G unify (intended behavior?) — PARKED, need owner framing.

## How to resume
1. Read this, then `docs/AUTONOMOUS_PROGRESS.md` (top logs), then `WORK_QUEUE.md`.
2. `git -C <repo> log --oneline -15`; confirm tree clean (only the 2 untracked non-ours files).
3. Re-read `docs/TASK_WORKFLOW.md`. Run the **Next action** decision tree above. Gate via `bash scripts/test-headless-gate.sh`; commit per item; log to `AUTONOMOUS_PROGRESS.md` + (user-facing) `CHANGELOG.md`.
</content>
