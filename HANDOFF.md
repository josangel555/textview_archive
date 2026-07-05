<!-- CLAUDE-HANDOFF v1 -->
# Handoff — mandates + web-for-content + stateful-core unblocked; MCP-into-running-app landing (2026-07-05)

**cwd:** /Users/me/Documents/workspaces/claude/markdown_viewer · **branch:** main (gate-green through be2a170f; TSK-1544 committing)

## Mission
Whole-core migration + rendering-stack policy + the four testing MANDATES, executed INLINE
(owner). PM model is migrating to PinBoard v4 (worker loop: main agent grooms/gates, Sonnet
executes; every ticket = complete contract with REQUIRED evidence classes — memory
`project_pm_v4_worker_loop`). The old "usability drain" park is superseded by these newer asks.

## What changed 2026-07-04→05 (all committed)
- **Fold gate flipped ON** (74d01932); formula display DESIGNED + edit box SHIPPED (768030fb,
  TSK-1215 fixed); Stage-B twin deletion UNBLOCKED — agent-driven UAT plan replaces soak
  (docs/STAGE_B_DELETION_UAT_2026-07-04.md, f3a43e42). Owner resolved: no-soak, formula display,
  eviction policy (TSK-589: dirty never evicts; clean LRU min(1–2GB, 200)).
- **Four testing MANDATES** codified (6c8cbe42): TEST_PYRAMID §MANDATES + CLAUDE.md block —
  per-surface matrix (TSK-1539), AX-everything (TSK-1543), agent-driven UAT, evidence-classes-in-
  tickets. AX TCC on the VM GRANTED (owner click); System Events proven insufficient → native
  AXUIElement adapter (TSK-1260/1261/1263) is the substrate.
- **Policy epic TSK-1524** "web for content, native for chrome, brain in Rust" + M1-M9 migrations
  (1525-1533: git diff/merge [dep: @codemirror/merge pending owner], CSV, XLSX, Word, TextDisplayView→CM6,
  hex, transcript/logs, git history) + allowlist guard (1534). BACKLOG has the map (38021ddb).
- **Stateful-core spike DONE** (TSK-1508→fixed, 6f955415): docs/research/stateful-core-spike-2026-07-04/
  DESIGN.md; slices TSK-1516-1523 under TSK-1117 (S5/S6 SUPERVISED ~2.5-3.5h owner total).
- **Meta-analysis** (be2a170f): docs/research/project-meta-analysis-2026-07-04/SYNTHESIS.md —
  v4 assessment + 6 DLD gaps; process tax ⅓ of commits; review/validated piles = serializer.
- **UAT findings:** TSK-1538 dark-theme scene paints nothing (owner: system-dark OK → likely
  content-only-by-design or scene bug); fold WV suite 2/2 green on flipped build.
- **MCP:** registered in ~/.claude.json (textview → --mcp-stdio). CanvasDemo built over MCP
  (docs/examples/CanvasDemo.canvas + -deck.html, 4e487567). Canvas M0-M6 remains built+parked
  for owner review (umbrellas 1344-1351 owner-decision).
- **Build dirs:** cargo target → ~/Library/Caches/mdv-rust-target (durable); dist/bin gets
  mdv-tui/web/serve via scripts/stage-frontends.sh; cargo aliases `cargo tui|web|serve` (67323303).

## IN FLIGHT — TSK-1544 (MCP into the RUNNING app)
Implementation COMPLETE, suite 6/6 green + teeth RED-proven; full headless gate running at
handoff-write. Files: Sources/ViewerCore/Automation/{MCPSocketListener,MCPSocketBridge}.swift,
main.swift (listener start in GUI launch after claudeMonitor branch; stop in
applicationWillTerminate; `--mcp-connect` early-pump at module scope + headless fallback),
Tests/ViewerCoreTests/Automation/MCPSocketListenerTests.swift. NEXT: gate log
tmp/gate-1544.log GATE_DONE rc=0 → commit all 4 files (TSK-1544, session trailer) →
task_record fixed with checks → then a release build (`build-app.sh release --install`)
gives the owner the socket endpoint + `claude mcp` config keeps working via fallback.
LESSON (this slice): socketpair+FileHandle test rig gave garbage fds — test the pump through
the REAL listener path; question the vehicle.

## Owner levers open
@codemirror/merge vendoring (unblocks M1/M2) · Canvas M0-M6 review · supervised sessions A/B
(after shadow-quiet) · TSK-838 flip · TSK-1287 dep · CLAUDE.md restructure proposal.

## How to resume (cold)
1. `git -C ~/Documents/workspaces/claude/markdown_viewer log --oneline -12` + `git status`.
2. If 1544 uncommitted: check tmp/gate-1544.log for `GATE_DONE rc=`; green ⇒ commit the 4 files
   + task_record TSK-1544 fixed; red ⇒ only non-bench failures count (TSK-1499 rule).
3. Then per BACKLOG order: Stage-B deletions per the UAT plan (fuzzy first) · TSK-1516/S1
   EditorSession · M6 TextDisplayView→CM6 (pattern-prover) · 1539 matrix guard.
4. Write ALL new tickets as worker-executable contracts with REQUIRED evidence classes
   (mandate #4; PM v4 memory). Work INLINE unless the owner says otherwise.
