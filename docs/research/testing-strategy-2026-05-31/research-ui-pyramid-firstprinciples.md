This is a research/knowledge question, not a codebase task. The user wants a thorough, first-principles answer on headless GUI testing. Given the heavy CLAUDE.md context about a macOS/SwiftUI markdown viewer with a VM-based UI testing setup, I should ground the abstract principles with concrete mechanisms — but the question is general. Let me think hard and write it directly. No files to create per instructions; return the answer as my message.

Let me draw on the actual codebase context for grounding examples since it's highly relevant (the project literally has a "don't run UI tests on host, use VM" rule that embodies the core tension here).

# Headless GUI Regression Testing — From First Principles

## The core reframe: "GUI test" is a category error

The single most expensive mistake in UI testing is treating "the UI" as one monolith to be validated by driving a live window. In reality a GUI app is a **stack of independent contracts**, and a defect lives at exactly one layer. The optimal strategy is to push every defect class down to the cheapest layer that can still observe it, and reserve the real-display layer for the residue that *provably* cannot be observed anywhere else.

So the right mental model isn't "how do I automate clicking" — it's **"what is the lowest layer at which this specific bug becomes observable, and what is the smallest observable proxy for it?"** Most "you need a real screen" intuitions are wrong: the bug was observable three layers down, you just never built the seam.

---

## The decomposition: what a GUI actually is

```
┌─────────────────────────────────────────────────────────────┐
│ L6  Pixels on a physical display (photons, refresh, HDR)     │  ← real hardware only
├─────────────────────────────────────────────────────────────┤
│ L5  Compositor / window server (GPU compositing, vsync,      │  ← real display server
│      occlusion, color mgmt, multi-monitor, subpixel AA)      │
├─────────────────────────────────────────────────────────────┤
│ L4  Renderer output (rasterized bitmap of a view/layer)      │  ← offscreen-capturable
├─────────────────────────────────────────────────────────────┤
│ L3  Layout / geometry (frames, constraints, intrinsic sizes, │  ← pure computation
│      text wrapping, flexbox/auto-layout solve)               │
├─────────────────────────────────────────────────────────────┤
│ L2  View tree / scene graph (what nodes exist, their props,  │  ← pure data structure
│      a11y tree, semantics, z-order intent)                   │
├─────────────────────────────────────────────────────────────┤
│ L1  View-model / presentation state (formatted strings,      │  ← plain unit tests
│      enabled/disabled, derived flags, selection)             │
├─────────────────────────────────────────────────────────────┤
│ L0  Domain / business logic (no UI types at all)             │  ← plain unit tests
└─────────────────────────────────────────────────────────────┘
```

Two seams dominate the economics:

- **L4 is the highest layer you can reach with zero on-screen window.** A renderer can rasterize into an offscreen buffer (bitmap context, FBO, software raster). Everything at or below L4 is automatable headlessly. The line "needs a real display" should sit **between L4 and L5**, not between L1 and L2 — which is where most teams accidentally draw it by reaching for a full UI automation driver.
- **L1/L2 is where most regressions actually originate.** Empirically, the overwhelming majority of UI regressions are wrong state, wrong derived value, wrong enablement, wrong node-present-or-not, wrong wiring of action→state. None of that is a pixel problem. It's a data problem wearing a UI costume.

---

## Defect taxonomy → cheapest catching layer

| # | Defect class | Example | Cheapest layer | Mechanism |
|---|---|---|---|---|
| 1 | Wrong domain result | Sum is wrong, sort unstable | L0 | Plain unit test |
| 2 | Wrong presentation state | Save button enabled on clean doc; `"$1,000"` vs `"$1000"` | L1 | Unit-test the view-model / reducer |
| 3 | Wrong wiring | Click "delete" calls "duplicate"; menu item bound to dead command | L1/L2 | Dispatch the action programmatically, assert state delta |
| 4 | Wrong tree shape | Empty-state view missing when list is empty; modal not in tree | L2 | Snapshot the view/a11y tree as data |
| 5 | Lifecycle / resource | Per-tab observer not torn down; retain cycle; leaked timer | L1/L2 | Allocation/teardown assertions, leak counters |
| 6 | State-machine / concurrency | Double-submit, stale async result overwrites newer, race on close | L1 | Deterministic scheduler + invariant assertions |
| 7 | Layout / geometry | Text clipped, overlap, 0-height row, RTL mirror wrong | L3 | Headless layout solve + frame assertions |
| 8 | Internationalization overflow | German label truncated; CJK line-break wrong | L3 | Pseudo-locale + layout solve |
| 9 | Drawing correctness | Wrong color, missing border, gradient inverted, icon flipped | L4 | Offscreen render + image assertion |
| 10 | Theming / dark mode / contrast | Invisible text in dark mode, fails WCAG contrast | L4 | Offscreen render per appearance + computed-contrast check |
| 11 | Accessibility semantics | Button has no label, wrong role, focus order broken | L2 | A11y-tree audit (data, no pixels) |
| 12 | Compositor behavior | Tearing, vsync stutter, occlusion wrong, layer-blend artifact | L5 | **Real display server** |
| 13 | GPU/driver-specific raster | Shader differs per GPU, subpixel AA, HDR tone-map | L5/L6 | **Real hardware matrix** |
| 14 | Input/event plumbing through OS | Global hotkey, IME composition, trackpad gesture, drag across apps | L5 | **Real window + event injection** |
| 15 | True end-to-end | App launches, opens file, doesn't crash, windows survive | L5 | **Smoke test on real session** |

