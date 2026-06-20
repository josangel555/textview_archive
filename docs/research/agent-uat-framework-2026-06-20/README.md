# T6 — Agent-driven journey UAT (framework design, 2026-06-20)

**"T6"** is the official name for this layer — the tier ABOVE T5 in the testing
pyramid (T1/T1m/T2' headless · T4 LiveApp · T5 Pixel/WindowServer · **T6
agent-driven journey UAT**). Unlike T1–T5 (XCTest), T6 is **agent-driven**: an
agent uses the app like a human along a real journey, judges the result with its
own eyes, and records it. Run via the `run-uat` skill (+ the `mac-computer-use`
MCP), not `swift test`.

A framework for **agent-driven, real-world-journey UAT** that an agent runs by
actually using the app like a human, stores, and re-runs as a regression /
release suite. Its purpose: **close the render-verification gap** so render-path
tickets can move `validated → done` with real proof — the #1 blocker from
`AGENT_PRODUCTIVITY_FEEDBACK_2026-06-20.md`.

## Two modes of T6
- **Partial T6 — MANDATORY per render-path change.** The agent confirms its OWN
  change on screen with its own eyes (the scoped slice). This is the gate for
  reporting "fixed" (CLAUDE.md ⛔ rule).
- **Full T6 — OWNER-REQUESTED, major releases.** The whole journey suite — a
  regression + completeness sweep. Not per-change (too expensive).

## 1. What this IS (and isn't)

**IS:** journeys that simulate real use — *interleave many features in one live
session without resetting UI state* (open a file → edit → switch session → open
git → scroll → toggle a panel …). Driven by an agent through the REAL UI (real
clicks/keys, reading the real screen), so it catches UI-layer bugs the model
tests and script-verbs structurally miss (e.g. the scroll bug: model right,
screen wrong). Plain-English encoded (the agent interprets). Stored + re-runnable.

