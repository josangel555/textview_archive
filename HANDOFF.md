<!-- CLAUDE-HANDOFF v1 -->
# Handoff — tmux -CC signal-translation done+integrated; next-wave-12 proposed  (2026-06-26)

**Session:** claude-mdv  ·  **cwd:** `/Users/me/Documents/workspaces/claude/markdown_viewer`  ·  **branch:** `main` @ `c26951ab` (verify `git log -1`). ⚠️ Extremely long session — `/compact` recommended.

## Mission
Drain toward done + build genuinely high-value work (owner: "no more low-hanging mandate"). This session: validated the scroll fix, cleaned + vended the repo, reconciled the board (it's far more complete than the lists), assessed the AX/UAT test pyramid, **completed + integrated the tmux `-CC` host signal-translation**, and proposed the **next wave of 12** features.

## Current state
- **Done + on main:** editor scroll-restore validated in-process (TSK-1046, `review`); CM6 2px caret + literal-Tab + `check-bundle-size.sh` doc-drift (TSK-1250/1098, `review`); View↔Edit size-match **host half** (TSK-1151, `review`); VST-non-goal doc (TSK-1097, `review`); vim mode-chip per-mode colors (TSK-1251, `review`). Repo cleaned (7.6G→92M). Prod `dist` built + **vended** to `github.com/josangel555/mvd_dist` (v1 + v2 zips). Stale-progress reclaim: TSK-280/302→`fixed`; INT-126 (`internal`) + TSK-1253 filed.
- **tmux `-CC` — host signal-translation COMPLETE + integrated (188 tmux tests green):** slices a/b/c were already done; this session added the **pump** (`TmuxController`, slice-d host half, `46e3ffb1`), the **typed outbound serializer** (`TmuxCommand`, `26c4f53a`, via the `tmux-cc-harden` ultracode run, 48 tests), and **inbound hardening** (`c26951ab`, 32 tests). Worktrees reaped.
- **In flight / next:** the next-wave-12 (in BACKLOG, awaiting owner groom/spike); the tmux **live wiring** remains (TSK-1023, VM-tail).
- **Next action (pick one):** (a) the small **`TmuxController` typed `encode(_ cmd: TmuxCommand)` overload** — closes the signal-translation loop now the serializer exists (host, quick); (b) **spike + groom the next-wave-12** as a board "Wave — high-value" epic; (c) the tmux **live wiring** (slice d spawn + slice e render — VM-tail).

## Key decisions & rationale
- **tmux:** host signal-translation done; live PTY spawn + SwiftUI split render = VM-tail (TSK-1023). Don't redo a/b/c.
- **Self-driving / UAT = two lanes** (owner 2026-06-26): AX-structural (out-of-process, `mdv.*` ids) + script-bus + CGEvent = the TEST lane (TSK-1254); human-like stays **purely screenshot-based**, no AX.
- **Next wave = 12** (owner): app-lane (web browser, image editor, RSS) + 2 perf + 2 agent + 2 leverage + dark-mode + LSP-autocomplete + tmux-finish. Dropped element-ref/share-context per owner.
- **Stale-progress reclaim** = a tool-side sweep (INT-126), NOT hand-mutating 80 #NNN-corrupted tickets.

## Gotchas / lessons (full text in LESSONS.md — 6 new entries this session)
- **Verify-before-build:** "open" board/backlog items are mostly already DONE — grep main + `task_get` before working anything.
- **The BOARD, not BACKLOG.md tags,** is the source of truth (`task_next`/`fleet`). Bottleneck = ~414 fixed/review awaiting owner close.
- **AX automation is out-of-process only** (`TerminalAccessibilityTests:78`).
- **Dist vend:** iCloud FinderInfo xattr trips strict-verify → `ditto --noextattr` + `xattr -cr` outside the synced tree; self-signed → clear quarantine; arm64-only.
- **Swift Testing** prints `✔ Test run with N tests passed` (not the XCTest line) — grep both.
- **`task_advance`** needs all params (understanding+note+summary+commits) in one call to reach `review`.

## Files that matter
- `Sources/ViewerUI/Terminal/TmuxController.swift` — the pump (slice-d host half). NEXT: add typed `encode(_ cmd:)`; add live `start/stop` (PTYProcess spawn `tmux -CC` + `onOutput→ingest` + `drainCommands→stdin`) — VM-tail.
- `Sources/ViewerCore/Terminal/TmuxCommand.swift` — the outbound serializer (use for input/resize in the live wiring).
- `docs/TMUX_CC_DESIGN_2026-06-18.md` §3 + §5 — the live-wiring plan (slices d/e).
- `Tests/ViewerUITests/EditorScrollRestoreWebViewTests.swift` — the in-process live-CM6 test pattern (template for editor render tests).
- `BACKLOG.md` — the **NEXT WAVE (12)** section + the **HIGH PRIORITY** section (TSK-1253/1254/1255).

## Open questions / blockers
- **dist v2 M5-Pro crash retest** — pending owner. v1 crashed on an M5 Pro with a `Bundle.module` trap that did NOT reproduce locally (build's 11 grammar bundles are intentional per TSK-854; not a missing-grammar issue). v2 uploaded for retest. If it recrashes, NEED the `Fatal error:` line (names the bundle) + the `OS Version:` from the `.ips` crash report.
- **Next-wave-12** — owner to confirm groom/spike, or pick the first feature.

## Tracker (tasked, agent claude-mdv)
- `review`: TSK-1046, TSK-1097, TSK-1151, TSK-1250, TSK-1251.
- `fixed`: TSK-280, TSK-302 (stale-progress reclaim).
- `reported` (filed this session): TSK-1248 (Cmd+F sidebar), TSK-1249 (terminal header), TSK-1252 (vim Esc beep), TSK-1253 (stale-ticket reclaim), TSK-1254 (AX UAT driver), TSK-1255 (pyramid health), TSK-1256 (element-ref); INT-126 (`internal`: stale-lease sweep).
- TSK-1023 (tmux live wiring, VM-tail) — commented with the full host-landing detail (pump+serializer+hardening commits).

## How to resume
1. Read this + `LESSONS.md` (top 6 entries) + `BACKLOG.md` (NEXT WAVE + HIGH PRIORITY). `git log -1` (expect `c26951ab`), `git status` (clean; untracked `OwnerWishlist.md*`/`Untitled.txt` are the owner's — leave them).
2. Quick win if continuing tmux: add `TmuxController.encode(_ cmd: TmuxCommand) -> Data` (wraps `core.encodeCommand(cmd.commandLine)`) + a host test; `swift test --filter ViewerUITests.TmuxControllerTests`.
3. Host gate: `bash scripts/test-headless-gate.sh`. tmux suites: `swift test --filter Tmux` (XCTest) + `swift test --filter TmuxCommandTests` (Swift Testing).
4. For ANY board pick: verify against main + `task_get` first (the "open" tags lie). VM creds: host `macOS15`, user `vm-tester`, sudo `<vm-sudo-password>`. NEVER `killall MarkdownViewer`; UI/live tiers VM-only.
