<!-- CLAUDE-HANDOFF v1 -->
# Handoff — minor-feature wave underway (TSK-748, TSK-763 landed → review); owner decisions at noon  (2026-06-13)

**Session:** claude-mdv (autonomous loop)  ·  **cwd:** `/Users/me/Documents/workspaces/claude/markdown_viewer`  ·  **branch/SHA:** `main` @ `885cb7b`

## Mission
Owner away until ~noon 2026-06-13; overnight autonomous chipping of the 2026-06-13 wishlist. USER-FACING
bugs first (DONE — whole bug bucket drained), now the `[WISH][minor-feature]` bucket. Validate across the
pyramid (human not in loop); keep `main` headless-gate-green; land per item via direct commit on the linear
trunk. Read `docs/TASK_WORKFLOW.md` every firing (esp. §0.5 spike+design autonomy + chipping order).

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
1. Read `docs/TASK_WORKFLOW.md`. `task_list {project:tasked, state:reported, q:"[WISH][minor]"}` for the bucket.
2. **Continue the `[WISH][minor-feature]` bucket** per chipping order. Headless-friendly next picks
   (model layer host-testable, render held at review): **TSK-745** (new-tab recent files — `model.recents`
   exists), **TSK-757/678** (keyboard-shortcut catalog + Help page — a typed catalog + completeness test),
   **TSK-770** (Find bar Replace/ReplaceAll — replace engine host-testable), **TSK-724** (Recent Locations
   popup). Avoid items needing live-only validation with no model seam.
3. Gates: `bash scripts/test-headless-gate.sh` (host, one at a time) · `bash scripts/rust-core-gate.sh`.
   VM: rsync + `bash scripts/test-in-vm.sh test --filter <Suite>` (headless) /
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