**ISN'T:** isolated-function unit tests (stay in XCTest host gate); pixel-perfect
golden images (that's T5 VisualRegression); a replacement for the host/VM tiers.
It's the **top tier — "T6 Journey UAT"** — the release/regression layer.

## 2. Why agent-driven (not scripted)

A pure script can't handle the messiness of real UI: an unexpected modal, a moved
control, a relayout, a slow async paint. The agent is the **intelligent test
runner** — it executes the journey, and when reality DRIFTS from the script it
decides: work around it (dismiss the modal, re-find the control), update the test
(the app legitimately changed), or fail-and-report (a real regression). That
judgment is the whole value; it's why this is expensive and why it's worth it.

## 3. The efficiency thesis (owner: "most efficient possible")

Vision + raw clicking is slow/flaky. The lever is **drive via the macOS
Accessibility API targeting the app's existing `accessibilityIdentifier`s.** The
codebase is already littered with them (`mdv.hexView`, `mdv.hex.search.field`,
`mdv.imageEditor.*`, `mdv.hex.widthPicker`, …). An AX-driven tool finds an element
by identifier/role/label, clicks it, reads its value — **deterministically, no
vision, no coordinates.** So the tiering is:

| Tier | Use for | Cost |
|---|---|---|
| **Script-verbs / in-app MCP** | pure setup + navigation that already has a verb (open file, set view mode, jump-to-line) | ~free, deterministic |
| **AX computer-use** (primary) | real interaction through the UI event path — click `mdv.…` identifiers, type, key-chords | cheap, deterministic, exercises real events |
| **Vision** (`screencapture` + Read PNG) | the visual `see` assertions ("looks right", layout, rendering quality) AX can't express | expensive — use sparingly |
| **Raw coordinate click** | last resort when no AX id/label exists | brittle — flag to add an identifier |

Plus **hint-caching**: the first authoring run resolves each step to a concrete
AX id / verb and stores it in the scenario; re-runs use the hint (fast) and only
re-resolve (vision/AX-search) on drift. And **batch the journey** — one app
launch, many interleaved features — to amortize launch cost + minimize vision.

Rule of thumb: ~80% of steps should resolve to a verb or AX id (deterministic);
vision is for the `see` that's genuinely visual.

## 4. The scenario encoding (plain-English, serializable)

YAML — machine-enumerable (the runner tracks per-step pass/fail + ticket linkage)
with plain-English `do`/`see` values (the agent interprets + executes). Steps are
ORDERED and share state (no reset between them — that's the point).

```yaml
id: editor-scroll-and-view-journey
title: Edit a large file, navigate sessions, confirm scroll + view-lock hold
covers: [TSK-1046, TSK-1047, TSK-936, TSK-602]
precondition: fresh launch              # or: "restore session X"
fixtures: [~/uat-fixtures/big.swift]    # files the journey needs
steps:
  - do: "Open big.swift in the editor"
    see: "It opens in Editor mode with Swift syntax highlighting"
    hint: { verb: "open-as big.swift editor" }     # cached after authoring
  - do: "Scroll the editor down to about line 200"
    see: "Line ~200 is at the top of the editor viewport"
    hint: { ax: "mdv.editor.webview", action: "scroll", to: "line 200" }
  - do: "Create a new session, then switch back to the first one"
    see: "The editor is STILL at ~line 200 — not reset to the top"   # the bug under test
    assert: { model: "editorScrollByTab[active].viewportFromLine ~= 200", live: "editor scrollTop > 0" }
  - do: "Press Cmd+Shift+L"
    see: "View-Only turns on — the View menu item shows a checkmark and the buffer is read-only"
    hint: { key: "cmd+shift+l" }
  - do: "Type a character"
    see: "Nothing is inserted (read-only is active)"
recovery:                                # known drift handlers (optional)
  - if: "a 'file changed on disk' modal appears"
    then: "click Keep Mine, continue"
```

- `do` / `see` are the human-readable intent — the agent's contract.
- `hint` / `assert` are the efficiency layer — resolved deterministic actions +
  cheap model assertions, filled in during authoring, used on re-run.
- `covers` links tickets — a green run is the proof to move them → done.
- `recovery` pre-declares known drifts so re-runs don't need the agent to
  improvise the same workaround every time.

## 5. MCP tools to build

1. **`mac-computer-use`** (the missing piece — standalone; needs Accessibility +
   Screen-Recording TCC grants). AX-first:
   - `find(app, {identifier|role|label|text})` → element handle (uses AXUIElement).
   - `click(handle)` / `type(text)` / `key(chord)` / `set_value(handle, v)`.
   - `value(handle)` / `tree(app)` → read the AX tree (what's on screen, by
     structure — cheaper + more robust than vision).
   - `screenshot(window|region)` + the agent Reads the PNG for visual `see`.
   - `scroll(handle, by|to)`.
   The AX tree + identifiers do most of the work; vision is the fallback.
2. **`app-state`** — read `DiagnosticDump` / `modelStateDump` (cheap model
   assertions) + expose the script-verb catalog (the deterministic action vocab)
   so the agent knows what it can do without the UI.
3. **`uat-runner`** — load a scenario, drive steps (via 1+2), verify `see`/`assert`,
   record `{step, pass/fail, screenshot, timing}`, link `covers` → board, and on a
   full green run advance the covered tickets `validated → done` (with the run as
   the artifact). Re-run any/all scenarios as a suite.

## 6. The agent's drift loop (per step)

```
execute(do)  →  observe (AX tree + model dump; screenshot only if `see` is visual)
            →  matches `see`/`assert`?
   yes → next step
   no  → classify the drift:
         • transient/environmental (modal, focus, timing) → apply `recovery` or
           improvise a workaround (dismiss/re-find/wait) → retry → continue
         • app legitimately changed (control moved/renamed) → UPDATE the scenario
           (new hint/step) + note "scenario evolved" → continue
         • real regression (behavior wrong) → FAIL, capture screenshot + AX tree,
           report against `covers` tickets (the UAT found a bug)
```

This is the human-judgment layer: the agent does what you'd do — work around the
incidental, fix the test when the app changed, flag the real bug.

## 7. Storage, re-run, board integration

- Scenarios: `Tests/UAT/scenarios/*.yaml`, version-controlled (they evolve with
  the app). Fixtures: a stable `~/uat-fixtures/` (never the owner's real docs).
- Runs: a log per run `{scenario, steps, pass/fail, screenshots, drifts handled}`.
- Board: `covers` ties each scenario to tickets. A green journey is the proof an
  agent attaches to move render-path tickets `validated → done` — finally an
  agent-ownable path past the review ceiling for on-screen behavior.
- Cadence: runs on the VM GUI lane (real WindowServer pixels + a real login
  session), as a nightly/release regression suite — expensive, so not per-commit.

## 8. Skills

- `author-uat` — turn an owner journey / a ticket into a scenario: do it once
  manually via `mac-computer-use`, resolving each step to a verb/AX hint, write
  the YAML, link `covers`.
- `run-uat` — execute a scenario (or the suite), the drift loop, record results,
  advance tickets on green.
(Both added under `.claude/skills/`.)

## 9. Phased build

1. **`mac-computer-use` MCP** (AX + CGEvent + screencapture) — the enabler;
   nothing else works without it. Start AX-only (find/click/type/key/value/tree),
   add vision (screenshot+read) + raw-coordinate fallback after.
2. **Scenario format + `uat-runner`** (agent-driven manually first).
3. **Author the first journeys** for the highest-value render-path tickets (the
   scroll/editor/session journey above; an image-editor journey; a git-review
   journey). Backfill `accessibilityIdentifier`s where steps fall back to vision
   (each fallback is a "add an AX id here" TODO — that investment compounds).
4. **Board `validated → done` integration** on green.
5. **VM nightly/release-gate** wiring.

## 10. Coverage gap this directly fixes

Today an agent's ceiling for render-path behavior is `review` — it can't prove
pixels, so the owner closes them by hand. This framework gives the agent a
*trustworthy, real-UI* proof, so it can drive `validated → done` itself for
on-screen behavior — turning the manual owner-close into an automated regression
asset. That is the structural fix for "model-green ≠ on-screen-works."
