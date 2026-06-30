<!-- CLAUDE-HANDOFF v1 -->
# Handoff — 4 render epics validated + walkthrough illustrations on-screen; T5-pixel render now OWNER-BLOCKED on the VM screencapture TCC re-grant (TSK-1334) (2026-06-30)

**Session:** claude-mdv · **cwd:** `/Users/me/Documents/workspaces/claude/markdown_viewer` · **branch:** `main` @ `74796e9f` (verify `git log -1`)

## Mission
Autonomous drain loop (cron). Work INLINE, one item/firing: read-first → implement → host-test → host-gate (`bash scripts/test-headless-gate.sh`) → commit per item; land rebase+ff; keep main gate-green; fold docs into the item's commit. Cron canonical = `docs/TASK_WORKFLOW.md §7`.

## ⚠️ CORRECTION THAT RESET THIS HANDOFF (owner, 2026-06-29) — READ FIRST
A prior version of this handoff declared a "host-testable-seam vein DRAINED" and routed all render/UI work to a "VM/owner venue." **That framing was WRONG and is now banned.** The owner's standing model: **the VM is UP and the ENTIRE UI/render lane is agent-workable — build AND VM-validate it. The ONLY off-limits tier is AX-driven tests.** There is NO "host-testable vs render" split in what to work; render/UI/VM items are first-class drain targets you BUILD and VALIDATE (on the VM), not hand to the owner. The instructions that caused the misread were hardened this session (CLAUDE.md new 2026-06-29 directive + §4 self-validation; TASK_WORKFLOW §4 + §7 cron; the live cron prompt). The render-confirm directive is satisfied BY VM-validating, not by leaving things at review.

## What shipped this session (4 render epics validated via the in-process template)
Render is FIRST-CLASS agent work — built + VM-validated, not handed to the owner. The template —
**view-model (host-tested) → SwiftUI panel → DocumentModel wiring → menu trigger → in-process
NSHostingView VM-hosting-test (webview lane) → validated** — drove FOUR owner-wishlist epics from
foundation-only to VALIDATED:
- **★ TSK-698 Script Console — VALIDATED.** View ▸ Script Console: JS query/transform over JSON/log/CSV, off-main, Apply→new-tab.
- **★ TSK-1161 Structural Search — VALIDATED.** View ▸ Structural Search: AST query (DSL) → ranged-match list.
- **★ TSK-1160 Task Runner — VALIDATED.** View ▸ Task Runner: discover package.json/Cargo/Makefile → Run → captured output (bounded, off-main).
- **★ TSK-1176 Terminal Command Palette — VALIDATED.** View ▸ Terminal Command Palette: search history+favorites → insert at prompt.

Plus:
- **TSK-1032** HEX byte-grid "blank" resolved as a T4 UAT false-negative (`numberOfGlyphs` is TK1-only, ~0 for the TK2 fixed-grid view) + a reliable host guard (`dc1caa45`); TSK-1332 filed for the UAT-harness fix.
- **TSK-1155** jump-to-step coordinator primitive landed (`06d51f11`), PARKED — the live-timeline UI needs the action-history INTEGRATION (unify-vs-separate-undo = TSK-703 architecture decision, owner).
- **settle() gate flake KILLED (`8c06b297`)** — it bit 3 gates; now 2-consecutive-empty quiescence ⇒ reliably green.
- Earlier: owner intake TSK-1302–1327, host slices (audio-persistence/overlay-selection/structural grammar).
- **TSK-1119 walkthrough illustrations ON SCREEN (review, `111bcab3`).** WalkthroughDiagramOverlay renders .ascii/.image + caption (occlusion-free, VM-validated); .mermaid shows source as interim. Slice 2 (rendered Mermaid) = TSK-1333.
- **TSK-1333 Mermaid-render foundation built; T5 owner-blocked.** WalkthroughMermaidPage (page builder, host-tested, `9482349e`) + WalkthroughMermaidWebView (WebView component, mount-validated on the VM, `62c400c6`). The occlusion verification needs T5-pixel.
- **NEW `pixel` targeted-T5 mode (`74796e9f`)** — `test-in-vm.sh pixel --filter <PixelSuite>` runs ONE T5 suite in ~50s (no full-`all` kill). BUT discovered the T5 screencapture is **TCC-DENIED** (owner-only re-grant, SIP) → **TSK-1334 filed**; ALL T5-pixel CAPTURE is owner-blocked until re-granted.

