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
- **T40: TSK-1562 s3 DONE (537f6878)** — run_task: allowlist-by-construction, shell-free env+argv
  spawn, 120/600s + 64KB bounds; e2e vs real make targets incl. hostile-id refusal. Census 36.
  Test-runner service COMPLETE.
- **T41: TSK-1563 s4 DONE (a7f0097c)** — review read-tools over ReviewQAContext/ReviewStore;
  most-recent default + availableReviews discovery; census 38. ALL FIVE services' buildable
  scope SHIPPED.
- **T42: TSK-1564 s5 audit DONE** — willRenameFiles: YES ts-ls+jdtls / NO sourcekit+pyright;
  client gap (fileOperations not advertised) found; build slice filed TSK-1565 (M). The
  agent-services epic is FULLY DISPATCHED (s1-s4 shipped, s5 audited+broken down).
- **T43: TSK-1565 s5-build DONE (17f145da)** — move_file: fileOperations advertised, will/did-
  RenameFiles client+pool, FileMover full-path form (extended the existing primitive), honest
  importFixup, dry-run default, census 39. THE AGENT-SERVICES EPIC IS BUILD-COMPLETE (7 new MCP
  tools this drain, census 32→39). Env-gated tail: live ts-ls/jdtls confirm (not installed here).
- **Next action:** the host-workable queue is DRAINED AGAIN. Options per the pool map: class-3
  spikes (691 agent-harness · 703/1155 action-history · 706 richtext · 713 diagrams · 715
  profiling — each spike auto-approved), waiting-lane reconciles, or TSK-697 epic-close summary.

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
