<!-- CLAUDE-HANDOFF v1 -->
# Handoff — 6 epics/features validated; T5-pixel render owner-blocked (TSK-1334 TCC re-grant), but the WEBVIEW + host lanes remain OPEN — render is NOT exhausted (2026-06-30)

**Session:** claude-mdv · **cwd:** `/Users/me/Documents/workspaces/claude/markdown_viewer` · **branch:** `main` @ `29e4c48b` (verify `git log -1`)

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
- **★ TSK-958/1163 Universal Paste — VALIDATED (`c32ee925`).** Edit ▸ Paste as New Document (⇧⌘V) → dispatch each clipboard kind to the right viewer (image/table/text/file). Was wrongly held at review-as-VM-only; host-testable via an INJECTABLE NSPasteboard (UniversalPasteActionTests 3/0).
- **★ TSK-1146 Spell/LSP squiggles — VALIDATED (`29e4c48b`).** Editor spell underlines + LSP diagnostics; logic host-tested at every layer + the RENDER webview-guarded (EditorDiagnosticsWebViewTests: setDiagnostics → `.cm-lintRange` in the live CM6 DOM, VM 2/0). The webview lane is NOT TCC-blocked (≠ T5 screencapture).
- **TSK-1136/463 LSP autocomplete — BUILT, at review.** Editor invocation wired end-to-end (`868b4c74`+`2716669a`); render-validation = a focused rebundle session (expose `startCompletion` in entry.js + `npm run build` → a webview render guard) + the live-app bridge round-trip (precisely scoped on TSK-1136).

## ⭐ NEXT ACTION — render is NOT exhausted: the WEBVIEW + host-completable lanes are OPEN; only T5-SCREENCAPTURE is owner-blocked + AX off-limits
**CRITICAL — DO NOT re-make the "render exhausted → host P2" mistake.** A prior version of this NEXT said exactly that; it was the SAME premature error the owner banned, and it was DISPROVEN this session by validating TSK-958 (universal paste, host) + TSK-1146 (spell squiggles, webview) AFTER it was written. The lanes:
- **WEBVIEW lane: OPEN + agent-runnable** — in-process WKWebView + JS DOM introspection (`MDV_VM_GUI_SESSION=1 MDV_VM_SUDO_PASS=<vm-sudo-password> MDV_WEBVIEW_FILTER=ViewerUITests.<Suite> bash scripts/test-in-vm.sh webview`). NOT TCC-blocked (≠ the T5 screencapture lane). Validated TSK-1146's diagnostics render via it (EditorDiagnosticsWebViewTests, the FoldGutter pattern: load codemirror.html → cmDispatch → query the CM6 DOM). Next render = un-drained webview-lane (CM6/rendered) items.
- **Host-completable feature logic: OPEN** — injectable-seam actions (universal paste was one). "AppKit/pasteboard = VM-only" is OFTEN FALSE — look for an injectable seam (NSPasteboard arg, etc.).
- **VERIFY-BEFORE-BUILD (recovered 2 epics this session):** several items sit at review wrongly labeled "VM-only" but are actually host/webview-validatable (TSK-1163 was). `task_get` + grep the seam before assuming a render item is un-agent-workable.
- **T5-SCREENCAPTURE (occlusion/pixel): OWNER-BLOCKED (TSK-1334)** — Screen-Recording grant TCC-denied (owner-only, SIP). When re-granted, `test-in-vm.sh pixel --filter <Suite>` (the new targeted-T5 mode) reopens it → land **TSK-1333** (mermaid occlusion, fully scoped + foundation-built) + TSK-955/1149.
- **AX-interaction: OFF-LIMITS** (the one excepted tier): TSK-924/1187, TSK-1139/1141.
- **Focused-session item:** TSK-1136/463 completion render — expose `startCompletion` (entry.js) + `npm run build` rebundle → a webview render guard (scoped on TSK-1136).
- **Host P2 (legit, but NOT as an escape from render):** TSK-382/538/764. Work the open webview/host RENDER lanes first.

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
VALIDATED this session (6): TSK-698 · TSK-1161 · TSK-1160 · TSK-1176 · TSK-958/1163 (universal paste) · TSK-1146 (spell/LSP squiggles) · + TSK-1032 (harness-false + guarded). REVIEW: TSK-1119 (illustrations on-screen; mermaid-render = TSK-1333) · TSK-1136/463 (LSP autocomplete built; render = focused rebundle session). PARKED: TSK-1155 (architecture) · TSK-1333 (T5-pixel owner-TCC-blocked → TSK-1334) · TSK-1182/1200/1320/1322 + flips 838/1215/1202 (owner). FILED: TSK-1332 (UAT-harness) · TSK-1333 (mermaid T5) · **TSK-1334 (VM screencapture TCC re-grant — OWNER ACTION, blocks ALL T5-pixel)**. NEW infra: `pixel` targeted-T5 mode (`74796e9f`). ~62 commits this run.

## How to resume
Read this + `BACKLOG.md` + `git log -1`. Confirm main gate-green (`bash scripts/test-headless-gate.sh` — reliably green now). The clean in-process render template is DONE (4 epics validated). Take the NEXT-ACTION vein: **T5-pixel render** (TSK-1119 overlay = highest value — build occlusion-safe `compositingGroup().zIndex` + T5-validate, NOT in-process [false-green trap]) OR **host P2** (TSK-382/538/764). Render is your lane (build + VM-validate); only AX-interaction tests + owner-gated items are off-limits. Do NOT re-pick the validated epics or blind-build the occlusion/AX items via the in-process test.
