# Teeth-demonstrated tests — is this captured in the SOP? (TSK-776)

**Date:** 2026-06-19
**Source:** wishlist-2026-06-13 / questions-and-research
**Type:** question → homework (survey the SOP, add if missing)

---

## TL;DR

**Yes — teeth-demonstration is in the SOP, but only as a one-liner, and the
operational hazards that make it actually *work* live entirely in `LESSONS.md`
where the SOP never points at them.** A new (or compacted) agent reading the
two authoritative SOP files (`docs/TASK_WORKFLOW.md`, `CLAUDE.md`) learns the
*rule* ("regression tests must have teeth") but not the *procedure*, and so
re-discovers four documented footguns the hard way:

1. mutating with `git checkout` wipes uncommitted work,
2. the mutant binary may not have recompiled (you tested the OLD binary),
3. the expected side of the assertion can move with the mutation (self-referential false green),
4. running a teeth mutate/restore cycle while a background `build-app.sh` is in flight hard-fails the build.

This doc records the survey and the fix applied: a single **"Teeth — the
mechanics"** subsection added to `docs/TASK_WORKFLOW.md §4` that consolidates
the rule + the four hazards, with `LESSONS.md` line pointers. No code change;
no behavior change. SOP-only.

---

## What "teeth" means here (definition)

A test has **teeth** if it has been *shown* to fail when the behavior it guards
regresses — i.e. someone broke the code under test (a "mutation"), watched the
test go red, then restored. The slogan throughout the codebase docs:

> "A green that has never been shown to go red is not a guard."

This is hand-run mutation testing applied to the *specific* fix/feature being
landed — not a full mutation-testing framework (there is none, and none is
proposed here). It is the codebase's primary defence against the **false
green**: a test that passes on both the fixed and broken code, proving nothing.
The canonical origin is the terminal-tab-strip miss (recurred FOUR times),
where `ImageRenderer`/`cacheDisplay`/headless frame-walks all reported a feature
"rendered" that was invisible on screen — green that could never go red.

---

## Where it IS captured today (survey)

### 1. `docs/TASK_WORKFLOW.md` — the SOP itself (1 line)

`docs/TASK_WORKFLOW.md:215`, under §4 "Work the task (lifecycle + discipline)":

> **Regression tests must have teeth:** mutation-check (break the fix → test
> fails → restore).

This is the *rule*, correctly placed in the lifecycle section. It is the only
mention in the operating-procedure doc. It has no pointer to the mechanics.

### 2. `CLAUDE.md` — the always-loaded project instructions (2 places)

- **Compositor / false-green section:** *"Demonstrate TEETH on every real-UI
  test. … After writing/maintaining a T5 pixel test, revert the fix once,
  rebuild, and confirm the test FAILS — then restore."* This is scoped to T5
  pixel tests but the principle is general.
- The same section codifies the **`ImageRenderer` false-green trap** (why the
  cheap rasterizers lie), which is the *reason* teeth matter for UI.

`CLAUDE.md` is loaded every session, so the *rule* is effectively always in
context. But it is framed as UI-specific (compositor), not as a universal
landing-checklist step.

### 3. `LESSONS.md` — institutional knowledge (~10 entries, all the mechanics)

Every operational detail lives here and *only* here. The load-bearing ones:

| LESSONS.md | Hazard / rule |
|---|---|
| ~2635 | The origin: always demonstrate teeth on a real-UI test (terminal-tab-strip). |
| ~2657 | Teeth on a depth-cap: test *balanced valid* deep input; neuter the cap → SIGABRT → restore. |
| ~2803 | **`git checkout -- <file>` during a teeth check WIPES uncommitted work** (the fix + new test). Undo mutations with the inverse `Edit`, never git, until committed. |
| ~2910 | **Never run teeth mutations while a background `build-app.sh` is in flight** — SwiftPM hard-fails "input file modified during build". Order: teeth → restore → commit → gate → THEN install. |
| ~3078 | Cheap **struct-shape pins** (`size_of` + field ref) are legitimate teeth for "never re-add storage" classes — brittle on purpose. |
| ~3147 | **Self-referential false green:** the expected side of a teeth assertion must use an INDEPENDENT oracle, not the helper being mutated, or both sides move together and stay green. |
| ~3167 | A teeth mutation that suppresses events can crash xctest — distinguish that from a real failure. |
| ~3187 | **A surviving mutation isn't always a weak test** — verify the mutant actually changes behavior first (probe empirically). **And confirm the mutant COMPILED** (grep `Compiling <module>`) — SwiftPM's incremental build can miss a same-second rewrite, so you may be re-running the OLD binary. |