The table's punchline: **rows 1–11 — the bulk of regressions by count — are catchable with no on-screen window.** Only 12–15 genuinely need a display server, and even several of those need it only as a *substrate*, not as a thing a human looks at.

---

## Layer-by-layer: the actual mechanisms

### L0/L1 — Make the view-model a first-class testable object

This is the highest-leverage and most underused move. The reason teams end up needing fragile end-to-end UI tests is that they **never extracted the presentation logic from the view**, so the only place the logic is observable is through a live widget.

- **Architect for a seam.** MVVM / Redux-style reducers / "humble object" pattern / The Elm Architecture all exist for *exactly* this: the view becomes a thin, logic-free projection of a plain value you can construct and assert in a microsecond. A reducer `(State, Action) -> State` is the ideal — pure, deterministic, exhaustively testable, and it captures defect classes 2, 3, 5, 6 outright.
- **Test actions, not clicks.** "User taps Save" → don't synthesize a tap; *dispatch the Save action* and assert the resulting state/effects. You lose the "is the button actually wired" check — but that's a separate, cheap L2 check (the binding exists), not a reason to drive a live window.
- **Counterintuitive:** the more your tests *look like* UI tests (find element, tap, assert visible), the worse your architecture is. Good UI test suites are mostly boring value-equality assertions on structs.

*(In this very codebase, the `ViewerCoreTests` split — `TabsState`, `DocumentController`, `EditorCoordinator` state-machine + republish-invariant tests — is precisely this discipline. Those run on the host with no window. The recent "fix latent per-tab leak in cursor/scroll/diagnostics dicts" commit is defect class 5 caught at L1 with a teardown assertion, not by staring at a window.)*

### L2 — Snapshot the tree as *data*, not as an image

Underused and powerful: serialize the view hierarchy / scene graph / accessibility tree to a stable textual form (JSON, S-expression, indented text) and diff it.

- This catches "the empty-state view disappeared", "modal isn't mounted", "two copies of the toolbar", "z-order intent wrong" — **without rendering a single pixel.** It's a `git diff` on structure.
- React's test renderer, SwiftUI/AppKit view-hierarchy dumps, the platform accessibility tree, Android's view-node dump all give you this. The a11y tree is especially good because it's *semantic* — it encodes role, label, value, focusability — so one artifact serves both structural snapshot **and** accessibility audit (defect class 11).
- **Why it beats image snapshots:** structural snapshots are stable across font-rendering noise, antialiasing, and OS point-releases; they diff legibly (you see *what node* changed, not "127 pixels differ"); and they don't need a GPU. Reach for pixels only when the bug is *in the pixels*.

### L3 — Layout is pure math; solve it headlessly

Constraint solvers (Auto Layout / Cassowary), flexbox engines (Yoga), and text layout (line-breaking, shaping) are deterministic functions. You can drive them with no window:

- Instantiate the view, give it a bounds, force a layout pass, read back frames. Assert "label is not clipped", "no two siblings overlap", "row height > 0", "content fits at 320pt width".
- **Property-based layout testing (rare, high-value):** generate random container sizes and assert *invariants* rather than golden frames — nothing overflows its parent, sum of children ≤ parent, no negative dimensions, monotonic reflow. This finds the catastrophic edge (tiny window, huge font) that a fixed golden never exercises.
- **Pseudo-localization** (defect class 8): replace strings with accented, ~40% longer surrogates (`Ŝéttîîngş…`) and run the layout solve. Catches truncation and hardcoded-width bugs across the whole app without translators or a screen. Severely underused outside large i18n shops.

### L4 — Offscreen rendering: pixels without a window

This is the boundary that confuses people. **You can rasterize without a display server.** Render a view/layer into an offscreen bitmap context / framebuffer object / software rasterizer and assert on the bytes. No window ever appears.

Two distinct techniques, often conflated:

1. **Image snapshot (golden / approval) testing** — render, compare to a committed reference image within a tolerance. Catches drawing/theming regressions (classes 9, 10). The right way to do it:
   - **Tolerance + perceptual diff, not exact equality.** Exact-match goldens are the most-hated flaky tests in existence because AA and font rasterization jitter by a pixel. Use a perceptual metric (SSIM / ΔE in a perceptual color space) with a budget, and **render at fixed scale, fixed font, fixed color space** to kill nondeterminism at the source.
   - **Pin the renderer, not just the test.** Fix DPI/scale factor, force a specific font (ship a test font), disable animations, freeze any RNG, fix the color profile. Most golden flakiness is uncontrolled inputs, not a flaky comparator.
   - **The deeper trap:** goldens test *self-consistency over time*, not *correctness*. A wrong layout that's wrong identically every run passes forever. They're regression nets, not specs.

2. **Computed-property assertions on rendered output** — far more underused and far more robust than golden images. Instead of comparing whole images, render and then *compute a semantic property*:
   - **Contrast/accessibility:** sample text-vs-background luminance, assert WCAG ratio. Catches "invisible text in dark mode" deterministically with zero golden maintenance.
   - **Did-anything-draw:** assert the dirty rect is non-empty, or that pixel variance > 0 (catches "rendered all-transparent / all-black" — a shockingly common real bug).
   - **Region invariants:** "the selected row's background is the accent color" — sample one pixel, compare to the theme token. Stable across unrelated layout churn.
   - **Bounding-box-of-drawn-content** vs expected frame — catches overflow that layout frames alone miss (e.g. a shadow/glow drawn outside bounds).

   These survive redesigns that nuke golden images, and they encode *intent* ("text must be legible") rather than *appearance* ("text must look exactly like this PNG").

### L5/L6 — The genuine display-required residue

Be candid: some things cannot be faithfully reproduced offscreen, because the bug **is in the layer you're skipping.**

- **Compositor & window-server behavior (class 12):** vsync/tearing, layer-blend and occlusion, multi-monitor straddling, fractional-scale boundaries, live-resize, the macOS *compositor* path (distinct from the in-process draw path). The project's own `LESSONS.md` notes a "compositor bug" — that is by definition not catchable at L4, because L4 *is* the layer the compositor sits above. If your renderer draws the right bitmap but the compositor mishandles it, an offscreen render shows green while the screen is wrong.
- **GPU/driver-specific rasterization (class 13):** shader rounding, subpixel text AA, HDR tone-mapping, color management end-to-end. A software offscreen raster won't match the GPU path bit-for-bit. Needs a real GPU matrix.
- **OS-mediated input (class 14):** global hotkeys, IME/CJK composition, trackpad gestures, drag-and-drop *between apps*, Accessibility-API-driven automation, focus stealing, Spaces/full-screen transitions. These traverse the window server's event machinery you can't fully fake in-process.
- **True launch smoke (class 15):** does the signed `.app` actually launch under a real login/window session, acquire its TCC permissions, open a file, and not crash. This is a *liveness* test, not a *pixel* test — but it needs a real session.

**Key nuance for "no human looking":** L5 needs a *display server*, not a *human*. A virtual/offscreen display server (Xvfb-style on Linux; a headless/VM login session on macOS) gives you the compositor and event plumbing while still being fully automated and capturable to a file. So most of L5 is "headless" in the sense the user cares about (no human, capturable artifact) even though it is *not* "no display server." That's the real distinction the question is circling: **headless-from-a-human ≠ no-display-server.** The truly irreducible-to-hardware set shrinks to L6 + driver-specific L5: physical refresh, real-panel HDR/color, real touch digitizer, real GPU driver quirks — a tiny tail you cover with a small device lab and sampling, not per-commit.

*(This codebase's split mirrors exactly this: pure-logic suites run on the host (L0–L2); `scripts/vm-smoke.sh` and `ViewerUITests` run on the UTM VM — a real-but-headless-from-a-human macOS session — because they exercise NSApplication, the compositor, and launch liveness. The CLAUDE.md rule "do NOT run UI tests on the host" is enforcing the L4/L5 boundary as a process rule.)*

---

## Non-obvious / underused / counterintuitive techniques

- **Determinism is the whole game.** Every flaky UI test is an uncontrolled input: a clock, an animation, an async scheduler, an RNG, a font-rasterizer, an unsorted dictionary iteration. Make UI tests deterministic *by construction*: inject a virtual clock, replace the async scheduler with a synchronous/controllable one, disable animations globally in the test bootstrap, freeze RNG seeds, fix locale/timezone/color-profile. A deterministic L4 render test is more valuable than ten "real screen" tests because it can run per-commit without quarantine.
- **The async scheduler is the highest-ROI seam after the view-model.** Most "race / stale result / double-submit" bugs (class 6) are untestable through a live UI (you can't reliably interleave) but *trivially* testable with a controllable scheduler where you single-step the interleavings. This is where a `(State, Action) -> (State, [Effect])` design pays off massively — you assert the effect *intent* without running it.
- **A11y tree as the universal headless oracle.** The accessibility tree is the single richest data structure the OS will hand you about a live UI without pixels: roles, labels, values, hierarchy, focus order, enabled state. One audit pass covers structural snapshot, wiring, enablement, *and* accessibility compliance. Most teams ignore it except for disability compliance — it's actually the best general-purpose headless assertion surface there is.
- **Differential / metamorphic testing instead of goldens.** When you have no oracle for "correct pixels," test *relationships*: rendering the same content at 1x then 2x should produce geometrically-scaled output; LTR vs RTL should mirror; light vs dark should preserve contrast and structure; rendering twice should be byte-identical (idempotence). These catch real bugs without ever committing a reference image to bless.
- **Property-based testing on UI state machines.** Generate random action sequences against the reducer and assert invariants: "no two tabs share an id", "closing the last tab yields a valid empty state", "selection always points to an existing item", "republish is idempotent". This finds the weird sequence a human scripter never tries. (The repo's "republish-invariant" tests are this idea.)
- **Mutation testing your UI logic tests.** Since the view-model is now plain code, run a mutation tester against it — it tells you whether your "we have 88 tests" actually *constrains* behavior or just executes lines. UI suites are notorious for high coverage / low assertion-density; mutation score exposes that.
- **Snapshot the *intent*, render the *appearance* sparingly.** Default to structural/semantic snapshots (cheap, legible diffs, GPU-free); escalate to pixel goldens only for the handful of views whose entire reason to exist is a specific visual (a custom-drawn chart, a gradient, an icon). Inverting this default — pixel-snapshotting everything — is the classic way to build a suite everyone disables.
- **Contract-test the platform boundary, don't re-test the platform.** You don't need a real window to verify *your* code calls `setEnabled(false)` — assert the call. Reserve the real window for verifying the *integration* (the OS actually honors it), and do that sparingly. Most "we need E2E" is really "we never asserted the outgoing call."
- **Record/replay event traces as data.** Capture a real interaction once (on a real session), serialize the event stream, then replay it against the headless renderer/reducer in CI. You get the realism of a real gesture sequence with the determinism and speed of an offscreen run — the live-session cost is paid once, not per-commit.

---

## Candid limits — where this strategy genuinely leaks

- **Goldens encode appearance, not correctness.** They only catch *changes*, and they will bless a bug that was present when the reference was taken. They also impose real maintenance tax and tempt teams into "just re-bless everything," which silently launders regressions. Use them surgically.
- **Offscreen render ≠ on-screen render.** Even pinned, the software/offscreen path can diverge from the GPU compositor path (AA, subpixel, color management, blend). An L4 test can be green while L5 is broken. You cannot fully close the compositor/driver gap without real hardware — only *shrink* it and cover the residue by sampling.
- **In-process driving misses the OS.** Anything that crosses the process/window-server boundary — focus, IME, global input, cross-app DnD, TCC/permission prompts, multi-window/Spaces — is only honestly tested on a real (headless-from-a-human) session. Faking it in-process tests your mock, not the OS.
- **The combinatorial surface is unbounded.** Sizes × locales × appearances × dynamic-type × GPUs × OS versions is effectively infinite. You manage it with *invariants and property tests* (which generalize) over *enumerated goldens* (which don't), and accept that the long tail is found by sampling + field telemetry, not exhaustive pre-merge testing.
- **A passing headless suite proves the parts, not the felt experience.** Perceived jank, animation timing feel, gesture latency, "does this layout *look* balanced" are human-judgment properties. You can measure proxies (frame budget, dropped frames, INP/latency percentiles) but cannot fully automate taste. That residue is real and small — don't pretend it's zero, don't let it justify automating nothing.

---

## The optimal allocation (the actual recommendation)

```
              cost/run   regressions caught   run cadence
L0/L1  logic    ~μs            ~50–60%          every commit, host, no window
L2     tree     ~ms            ~15%             every commit, host, no window
L3     layout   ~ms            ~10%             every commit, host, no window
L4     offscreen ~10ms         ~10%             every commit, host, no window
─────────────────────────────────────────────────────────────────────────
L5     headless display ~s     ~5%              per-PR / nightly, VM/Xvfb (no human)
L6     real HW     ~min        tail             pre-release sampling + field telemetry
```

Spend your engineering effort *building the seams* (view-model extraction, injectable scheduler/clock, structural-snapshot harness, offscreen-render harness, a11y-tree audit) — those are what move regressions down into the cheap, headless, deterministic layers. The real-display lab is a thin top cap for the compositor/driver/OS-input residue plus a launch smoke, run sparingly and captured to artifacts so no human has to watch. Treat any pressure to push validation *up* into live-window driving as a signal that a seam is missing one layer down.