<!-- CLAUDE-HANDOFF v1 -->
# Handoff — wishlist wave: 6 features landed; board fully owner-gated  (2026-06-12 ~21:30)

**Session:** claude-mdv (autonomous loop)  ·  **cwd:** `/Users/me/Documents/workspaces/claude/markdown_viewer`  ·  **branch/SHA:** `main` @ b2fae4e

## Mission
Owner directive 2026-06-12: rust-core toward Swift-core deprecation (epic TSK-651);
USER-FACING bugs first when present; never idle while background runs execute.

## Current state — the wishlist wave (all installed to /Applications)
Six features landed this wave, every one held at `fixed` for the owner's glance:
- **TSK-284 drag-OUT** (b2f66ba): sidebar rows / filter rows / tabs carry real file
  refs (NSItemProvider(contentsOf:)); tab reorder payload composes (pinned).
- **TSK-330 undo** (51b6a12): bookmark-removal ⌘Z outside the editor; text-input
  guard releases ⌘Z to fields. Audit ledger on the ticket (clearRecents follow-up).
- **TSK-311 archives** (1a734b5+3ab1d5f): `.archive` FileCategory → preview lens;
  list+extract via system unzip/tar (zip-slip structurally impossible — stdout
  pipes); ArchiveBrowserView; double-click opens entries.
- **TSK-259 font picker** (f5f319a+ee09f99): fail-safe FontPreference; Settings →
  Appearance → Font (fixed-pitch only); drives BOTH the source view (AttrKey +
  gutter lineHeight from the RESOLVED font) and the CM6 editor (setFontFamily into
  the fontCompartment; double-optional clear channel).
- **TSK-282+666 fuzzy filter** (05dd9bd+ed848cd) and **TSK-641/642 theming**,
  **TSK-327 drag-to-snap**, **TSK-563 wire v2** etc. — earlier in the wave; see
  LOG +292..+310 in docs/AUTONOMOUS_PROGRESS.md.
- **VM sweep was CLEAN**: 4942 tests / 1 confirmed load-flake; WebView lane 18/18.

## Board state (the live truth — re-query, don't trust this list)
- **Parked on the owner:** TSK-336 (hook-event surfacing, 4 options), TSK-338
  (plugins/MCP/walkthroughs consolidation, 4 options; 339/340 deduped into it),
  TSK-649 stage B (waiting:human).
- **The glance batch** (fixed, blocker live-validation): 327 drag-snap (review),
  641/642 theme, 637 outline, 638 print, 640 rename, 282/666 filter, 284 drag-out,
  330 ⌘Z, 311 archives, 259 fonts.
- **Supervised:** the MountedPanesLRU session (TSK-598 family — five captures).
- **Remaining reported wishlist:** TSK-275 (render-FPS jank meter — obvious default:
  opt-in CVDisplayLink chip; semi-parkable), TSK-316/317 (walkthrough versioning/
  deeplinks), TSK-280/319 (dependency graph/explorer — big), TSK-318, TSK-320,
  TSK-264/265 (sessions/multi-window — architectural), TSK-256 (DEPGATED).

## Gotchas added this wave (durable forms in LESSONS.md)
- A SURVIVING mutation isn't always a weak test: NSItemProvider URL-sniffs strings
  (the "degraded" mutant was behavior-preserving). Probe empirically (`swift -e`).
- Same-second SwiftPM staleness: confirm a mutant COMPILED (grep `Compiling`) before
  reading its test result; and the cross-module-enum-layout trap (FileCategory) makes
  PHANTOM failures — touch referents first, then diagnose.
- Weak source-pin needles match the wrong site (call site vs construction; substring
  vs structural plist) — target the exact seam; demonstrate red.
- VM "wedge" can be ssh buffering under memory pressure — check process CPU trend +
  log mtime, not the tail.

## How to resume
1. docs/TASK_WORKFLOW.md in full; `task_list {waiting: human}` FIRST — owner answers
   outrank everything; then `task_next {project: tasked}`.
2. Owner-answer playbook: glance-confirmed → task_validate citing the held evidence;
   park answers → execute the chosen option (TSK-336/338 have costed options inline).
3. Gates: `bash scripts/test-headless-gate.sh` + `bash scripts/rust-core-gate.sh`;
   wire/serve changes → rebuild `/private/tmp/mdv-rust-target` mdv-serve (handshake
   rejects stale binaries by design). Bundle: `bash scripts/build-app.sh debug
   --install` after user-facing changes.
4. Next NEW work if nothing answered: TSK-275 (FPS chip — smallest), then 316/317.
   Mode-B follow-ups recorded on tickets: clearRecents undo, 7z/rar locator,
   TSK-259 VM computed-style case.
