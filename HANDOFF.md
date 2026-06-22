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
- Validated this session: 1234, 1235, 1236, 1233, 1133, 1241, 1036, 1242, **1131** (coverage capability — G1 closed). · Built/fixed: **1244** (coverage.yml — scheduled non-gating coverage workflow). · **#NNN-trap cluster 1237 DONE — 5/5 corrected** (283/326/373/375/376; TSK-373 New-session-kind-chooser genuinely UNBUILT was falsely-fixed; TSK-375 plugin contributions further-along than its stale report). · Open findings/next: **1243** (ui-key-synthesis infra — THE interaction-render unblock), 1238 (coverage-gate sibling), 1239 (VM full-suite fd leak), 1240 (PaneRetention LRU), **847** (owner-resolved option A but needs a BenchTestCase-tier + careful full-bench-audit — completeness-risky, see the ticket), 1242 (ods/xlsx UATs redundant — recipe on the ticket). · Owner-gated: 1046, 1215, 1202, 775, 1214, 1138.
- **Render-backlog drain — IMPORTANT finding (2026-06-22):** the CLEAN (open-a-file → assert dump) render drains are DONE (routed-docs validated). The REMAINING review items (TSK-272 arrow-preview, 303 table-find, 1102 CSV cell-cursor) are **INTERACTION-gated** (arrow keys / find-bar / cell nav), and live-app event synthesis is UNRELIABLE (TSK-1020 CGEvent→WKWebView no-insert; TSK-1200 scroll-verb no-op) — and for these items the synthesis residual IS the thing under test (e.g. TSK-272's open question is literally "does the arrow reach previewSelectedFile"). So they are NOT cleanly autonomously-drainable; they sit at the CORRECT review ceiling per the cron ("leave render at review"). **The next real leverage is event-synthesis INFRA** — make CGEvent keys/clicks reliably reach the live app (TSK-1020/1200 class) — a deep fresh-context effort that would unblock the whole interaction-render UAT class. Until then, interaction-render items stay at review (agent ceiling) for the owner/VM-manual close.
- **#NNN-trap cluster (TSK-1237): 4/5 corrected** — 283/326/373/376 recorded back to progress with corrections (their `understanding` fields were stale notes from unrelated findings; e.g. TSK-373's New-session-kind-chooser is genuinely UNBUILT, was falsely `fixed`). TSK-375 (plugin custom-action contribution) still needs a FRESH state-verify (its audit report is vs an old main) before correcting.

## How to resume
1. `git -C <cwd> log -1` (expect `faa9999c`+). Gates: `bash scripts/test-headless-gate.sh` + `bash scripts/rust-core-gate.sh` (verdicts in separate steps).
2. **The CLEAN autonomous done-drain in this session's reach is EXHAUSTED** — confirmed by 3 consecutive "clean" picks (1242 ZIP fixtures / 272 ui-key / 847 bench-completeness) all turning completeness/scoping-heavy, + 2× `task_next` → review-ceiling epic (TSK-590). The remainder is careful/deep fresh-context work (this is why a compaction reset helps).
3. **Highest-leverage next: TSK-1243** (real-keystroke ui-key synthesis infra — unblocks the whole interaction-render UAT class 272/303/1102; the `currentURL` dump field already suffices for the assert, so the blocker is purely keystroke delivery). Then **847** (BenchTestCase-tier + careful bench audit → --num-workers 18), **543/1124** (cm_apply-delta FFI), **1110** (DocumentModel SRP split), or a new host-buildable feature. State-check vs the board first (curated is stale).

Commit trailer:
