<!-- CLAUDE-HANDOFF v1 -->
# Handoff — prod-build packaging fix shipped; eval/AX prioritized; cron armed  (2026-06-26)

**Session:** claude-mdv  ·  **cwd:** `/Users/me/Documents/workspaces/claude/markdown_viewer`  ·  **branch:** `main` @ `0f11e59b` (verify `git log -1`).

## Mission
Fix the prod-build clean-machine crash + ship a working dist, then set the autonomous drain back up with the owner's 2026-06-26 priority order (eval/AX → validate-pending → wave-12).

## Current state (all on main, headless-gate GREEN)
- **TSK-1257 (`d810d4c6`, review) — THE packaging fix.** The hand-assembled `.app` crashed at launch on any clean machine: the minimal SwiftPM `Bundle.module` accessor resolves resource bundles from the `.app` ROOT then a hardcoded dev `.build` path — never `Contents/Resources`. Fix = `Bundle.resolveResourceBundle` (ViewerCore) preferring the app's own `Contents/Resources`; per-target `Bundle.viewerCoreResources`/`viewerUIResources` replace the `Bundle.module` call sites; minimal `Info.plist` stamped into each shipped bundle; host-safe `--verify-resources` self-check wired into `build-app.sh` + `verify-app.sh` (fails if any resource resolves from `/.build/`); `verify-app.sh` strict-codesign now runs on a de-xattr'd copy. **Fixed dist uploaded** to `github.com/josangel555/mvd_dist` → `TextView-2026-06-26-packagingfix.zip` (commit `17e1d71`) AND **installed to `/Applications/TextView.app`** (verified self-contained). Owner close = M5-Pro retest (clear quarantine → launch).
- **TSK-1258 (`206bbbfc`, review) — restored headless gate to green.** `ScriptVerbCatalog` drift test now treats `ScriptRunner.swift` as the 2nd dispatch surface (runner-only `wait-editor-line`/`wait-rendered-scroll` were false-flagging since TSK-1047). main was secretly red before this.
- **TSK-1259 (`0f11e59b`, review) — steady (non-blinking) caret in vim mode.** `drawSelection({cursorBlinkRate:0})` — one facet drives BOTH the NORMAL block cursor and INSERT line caret (vim `setBlinkRate` reads the same facet; combine=Math.min). In-process WebView guard added (VM/#192 lane). Reinstalled. Owner: relaunch to confirm on-screen.
- **Docs:** CHANGELOG 2026-06-26 (caret + launches-on-other-Macs + system work); BACKLOG has the new **🎯 OWNER PRIORITY ORDER (2026-06-26)** block at the top; LESSONS has the Bundle.module-clean-machine entry.
- **Cron ARMED:** session-only `beafb39c`, every 5 min, drains BACKLOG top-down (7-day auto-expire; dies when this session exits).

## Owner priority order (encoded at the top of BACKLOG.md)
- **P0a — eval/AX self-driving + agent-drivable interfaces:** TSK-1254 (out-of-process AX driver) → TSK-1255 (pyramid restructure + canonical doc) → agent-drivable `mdv.*` + script-bus action surface → TSK-1256 (element refs). Human-like self-drive stays a SEPARATE purely-screenshot harness.
- **P0b — battle-test the ~215 fixed/review pile to validated WITH TEETH** (task_validate + checks for pure-logic; render/WebView/AX-pixel caps at review). Reclaim stale-progress TSK-1253/INT-126.
- **P1 — the NEXT WAVE 12** (app lane / perf / agent / leverage / dark-mode / LSP-autocomplete / tmux-finish). Verify-state + spike each first.

## Gotchas / lessons (full text in LESSONS.md)
- **Bundle.module clean-machine trap** (the headline): never hand-assemble resources to a place the minimal accessor doesn't read; keep them in `Contents/Resources` + the resolver. `--verify-resources` is the gate.
- **Verify-before-build:** "open" board/backlog tags are mostly already DONE — grep main + `task_get` first. The BOARD is the source of truth, not BACKLOG tags.
- **iCloud FinderInfo** trips `codesign --strict` on `dist/` in place → verify a `ditto --noextattr` /tmp copy.
- **WebView/AX tests are VM-lane** (`MDV_RUN_WEBVIEW_TESTS=1`), not the host gate; AX is out-of-process only.

## How to resume
1. Read this + BACKLOG.md (the 🎯 priority block) + the cron tick prompt in `docs/TASK_WORKFLOW.md §7`. `git log -1` (expect `0f11e59b`).
2. The cron `beafb39c` is draining every 5 min. If it's gone (session ended), re-arm from `TASK_WORKFLOW.md §7` (CronCreate `*/5 * * * *`, session-only) with the current session's commit trailer.
3. Host gate: `bash scripts/test-headless-gate.sh`. Prod build: `bash scripts/build-app.sh release --install` (now runs the `--verify-resources` packaging gate). VM creds: host `macOS15`, user `vm-tester`, sudo `<vm-sudo-password>`. NEVER `killall MarkdownViewer`; UI/live tiers VM-only.
