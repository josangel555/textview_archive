<!-- CLAUDE-HANDOFF v1 -->
# Handoff — launch blog + download page + OSS-prep decisions (2026-08-08)

**cwd:** /Users/me/Documents/workspaces/claude/markdown_viewer · **branch/SHA:** main @
`e36db17c`. Clean tree; only the 4 protected untracked files (OwnerWishlist.md/.bak,
Untitled.txt, archive/Untitled.txt — NEVER touch). /Applications/TextView.app = RELEASE at
the 08-05 batch head (titlebar sessions, image-save fix, footer reorg — see below).

**THIS SESSION (2026-08-08) shipped OUTSIDE the app repo:**
- **Launch blog post** (Zola): `<CloudDocs>/workspaces/claude/blog/content/textview-native-macos-editor-built-by-an-agent.md`,
  built into `<CloudDocs>/workspaces/web/josangel.com/blog/…`. Voice matches the `tasked` post.
- **Download page**: `<CloudDocs>/workspaces/web/josangel.com/textview/index.html` (inline-SVG
  logo, features grid, 4 real VM screenshots in `textview/shots/`, download →
  github.com/josangel555/mvd_dist, "open source coming soon (MIT)"). Homepage now lists it.
  Both sites are CloudDocs-synced, NON-git (Cloudflare deploy) — nothing to commit there.
  Recipe + screenshot method in memory `blog-and-download-site`.
- **IN the app repo (committed e36db17c):** `LICENSE` = MIT + BACKLOG § "★ OSS-PREP QUEUE".

**OSS-PREP (owner decisions 2026-08-08 — the next real work, BACKLOG §OSS-PREP O-1..O-6):**
MIT ✓ · publish with **FULL history (do NOT squash — owner corrected)** ⇒ history-rewrite to
scrub VM creds (git-filter-repo, needs dep-approval) · notarization NOT needed for source ·
**O-1 MCP socket default-off + token auth** (+ run_verb fence + task-runner env scrub) ·
**O-2 Canvas WebView fence** · **O-3 buildability + bootstrap + README/CONTRIBUTING/SECURITY** ·
**O-4 CI portability** · **O-5 scrubbed full-history export** · **O-6 data-safety tail**
(subagent-verified: CM6 flush-before-read PARTIAL, session-drain FIXED, HotExitSpill silent-fail).

**Standing app queue (BACKLOG § "★ OWNER INTAKE 2026-08-01", I-## ids, board still down):**
remaining big items = I-14 AutoSave (opt-in), I-09 web-migrate wave, I-16b/c/d strip/footer
slices, I-15 LSP occurrences, I-07 pointer batch 2. Paired-rounds mode (1 user-facing + 1
quality). CI CADENCE: NO inline full gate — targeted `--filter` per commit; the standing loop
`scripts/ci-loop.sh` (persistent Monitor, CI worktree ../markdown_viewer-ci) gates each HEAD —
RE-ARM it after compaction if no Monitor is live. Report round DONE at commit (never wait on
CI); INSTALL release only after that commit's CI = rc=0; red → fix-forward. Refresh the
icloud-backup mirror after every committed round (LESSONS 2026-08-01).

## Mission
Owner-driven drain. Standing owner mode (2026-08-01, in memory): **every round = one
user-facing improvement + one quality improvement**, both named, both committed+validated per
round. Full test pyramid incl. pixels/AX for every render/interaction change; commit-as-you-go.

## Current state
**17 commits landed 07-31..08-01** (all gate-green, VM-validated where render/interaction was
touched, installed):
- Owner queue (07-31): tab-drag-onto-session-pill `5c45c04a` · markdown gap-closures
  (footnotes/alerts/def-lists/sup-sub/heading-ids) `95ec7a48` · saved sessions (named save
  points) `a908439e` · AX tier bootstrap `1bad80f4` + drag rung `0667f75e`.
- Release pipeline (07-31): exec cap 65→70 (owner-approved) `21416a1b` · EMFILE/kern-ceiling fix
  `05337de7` · **TextView-2026-07-31.zip pushed to github.com/josangel555/mvd_dist** (now 7
  features behind — refresh is a standing offer; recipe in memory `mvd-dist-publishing`).
- Paired rounds (08-01): R1 View-Diff button + ModeBar deletion `1fb56221` · R2
  Recently-Closed persistence + detector false-red `233e926b` · R3 conflict pre-confirm
  unification + palette/strip AX `f806c48c` · R4 wikilinks + relative links + AX derived-click
  `ebba3a8b` · R5 hex hot-exit + AX catalog `f711c2b8`.

**In flight:** nothing half-written.

**Next action (the proposed round 6, not yet started):** user-facing = Local History
re-diff-on-eviction (BACKLOG "smarter retention" (a)); quality = merge-sheet interactive
pick→Apply AX rung (unblocked by the tier). Alternatives in BACKLOG §OPEN FOLLOW-UPS header.

## Key decisions & rationale
- **AX tier works and is the interaction rung** (owner mandate): find via `AXDriverCore` +
  `AXUIElementNode`, ACT via `AXClickExecutor` (global HID tap — AXPress is accepted-but-not-
  dispatched by SwiftUI; postToPid isn't hit-tested; all probed). Drags = interpolated HID
  moves. Small controls under `.contain` parents report the PARENT's frame — derive positions
  (tab × = maxX − height·18/28); a pinned tripwire flips if SwiftUI fixes child frames.
- **Wikilink resolution is host-side** (core is sans-IO): `WikiLinkResolver` ladder =
  beside-file → `.md` → bare-name at workspace root → toast. The same interception revived
  ordinary relative file links (decide() cancels file: clicks for the browser path).
- **Hex hot-exit rides the text rails**: `TabSnapshot.unsavedHexBase64` (additive-optional),
  captured at the SAME coordinator boundaries as text, restored at materialize, hex view seeds
  from the stash (seen==saved). 512 KB inline cap, refused captures TOLD, live stash never
  dropped.
- **Conflict family has ONE rule everywhere**: destructive branches gate on
  `confirmDiscardIsPreserved` (pre-confirm on refused capture); the shared apply-funnel keeps a
  belt-and-braces reporter because its callers pre-confirm upstream.
- **Saved sessions**: `saved/` shelf in SessionStore — a SUBDIR so `liveSnapshotIDs`/recovery
  can never adopt save points (pinned).

## Gotchas (full text LESSONS.md 2026-07-30..08-01)
- `ulimit -n` silently caps at `kern.maxfilesperproc` (10240) — the sweep's ~90-fail EMFILE
  flood; test-in-vm.sh now sysctl-raises when sudo available. Grep "Too many open files"
  BEFORE triaging any sweep failure list.
- SwiftUI AX: `.ignore` drops children; a BARE container id implicitly combines loose
  pure-SwiftUI descendants (AppKit boundaries escape) — `.contain` fixes; the AX tier is how
  you PROVE an id materialized.
- VM clock ~21h behind → after ANY binary rsync: `ssh macOS15 'cd markdown_viewer && touch
  rust-core/link/*.a'`.
- Bench failures (FoldBench etc.) under host load are flaky — re-run quiet before chasing.
- The shell CWD persists across tool calls — a stray `cd` broke a gate run (127) and nearly
  a commit; prefer `git -C` and absolute paths.
- pulldown sup/sub (`^x^`/`~x~`) can't open INTRA-word (mc^2^ stays literal — pinned).

## Files that matter (this handoff's surfaces)
- `Tests/ViewerUITests/AX/` + `Harness/TierBaseCases.swift` (`AXInteractionTestCase` owns the
  spawn rig) + `Sources/ViewerUI/Automation/AXClickExecutor.swift` — the AX tier. Run:
  `ssh macOS15 'cd markdown_viewer && MDV_VM_GUI_SESSION=1 MDV_VM_SUDO_PASS=<vm-sudo-password> bash
  scripts/test-in-vm.sh pixel --filter ViewerUITests.AXChromeInteractionTests'`.
- `Sources/ViewerCore/WikiLinkResolver.swift` + `MarkdownRenderedView.swift` (decidePolicyFor
  interception) — in-document links.
- `Sources/ViewerUI/DocumentModel+EditableHex.swift` (capture/restore) + `HexView.swift`
  (dirtySeed) — hex hot-exit.
- `Sources/ViewerCore/RecentlyClosedStore.swift` (persisted), `SessionStore.swift` (saved/),
  `Coordinators/EditorCoordinator.swift` (confirmDiscardIsPreserved).
- `tmp/mvd_dist/` — the dist-repo clone (push recipe: memory `mvd-dist-publishing`).

## Open questions / blockers
- **tasked board MCP disconnected all session** (ToolSearch: no tools). 17 commits owe tickets
  + the TSK-1594..1609 placeholder reconciliation. Needs owner-side reconnect.
- mvd_dist: CURRENT — TextView-2026-08-05.zip @ 495d2f0e pushed (19efeed).
- Math typography eyeball on the owner's machine (one open of a math file); TSK-1247 blocks
  the capture lane from showing WebView content.
- Exec 68 of 70 MB — TSK-1214/1098 grammar-table reclaim nearly due (owner call on target).
- `~/Documents/config/` (GitHub ssh key) exists only in CloudDocs; owner may want it restored
  locally + `gh` (dep approval) for proper Releases.

## Tracker
Board unreachable (see above). The 17 commit messages + BACKLOG §OPEN FOLLOW-UPS (2026-08-01
header = the live open set) are the state of record.

## How to resume
1. `git -C /Users/me/Documents/workspaces/claude/markdown_viewer log --oneline -17` (head
   f711c2b8) · `git status --short` (only the 4 protected files).
2. Read `BACKLOG.md` § "⚠ OPEN FOLLOW-UPS (updated at the 2026-08-01 handoff)" — the header
   paragraph IS the live open set.
3. Owner mode: paired rounds (one user-facing + one quality per round, named). Loop per item:
   host tests → gate (`bash scripts/test-headless-gate.sh`) → VM rung for any render/
   interaction change (webview: `MDV_WEBVIEW_FILTER=<suite> … webview`; T5/AX:
   `pixel --filter <suite>`; ALWAYS rsync + touch the staticlib first) → commit (group ok,
   `Claude-Session:` trailer) → `bash scripts/build-app.sh release --install` (RELEASE — the
   owner runs the release build now).
4. If the board reconnects: create tickets for the 17 commits, reconcile TSK-1594..1609, then
   drive from the board.
