<!-- CLAUDE-HANDOFF v1 -->
# Handoff — remote-core program: soak stage A live (csv/indent/diff ON); A0 complete  (2026-06-12)

**Session:** claude-mdv (autonomous loop)  ·  **cwd:** `/Users/me/Documents/workspaces/claude/markdown_viewer`  ·  **branch/SHA:** `main` @ 7d042c0

## Mission
Owner directive 2026-06-12: rust-core to the point Swift core is deprecated; deploy
RUST-ONLY on a remote server, thin Swift UI (epic TSK-651). Bugs deprioritized by owner.

## Current state
- **Engine ports: ALL DONE** (csv/diff/hex/indent/cm-edit + find/fuzzy/transcript/
  markdown + mermaid host TSK-661). No reserved capability bits.
- **Adapters: ALL CONSUMED (A0 complete, 23b29ca).** Soak stage A LIVE: csv/indent/diff
  ship DEFAULT-ON (55bb765, installed to /Applications). Off-switches: MDV_RUST_<CAP>=0
  or Settings toggle; explicit user OFF survives the flip (object(forKey:) tri-state).
- **CoreTransport seam landed** (6c912c3, TSK-652 at progress blocked_by TSK-653):
  all 7 frame wrappers route through CoreTransportRegistry; RemoteTransport = stage 2.
- Validated this wave: TSK-630/631/632/633/634/645/646/647/648/661. In progress:
  TSK-649 (soak; flip plan on ticket: hex family → wave-1 four → cmEdit LAST),
  TSK-652 (stage 2 with mdv-serve).

## Next actions (the recorded order, TSK-651 comment)
1. TSK-655 watch/push protocol DESIGN (before mdv-serve hardens).
2. TSK-653 mdv-serve (frames over ssh-forwarded socket — owner ruling: no TLS dep;
   terminal = ssh/tmux; LSP = server-side processes piped, see TSK-659 re-scope).
3. TSK-654 fs family (windowed read — Phase-1 contract), TSK-656/657/658, TSK-660
   TreeSitter port (crates/highlight EXISTS, owner-approved deps).
4. Flip rounds on TSK-649 as soak proves quiet; stage B twin deletion is owner-gated.

## Gotchas
- Tests that encode gate defaults go red on every flip round — migrate to env-pinned
  (MDV_RUST_X=0) + shipped-default pins (six already migrated, see 55bb765).
- The mermaid/code chunk contract: only raw_html+code cross to Swift; sentinel splice
  is segment-based (injection-proof); unknown kinds → escaped text.
- SwiftPM staleness: touch Sources/ AND Tests/ referents after cross-module layout
  changes (CLAUDE.md rule). Bench-only gate failures under load are flaky — re-run.
- Board lifecycle: restate→triage→claim→record(fixed)→task_validate with checks.

## Tracker
TSK-649 progress (soak), TSK-652 progress (blocked_by 653), TSK-651 epic + children
653-660 reported, TSK-643 egress parked, TSK-650 mermaid-render bug parked (owner),
TSK-452 statusbar parked (owner: ignore bugs). Owner parks unchanged: 322/598/608/270/372.

## How to resume
1. Read docs/TASK_WORKFLOW.md in full (991bad5 — unchanged).
2. git log --oneline -5; tree clean except .profiling/.
3. Pick from "Next actions" above; board via mcp__tasked__* (agent claude-mdv).
4. Soak watch: Obs `rust-core` channel logs every fallback; a noisy engine = bounce
   its default OFF and file the regression.
