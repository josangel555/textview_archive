<!-- CLAUDE-HANDOFF v1 -->
# Handoff — VM-lane repair DONE+validated; render-backlog VM-UAT work-stream started  (2026-06-22)

**Session:** claude-mdv (AUTONOMOUS, ~5min cron).  ·  **cwd:** `/Users/me/Documents/workspaces/claude/markdown_viewer`  ·  **branch:** `main` @ `52c57736` (verify `git log -1`).

## Mission
Autonomous cron drain. Owner re-enabled the UTM VM ("VM is up — UI evals/tests/dev/validation there"). This session: (1) stood up + repaired the VM validation lane; (2) started draining the render-path backlog via targeted VM UATs. Keep `main` headless-gate-green; commit per item, inline (NO workflows).

## Current state
**VM-lane CI-infrastructure repair — COMPLETE + validated** (4 latent breakages the host gate structurally can't see, all surfaced by bringing the VM up):
- **TSK-1234 (validated)** — `sharedCIContext` static non-`Sendable` `CIContext`; host accepts, VM Swift-6.3 rejects → broke EVERY VM build since Mon (nightly red for days). `nonisolated(unsafe)` (`c309c852`).
- **TSK-1235 (validated)** — `build-app.sh` globbed lazy-grammar dylibs → shipped 8 stale orphans (host + VM `.build`) → tripped verify-app.sh SIGN-13 (would break owner's `--install`). Allowlist from Package.swift (`308cb23c`).
- **TSK-1236 (validated)** — WebView lane fd-exhaustion: ran `--parallel` (multiplies WKWebView fds) AND `MDV_RUN_WEBVIEW_TESTS` leaked into the main sweep. Fix: serial dedicated lane + strip the env from the main sweep (`57eb9816`+`1e32d666`). VM-confirmed: dedicated lane 16/16 ran, 0 EMFILE.
- **TSK-1233 (validated)** — coverage.sh produced no report (SwiftPM skips auto-merge on the benign coverage+parallel non-zero exit). Manual `llvm-profdata merge -f listfile --failure-mode=warn` fallback (`1226742f`+`5cb7ff68`); verified on the real 8943 profraw → 69.56% report. (`-f`=ARG_MAX, `--failure-mode=warn`=corrupt partials — both self-caught by verifying.)
- **TSK-1133 (validated)** — pr.yml WebView-lane doc truth (guard test green).

**Render-backlog VM-UAT work-stream — STARTED:**
- **TSK-1241 (validated)** — added `DocumentModel.selectedLoadedTextPrefix` + `loadedTextPrefix` dump field (`cbfd0a5b`). The reusable enabler: lets a UAT assert source-view CONTENT (the dump's `editorText` is "" for read-only tabs). 3 host tests.
- **TSK-1036 (fixed; UAT VM-verify IN FLIGHT)** — routes .rtf/.docx/.ods/.xlsx into the viewer as extracted text, read-only (host core done, 9 tests). NEW `MultiFormatViewerUATTests` (`52c57736`) asserts a routed .rtf shows extracted text (not raw `\rtf1`) via `loadedTextPrefix`. **In flight:** VM run `bjyssd9eh` = `test-in-vm.sh build && test --filter ViewerUITests.MultiFormatViewerUATTests` (GUI lane). Output `/private/tmp/claude-501/.../tasks/bjyssd9eh.output`.

**Findings filed (open):** TSK-1237 (#NNN-trap cluster 326/373/375/376 — understandings mismatch titles), 1238 (coverage-gate.sh sibling defect), 1239 (general heavy-tier fd leak — full single-process VM suite exceeds ulimit 16384; use TARGETED runs), 1240 (PaneRetentionMountProbeTests LRU failure, real, unmasked by the WebView serial fix).

## Next action
1. **Read `bjyssd9eh`** (grep `MultiFormatViewerUATTests` for passed/failed; tail for `test done`). If the RTF UAT passed → **validate TSK-1036** (VM evidence) + extend the UAT to docx/ods/xlsx (reuse the ZIP fixtures from `RtfViewerRoutingTests`). If it failed → diagnose from the dump (did the open land? is `loadedTextPrefix` populated? — `currentURL`/`loadedTextPrefix` in the dump).
2. **Continue the render-backlog via TARGETED VM UATs** (the pattern is now proven: `loadedTextPrefix` for content, `assertModel` for flags). Each: author a `*UATTests` assertion → `build && test --filter <Suite>` in the GUI lane → validate.
3. **Owner-gated (skip in the loop):** TSK-1046 (scroll-restore, `waiting:human` — needs owner's eyes on editor-scroll), TSK-1215/1202 (engine flips — owner's call), 775/1214/1138.

## Key gotchas / lessons (also LESSONS.md "Bringing up the VM validation lane…")
- **Use TARGETED VM runs** (`test-in-vm.sh build` then `test --filter <Suite>`, both with `MDV_VM_GUI_SESSION=1 MDV_VM_SUDO_PASS=<vm-sudo-password>`) — `all` runs the full single-process suite which hits the general fd leak (TSK-1239, intermittent EMFILE) + is slow. `build` rebuilds `dist/`; `test` does NOT (don't run `test` alone against a stale dist).
- **The render-backlog is at the agent ceiling** (host model done, render at review — the cron's bar). Push past review only via: (a) script-reachable + a dump field (model flag OR `loadedTextPrefix`), OR (b) owner on-screen. The `--script` UAT CANNOT reach Settings/menus/NSAlerts ("live-menu only") — those stay owner-gated.
- **The dump's `editorText` is "" for un-edited read-only tabs** (buffer not materialized) — use `loadedTextPrefix` (TSK-1241) for source-view content assertions.
- **VERIFY on real data** — both coverage.sh bugs (ARG_MAX, corrupt-partial) were caught only by running on the real 8943 profraw, not by reasoning.
- Commit messages: NO backticks (zsh). Gate verdict SEPARATE from the commit. Append the `Claude-Session:` trailer. Curated `[reported]` is STALE — state-check vs the board (task_get) before working.

## Files that matter
- `Sources/ViewerUI/DocumentModel.swift:1836` — `selectedLoadedTextPrefix` (TSK-1241).
- `Sources/ViewerUI/Automation/ScriptVerbDispatch.swift` — `loadedTextPrefix` dump field.
- `Tests/ViewerUITests/uat/MultiFormatViewerUATTests.swift` — the routed-doc UAT (extend to docx/ods/xlsx).
- `Tests/ViewerUITests/RtfViewerRoutingTests.swift` — host routing tests + the docx/ods/xlsx fixture construction to reuse.
- `scripts/test-in-vm.sh` — modes: `build` (rebuild dist), `test --filter X` (targeted), `all` (full — avoid, fd leak).

## Tracker (tasked, agent claude-mdv)
- Validated this session: 1234, 1235, 1236, 1233, 1133, 1241, **1036** (routed-doc viewing), **1242** (rtf+docx on-screen UATs — both extraction paths VM-confirmed). · Open findings: 1237, 1238, 1239, 1240. · Owner-gated: 1046, 1215, 1202, 775, 1214, 1138.
- **Next render-backlog item:** apply the proven methodology (enabler dump field if needed → targeted VM UAT via `build` + `test --filter`, GUI lane) to the next script-reachable review item. Candidates: TSK-272 (arrow-preview — sidebar arrows → preview-slot model flag, via KeySynth), TSK-303 (table-find), TSK-1102 (CSV cell cursor). State-check each vs the board first (curated is stale).

## How to resume
1. `git -C <cwd> log -1` (expect `52c57736`+). Gates: `bash scripts/test-headless-gate.sh` + `bash scripts/rust-core-gate.sh` (verdicts in separate steps).
2. Read `bjyssd9eh` output → act per "Next action" (validate TSK-1036 if green; extend the UAT to the other formats).
3. Continue render-backlog targeted VM UATs; skip owner-gated items.

Commit trailer:
