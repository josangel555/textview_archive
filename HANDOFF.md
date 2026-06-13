<!-- CLAUDE-HANDOFF v1 -->
# Handoff — RUST-CORE Stage B (twin deletion) is the active lane; #1 indent done  (2026-06-13)

**Session:** claude-mdv (autonomous loop)  ·  **cwd:** `/Users/me/Documents/workspaces/claude/markdown_viewer`  ·  **branch/SHA:** `main` @ `ed2821a` (+ log commit). Latest tick: TSK-626 validated (§1.5 drain — header-staleness guard now has a hermetic Process-driven regression test; `scripts/lib/restage-header.sh`).

## Mission
Owner away until ~noon 2026-06-13; autonomous chipping. USER-FACING bugs are drained; the wishlist
minor-feature wave is in flight (748/763 at review). **HIGHEST-VALUE LANE RIGHT NOW: TSK-649 Stage B — the
owner-approved Swift-twin DELETION endgame ("deprecate swift core").** Validate across the pyramid (human not
in loop); keep `main` headless-gate-green; land per item on the linear trunk. Read `docs/TASK_WORKFLOW.md`
every firing (§0.5 spike/design autonomy + chipping order; §1.5 validation-drain outranks new work).

## ⭐ ACTIVE LANE: TSK-649 Stage B — delete the Swift engine twins (owner-approved 2026-06-13)
The owner resolved TSK-649's park: **"Approve policy + batch 1-4 (indent/hexSearch/hex/diff); review 5-9
individually."** Stage A (all 10 caps default-ON) is done + soaked. Stage B deletes the now-dead twins per
`docs/STAGE_B_DELETION_PLAN.md`, one package per engine.
- **#1 indent — DONE + VALIDATED (TSK-808, `1e2b557`).** The clean template.
- **#4 diff — DONE + VALIDATED (TSK-809, `954f1d8`).** Also clean (twins adapter-only, fully deleted).
  Bigger blast radius (12 test files): A/B → golden snapshots, 8 fixture suites retargeted to the adapter,
  twin tests + bypass audit retired, seam/obs tests reparented to `.csv`.
- **#2 hexSearch · #3 hex — PARKED (TSK-810, owner-decision).** NOT clean: the Swift engine has a live
  non-gated consumer (hexSearch click-highlight `HexSearchEngine.find(pattern:)`; hex un-ported windowed
  `HexDumpBuilder`), so the "delete twin / no fallback" model can't apply as-is. 3 options framed; recommend
  (A) keep-fallback + retire-gate. **Do NOT start #2/#3 until the owner answers** — the call sets the pattern.
- **#5-9 (csv/fuzzy/find/transcript/markdown) — each needs individual owner review** + a named caveat (csv
  DocId, fuzzy FileTreeFilter per-node, find ICU-fallback REMOVAL = behavior change, transcript
  ClaudeSessionIndex helpers, markdown sanitizer/mermaid/TS spans stay) — several share #2/#3's carve-out shape.
