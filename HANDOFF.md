<!-- CLAUDE-HANDOFF v1 -->
# Handoff — owner-intake filed (TSK-1302–1327) + VM render lane + parser hardening; fresh backlog to drain (2026-06-29)

**Session:** claude-mdv · **cwd:** `/Users/me/Documents/workspaces/claude/markdown_viewer` · **branch:** `main` @ `a3be33ac` (verify `git log -1`)

## Mission
Autonomous drain loop (cron, every 5 min). Build INLINE, one item/firing: spike → implement → test → host-gate → commit; land rebase+ff; keep main gate-green; fold docs into the item's commit. The cron prompt is canonical in `docs/TASK_WORKFLOW.md §7` (verified universal + current this session — no change needed).

## ⭐ NEXT ACTION (the surface is NO LONGER drained — owner gave fresh work)
**Drain the owner intake TSK-1302–1327** (filed 2026-06-29, grouped in BACKLOG §"Owner intake"). Read-first each, build the host-completable slice, leave render at review. Likely host-completable starting points:
- **TSK-1327** smart text-paste formatting — a pure host-testable formatter (rich-text/HTML → markdown: bullets→`- `, headings, lists). Strong host slice.
- **TSK-1325** image format+quality convert · **TSK-1324** audio format+quality · **TSK-1323** extract-audio-from-video — converter-model slices (reuse the converter infra + host ffmpeg TSK-528); render/UX at review.
- **TSK-1315** key-event routing audit — host-analyzable (map the responder chain / event-routing; the owner reports leaks: Side-nav eats tab keys, Terminal keys reach tab content). Diagnose host-side first.
- **TSK-1318** menu reorg — the menu structure is host-data (CommandRegistry); reorganize + host-test the grouping.
- The image-editor cluster (TSK-1302/1303/1305/1307/1309/1310/1320/1321) is mostly render-VM (SwiftUI image editor) — host-test models where they exist; **NOTE the occlusion-class trap** (TSK-1119-style WKWebView-beside-SwiftUI → MUST T5-pixel-verify, never built-blind-at-review).
- **READ-FIRST EACH** (`task_get` + grep main) — ~18 saves this session; the host work is often already done.

## Current state — this session's delivery (all on `main`, gate-green)
- **TSK-1188** CM6 plain-click-extends-selection — FIXED → review (`c0fd1543`): deferred re-entrant mouse-handler dispatch to `queueMicrotask` (active-line + drag-gate); host grep-guard. On-screen = VM/owner.
- **TSK-1271** find-scroll-past — FIXED → review (`6e9e4efb`, prior).
- **VM render lane RE-ESTABLISHED + validated** — in-process WebView lane GREEN (78 tests, 0 fail). Recipe: `MDV_VM_GUI_SESSION=1 MDV_VM_SUDO_PASS=<vm-sudo-password> MDV_RUN_WEBVIEW_TESTS=1 bash scripts/test-in-vm.sh webview` (NOT `all` — killed ~10-12 min). First-sync toolchain-skew fix: `ssh macOS15 'cd markdown_viewer && echo "$MDV_VM_SUDO_PASS" | sudo -S rm -rf .build/arm64-apple-macosx'` (clean per-arch products, KEEP checkouts/repositories).
- **TSK-1247 ROOTED (4 rounds) + PARKED a/b/c** — the VM GUI session doesn't framebuffer-composite app-window CONTENT (window AppKit-healthy per the committed `MDV_WINDOW_DIAG=1` probe `8646ac07`, but `screencapture -x` blank → WKWebView never lays out → spawned-app UAT scroll-probe reads -1). Shared root of TSK-1200 + ScrollRestore UATs (HARNESS-FALSE, not real bugs). T5 works only via window-ID capture. Fix = VM display-config OR refactor UATs to window-ID reads (owner a/b/c).
- **TSK-838 DOM-patch RE-VERIFIED built→flip-ready** (`MarkdownRenderedView.swift:136`=flag `MDV_DOM_PATCH`, `:340`=re-render path with `tryApplyDOMPatch` else loadHTMLString fallback; in-process-correctness-tested). Low-risk to flip — kills the 2-9s reload storm.
- **Parser no-panic hardening** — added arbitrary-input fuzz to formula (`2b8fe4db`) + csv (`d6113304`); the genuine audit-harden gaps. Rest covered (FFI catch_unwind, cm_edit Option-safe, hex/serve/find/markdown).
- **Owner intake** — TSK-1302–1327 filed (26 bug/feature tickets, `a3be33ac`).

## Owner-gated queue (the real bottleneck — your call)
- **Parked decisions:** TSK-543 stage-3 timing · TSK-1129 LSP-binary a/b/c · TSK-1247 a/b/c.
- **Flips (re-verified ready):** `MDV_DOM_PATCH` (TSK-838) · formula (TSK-1215) · fold (TSK-1202).
- **Close-queue:** ~417 review/fixed (on-screen close).

## Gotchas / lessons (full detail in LESSONS.md §2026-06-29)
- The VM-compositing root (above) — spawned-app render UATs are harness-false; use the in-process `webview` lane.
- A proptest on only STRUCTURED input misses no-panic-on-arbitrary-input (the formula/csv gap).
- read-first ALWAYS — the host-completable surface is overwhelmingly already done.
- Occlusion class (TSK-488): a WKWebView beside SwiftUI → host/ImageRenderer false-green; MUST T5-pixel-verify, never built-blind-at-review.

## Files that matter
- `Sources/MarkdownViewer/main.swift:~120` — the `MDV_WINDOW_DIAG` probe (VM window-state diagnostic).
- `Sources/ViewerUI/MarkdownRenderedView.swift:136/340` — `MDV_DOM_PATCH` flag + the re-render path (TSK-838 flip).
- `rust-core/crates/core/src/{formula,csv}.rs` — the new `*_arbitrary_input_never_panics` proptests.
- `scripts/test-in-vm.sh` — `webview` mode (agent render tier), `build` (build-only), `all` (full, gets killed).
- `BACKLOG.md` §"Owner intake 2026-06-29" — TSK-1302–1327 grouped.

## Tracker (tasked / claude-mdv)
TSK-1302–1327 filed (reported). TSK-1188/1271 review · TSK-1247 parked · TSK-543/1129 parked · TSK-1300/1301 validated · TSK-838/1215/1202 owner-flip. ~417 review/fixed = owner close-queue.

## How to resume
Read this + BACKLOG.md top (the "Owner intake" section). Confirm `main` gate-green (`bash scripts/test-headless-gate.sh`). **Drain the owner intake TSK-1302–1327 (NEXT ACTION above), one item/firing, read-first each.** VM render validation = the in-process `webview` lane (recipe above). Do NOT build occlusion-class render blind. The owner-gated queue (flips/decisions/close) is theirs.
