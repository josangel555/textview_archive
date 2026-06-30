<!-- CLAUDE-HANDOFF v1 -->
# Handoff — render epics draining via the console template: 698+1161 VALIDATED, 1160 committed, 1155 parked (2026-06-29)

**Session:** claude-mdv · **cwd:** `/Users/me/Documents/workspaces/claude/markdown_viewer` · **branch:** `main` @ `95ed8702` (verify `git log -1`)

## Mission
Autonomous drain loop (cron). Work INLINE, one item/firing: read-first → implement → host-test → host-gate (`bash scripts/test-headless-gate.sh`) → commit per item; land rebase+ff; keep main gate-green; fold docs into the item's commit. Cron canonical = `docs/TASK_WORKFLOW.md §7`.

## ⚠️ CORRECTION THAT RESET THIS HANDOFF (owner, 2026-06-29) — READ FIRST
A prior version of this handoff declared a "host-testable-seam vein DRAINED" and routed all render/UI work to a "VM/owner venue." **That framing was WRONG and is now banned.** The owner's standing model: **the VM is UP and the ENTIRE UI/render lane is agent-workable — build AND VM-validate it. The ONLY off-limits tier is AX-driven tests.** There is NO "host-testable vs render" split in what to work; render/UI/VM items are first-class drain targets you BUILD and VALIDATE (on the VM), not hand to the owner. The instructions that caused the misread were hardened this session (CLAUDE.md new 2026-06-29 directive + §4 self-validation; TASK_WORKFLOW §4 + §7 cron; the live cron prompt). The render-confirm directive is satisfied BY VM-validating, not by leaving things at review.