- **The template pattern** (proven on #1): delete twin source → collapse adapter to a direct `mdvCore*` call
  with a safe degraded value + loud `Obs.error` (no Swift fallback) → retire the `RustCoreCapability` gate
  case + env var + Settings toggle (KEEP the ABI bit in `CoreCapabilities` — bits are ABI) → freeze the A/B
  suite to a GOLDEN suite (frozen values, no Swift oracle) + retarget/retire the twin's unit tests → headless
  gate + golden teeth. `RustCoreSeamTests` `allCases` loops adapt automatically to a removed gate case.

## Standing directives (2026-06-13)
- **Spike + design AUTO-APPROVED** (TASK_WORKFLOW §0.5 / memory `feedback_spike_design_autonomy`): never
  `task_park` just because something needs design/an-approach-decision. Re-surface ONLY a genuine dep
  approval / true undifferentiated ambiguity / hard blocker, post-spike.
- **Chipping order:** regressions → bugs → minor-features(no-design) → epics(spike→design→ship) → very-large.
- **Per-tick cadence:** land 1–2 items per tick with teeth; keep `main` green; commit + log each.
- **Validation split:** model/pure-logic → self-validate (host). Render/event/concurrency (SwiftUI pixels,
  AppKit key routing, off-main) → host-test the LOGIC, hold at `review` for the VM. Don't over-claim validated.

## DONE this session (minor-feature wave — 2 items, 4 commits)
- **TSK-748 → review** (3 commits): file-info **multi-algo checksums** + responsive copy button.
  - `2e1d345` ENGINE: `FileChecksum` generalized to `ChecksumAlgorithm` (CRC-32/MD5/SHA-1/SHA-256/SHA-512)
    — generic CryptoKit fold + hand-rolled streaming CRC32 (no new dep). Pinned to published vectors.
  - `2c43d0a` MODEL: `MetadataChecksumModel` algorithm-parameterized, (url,algorithm) stale-completion
    guard; `metadata-set-checksum-algorithm` verb + `algorithm` in dump projection; Picker + dynamic labels.
  - `d3a469b` COPY FEEDBACK: `copyHash()` via injectable `PasteboardIO`, transient `justCopied` → green
    "Copied!" self-clears 1.2s. 13 model + 8 engine host tests, teeth on 3 paths.
  - **(c) "metadata for all formats" SPLIT OUT → TSK-807** (needs a FileCategory coverage-inventory spike).
- **TSK-763 → review** (`885cb7b`): recents grey containing-folder hint. `HistoryEntry.parentFolderLabel`
  (home→~, root→/, nil for bare name) rendered tertiary-grey in `RecentRow`. 4 host tests, teeth shown.

## Earlier this session (pre-minor-feature)
Wishlist bug bucket FULLY DRAINED (TSK-728..744, 14 fixes; 8 validated, 6 in the VM review queue, 743 awaiting
owner A/B). Wishlist intake via ultracode workflow (184 lines → 136 tickets). VM FULLY UNBLOCKED (owner's 6GiB
+ Screen-Recording; TSK-451 closed). Spike docs + intake triage committed `babbe31`
(`docs/research/*-2026-06-13/`). rust-core: TSK-572/570 validated.

## VM REVIEW QUEUE for the owner's noon pass (one UI/live session validates all)
Render/event/concurrency items held at `review` — `task_list {project:tasked, state:review}`:
- Bug bucket (6): **734·728·730·738·736·741**.
- Minor-feature (2 new): **748** (checksum Picker shows 5 algos · switch clears hash · per-algo digest ·
  Copy→green "Copied!" reverts ~1.2s) · **763** (recent row shows grey folder; same-named files differ).

## Owner decisions waiting at noon (`task_list {waiting:human}` + below)
- **743 A/B**: scroll "preserve" — independent-scroll done; "remember-on-return" needs a per-URL store
  (recommend confirming interpretation). Sibling filed: TSK-806 (split-pane).
- **Migration plan §6** (`docs/research/rust-migration-plan-2026-06-13/PLAN.md`) — 3 calls (TSK-775).
- **Terminal Tier-D** (TSK-781). **Dep approvals**: 584/585/587/399.

## How to resume
1. Read `docs/TASK_WORKFLOW.md`. Stage B's CLEAN packages are done (#1 indent TSK-808, #4 diff TSK-809,
   both validated). **#2 hexSearch + #3 hex are PARKED on TSK-810 (owner-decision) — do NOT start them until
   the owner answers** (the carve-out fallback model). #5-9 also need owner review. So Stage B is owner-gated
   for now → **pick another lane** (don't idle). Good headless picks: the `[WISH][minor-feature]` bucket
   (TSK-745 new-tab recents · TSK-757/678 shortcut catalog · TSK-770 Find-bar Replace/ReplaceAll), or the
   `fixed`-lane validation drain (§1.5) for any host-validatable ticket. Template for a clean Stage B engine
   (when unblocked): `TSK-808`/`TSK-809`.
2. **Secondary: the `[WISH][minor-feature]` bucket** (when Stage B 1-4 is done or you want variety). Headless
   picks: **TSK-745** (new-tab recents — `model.recents` exists), **TSK-757/678** (shortcut catalog + Help),
   **TSK-770** (Find bar Replace/ReplaceAll), **TSK-724** (Recent Locations). TSK-573 (web palette → core)
   is triaged but its honest fix is a large CSS var() refactor that needs VM pixel proof — deprioritized.
3. Gates: `bash scripts/test-headless-gate.sh` (host, one at a time) · `bash scripts/rust-core-gate.sh`
   (only if `rust-core/` source changed — Stage B twin deletions are Swift-side, so the headless gate covers
   the golden suites). VM: rsync + `bash scripts/test-in-vm.sh test --filter <Suite>` (headless) /
   `MDV_VM_GUI_SESSION=1 MDV_VM_SUDO_PASS=<vm-sudo-password> ... --filter <T5 suite>` (pixel).

## Gotchas / lessons (also in LESSONS.md)
- The MetadataChecksumModel state machine is the host pixel-equivalent seam: a script verb +
  dump-projection lets the T4 UAT assert the compute/algorithm/copy outcome cross-process without rendering.
  Pattern to reuse for any live-gated UI feature with a model behind it.
- `task_advance` walks reported→…→target but takes NO commits param — attach the SHA via a `task_comment`
  after, or `task_record` (with commits) before advancing. The triage step needs a `note`; progress→fixed→
  review needs a `summary`.
- AUTONOMOUS_PROGRESS.md LOG entries are NOT strictly monotonic on disk (a +318..+325 block sits below the
  +350 region). Find the max with `grep -oE '^## LOG \+[0-9]+' | sort -n | tail` and prepend the new entry
  directly above the current max.
- Demonstrate teeth every fix: mutate→red (confirm the mutant COMPILED: grep `Compiling <module>`)→restore.

## Tracker
- tasked / TSK-748 (review, 3 commits) · TSK-763 (review, 885cb7b) · TSK-807 (reported, new split for metadata-all-formats).
