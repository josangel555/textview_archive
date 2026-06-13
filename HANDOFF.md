<!-- CLAUDE-HANDOFF v1 -->
# Handoff — wishlist wave complete; board fully owner-gated (documented HOLD)  (2026-06-12 ~22:00)

**Session:** claude-mdv (autonomous loop)  ·  **cwd:** `/Users/me/Documents/workspaces/claude/markdown_viewer`  ·  **branch/SHA:** `main` @ bde853f

## Mission
Owner directive 2026-06-12: drive rust-core toward Swift-core deprecation (epic TSK-651);
USER-FACING bugs first when present; never idle while background runs execute; work the
`tasked` board, validate with automated tests across the pyramid, keep main gate-green.

## Current state
- **Done & installed this wave** (every one at `fixed`, blocker `live-validation` — they need
  ONE owner relaunch+glance to reach `validated`):
  - TSK-284 drag-OUT (b2f66ba) · TSK-330 bookmark ⌘Z undo (51b6a12) · TSK-311 archive
    browsing (1a734b5+3ab1d5f) · TSK-259 font picker BOTH surfaces (f5f319a+ee09f99) ·
    TSK-282+666 sidebar fuzzy filter A+B (05dd9bd+ed848cd) · TSK-275 FPS/jank strip
    (e087051) · TSK-317 walkthrough deeplinks (ffd6869) · plus earlier-in-wave
    641/642 theming, 327 drag-to-snap, 637 outline, 638 print/PDF, 640 LSP rename.
  - **Rust-perf lane FULLY drained + VALIDATED**: 545/546/547/560/561/562/563/566/544.
  - TSK-659 (remote LSP spike) VALIDATED (doc-only deliverable). TSK-554/634/579/581/582
    VALIDATED earlier.
  - **VM full-suite sweep was CLEAN**: 4942 tests / 1 confirmed load-flake
    (TerminalForegroundBump, isolated re-run green); WebView lane 18/18 incl.
    EditorThemeParityTests (closes the editor-theme painted half).
- **In flight: NOTHING.** Working tree clean at bde853f, gate-green.
- **Next action: the loop is INPUT-BOUND.** Hold per TASK_WORKFLOW §5 until an owner
  answer/glance lands. Every remaining `reported` wishlist item is big / architectural /
  dep-gated (see "Open questions"). Do NOT manufacture marginal tests or speculative
  design docs — that's the paper-cut failure mode the SOP forbids.

## Key decisions & rationale
- **Documented HOLD, not busywork** (LOG +314): with all buildable wishlist items landed or
  owner-shaped, the honest move is a no-op that keeps main green + the decisions queue crisp.
- **Per-feature slicing**: every wishlist feature split headless-core-first (testable, lands
  in the gate) then live-glance tail held at `fixed` — the human is the only validator for
  painted SwiftUI/WebView pixels.
- **§2.5 honored throughout**: new consumers (sidebar fuzzy filter) route the PORTED rust
  engine via the adapter, never the Swift twin (source-pinned).
- **TSK-339/340 deduped into TSK-338** (one wishlist line → one consolidation decision).

## Gotchas / lessons (durable forms in LESSONS.md, dated 2026-06-12)
- A SURVIVING mutation isn't always a weak test — `NSItemProvider` URL-sniffs strings, so a
  "degraded" mutant was behavior-preserving. Probe empirically (`swift -e`) before
  strengthening. AND: confirm a mutant COMPILED (grep `Compiling <module>`) before trusting
  a teeth result — SwiftPM misses same-second rewrites.
- Weak source-pin needles match the WRONG site (call-site vs key construction; substring vs
  structural plist parse). Target the exact seam; demonstrate red. Bit me 3× this wave.
- **TSK-626 cross-module-enum-layout staleness**: adding a `FileCategory` case produced
  PHANTOM gate failures (png → text loader!) from stale test objects. Touch FileCategory
  referents FIRST, then diagnose — the first gate FAIL was the trap, not the change.
