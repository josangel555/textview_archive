<!-- CLAUDE-HANDOFF v1 -->
# Handoff — audit-fix drain + partial-T6 pixel discipline (2026-07-30)

**cwd:** /Users/me/Documents/workspaces/claude/markdown_viewer · **branch/SHA: main @ 7b2fe687**
(clean tree; only the 4 protected untracked files remain: OwnerWishlist.md/.bak, Untitled.txt,
archive/Untitled.txt — NEVER touch them). Installed to /Applications 2026-07-30 03:10.

## Mission
Owner-driven hardening: drain the pre-launch-audit P1s (data safety, crashes, licensing, security,
perf) + owner feature asks, with the FULL test pyramid — the owner's 2026-07-30 directive ended the
"on-screen unverified" habit: **every render change gets a VM pixel/geometry rung + an eyeball pass
before "done"**. Commit-as-you-go is authorized (group commits fine; full gate for major changes).

## Current state
**Done, committed (14 commits, 081f1fc5..7b2fe687 — all gate-green, all installed):** session-switch
>1MiB data loss · disk-conflict preservation + 3-pane merge mounted · bookmarks lenient decode ·
Local History 100MB + gap-thinning (never oldest-first) · formula-parser recursion abort · restore
crash-loop breaker · silent persistence failures (choke-point hook + coalescing reporter) · CRLF
LSP lines · THIRD_PARTY_NOTICES bundled + 49 rust crates attributed · Mermaid 11.16.0 · web-diff
nav jump/scrollspy (measured on VM: scroll-past-end + rAF-never-ticks) · split-pane off-main render
· find >1MiB off-main ("Searching…", ≤1MiB byte-identical) · hex + CSV conflict machinery (sibling
audit complete) · tab/session drag-reorder + recently-closed (⇧⌘T) + name-first New File · Split
mode segment (in the LIVE ContentToolbar; Render|Split|Editor|HEX) · user-creatable Canvas ·
LaTeX math via pulldown-latex (backend MathML, no JS) · partial-T6 rig (3 scenes +
PartialT6SceneCaptureTests + MathRenderWebViewTests, both VM lanes).

**Pixel-verified on the VM (PNGs eyeballed):** Split segment lit + two-pane layout; the 3-pane
merge sheet (first time ever on screen — fully correct); math geometry on live WebKit (inline +
mfrac boxes; merror visible for lexed-bad TeX).

**In flight:** nothing half-written.

**Next action:** the owner's queue, in order — (1) tab-drag-onto-session-pill with drop-target
highlight → switch + select moved tab; (2) markdown gap-closures (footnotes/def-lists/alerts —
enable option + WRITE THE WRITER ARMS together, the math near-miss); (3) save/retrieve-session
design (frame: sessions already persist + 30-day trash; the ask is probably NAMED snapshots);
(4) AX harness bootstrap (owner now WANTS AX tests for new UI — policy amended in CLAUDE.md).

## Key decisions & rationale
- **Split is a LAYOUT, not a ViewMode case** — `.editor` + same-file split preview; a new enum case
  would ripple through persistence/locks/switches. Lives in `DocumentModel+SplitEditing.swift`
  (`ToolbarModeSegment`, `selectToolbarSegment`); the LIVE control is **ContentToolbar's TSK-898
  segmented primaries** — the `ModeBar` struct in ContentView (~1641) is DEAD, never instantiated.
- **Math renders in the RUST backend to MathML** (owner: "render the HTML in the backend") —
  pulldown-latex =0.8.0 (approved; closure = bumpalo only). No JS; works in script-free export.
- **Local History**: capture() returns stored/alreadyPresent/refused(reason) so discard paths can
  PROVE recoverability; binary is REFUSED → hex conflict branches pre-confirm instead of pretending.
- **Thinning, not truncation**: over-budget drops the interior version with the smallest time gap;
  first + newest never dropped; no age expiry (owner: "don't lose the oldest ones").
- **Persistence failures**: one hook at JSONFileStore (every path funnels through) + rate-limited
  reporter — not per-caller Bool handling.

## Gotchas (full text LESSONS.md 2026-07-27..30)
- **Grep for a view's INSTANTIATION before editing it** — 12 green host tests sat on the dead
  ModeBar while the toolbar showed no Split; only the pixel capture caught it.
