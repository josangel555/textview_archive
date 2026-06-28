# Backlog — the single curated worklist (reconciled 2026-06-27)

> The ONE prioritized "what to work on" list. The `tasked` board (http://localhost:8787/) is the
> **system of record** for task STATE/detail; this file is the human-scannable selector.
> **Verify any `TSK-###` against the live board before working it** — most "open"-looking items are
> already done (the board moved, this file lags). The full pre-reconcile snapshot (the 06-19/06-20/06-25
> captures, done-sweeps, Quick-Wins, and verify-state reports) is in
> `archive/BACKLOG_archive_2026-06-27.md`.

## 📊 Current state (2026-06-27)

Board lanes (the shared `tasked` board; the vast majority is markdown_viewer):

| Lane | Count | |
|---|---:|---|
| `review` | 324 | agent-complete, awaiting owner `→ done` |
| `fixed` | 86 | agent-complete, awaiting validate/close |
| `reported` | 290 | backlog + ~#NNN phantoms (unsafe to per-item mutate) |
| `ack` | 33 | acknowledged epics/spikes |
| `triaged` | 7 | scoped, not started |
| **in-flight total** | **740** | |
| **closed** (validated / done / wontdo) | **~912** | total board = 1652 |

- **~410 items await OWNER CLOSE** (324 `review` + 86 `fixed`) — **the real bottleneck.** They're agent-complete; they need the owner's `→ done` (render/WebView/AX-pixel items: a quick on-screen confirm).
- **0 stale-progress** — INT-126 auto-expiry working (`liveLeases:[]`, progress lane empty).
- **Host-completable surface is DRAINED** — build / validate-with-teeth / reconcile / audit-harden all worked through this session. Remaining is owner-action or a focused VM session.

## 🎯 OWNER PRIORITY ORDER (drain in THIS order)

P0a and P0b are CO-EQUAL + interleaved; finish ALL of P0 before P1.

- **P0a — Eval / AX self-driving + agent-drivable interfaces.** TSK-1254 native-chrome UAT driver → TSK-1255 test-pyramid doc → `mdv.*` AX ids + script-bus action surface → TSK-1256 element-refs.
  - *State: host foundation COMPLETE + comprehensive (AXDriverCore + 59-id catalog + AXUIElementNode + ElementRef + AXDrivePlan + ~134-verb `run_verb` + `list_verbs`/`list_surfaces`/`current_state`; pyramid doc done; element-refs host-complete). REMAINING = the out-of-process EXECUTOR (TSK-1261/1263), AX/Automation-TCC-gated → **owner grant.***
- **P0b — Battle-test → VALIDATE the pending pile with TEETH** (`task_validate` + a checks artifact for pure-logic/model/FFI/parser; render/WebView/AX-pixel cap at `review`).
  - *State: host-validatable items drained; the ~410 review/fixed are render features with host-tested models → **owner on-screen close**. TSK-1253 stale-progress reclaim done.*
- **P1 — the wave-12 features.** *State: host layers COMPLETE (RSS reader, approve/reject engine+guard, image-perf/search/local-history/cm_apply/tmux host layers); render/VM tails remain (below).*
- **P2+ — rest of the board** (`task_next` / `task_list`).

## Upcoming / open work (grouped by what unblocks each)

**A. Render-VM passes** (host model done + tested; need an on-screen / T5 VM session):
RSS tool-window mount (TSK-1149 slice-3, OCCLUSION-class) · approve/reject per-hunk UI (TSK-941) · image-editor canvas + paint gestures (TSK-1048/1052/1101/1102) · agent-monitor view (TSK-111/336) · font picker (TSK-259) · multi-window (TSK-265) · dep-graph entry (TSK-280/1100) · local-history UI (TSK-301/1103) · md-overview (TSK-305) · cmd-palette overlay (TSK-326) · treemap (TSK-334) · LSP completion wiring (TSK-463/1127) · View↔Edit line-height (TSK-1151) · diff multi-line select (TSK-910/1182) · unified search palette (TSK-1143) · dark-mode T5 confirm (TSK-1279) · small render items (find-clear TSK-1270, find-scroll TSK-1271, Cmd-F sidebar route TSK-1272, terminal header TSK-1273).

**B. Owner DECISIONS / spikes** (design produced; the call is the owner's):
approve/reject UX-semantics (TSK-941) · web browser (TSK-676) · spell/grammar (TSK-685) · app name (TSK-683) · Developer-ID signing + notarization (TSK-686) · debugger/DAP (TSK-276) · encryption (TSK-293) · markdown formatter (TSK-296) · zoom-split (TSK-470) · crypto-hash for PM 2b (TSK-1287) · DIY mutation-tester option 1/2/3 (TSK-1137) · diff-selection model (TSK-1182).

**C. Engine / design-blocked** (need a live engine or sandbox design):
LSP→MCP bridge (TSK-279) · Agent-Services MCP: semantic-search / refactor / test-runner[sandbox] / code-review (TSK-1154) · Java formatter ext-tool (TSK-298) · CLI find-instance / socket RPC (TSK-353).

**D. Deps** (owner-approved 2026-06-27; `default-features=false` + pinned):
memchr ✅ · proptest ✅ · rusqlite ✅ (PM store) · **cargo-fuzz + wasm32 (TSK-584/587) — CDN-blocked** (rust-std-wasm32 download times out; re-check periodically) · cargo-mutants REJECTED (dep hygiene) → DIY option owner-deciding (TSK-1137).

**E. Owner close / TCC / flips** (highest-leverage unblocks):
1. **Flip `MDV_DOM_PATCH`** — the rendered-MD DOM-patch perf lever (kills the 2–9s reload storm); built + VM-validated, gated OFF (TSK-838/1183, addresses TSK-598).
2. **Grant Accessibility + Automation TCC** — unblocks the P0a out-of-process executor (TSK-1261/1263).
3. **Close the ~410 review/fixed queue** (`→ done`; render items by on-screen glance).
4. **Flip the rust ports** — formula `MDV_RUST_FORMULA` (TSK-1215), folds `MDV_RUST_FOLD` (TSK-1202); parity-proven, await owner soak.
5. **Close TSK-590** (owner bug-list epic, 20/21 done; pending TSK-598, which the DOM-patch flip addresses).

## Epics (slice-and-iterate)

image-editor (TSK-1048) · code-review (TSK-537) · rust-audit (TSK-538) · rust-migration (TSK-379) · remote-core (TSK-651, 13/14 children done) · feeds / AU / macros / paste (TSK-955–958) · git-reconcile (TSK-764) · tmux `-CC` live PTY + render (TSK-1023, host done) · PM-store FFI-link tail (TSK-345 slice-5b) · P7/P8 wishlist (TSK-697/703/706/713/715/716/722/723).

---

*The autonomous loop drains this top-down. When the host-completable surface is drained (as now), it validates / reconciles / audit-hardens and surfaces the owner-unblocks in section E, acting the moment a new board item, env-unblock, or owner decision appears. Priority lives HERE + on the board — issues the agent must know live in CLAUDE.md / docs/TASK_WORKFLOW.md / memory.*
