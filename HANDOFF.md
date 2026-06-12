<!-- CLAUDE-HANDOFF v1 -->
# Handoff — STAGE A COMPLETE: all ten engines default to Rust; stage B is owner-gated  (2026-06-12)

**Session:** claude-mdv (autonomous loop)  ·  **cwd:** `/Users/me/Documents/workspaces/claude/markdown_viewer`  ·  **branch/SHA:** `main` @ 339146a

## Mission
Owner directive 2026-06-12: rust-core to the point Swift core is deprecated; rust-only
remote server, thin Swift UI (epic TSK-651). Bugs deprioritized by owner.

## Current state — the program is nearly converged
- **STAGE A COMPLETE (TSK-649 at fixed):** all TEN capabilities route Rust by default
  (rounds: csv/indent/diff → hex/hexSearch → find/fuzzy/transcript/markdown → cmEdit).
  Swift twins are fallback-only. Off-switches: MDV_RUST_<CAP>=0 / Settings toggles.
- **Remote-core spine VALIDATED:** mdv-serve (engine methods + fs/git/search/
  transcript.list families, root containment, redaction FORCED at the wire) +
  RemoteTransport (loopback A/B byte-equal). Protocol doc: docs/REMOTE_PROTOCOL.md.
- **Validated this run:** TSK-630-634, 645-648, 652-654, 656-658, 661, 636 (audit log),
  554, 635. At fixed: 649 (soak), 628 (needs one green nightly), 637 (outline — VM
  glance), 641/642 (theming owner-usable; CM6+chrome surfaces = recorded tail), 655
  (protocol design at review).
- **Soak bundle installed**; audit log live at ~/Library/Application Support/
  MarkdownViewer/audit.jsonl.

## Next actions
1. **STAGE B (the endgame, owner-gated per engine):** prepare deletion packages —
   gate removal + Swift twin deletion + test retargeting for: CSVParser, diff parse,
   HexDumpBuilder/HexSearchEngine, IndentDetector, CMEditApplier, FindEngine,
   FuzzyMatcher, ClaudeLogParser, HTMLVisitor (structural). One package per engine,
   owner signs each.
2. TSK-660 TreeSitter port (crates/highlight EXISTS, deps approved; retires the
   markdown 'code' chunk; likely fixes TSK-410; bundle-size win).
3. The push loop (fs.watch + transcript.follow + search streaming, protocol §5).
4. TSK-659 LSP pipe (re-scoped: server-side processes piped; ssh = tunnel).
5. Live-gated tails: 641 stage-2 VM check, 638 print/PDF, 639 multi-cursor, 640 LSP
   rename; fixed-lane drain (TSK-468 etc.).

## Gotchas (this run's lessons; full entries in the LOG +237..+260)
- Flip rounds redden tests that ENCODE defaults — env-pin gate-off tests; the probe
  pool shrinks every round (now empty: leak probe is INVERTED, fallback uses env-0).
- mdv-serve test fixtures need per-instance temp dirs (parallel tests collide).
- grep -c returning 0 exits 1 — don't let it fail a wrapper script.
- Bench (FoldBench) + LSPPoolSmoke tests flake under build load — re-run before chasing.
- The acceptance-test skip path must NEVER swallow real failures (the loopback suite's
  handshake-failure-was-a-skip false green; fixed: binary-exists+failure = XCTFail).

## How to resume
1. docs/TASK_WORKFLOW.md in full (991bad5 unchanged); board via mcp__tasked__*.
2. git log --oneline -10 for the wave; gates: scripts/test-headless-gate.sh +
   scripts/rust-core-gate.sh (serve crate is in default-members).
3. Pick from Next actions; stage B packages are the highest-value owner-facing work.
4. Soak watch: Obs `rust-core` channel + the audit log; a noisy engine → bounce its
   default OFF (one line in RustCoreGates.defaultEnabled) and file the regression.