- The loopback `mdv-serve` at `/private/tmp/mdv-rust-target` must be rebuilt after wire/serve
  changes — the handshake rejects stale binaries by design (wire v2 bump proved it live).

## Files that matter (this wave's new surfaces)
- `Sources/ViewerCore/Archive/ArchiveCatalog.swift` — system-tool list+extract; zip-slip
  impossible (stdout pipes, app-chosen temp). `Sources/ViewerUI/ArchiveBrowserView.swift` — UI.
- `Sources/ViewerCore/FontPreference.swift` — fail-safe font resolution + fixed-pitch filter.
  Wired into `TextDisplayView.swift` (AttrKey + lineHeight use RESOLVED font) + CM6 via
  `setFontFamily` in `CodeMirrorBridge.swift` + `codemirror.html`.
- `Sources/ViewerUI/SidebarFilter.swift` + `SidebarModel.swift` (descendant cache, mode B).
- `Sources/ViewerUI/Observability/FrameRateMonitor.swift` — FPS/jank, nominal-cadence-judged.
- `Sources/ViewerCore/URLSchemeRouter.swift` — verb routing extracted from AppDelegate.
- `Sources/ViewerUI/ChromeTheme.swift` — the 4th theme surface (Palette consults it).

## Open questions / blockers (ALL owner — the entire remaining queue)
1. **3 parked product decisions** (costed options on each ticket): TSK-336 hook-event
   surfacing · TSK-338 plugins/MCP/walkthroughs consolidation · TSK-316 walkthrough mgmt.
2. **TSK-649 stage B**: per-engine Swift-twin deletion sign-off (docs/STAGE_B_DELETION_PLAN.md;
   indent first as template; find ICU-channel removal is the one behavior change needing OK).
3. **Supervised MountedPanesLRU session** (TSK-598 family): 5 captures indict per-switch pane
   teardown (MD-open lag, tab-switch, HEX ~1s, close residue, resize jank). Needs owner
   watching (WV race history). TSK-275's FPS strip is the live before/after readout.
4. **The glance batch** (one relaunch, one sitting — 13 installed features): see DECISIONS
   NEEDED in docs/AUTONOMOUS_PROGRESS.md item 4.
5. **TSK-306 validation bar** (carried): how to validate preview-tab Phase 2 — VM/wire/eyeball.

## Tracker (project `tasked`, agent `claude-mdv`)
- `waiting:human`: TSK-649, TSK-336, TSK-338, TSK-316. All `fixed` wishlist items above are
  `waiting:agent` but blocked `live-validation` (owner glance → task_validate).
- The board IS the queue; nothing needs reconciling — every item is in its true state.

## How to resume
1. Read `docs/TASK_WORKFLOW.md` in full. Then `task_list {project: tasked, waiting: human}`
   FIRST — an owner answer outranks everything and unblocks a full work stream.
2. **If a park was answered**: execute the chosen option (336/338/316 have costed options inline).
   **If a glance confirmed a feature**: `task_validate` citing the held evidence on that ticket.
   **If stage B signed off**: docs/STAGE_B_DELETION_PLAN.md, indent twin first.
   **If perf session scheduled**: it's supervised — wait for the owner to be watching.
3. **If still nothing answered**: HOLD per §5. Do NOT mine deep-wishlist items (dependency
   graph 280/319, CR agent 318, photo editor 320, sessions/multi-window 264/265) — they need
   owner shaping. A documented no-op is correct; re-confirm gate-green and stop.
4. Gates: `bash scripts/test-headless-gate.sh` (Swift) + `bash scripts/rust-core-gate.sh`
   (rust); after rust wire/serve changes rebuild `/private/tmp/mdv-rust-target` mdv-serve.
   Install after user-facing change: `bash scripts/build-app.sh debug --install`.
5. Parallel-work rule (owner, corrected twice): if a VM/background run is in flight, arm a
   monitor and pick up the next board item — a tick is NOT a no-op just because a run executes.