## What shipped this session (render-drain via the validated console template)
Render is FIRST-CLASS agent work — built + VM-validated, not handed to the owner. The console
template — **view-model (host) → SwiftUI panel → DocumentModel wiring → menu trigger →
in-process NSHostingView VM-hosting-test → validated** — is now a repeatable rhythm. Epics:
- **★ TSK-698 Script Console — VALIDATED.** View ▸ Script Console: JS query/transform over JSON/log/CSV, off-main, Apply→new-tab. (`17845599`…`af1149bb`)
- **★ TSK-1161 Structural Search — VALIDATED.** View ▸ Structural Search: AST query (DSL) over the active buffer → ranged-match list. (`d580b087` + `6eb4e1b0`)
- **TSK-1160 Task Runner — COMMITTED (`95ed8702`); VM-validation in flight.** View ▸ Task Runner: discover package.json/Cargo/Makefile tasks → Run → captured output (bounded, off-main). View-model `e3c97298`, UI `95ed8702`.
- **TSK-1155 Action-history timeline — jump-to-step primitive landed (`06d51f11`); PARKED.** The live-timeline UI needs the action-history INTEGRATION (coordinator not wired into the app; unify-vs-separate-undo = parent TSK-703's architecture decision) — owner-design, task_park'd.
- Earlier this session: owner intake TSK-1302–1327 (14→review), host slices (audio-persistence/overlay-selection/structural grammar), dogfood TSK-1329/1330.

## ⭐ NEXT ACTION — continue the render-drain via the console template
- **Finish TSK-1160:** the VM-validation (`MDV_VM_GUI_SESSION=1 MDV_VM_SUDO_PASS=<vm-sudo-password> MDV_WEBVIEW_FILTER=ViewerUITests.TaskRunnerHostingTests bash scripts/test-in-vm.sh webview`) is in flight — on green, `task_validate` TSK-1160 → validated (committed @`95ed8702`; check `$SP/scratchpad/vm_runner.log`).
- The intake render remainder (TSK-1302 layout, 1310 vector-text, 1316/1317 drag, 1318/1319 menu, 1326 walkthroughs) — build + VM-validate via the template.
- **TSK-1331** (history Revert) — data-safety-sensitive (guard unsaved edits); build with a data-safety review + VM-validate.
- OWNER-PARKED (don't blind-build): TSK-1155 (action-history integration architecture), TSK-1182 (diff single-Text-vs-NSTextView).

## Owner-input-gated (the genuine exceptions — task_park, don't block)
- Parked: TSK-1200 (scroll: real-bug-vs-harness-false — needs owner's real screen), TSK-1322 (paste repro), TSK-1320 (annotations keep/remove). Flips: TSK-838/1215/1202.
- AX-driven tests = the one off-limits tier.

## Gotchas / lessons (also LESSONS.md)
- **SwiftUI render VM-validation pattern (worked for the console):** in-process host the SwiftUI view in an `NSHostingView`+`NSWindow` (a `WebViewTestCase`, `#192`-gated), force `layoutSubtreeIfNeeded`, walk the NSView hierarchy — sidesteps the TSK-1247 spawned-app framebuffer bug. Add the suite to `run_webview_tests`' filter list (+ use `MDV_WEBVIEW_FILTER=ViewerUITests.<Suite>` to run just it), then `MDV_VM_GUI_SESSION=1 MDV_VM_SUDO_PASS=<vm-sudo-password> MDV_WEBVIEW_FILTER=… bash scripts/test-in-vm.sh webview`. ASSERT ON STRUCTURE not titles: a SwiftUI `Button("X")` bridges to an NSButton whose `.title` is EMPTY (label is a subview) — assert `count`/types (NSButton/NSSegmentedControl/NSTextField), not `.title=="X"`.
- **`test_findTypeahead_doesNotReBodyChromeStrip` (ChromeBodyEvalCountTests) flakes under gate `--parallel` load** (a coincidental SidebarView body-eval lands in the measured window — TSK-1328 class, residual). Isolation-green confirms it; re-run the gate. Worth a dedicated settle-after-action fix.
- **The VM render lanes work — use the RIGHT one.** Webview (in-process WKWebView) for WebView/CM6 render; T5 window-ID capture for SwiftUI/AppKit pixels. The SPAWNED-APP UAT lane has a framebuffer-compositing bug (TSK-1247 — the app window isn't composited so live-WebView reads return -1/0); that's a SPECIFIC broken lane to fix/route-around, NOT a reason to call render "un-workable." Don't grind the full `all`-mode UAT (it gets killed) — use the targeted lane.
- **Owner-sensitive scroll (TSK-1200):** the editor-scroll "no-op" seen via the spawned-app UAT is harness-false (the framebuffer bug). Disambiguate real-vs-harness on the owner's real screen / T5 window-ID before changing scroll code (parked). Don't blind-fix.
- **Backticks in `git commit -m "..."` trigger shell command-substitution** → mangled message. Use `git commit -F -` with a `<<'EOF'` heredoc.
- **Read-first ALWAYS** — most P0/board items were already fixed→review or stale-reset-but-done (1188 `c0fd1543`, 1271 `6e9e4efb`, 343 delta-storage); don't re-build.
- **The INT-126 lease sweep re-resets long-lived `progress` items to `reported`** — `review` sticks, `progress` doesn't. To permanently drain a host-done/render-tail epic, take it to review (host done) with the render UI tracked as a child to BUILD on the VM.

## Tracker (tasked / claude-mdv)
TSK-698 + TSK-1161 VALIDATED · TSK-1160 committed (`95ed8702`; VM-validation in flight → validate) · TSK-1155 jump primitive landed + PARKED (architecture) · TSK-1182/1200/1320/1322 parked (owner) · TSK-722/723/343/703 review (host done; render children built). ~30+ commits this run.

## How to resume
Read this + `BACKLOG.md` + `git log -1`. Confirm main gate-green (`bash scripts/test-headless-gate.sh`). Then BUILD a render UI from NEXT ACTION on the VM (build + VM-validate via `scripts/test-in-vm.sh`, drive to validated) — render is your lane, not the owner's. Only AX tests + the genuine owner-input items are off-limits.
