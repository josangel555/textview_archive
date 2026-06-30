<!-- CLAUDE-HANDOFF v1 -->
# Handoff — owner-intake drained + host slices built; render/UI work continues ON THE VM (2026-06-29)

**Session:** claude-mdv · **cwd:** `/Users/me/Documents/workspaces/claude/markdown_viewer` · **branch:** `main` @ `af1149bb` (verify `git log -1`)

## Mission
Autonomous drain loop (cron). Work INLINE, one item/firing: read-first → implement → host-test → host-gate (`bash scripts/test-headless-gate.sh`) → commit per item; land rebase+ff; keep main gate-green; fold docs into the item's commit. Cron canonical = `docs/TASK_WORKFLOW.md §7`.

## ⚠️ CORRECTION THAT RESET THIS HANDOFF (owner, 2026-06-29) — READ FIRST
A prior version of this handoff declared a "host-testable-seam vein DRAINED" and routed all render/UI work to a "VM/owner venue." **That framing was WRONG and is now banned.** The owner's standing model: **the VM is UP and the ENTIRE UI/render lane is agent-workable — build AND VM-validate it. The ONLY off-limits tier is AX-driven tests.** There is NO "host-testable vs render" split in what to work; render/UI/VM items are first-class drain targets you BUILD and VALIDATE (on the VM), not hand to the owner. The instructions that caused the misread were hardened this session (CLAUDE.md new 2026-06-29 directive + §4 self-validation; TASK_WORKFLOW §4 + §7 cron; the live cron prompt). The render-confirm directive is satisfied BY VM-validating, not by leaving things at review.

## What shipped this session (host-tested + gate-verified)
- **★ TSK-698 Script Console — VALIDATED (the full build→VM-validate→validated flow; THE PROOF the corrected render directive works).** A complete, user-reachable feature (View ▸ Script Console): a JS query/transform console over JSON / log lines / CSV, off-main with a soft timeout, Apply→opens output in a new tab. VM-render-validated (`ScriptConsoleHostingTests` on the VM webview lane — caught a real test bug) + comprehensively host-tested (JSTransform 22 · ViewModel 6 · DocumentModel glue 4); self-validated. ~10 commits `17845599`…`af1149bb`. Two reusable test-infra wins: registered the suite in `run_webview_tests`' nightly list + an `MDV_WEBVIEW_FILTER` override to run ONE WebView suite without the ~20-suite serial lane.
- **Owner intake TSK-1302–1327: 14 → review**, 5 triaged, 2 parked (TSK-1200 scroll, TSK-1322 paste — genuine owner-input items), 1 spike (TSK-1320).
- **Host slices (7):** TSK-1308 audio-persistence (`52d37b7f`) · TSK-1321 overlay-selection model (`7ff73246`) · TSK-723 structural-query grammar (`694a4700`) · **TSK-698 script console: slice 2 off-main exec (`17845599`), slice 4 log-line input (`bfbcf0d9`), slice 3a controller (`1b8d8049`), slice 4b CSV input (`5cf36751`)** — the console is host-complete; its SwiftUI panel (slice 3b) is the next VM build.
- **Reconciled** to review (host engines done, render UIs = the next VM build, tracked as children): TSK-722 (→ child TSK-1160), TSK-723 (→ TSK-1161), TSK-343 (history; → revert child TSK-1331), TSK-910 (→ TSK-1182). TSK-703 coordinator done (UI 1155).
- **Dogfood:** TSK-1329/1330 → `docs/TRACKER_FEEDBACK.md`.

## ⭐ NEXT ACTION — BUILD THE RENDER UIs ON THE VM
These are NOT "owner's lane" — build each + VM-validate (`scripts/test-in-vm.sh`; webview lane for WebView render, T4/T5 for SwiftUI/AppKit), drive to validated. TSK-698 is the worked template (panel + view-model + DocumentModel wiring + menu trigger + `ScriptConsoleHostingTests` VM-validation). Next:
- **TSK-1161** (structural-search UI) — the natural next: its engine + StructuralQueryParser grammar were built this session, so most context. A query field + results list binding to `StructuralSearchEngine.structuralSearch` over the active file's tree-sitter tree (the jump-to-match is the extension).
- The other epic UI children: **TSK-1160** (runner panel), **TSK-1155** (action-history timeline), **TSK-1182** (diff single-Text — OWNER-PARKED on the one-Text-vs-NSTextView design call).
- The intake render remainder (TSK-1302 layout, 1310 vector-text, 1316/1317 drag, 1318/1319 menu, 1326 walkthroughs) — build + VM-validate.
- **TSK-1331** (history Revert) — data-safety-sensitive (guard unsaved edits); build with a data-safety review + VM-validate.

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
TSK-698 progress (host-complete; 3b = next VM build) · TSK-722/723/343 review (host done; render children to build) · TSK-1160/1161/1155/1182/1331 = render UIs to build on the VM · TSK-1200/1322/1320 parked (owner) · TSK-1329/1330 filed. ~22 commits this run.

## How to resume
Read this + `BACKLOG.md` + `git log -1`. Confirm main gate-green (`bash scripts/test-headless-gate.sh`). Then BUILD a render UI from NEXT ACTION on the VM (build + VM-validate via `scripts/test-in-vm.sh`, drive to validated) — render is your lane, not the owner's. Only AX tests + the genuine owner-input items are off-limits.