## ⭐ NEXT ACTION — render is currently EXHAUSTED for the agent (drained / owner-blocked / off-limits) → host P2, OR await the TCC re-grant
NOT the banned framing — render was BUILT + VM-validated ALL session (4 epics + illustrations). The lanes are now genuinely exhausted:
- **In-process render: DRAINED** (the 4 tool-panel epics + TSK-1119 illustrations — all validated).
- **T5-pixel render: OWNER-BLOCKED (TSK-1334).** The screencapture grant is TCC-denied (owner-only, SIP — the agent can't INSERT into TCC.db). When the owner re-grants Screen-Recording to the xctest runner on the VM, the T5-pixel vein REOPENS: `MDV_VM_GUI_SESSION=1 MDV_VM_SUDO_PASS=<vm-sudo-password> bash scripts/test-in-vm.sh pixel --filter ViewerUITests.<Suite>` (the new targeted-T5 mode), then land **TSK-1333**'s atomic unit (wire the mermaid WebView occlusion-safe `compositingGroup().zIndex` + an MDV_UI_SCENE + a PixelTestCase mirroring ClaudeMonitorVisualRegressionTests — all scoped on the ticket) + TSK-955/1149.
- **AX-interaction render: OFF-LIMITS** (the one excepted tier): TSK-924/1187 (CSV rect-select), TSK-1139/1141/1146.
So the agent-workable vein RIGHT NOW is **host P2 (clean host-gate work):** TSK-382 (DocumentModel memory perf — measure-first), TSK-538 (rust-core audit follow-ups), TSK-764 (git reconciliation), TSK-441–445 (CI infra) — OR re-verify/reconcile toward the owner-close queue.
**When TSK-1334 (the TCC re-grant) lands, PRIORITIZE the reopened T5-pixel vein — TSK-1333 first** (fully scoped + foundation-built + the `pixel` lane ready).

## Owner-input-gated (the genuine exceptions — task_park, don't block)
- Parked: TSK-1200 (scroll: real-bug-vs-harness-false — needs owner's real screen), TSK-1322 (paste repro), TSK-1320 (annotations keep/remove). Flips: TSK-838/1215/1202.
- AX-driven tests = the one off-limits tier.

## Gotchas / lessons (also LESSONS.md)
- **SwiftUI render VM-validation pattern (worked for the console):** in-process host the SwiftUI view in an `NSHostingView`+`NSWindow` (a `WebViewTestCase`, `#192`-gated), force `layoutSubtreeIfNeeded`, walk the NSView hierarchy — sidesteps the TSK-1247 spawned-app framebuffer bug. Add the suite to `run_webview_tests`' filter list (+ use `MDV_WEBVIEW_FILTER=ViewerUITests.<Suite>` to run just it), then `MDV_VM_GUI_SESSION=1 MDV_VM_SUDO_PASS=<vm-sudo-password> MDV_WEBVIEW_FILTER=… bash scripts/test-in-vm.sh webview`. ASSERT ON STRUCTURE not titles: a SwiftUI `Button("X")` bridges to an NSButton whose `.title` is EMPTY (label is a subview) — assert `count`/types (NSButton/NSSegmentedControl/NSTextField), not `.title=="X"`.
- **`test_findTypeahead_doesNotReBodyChromeStrip` (ChromeBodyEvalCountTests) flake — FIXED (`8c06b297`).** It bit 3 gates this session: `settle()` declared quiescence on a SINGLE empty pump, so a slow async residual under the 18-worker load leaked into the measured window. Fixed: `settle()` now requires TWO consecutive empty pumps (sustained-idle) + doubled the bound (12→24). Gates reliably green. (LESSONS: "quiescent" must mean sustained-idle, not a single idle tick.)
- **The VM render lanes work — use the RIGHT one.** Webview (in-process WKWebView) for WebView/CM6 render; T5 window-ID capture for SwiftUI/AppKit pixels. The SPAWNED-APP UAT lane has a framebuffer-compositing bug (TSK-1247 — the app window isn't composited so live-WebView reads return -1/0); that's a SPECIFIC broken lane to fix/route-around, NOT a reason to call render "un-workable." Don't grind the full `all`-mode UAT (it gets killed) — use the targeted lane.
- **Owner-sensitive scroll (TSK-1200):** the editor-scroll "no-op" seen via the spawned-app UAT is harness-false (the framebuffer bug). Disambiguate real-vs-harness on the owner's real screen / T5 window-ID before changing scroll code (parked). Don't blind-fix.
- **Backticks in `git commit -m "..."` trigger shell command-substitution** → mangled message. Use `git commit -F -` with a `<<'EOF'` heredoc.
- **Read-first ALWAYS** — most P0/board items were already fixed→review or stale-reset-but-done (1188 `c0fd1543`, 1271 `6e9e4efb`, 343 delta-storage); don't re-build.
- **The INT-126 lease sweep re-resets long-lived `progress` items to `reported`** — `review` sticks, `progress` doesn't. To permanently drain a host-done/render-tail epic, take it to review (host done) with the render UI tracked as a child to BUILD on the VM.

## Tracker (tasked / claude-mdv)
VALIDATED this session: TSK-698 · TSK-1161 · TSK-1160 · TSK-1176 · TSK-1032 (harness-false + guarded). REVIEW: TSK-1119 (illustrations on-screen; mermaid-render = TSK-1333). PARKED: TSK-1155 (architecture) · TSK-1333 (T5-pixel owner-TCC-blocked → TSK-1334) · TSK-1182/1200/1320/1322 + flips 838/1215/1202 (owner). FILED: TSK-1332 (UAT-harness fix) · TSK-1333 (mermaid T5) · **TSK-1334 (VM screencapture TCC re-grant — OWNER ACTION, blocks ALL T5-pixel)**. NEW infra: `pixel` targeted-T5 mode (`74796e9f`). ~57 commits this run.

## How to resume
Read this + `BACKLOG.md` + `git log -1`. Confirm main gate-green (`bash scripts/test-headless-gate.sh` — reliably green now). The clean in-process render template is DONE (4 epics validated). Take the NEXT-ACTION vein: **T5-pixel render** (TSK-1119 overlay = highest value — build occlusion-safe `compositingGroup().zIndex` + T5-validate, NOT in-process [false-green trap]) OR **host P2** (TSK-382/538/764). Render is your lane (build + VM-validate); only AX-interaction tests + owner-gated items are off-limits. Do NOT re-pick the validated epics or blind-build the occlusion/AX items via the in-process test.
