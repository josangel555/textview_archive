# Revert Commits — Enumeration & Classification

**Discrepancy resolution:** INDEX.md reports **2 reverts** (counting formal "Revert"-prefixed commits only); unprimed-explorer-2.md reports **12** (counting all commits with "revert/rollback/undo" keywords in subject or body). The true count is:
- **6 actual revert-category commits** (4 formal "Revert" + 2 informal "revert()" style)
- **~56 commits mentioning "revert/rollback/undo" in body or subject**, mostly describing feature behavior, not commits that undo prior work

---

## Formal Revert Commits (Git `Revert` prefix)

These are commits created by `git revert` or manually formatted as `Revert "..."`.

### 4 × Terminal/Tmux Control-Mode Reverts (2026-06-19, TSK-964 integration failure)

**Commit cluster:** 127f2aa9, c760d0d0, 484d237e, 02f967f2
**Unified author/date:** Jos, Fri Jun 19 07:15:12 2026 -0400
**Span:** ~7 hours after initial landing (original commits ~00:08, reverts ~07:15)

#### What was reverted

Four interdependent TSK-964 terminal/tmux features that landed as a cohesive wave on 2026-06-19 at ~00:08:
1. **TmuxLayoutParser** (041de517) — hand-written recursive-descent parser for tmux layout strings (`WxH,X,Y{...}` grammar) into a PaneNode tree; 156 lines code + 206 lines tests
2. **TmuxControlParser** (7fb2a7d5) — control-mode protocol parser (line/byte stream → typed ControlModeEvent); 304 lines + 271 tests
3. **TmuxSession topology model** (c2f25e01) — window/pane/session state machine; 273 lines + 363 tests
4. **TerminalPaneTree** (8a6ed06d) — split-tree node model + geometry + key-routing; 199 lines + 209 tests

Total: ~932 lines of code + 1,049 lines of tests deleted.

#### Why reverted

**Root cause:** The four parsers/models landed with a **DESIGN COLLISION** — two incompatible `PaneNode` types:
- The landing included a **typed enum** `PaneNode` (leaf/hsplit/vsplit from TmuxLayoutParser)
- A competing **geometry enum** approach was also present in the wave
- At integration, the codebase hit **ambiguous reference errors** (`'PaneNode is ambiguous'`) that cascaded into a build failure

The decision was **immediate and complete rollback** — all four interdependent commits reverted in one shot within 7 hours of landing. The design reconciliation work was deemed necessary BEFORE re-landing, rather than trying to patch the conflict.

#### How fixed (re-landed)

Same day, ~4 hours after the reverts (11:06):
- **d382abc9** (feat): "tmux coherent typed-PaneNode model + layout/control parsers + session topology (TSK-1018)"
  - **Reconciled design:** ONE canonical typed `PaneNode` enum, replacing the conflicting geometry enum
  - **Kept TmuxControlParser & TmuxSession:** restored mostly as-is from the reverted commits
  - **Rewrote TmuxLayoutParser:** now produces the typed PaneNode (not the rejected geometry enum)
  - **Re-tested:** 96 ViewerCoreTests covering all four classes end-to-end
  - **Scope reduction:** explicitly excluded controller/router/PTY wiring (deferred to VM tail) — the reverted wave included more than the parsers

- **51d9d315** (~2.5h later): "re-land tmux controller host-logic core — TmuxControllerCore (TSK-1018)"
  - Slimmed-down re-land of the core event-demuxer + routing logic (no full control wiring yet)

**Key lesson:** The collision revealed that the wave had tried to land **too much in one shot** (design reconciliation, parsers, session model, AND controller logic). The re-land succeeded by splitting: (1) parsers + model on day 1, (2) controller core a few hours later.

---

## Informal Revert Commits (lowercase `revert()` format)

These follow a similar pattern (reverting prior work) but use the lowercase `revert(category):` prefix instead of the formal `Revert "..."` format.

### Commit 1a9f1f6c: Inside-Out Signing Rollback (2026-05-30)

**Hash:** 1a9f1f6c
**Date:** Sat May 30 21:46:54 2026 -0400
**Ticket:** G14 / inside-out signing (Phase-9 item)
**Category:** Build infrastructure

#### What was reverted