- **VM clock runs ~21h behind the host** → rsync'd staticlib mtimes are in the VM's future →
  build-app.sh STALE-LINK loops forever. After ANY binary sync:
  `ssh macOS15 'cd markdown_viewer && touch rust-core/link/*.a'` (+ rm the link product once).
- `MDV_PIXEL_DEBUG_DIR` copies are `try?` — mkdir the dir first or captures silently vanish.
- WebView CONTENT is blank under asuser-bridge captures (TSK-1247) — webview-lane geometry tests
  are the layout authority; captures verify chrome/arrangement. `test-in-vm.sh test` mode STRIPS
  `MDV_RUN_WEBVIEW_TESTS` — use `webview` mode; `pixel --filter <suite>` for one T5 suite (~160s).
- `@State` initialized with a FRESH OBJECT (`= SomeClass()`) costs the view SwiftUI's body-skip;
  arrays/nil-optionals don't. Keep such state on a leaf view (LESSONS 2026-07-27).
- pulldown-cmark options with `=> {}` writer arms SILENTLY EAT content (math near-miss; footnotes
  still have this shape today).
- pulldown-latex is TOTAL (merror inline, Ok) — `$\frac{$` never lexes as math (stays prose).

## Files that matter (this session's surfaces)
- `Sources/ViewerUI/DocumentModel+SplitEditing.swift` — ToolbarModeSegment + split-editing model.
- `Sources/ViewerUI/ContentToolbar.swift` — the LIVE mode control (segment row).
- `rust-core/crates/core/src/markdown.rs` — ENABLE_MATH + render_mathml (catch_unwind).
- `Sources/ViewerUI/DocumentModel+DiskConflict.swift` / `+ConflictPreservation.swift` — the
  never-silent conflict rules (text + hex branches).
- `Sources/ViewerCore/LocalHistoryStore.swift` — capture outcomes + thinningVictimIndex.
- `Tests/ViewerUITests/PartialT6SceneCaptureTests.swift` + `UISceneApplier.swift` scenes
  (math-render / md-split / conflict-merge) — THE pixel rig; run via
  `MDV_VM_GUI_SESSION=1 MDV_VM_SUDO_PASS=<vm-sudo-password> MDV_PIXEL_DEBUG_DIR=/Users/vm-tester/pixdebug-t6
  bash scripts/test-in-vm.sh pixel --filter ViewerUITests.PartialT6SceneCaptureTests`, then
  `scp macOS15:/Users/vm-tester/pixdebug-t6/\*.png tmp/t6shots/` and **Read the PNGs**.
- `Sources/ViewerUI/StripDragReorder.swift` + `ViewerCore/StripReorder.swift` — tab reorder.

## Open questions / blockers
- **tasked board MCP tools disconnected ALL session** (server answers HTTP; tools absent from the
  session). Owner said board is up — needs an MCP reconnect on the owner's side. Nothing recorded
  on the board since TSK-1593; TSK-1594..1609 remain PLACEHOLDER ids from 07-24..27.
- Math typography quality: one eyeball on the OWNER's machine (capture lane can't show WebView).
- Save/retrieve-session: needs the owner's intent (named snapshots?) before building.

## Tracker
Board unreachable from this session (see above). All landed work is traceable via the 14 commit
messages instead; BACKLOG "⚠ OPEN FOLLOW-UPS (2026-07-30)" is the accurate open list.

## How to resume
1. `git log --oneline -15` (expect 7b2fe687 head, 14 session commits) · `git status --short`
   (only the 4 protected files).
2. Read `BACKLOG.md` § "⚠ OPEN FOLLOW-UPS (updated at the 2026-07-30 handoff)".
3. Loop per change: host tests → gate (`bash scripts/test-headless-gate.sh`) → commit (group ok,
   `Claude-Session:` trailer) → `bash scripts/build-app.sh debug --install` → for ANY render
   change: scene + capture + **eyeball the PNG** (rig above) — never ship "on-screen unverified".
4. VM sync recipe: rsync (exclude .build/.build-gate/.swiftpm/dist/tmp) → `touch rust-core/link/*.a`
   on the VM → lane. Webview suites: `webview` mode. One T5 suite: `pixel --filter`.
5. If the board reconnects: create real tickets for the 14 commits' work, reconcile the
   TSK-1594..1609 placeholders, then drive from the board again.
