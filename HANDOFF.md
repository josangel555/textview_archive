<!-- CLAUDE-HANDOFF v1 -->
# Handoff — rust-perf lane drained; theming COMPLETE (4 surfaces); owner glances queued  (2026-06-12 ~19:10)

**Session:** claude-mdv (autonomous loop)  ·  **cwd:** `/Users/me/Documents/workspaces/claude/markdown_viewer`  ·  **branch/SHA:** `main` @ 18b3773

## Mission
Owner directive 2026-06-12: rust-core to the point Swift core is deprecated; rust-only
remote server, thin Swift UI (epic TSK-651). USER-FACING bugs first when present.

## Current state (this wave, after the owner-answer sweep)
- **Owner answered a park batch (2026-06-12):** TSK-359 → wontfix per "leave as is";
  TSK-608 → validated riding TSK-614 (owner confirmed ROW COUNTS); TSK-327 re-scoped
  by owner re-report ("still not draggable") → THREE roots fixed (un-declared
  exported UTI in Info.plist, no drag source on accordion headers, none on rail
  icons; 2aab064) → at review for the owner's drag try-out.
- **Rust-perf lane fully drained + validated:** TSK-566 (string_slice lint wall,
  33a552d), TSK-561 (zero-copy borrowed wire decode ×6 seams + the gutter finally
  routes the rust diff engine, 5d4d5db), TSK-546 (TableArena — session store is 2
  heap blocks, arena/vec filter parity via shared CellMatcher, d764ed8), TSK-563
  (diff per-element records positional, **WIRE v2**, 37f2d48). Remaining: TSK-544
  (TUI redraws — front-end lane, last resort by policy).
- **THEMING COMPLETE — all four surfaces follow the selected theme:** stage 3 editor
  (CM6 setTheme dedupes on dark+palette, 20b842f) + stage 4 chrome
  (ChromeTheme/ChromeColors; Palette.textBackground/windowBackground/
  sidebarPanelBackground consult it, fallback derivation for slot-less themes,
  VS Code workbench-color mapping; 52db383). TSK-641+642 at fixed,
  blocker live-validation (owner glance / VM pixels).
- **Wire v2 note:** the loopback mdv-serve binary at `/private/tmp/mdv-rust-target`
  must be REBUILT after wire changes — the handshake guard rejects stale binaries
  ("wire_version_skew") by design; third hit of this trap.
- **VM full-suite run IN FLIGHT at handoff time** (host log `/tmp/vm-test-*.log`,
  started ~19:05) — the standing post-substantive-change sweep. Process results on
  resume if finished: chase non-bench failures; remember the documented load-flake
  class (re-run isolated before believing a red).

## Key decisions & rationale
- usize (not u32) arena offsets — correctness must not depend on caller Limits < 4 GiB.
- Positional wire elements ONLY for the diff family this round; envelope stays named
  (remote debuggability). find/transcript/runs measured-before-converted (on TSK-563).
- Chrome theming scope: the three main Palette surfaces only; semantic colors stay
  system-native (macOS-citizen look, per the ticket).
- TSK-642 held at fixed deliberately: same owner-glance bar as 327/641 (thin Button →
  closure hop is the only untested link; importer pipeline fully host-guarded).

## Gotchas / lessons (durable forms in LESSONS.md)
- An exported UTType MUST be declared in Info.plist UTExportedTypeDeclarations or
  drag/drop dies silently (TSK-327 root 1).
- Substring pins are fooled by suffixed mutants — parse plists/structures for config
  pins (the TSK-327 teeth check caught my own weak assertion live).
- rmp-serde's borrowed reader has no consumed-bytes API — strict end-of-input via
  the IgnoredAny second-value probe (wire.rs decode_borrowed).
- Stale test objects after a header/public-type change SIGSEGV (TSK-626) — the build
  script auto-touches now (it fired on the wire-v2 bump); suspect staleness first.
- Teeth must FAIL, never crash (zombie-xctest wedge); self-referential oracles give
  false greens; the loopback mdv-serve must be rebuilt after serve/wire changes.

## Open questions / blockers (owner)
- TSK-327: try the three drag sources after relaunch (review).
- TSK-641/642: pick a theme after relaunch — the whole window should follow; name
  any region that stays light (the stale-chrome/non-republishing-view class).
- TSK-637/638/640: rendered-surface glances (md outline panel, print/PDF, rename/
  code-actions against a live LSP).
- TSK-598 family: schedule the supervised MountedPanesLRU session (five captures
  indict per-switch pane teardown).
- TSK-649 stage B (Swift grammar deletion) remains waiting:human.

## Tracker
- Validated this wave: TSK-546/561/563/566/608. Review: TSK-327. Fixed+held
  (live-validation): TSK-637/638/640/641/642. Wontfix: TSK-359. Progress(gated):
  TSK-591/592/598/601 (supervised session).

## How to resume
1. Read docs/TASK_WORKFLOW.md; `task_next {agent: claude-mdv, project: tasked}`;
   check `task_list {waiting: human}` — owner answers outrank everything.
2. If the VM run finished: tail the newest `/tmp/vm-test-*.log` — `Executed` lines;
   non-bench failures get chased; where the run covers a held ticket's claimed lane
   (WebView theme parity, outline panel), attach it as evidence.
3. Gates: `bash scripts/test-headless-gate.sh` + `bash scripts/rust-core-gate.sh`;
   after rust wire/serve changes also rebuild `/private/tmp/mdv-rust-target`'s
   mdv-serve.
4. Soak watch unchanged: Obs `rust-core` channel + audit.jsonl; a noisy engine →
   bounce its default OFF in RustCoreGates.defaultEnabled + file the regression.