**Previous attempt:** A complex multi-stage signing approach ("inside-out signing" with distinct per-dylib identifiers) in `scripts/build-app.sh` that was meant to:
- Avoid stamping the app's single identifier onto every nested dylib (AppKit library-validation violation)
- Use per-dylib identifiers derived from basename
- Sign in a strict order (Frameworks first, resource bundles, then outer .app last)

**Code deleted:** ~57 lines of complex signing logic, 6 comments explaining the approach, cleanup steps.

#### Why reverted

**Root cause:** The signing approach broke `.bundle` codesign validation — it was discovered to be a "surface-only Phase-9 item" that was not production-ready. The commit message explicitly states:
> "broke .bundle codesign (FinderInfo/runtime). Full inside-out signing deferred to Phase-9 w/ VM re-test."

**Discovery context:** This was during bootstrap (c-02 era) when build infrastructure was being hammered out. The feature was too risky to ship as-is.

#### How fixed

**Restored to simpler approach:** Reverted to the original `--deep` signing (single pass, single identifier for everything). The complex multi-stage signing was deferred to a later Phase-9 project with dedicated VM validation.

**Status:** Marked explicitly "deferred" — not abandoned, but pushed back for when the team had better infrastructure to test it.

---

### Commit ad030f30: NSTextView Compositor Bug Regression (2026-05-15)

**Hash:** ad030f30
**Date:** Fri May 15 03:45:26 2026 -0400
**Ticket:** #88 (UI rendering compositor bug)
**Category:** UI/rendering

#### What was reverted

**Previous attempt:** A reintroduction of `NSTextView` (AppKit text view) as the source-code viewer in `TextDisplayView.swift`, replacing the pure-SwiftUI version.

**Motivation for change:** NSTextView provides features that pure SwiftUI can't:
- Drag-select across lines
- Click in empty space to extend selection
- Native find-bar interop
- Word-by-word double-click selection
- Standard right-click services

#### Why reverted

