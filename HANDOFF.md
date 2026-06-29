<!-- CLAUDE-HANDOFF v1 -->
# Handoff — owner-intake drain: 11 shipped → review, 4 triaged; remaining = substantial render/session (2026-06-29)

**Session:** claude-mdv · **cwd:** `/Users/me/Documents/workspaces/claude/markdown_viewer` · **branch:** `main` @ `a23c1edc` (verify `git log -1`)

## Mission
Autonomous drain loop (cron). Build INLINE, one item/firing: read-first → implement → host-test → host-gate (`bash scripts/test-headless-gate.sh`) → commit; land rebase+ff; keep main gate-green; fold docs into the item's commit. Cron canonical = `docs/TASK_WORKFLOW.md §7`.

## Current drain state — owner intake TSK-1302–1327
**Shipped → review (built + host-gate-verified):**
- Features: TSK-1327 smart-paste HTML→MD formatter (`0c29bfff`) · TSK-1323/1324 audio extract/convert (`f5ca0622`) · TSK-1325 image convert (`5bd739dd`) · TSK-1306 New-Image landing button (`f767a564`) · TSK-1312 terminal colour-scheme picker, full (`667412be`+`7e60fb98`)
- Render fixes: TSK-1314 sidebar file-tree respects `.files` toggle (`df3572a6`) · TSK-1309 remove redundant Draw-Box button (`8fca0d1f`) · TSK-1313 terminal pane size-cap lift (`a23c1edc`)
- Infra: TSK-1328 gate body-eval parallel-flake fix (`982e3e01`)
- Reconcile: TSK-1307 MS-Paint resize — already built (TSK-1073/1076)

**Triaged with findings + fix-directions (diagnosed, NOT built — render-VM / data-safety):**
- TSK-1315 key-event routing — no central focus coordinator (fragmented @FocusState + imperative makeFirstResponder); fix = a focus coordinator. Render-VM.
- TSK-1304 hide file-property pane — the metadata-panel toggle EXISTS (BottomAttributesBar "Info"); the image-editor sidebar hide is render (batches TSK-1302).
- TSK-1305 image undo — draw/geometry DONE (TSK-749/1055); tonal-undo (sliders not in the op-list) is the likely gap — a live-slider→committed-op model change.
- TSK-1303 image edit-state lost on session-switch — ImageEditorViewModel state is in-memory, not in the session snapshot; fix = serialize the op-list+tonal. DATA-SAFETY-sensitive; needs VM.

**Remaining (~9) — substantial render / session / content / spike (no clean blind build):**
- Substantial render: TSK-1316 (empty-shoulder-only-on-drag — needs NEW global drag-state plumbing) · TSK-1317 (drag Terminal icon — it's a toggle not a draggable panel; + remove the coupled Pane-placement Setting) · TSK-1318/1319 (menu reorg + dynamic per-tab menu — render + subjective grouping) · TSK-1310 (edit Draw Text element — overlay editing) · TSK-1321 (selectable overlay elements — big) · TSK-1302 (image pane covered by property pane — render-layout)
- Spike → owner decision: TSK-1320 (Annotations vs Shapes — clarify + keep/remove)
- Session-lifecycle: TSK-1308 (music stops on switch) · TSK-1311 (session-state umbrella)
- Vague bug (needs owner repro): TSK-1322 (paste is buggy)
- Content (on-screen-coupled): TSK-1326 (sample walkthroughs)

## ⭐ NEXT ACTION
The tractable host + clean-small-render slices are DONE. The remainder is **substantial render** (pure SwiftUI, no host model: drag mechanics, overlay editing, menu reorg) — building these BLIND is low-confidence. Two paths:
1. **VM render lane** (owner's "VM is open for work") — build + VM-validate the substantial render. SwiftUI/AppKit pixels = T5 window-ID capture; NOTE TSK-1247 (the VM GUI session doesn't framebuffer-composite app-window content → spawned-app UATs read blank; use window-ID capture, or the in-process `webview` lane for WebView render).
2. **Owner render sessions** — the heaviest (drag/overlay/menu) + the clarification items (TSK-1322 paste specifics, TSK-1320 annotations keep/remove, TSK-1318 grouping preference).
- If continuing INLINE, the most-tractable next: TSK-1320 (annotations spike → owner decision) · TSK-1308 (read the audio-player lifecycle) · TSK-1318 (read the CommandRegistry / menu structure).

## Gotchas / lessons (LESSONS.md §2026-06-29)
- **Read-first ALWAYS** — the image-editor intake was largely already-built (1306 action, 1307 resize, 1305 undo-mostly); don't re-build.
- **Mirror established fix patterns** — TSK-1314 mirrored the bug5 pluginSections gate (a panel mounted on presence, bypassing `isVisible`).
- **Cap-changes break old-cap tests** — TSK-1313 broke 4 tests using `99999` as "above-max"; grep + update the inputs.
- **@ViewBuilder placement** — a `Bool` computed inserted above a `@ViewBuilder var` steals the attribute (TSK-1314 compile slip; the attribute must sit directly on the `some View` var).
- **The body-eval gate flake (TSK-1328)** — fixed via settle-to-quiescence; if a `ChromeBodyEvalCount` off-by-one recurs, it's load not a regression.

## Tracker (tasked / claude-mdv)
Owner intake TSK-1302–1327: **11 → review**, **4 → triaged**, ~9 reported/remaining (substantial render/session/content). TSK-1328 → review. ~14 commits this drain, each gate-verified, docs folded in.

## How to resume
Read this + BACKLOG §"Owner intake 2026-06-29". Confirm main gate-green (`bash scripts/test-headless-gate.sh`). The tractable slices are shipped → review (owner closes on-screen). For the substantial-render remainder: prefer the **VM render lane** (build + VM-validate) OR surface to the owner. If continuing inline, the most-tractable are TSK-1320 / TSK-1308 / TSK-1318 — read-first each (`task_get` + grep main).
