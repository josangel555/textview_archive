<!-- CLAUDE-HANDOFF v1 -->
# Handoff — §5 push pipeline END-TO-END; TSK-640 headless-complete; owner gates queued  (2026-06-12 ~13:45)

**Session:** claude-mdv (autonomous loop)  ·  **cwd:** `/Users/me/Documents/workspaces/claude/markdown_viewer`  ·  **branch/SHA:** `main` @ 953acf0

## Mission
Owner directive 2026-06-12: rust-core to the point Swift core is deprecated; rust-only
remote server, thin Swift UI (epic TSK-651). Bugs deprioritized by owner.

## Current state (since the stage-A handoff @ 339146a)
- **§5 PUSH PIPELINE COMPLETE end-to-end (validated):** TSK-662 fs.watch/unwatch in
  mdv-serve (duplex connection, std-only polling watcher, debounce-by-tick,
  burst→resync, per-sub monotonic seq) + TSK-663 transcript.follow (tail-follow with
  WIRE-FORCED redaction — never raw lines; torn-line carry; truncation resync) +
  TSK-664 RemoteTransport client (reader-thread demux, subscribe/unsubscribe, bounded
  pre-registration buffer, 30s call deadline, SO_NOSIGPIPE hardening, onClose).
- **TSK-640 LSP rename + code actions: headless surface COMPLETE, at `fixed`**
  (894a7be request plumbing, 9bed97a rename model action w/ snapshot-guarded
  WorkspaceEdit apply across open tabs — unopened files NEVER written, d6391b7 code
  actions: union decode, pool route, fetch/apply edit-bearing-only). Remaining: the
  live UI tail (menu entries + name prompt + action picker — VM lane).
- **TSK-660 TreeSitter→rust stages 1+2 landed, PARKED on the owner:** rust highlight
  is a core capability (MDV_CAP_HIGHLIGHT=1<<14, UTF-16 app-contract runs mirroring
  CaptureMap, serve dispatch) + RustHighlightAdapter behind `.highlight` gate DEFAULT
  OFF, all three tokenize consumers routed, TSK-410 predicate fix pinned. THE GATE:
  release bundle 63MB/exec 43MB vs 48/26 caps (grammar C objects enter the exec).
  Options on the ticket: transient bump / dlopen dylib / feature-off-in-app.
  Stage 3 (+10 grammar crates for 22-lang parity, list needs pre-approval) + stage 4
  (Swift grammar deletion, reclaims double-carry) queue behind the decision.
- **TSK-628 advisory watch: VALIDATED after the drain caught it had NEVER worked**
  (herestring overrode the matcher heredoc → permanent silent PASS; no GitHub remote
  → the nightly never runs; no unauth API fallback). Fixed + hermetic fixture seam +
  4 in-gate tests (25dc089).
- **VM lane green on the wave:** 4886 tests, 0 genuine failures (the 2 reported =
  the documented load-flake class, both isolated-green; ViewModesUAT/test_VM_02 added
  to the known list).
- Validated this run: 628, 662, 663, 664. At fixed: 640 (live tail), 637/641/642
  (VM/glance tails), 649 (stage B owner), 660 (progress, owner-parked).

## Next actions
1. **Owner gates (parked, pinged):** TSK-660 bundle-cap decision (63/43 vs 48/26 —
   release builds FAIL the size gate until answered); TSK-649 stage B per-engine
   deletion sign-off; GUI glance batch (References menu/outline/theme picker).
2. App-level push consumers: FolderWatcher/monitor remote mode over
   RemoteTransport.subscribe (new ticket; the transport seam is ready).
3. TSK-659 LSP pipe spike (park-grade per its own title — triage into a plan first).
4. Live-gated tails: TSK-640 UI (rename prompt/code-action picker), 638 print/PDF,
   639 multi-cursor, 641 stage-2 VM check.
5. Search streaming (protocol §5 third family) if the owner wants it before remote v1.

## Gotchas (LOG +263..+272; LESSONS.md has the durable forms)
- **Teeth must FAIL, never crash:** a force-unwrap in a test crashed xctest under a
  mutation; swift-test wedged FOREVER on the zombie child (signature: ~0 CPU, defunct
  child, no compilers). XCTUnwrap in assertion paths; check for orphaned mdv-serve
  daemons after killed runs.
- **Self-referential teeth false green:** computing a test's expected values through
  the same helper it pins (utf16_len) — use an independent std oracle + literals.
- **heredoc + herestring on one command: the LAST stdin redirection wins** (the
  advisory-watch silent-PASS class). `|| fail` any command substitution that gates a
  verdict.
- Sockets need SO_NOSIGPIPE at dial or a dead peer SIGPIPE-kills the app.
- A unix-socket test client must drop ALL fd clones or the server never sees EOF
  (join() wedge).
- The loopback suites spawn `/private/tmp/mdv-rust-target/debug/mdv-serve` — REBUILD
  it after serve changes or hello-mask/method tests fail stale.
- Bash auto-backgrounds long commands in this harness; their tail output may lag —
  prefer foreground for short test runs, read task output files for the rest.

## How to resume
1. `docs/TASK_WORKFLOW.md` in full; board via `mcp__tasked__*` (agent claude-mdv).
2. `git log --oneline -15` for the wave; gates: `scripts/test-headless-gate.sh` +
   `scripts/rust-core-gate.sh`.
3. Check `task_list {waiting: human}` first — if the owner answered TSK-660/649, that
   work outranks everything else.
4. Soak watch unchanged: Obs `rust-core` channel + audit.jsonl; a noisy engine →
   bounce its default OFF in RustCoreGates.defaultEnabled + file the regression.