**Root cause:** The NSTextView reintroduction brought back a **macOS 14+ WindowServer compositor bug** that had already been encountered and supposedly fixed:
- When NSTextView (AppKit layer via `NSViewRepresentable`) is embedded in a SwiftUI tree alongside other SwiftUI siblings (TabBar, ModeBar, Sidebar, StatusBar)
- The sibling SwiftUI views **stop committing layer contents at WindowServer time** (become invisible)
- The bug is **INVISIBLE to every headless test:**
  - `xctest` view-tree walks show the elements present ✓
  - `cacheDisplay()` redraw gives false green ✓
  - In-process `ImageRenderer` snapshots lie about composition ✓
  - **Only real WindowServer pixel capture catches it** (expensive, can't gate every commit)

The commit message emphasizes the testing gap:
> "The structural test I added passed; the visual broke. Sloppy on my part."

And explicitly lists what was tried and failed:
> "The pure-SwiftUI implementation is missing things only NSTextView gives us... but the AppKit/SwiftUI bridge had a compositor bug on macOS 14 that hid sibling SwiftUI views around the text scroll."

#### How fixed

**Reverted to pure-SwiftUI approach** from commit 82679e3, keeping complementary work:
- **Kept:** `findState` plumbing (find bar still highlights matches; scroll-to-match noted as missing)
- **Kept:** `wordWrap` honored (toggle between vertical-only and horizontal+vertical scroll axes)
- **Kept:** All call-site contracts preserved (ContentView / DocumentModel didn't need to change)

**Test acknowledgment:** `DiagnosticDumpTests` was reverted to assert `nsTextViewCount == 0` with an explicit comment explaining why xctest can't detect this regression class.

**Deferred solution:** Created `/scripts/visual-smoke.sh` — a manual workflow that:
1. Builds the app
2. Launches it
3. Captures via real `screencapture` (WindowServer-rooted, not cacheDisplay)
4. Prompts human visual inspection of TabBar/ModeBar/Sidebar/StatusBar visibility

This became the standing workflow for any future TextDisplayView containment changes.

**Follow-up:** Re-tasked (#88 → later work) to host the source area in `NSHostingController` (not `NSViewRepresentable`) to place the AppKit/SwiftUI boundary OUTSIDE the problematic nesting — a better architectural solution.

---

## Commits Mentioning Revert/Rollback in Body (Feature Behavior, Not Undoing Prior Work)

The 56 remaining mentions of "revert/rollback/undo" in commit subjects/bodies are **NOT commits that undo prior work**, but rather:

| Category | Count | Examples |
|---|---|---|
| **Feature behavior** — code that implements reversible/undoable operations | ~25 | `dbd3794e` (Escape reverts edits), `1cb22ae5` (rollback semantics), `730c1412` (disk-conflict revert), `030215fe` (undo toast) |
| **Auto-revert on failure** — safety patterns that automatically roll back state on errors | ~8 | `06ba3422` (auto-revert attach on connection loss), `692af1c4` (fail-safe to in-process) |
| **Test/guard semantics** — test names or guard descriptions mentioning revert patterns | ~10 | `6e4d2ba3` (guard against clone-to-serialize revert) |
| **Documentation/discussion** — handoff/docs commits discussing reverts as a concept | ~13 | `d9a5dfc5` (revert over-baked docs), various handoff checkpoints |

None of these represent commits that UNDO prior code commits.

---

## Summary: The Real "2 vs 12" Discrepancy

| Source | Count | Definition |
|---|---|---|
| **INDEX.md ("2")** | 2 | Formal "Revert" commits in git history (narrow technical definition) |
| **unprimed-explorer-2.md ("12")** | 12 | Commits with "revert" in subject + commits reverting prior work (broader, but inflated by false positives) |
| **True revert count** | **6** | Commits where prior committed work was UNDONE (4 formal + 2 informal) |
| **Mentions of "revert/rollback/undo"** | ~56 | All commits with those keywords (mostly feature behavior, not actual reverts) |

The corpus's "2 vs 12" discrepancy stems from:
1. INDEX's strict git-only count (2 comments mentioning explicit "Revert" in the commit body)
2. unprimed-explorer-2's overly-broad grep that conflated feature behavior words ("revert" as a user action) with actual code reversions

---

## What NOT to Build — Lessons from These Reverts

### From Terminal/Tmux Wave (design collision):
- **Don't land incompatible abstractions in a single wave.** The four parsers/models worked individually but collided at integration because two conflicting `PaneNode` designs coexisted.
- **Split large features by scope, not by time.** The wave tried to land design+model+controller+routing simultaneously. Re-landing succeeded by separating: (1) models/parsers first with confirmed design, (2) controller wiring as a follow-up.
- **Design reconciliation gates code landing.** When you hit a merge conflict on fundamental abstractions, don't patch — revisit the design.

### From Inside-Out Signing (risky approach):
- **Don't ship build infrastructure that's "surface-only" and unvalidated.** Complex signing logic that hadn't been tested end-to-end against real codesign + notarization was reverted immediately.
- **Defer architectural changes to infrastructure when you lack the harness to test them.** VM/signing validation wasn't ready; pushing to Phase-9 was the right call.

### From NSTextView Compositor (test infrastructure gap):
- **Headless test false-greens are a trap for AppKit/WebView integration.** xctest + cacheDisplay + ImageRenderer all lied; only WindowServer pixels told the truth.
- **Mixed AppKit/SwiftUI composition bugs are architectural, not patch-able.** Adding another `@State` variable or reordering views won't fix a compositor pathology — you need to change the boundary.
- **Establish real pixel validation EARLY for hybrid rendering.**  The team did this eventually (`screencapture` + visual-smoke.sh), but only AFTER the regression burned them. This became a CLAUDE.md directive for all future render-path work.
- **Don't trust in-process rendering tests for WindowServer composition.** A pure-logic test can pass while the on-screen pixels are wrong — this is the whole lesson of T5 pixel-test tier.

---

## Process Notes

- All 6 revert commits were **rapid reversals** (same day or within a few days) — neither sat unresolved for weeks, suggesting good on-the-fly decision-making.
- None were **sneaky or hidden** — all logged with clear intent (explicit "Revert" or "revert()" prefix) + bodies explaining why.
- **All led to follow-up work:** tmux was re-landed same day with design fix; signing was deferred with explicit Phase-9 plan; compositor regression was addressed with a new validation workflow.
- **None represent abandoned features** — all either re-landed in refined form or explicitly parked for later (with follow-up tickets filed).
