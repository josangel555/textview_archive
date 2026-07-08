<!-- CLAUDE-HANDOFF v1 -->
# Handoff — drain phase T37 checkpoint (2026-07-07 20:26)

**cwd (canonical):** /Users/me/Documents/workspaces/claude/markdown_viewer (iCloud sync verified
OFF; if EVER re-enabled, relocate out of ~/Documents FIRST + park a Need-me) · **main @ 9a70297f**
· backup rsync target: /Users/me/Local_Docs/local_workspace/markdown_viewer/

## Mission
Drain the ticket board under the owner's 2026-07-07 BATCH WORK-LOOP mandate (BACKLOG §WORK-LOOP
MANDATE). All 25 batches ✅; the loop is in §AFTER THE BATCHES. PURE AUTONOMY: never ask inline —
every decision = task_park Need-me with homework, then move on. Never task_validate (owner
validates). One gate + one commit + board-record per work unit.

## Current state
- **Done:** 25/25 batches + 37 drain ticks. Ledger: ~20 host cores (all tested/gated/recorded);
  4 salvage features integrated, 1 rejected-superseded; the FULL daemon epic TSK-1553-1558
  (launchd activation + install path, idle-exit core+ticker, retire arbiter+wiring, reconnect
  policy, CoreTransport lib+bin seam, web thin-client slice 1); TSK-1559 MCP crash/gate-wedge
  fixed (3 layers — reader fd-cache, send raw-write(2), window-shrink+watchdog; gate reliable
  since); TSK-697 agent-services SPIKE delivered (docs/AGENT_SERVICES_DESIGN_2026-07-07.md).
- **State of record:** BACKLOG §RE-CURATED POOL MAP — the ~85 reported items in 4 classes:
  (1) VM/render tails sitting on TESTED models (unlock: TSK-1550 VM + TSK-1334 T5 grant),
  (2) 9 owner Need-me cards + dep gates, (3) design-first epics, (4) foreign/infra.
- **In flight:** nothing uncommitted; tree clean.
- **T38: TSK-1560 s1 DONE (5b5d6bc0)** — goto_definition + find_references on the async lane;
  CodeNav.navLocations pure mapping; 1-based agent inputs → 0-based LSP pinned by test; census
  32→34; the "Semantic/LSP code search" service is COMPLETE.
- **T39: TSK-1561 s2 DONE (630b23c1)** — rename_symbol, dry-run default; apply via the standard
  TSK-640 path now returning (applied,skipped); payload reports skippedFiles; census 35.
  Refactor:rename service COMPLETE.
- **Next action:** TSK-1562 (run_task — allowlisted to list_runnable_tasks, output capture,
  bounded runtime). Then 1563 review read-tools · 1564 move-file spike.

## Key decisions & rationale
- Drain-tick pattern: extract the PURE core under render/owner-gated features, host-test (+ a
  source-parsing DRIFT GUARD when mirroring a live file), record the render tail — never blind
  render claims. Primitives compose (OutputNaming → 3 consumers).
- mdv-serve NOT bundle-embedded (30MB vs 80MB cap ~72 used — cap bumps are owner budget);
  installs to ~/Library/Application Support/MarkdownViewer/bin/ via install-app.sh --with-daemon.
- Salvage: cherry-pick by SHA (reaped branches' commits survive in the object DB) → central gate
  → commit; CHECK MAIN FIRST (feeds 4577ce95 would have regressed the tested quiet-on-success
  contract). TSK-1506 wf-5/6/7 WIPs SUPERSEDED by landed cores — do NOT integrate.

## Gotchas (full list LESSONS.md tail)
- FileHandle `.fileDescriptor`/`.availableData` accessors raise UNCATCHABLE ObjC exceptions when
  closed under a blocked reader — cache the fd at init, raw read(2)/write(2) (both MCP paths fixed).
- Don't kill-9 gate workers (orphan holds .build-gate lock + MCP socket → re-wedge); kill the
  `bash scripts/test-headless-gate` wrapper. Scoped verify: `swift test --skip MCPServerWedgeTests
  --filter ViewerCoreTests`.
- rust-core: cargo needs `--manifest-path rust-core/Cargo.toml`; clippy denies indexing_slicing /
  Instant::now (sleeps-are-the-clock pattern) / one-unsafe-op-per-block / collapsible_if
  (let-chains); `gen` RESERVED in edition 2024; new ffi module → build-rust-core.sh restage.

## Files that matter
- `BACKLOG.md` §RE-CURATED POOL MAP + §T37 replenishment — the queue map.
- `docs/AGENT_SERVICES_DESIGN_2026-07-07.md` — the design the next slices implement.
- `Sources/ViewerCore/Automation/MCPToolCatalog.swift` — where s1-s4 tools land (who_calls
  precedent at :229, isAsyncTool :240).
- `rust-core/crates/serve/src/{lifecycle,transport}.rs` — the daemon cores.
- `scripts/install-app.sh --with-daemon` + `scripts/com.markdownviewer.mdv-serve.plist.template`.

## Open questions / blockers (all parked as board Need-mes — none block the loop)
9 owner cards: 508 dot-view · 1149 feeds-UI q · 1155 action-history architecture · 1200
editor-scroll real-vs-harness · 1322 paste repro · 1413 menu eyeball · 1449 surfaces · 1471
log-patterns finish-or-cut · 1540 WV-host trial. Plus dep gates (835/1137/1525-26/1287) and the
two MASTER UNLOCKS: TSK-1550 (VM ssh restore) + TSK-1334 (T5 Screen-Recording re-grant).

## Tracker
Fully reconciled tick-by-tick; every drain item at `fixed` with commits+checks (owner validates).
This tick: TSK-697 → fixed (spike); TSK-1560-1564 filed as its children (complete contracts).

## How to resume (cold)
1. `cd /Users/me/Documents/workspaces/claude/markdown_viewer && git log --oneline -3 && git status`.
2. Read BACKLOG §WORK-LOOP MANDATE + §RE-CURATED POOL MAP (+ §T37 replenishment); this file.
3. Take TSK-1560: task_get first (recon), implement per docs/AGENT_SERVICES_DESIGN_2026-07-07.md
   §s1 (copy the who_calls pattern), test vs MDVFakeLSPServer, then ONE
   `bash scripts/test-headless-gate.sh` (GATE_DONE rc marker in tmp/), commit with the
   Claude-Session trailer, board-walk to fixed, update this file + rsync backup.
4. If the VM returns (TSK-1550): switch to the class-1 render-tail queue top-down instead —
   every ticket names its tested model + remaining view work.