The pattern: the *rule* is in the SOP, but the *how-to-not-shoot-yourself*
is scattered across `LESSONS.md` with no path from the SOP to it.

### 4. Tooling — none exists, and that is fine

There is **no script** that automates teeth (grep across `scripts/` finds only
*false-green* avoidance in the test harness — `test-in-vm.sh`, `build-app.sh`
unsetting the gate env, `ui-snapshot.sh`). Teeth is a hand-run discipline by
design: it targets the *one specific* fix being landed, which no generic mutation
framework can know. This survey does **not** propose a teeth-automation script —
that would be a large, low-value tool (full mutation testing) and is out of
scope for a "confirm it's in the SOP" question.

---

## The gap (what was missing)

The SOP teaches the *rule* but not the *procedure*, so the procedural footguns
are re-learned per agent:

```
SOP (TASK_WORKFLOW.md §4)        LESSONS.md (the mechanics)
┌───────────────────────────┐    ┌──────────────────────────────────┐
│ "tests must have teeth:    │    │ git checkout wipes uncommitted    │
│  break → fails → restore"  │ ?? │ mutant must have recompiled       │
│  (1 line, no pointer)      │────│ independent oracle (no self-ref)  │
└───────────────────────────┘    │ don't mutate during build         │
                                  │ ... (~10 entries)                 │
   gap: no path from rule ───────▶└──────────────────────────────────┘
        to mechanics
```

A self-validating agent (owner policy 2026-06-07: an agent MAY `task_validate`
its own work with a `checks` artifact "that would fail on regression") is
*exactly* the audience that needs the mechanics inline — it is asserting the
test has teeth without a human checking. The four hazards above are precisely
the ways that assertion is silently false (false green) or destructive (lost
work).

---

## The fix applied (SOP-only)

Replaced the single teeth line in `docs/TASK_WORKFLOW.md §4` with a tight
**"Teeth — the mechanics"** subsection that keeps the rule and adds:

- the procedure (break → confirm red → restore),
- the four hazards as a checklist (independent oracle; mutant-must-compile;
  restore via inverse Edit not git; don't mutate during an in-flight build),
- a one-line note that UI render-path teeth are VM-only (ties to the existing
  self-validation policy two bullets up),
- a pointer to the `LESSONS.md` entries for the full detail (so the SOP stays
  the index, `LESSONS.md` stays the depth — matching the doc's own
  "board = live state, doc = the story" split).

Why edit the SOP and not just file this doc: the wishlist item asks to *add it
to the SOP if missing*. The mechanics were missing from the SOP. A homework doc
that nobody's loop reads each firing would not satisfy "in the SOP" — the SOP is
the doc read in full every firing (`CLAUDE.md` → "read `docs/TASK_WORKFLOW.md`
IN FULL and follow it").

### Deliberately NOT done

- **No teeth-automation script / mutation-testing framework.** Out of scope,
  large, low ROI; teeth is hand-run by design (it targets the specific landing).
- **No duplication of `LESSONS.md` into the SOP.** The SOP gets the checklist +
  pointers; `LESSONS.md` keeps the war stories. Duplicating would drift.
- **No change to `CLAUDE.md`.** Its TEETH rule (UI/compositor) is correct and
  still the always-loaded reminder; the SOP subsection now generalizes it.

---

## Verification

This is a docs-only change to two `docs/*.md` files — no Swift/Rust source, no
tests affected, headless gate unaffected (it compiles + runs no doc). The
"test" for a homework/SOP item is that the SOP now answers the question it
posed: an agent reading `docs/TASK_WORKFLOW.md §4` end-to-end now learns both
the teeth rule and the four mechanics, with pointers to the depth. Confirmed by
re-reading the edited section.
