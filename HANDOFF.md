<!-- CLAUDE-HANDOFF v1 -->
# Handoff — VM validation lane brought up (owner re-enabled it); 3 dist-build defects fixed  (2026-06-22)

**Session:** claude-mdv (AUTONOMOUS, ~5min cron).  ·  **cwd:** `/Users/me/Documents/workspaces/claude/markdown_viewer`  ·  **branch:** `main` @ `57eb9816` (verify `git log -1`).

## Mission
Autonomous cron drain. The owner re-enabled the UTM VM ("we don't have to stick with host-doable tasks; VM is up — UI evals/tests/dev/validation there"). PRIMARY this arc: stand up the VM render-validation lane and use it to drain the render-path review backlog. Keep `main` headless-gate-green; commit per item, inline (NO workflows).

## Current state — VM lane is UP and the render tiers are GREEN; a final verify re-run is in flight
Standing up the VM lane surfaced 3 `dist/`-build defects the host gate never sees (it never builds `dist/`). All fixed + committed this arc:
- **TSK-1234 (validated)** — `sharedCIContext` (TSK-1049, `Renderer.swift:103`) is a static non-`Sendable` `CIContext` the host accepts but the VM's Swift 6.3 rejects (`#MutableGlobalVariable`). Broke EVERY VM `dist/` build since Mon → **the nightly VM lane had been red for days**. Fixed `nonisolated(unsafe)` (`c309c852`). Host gate green + VM compiles past it.
- **TSK-1235 (validated)** — `build-app.sh` globbed `$BIN_DIR/libTreeSitter*Lazy.dylib` → shipped 8 STALE orphan dylibs from a former Package.swift (both host AND VM `.build` carry them) → 11 shipped vs 3 declared → tripped `verify-app.sh` SIGN-13 (would also break the owner's `--install`). Fixed: allowlist from Package.swift (`308cb23c`). Host-verified: copied 3, SIGN-13 PASS.
- **TSK-1236 (fixed, VM-verify pending)** — the WebView lane ran `swift test --parallel` over 16 live-WKWebView suites → fd-exhaustion EMFILE false-failures (TSK-500 class). Fixed: run SERIAL (dropped `--parallel`) in `test-in-vm.sh` + `nightly-vm.yml`, + ulimit 8192→16384 (`57eb9816`).
- VM result before the WebView fix: **main lane (headless + T4 GitPanel UAT + T5 ImageEditor pixel) = 0 real failures**; only the WebView lane fd-exhausted. So the render-validation lane WORKS for T4/T5.

**In flight:** full VM re-run `bxuqofm3a` (background, `MDV_VM_GUI_SESSION=1 MDV_VM_SUDO_PASS=<vm-sudo-password> MDV_RUN_WEBVIEW_TESTS=1 bash scripts/test-in-vm.sh all`) verifying all 3 fixes end-to-end + the WebView lane going green. Output: `/private/tmp/claude-501/.../tasks/bxuqofm3a.output`. ~23 min; notifies on completion.

## Next action
1. **Read the `bxuqofm3a` verdict** (grep `with [0-9]+ failures` excluding `0 failures`; tail for `all done`). If the WebView lane is now green → validate TSK-1236 (VM evidence). If still failing → diagnose (serial should bound fds; check the ulimit actually applied in the WebView invocation's process).
2. **Drain the render-review backlog via the now-working T4/T5 lanes.** BUT note the framework limit (learned this arc): the `*UATTests` `--script` dispatcher asserts MODEL FLAGS and **cannot open Settings, read menu enable/checkmark, or drive NSAlerts** ("live-menu only"). So font-picker (259, in Settings), menu-item, and alert-driven review items are NOT agent-VM-validatable — they stay owner-gated. The drainable subset = script-reachable + model-flag-backed items (preview, table-find, view-mode flows) + whatever existing T5/UAT tiers already cover. Author a real assertion per drainable item, run on the VM, validate; leave the rest at review honestly.
3. Owner-gated leverage still parked: **TSK-1215** (formula flip) + **TSK-1202** (fold flip) — `waiting:human`; the VM now makes their render-confirm doable, but flipping the default is still the owner's call. TSK-775 (migration horizon), TSK-1214 (bundle budget), TSK-1138 (Tier-D ratification).

## Key gotchas / lessons (also LESSONS.md — new section dated 2026-06-22 "Bringing up the VM validation lane…")
- **A red VM build = ZERO render coverage, not "render is fine."** The VM 6.3 is the forward-compat catcher; when it's red, fix the build FIRST.
- **A build script that globs a build dir ships whatever a stale `.build` left behind.** Derive from the manifest, not a glob.
- **Many DIVERSE suites failing + EMFILE/Code=24 = systemic fd exhaustion, not N regressions.** WKWebView suites must run serial.
- **VM render/UAT needs `test-in-vm.sh all`** (rebuilds `dist/`; `test` spawns a stale bundle). GUI lane needs `MDV_VM_GUI_SESSION=1 MDV_VM_SUDO_PASS=<vm-sudo-password>`; WebView suites need `MDV_RUN_WEBVIEW_TESTS=1`.
- Commit messages: NO backticks (zsh). Gate verdict in a SEPARATE step from the commit. Append the `Claude-Session:` trailer.

## Files that matter
- `Sources/ViewerCore/ImageEditing/Renderer.swift:103` — `nonisolated(unsafe)` sharedCIContext (TSK-1234).
- `scripts/build-app.sh:137` — lazy-grammar dylib allowlist copy (TSK-1235).
- `scripts/test-in-vm.sh:53,231` — ulimit 16384 + serial WebView lane (TSK-1236).
- `.github/workflows/nightly-vm.yml:64` — serial WebView lane + ulimit (TSK-1236).
- `Tests/ViewerUITests/uat/*UATTests.swift` — the `--script` model-flag UAT framework (read SettingsMenusAndShortcutsUATTests for the limits).

## Tracker (tasked, agent claude-mdv)
- TSK-1234 validated · TSK-1235 validated · TSK-1236 fixed (VM-verify pending) · TSK-1233 (coverage.sh defect, reported, diagnosed).

## How to resume
1. `git -C <cwd> log -1` (expect `57eb9816` or later). Gates: `bash scripts/test-headless-gate.sh` + `bash scripts/rust-core-gate.sh` (read each verdict separately).
2. Read the `bxuqofm3a` VM-run verdict (path above). Act per "Next action".
3. Drain the render-review backlog via the VM T4/T5 lanes (rsync → `MDV_VM_GUI_SESSION=1 MDV_VM_SUDO_PASS=<vm-sudo-password> MDV_RUN_WEBVIEW_TESTS=1 bash scripts/test-in-vm.sh all`), respecting the UAT framework limits (Settings/menu/alert items stay owner-gated).

Commit trailer:
