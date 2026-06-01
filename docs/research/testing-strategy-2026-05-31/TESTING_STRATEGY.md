**Context:** Synthesizing the research + audit into a strategy doc the team will execute against. This is the deliverable; I'll write it directly as my return value.

# Testing Strategy + Migration Plan — `markdown_viewer`

## 0. The one idea everything hangs on

A UI defect lives at exactly one layer. The job is to **observe each defect at the lowest layer where it is still faithfully produced**, and reserve a real display only for the residue where the defect *is* in the layer you'd otherwise skip. For this codebase the seams are already built (DI'd `DocumentModel`, SwiftUI-free `ViewerCore`/`ViewerKit`, `AutomationHost` value surface, coordinator/`RepublishInvariant` pattern, Page Objects decoupled from artifact source, `MDVFakeLSPServer` fake-the-other-end template). The heaviness that remains is **historical, not necessary** — the `--script` real-app tier predates the coordinator extraction and its verbs were never refactored into a model-callable function.

---

## 1. The honest layer model

### 1.1 SwiftUI / AppKit (today) — where the "real screen" line actually is

The pipeline, and which stage each tier taps:

```
 SwiftUI body eval ─①─▶ AGGraph ─②layout─▶ NSHostingView→NSView/CALayer ─③draw─▶ layer.contents
                                                                          │
 ════════════════════════════ PROCESS BOUNDARY ═══════════════════════════╪═════
                                                                          ④ WindowServer composite ─▶ pixels
```

| Tier | Mechanism | Taps | Headless? | Permission |
|---|---|---|---|---|
| **T1** pure value/logic | plain XCTest | ①-inputs | yes, host | none |
| **T1m** `@MainActor` model/coordinator | construct `DocumentModel`, dispatch actions, count `objectWillChange` | ① | yes, host | none |
| **T2'** in-process `NSHostingView` walk | `host.layoutSubtreeIfNeeded()` + walk realized `NSView` tree (`DiagnosticDump`) | ②③ structure+geometry | yes, host | none |
| **T2-px** in-process raster | `cacheDisplay` / `ImageRenderer` → bitmap, sample | ③ pixels-as-drawn | yes, host | none |
| **T4** real `.app` `--script` | spawn bundle, JSON dump round-trip | ①②③ in a real process | needs bundle, VM-coupled | none (but blank PNG) |
| **T5** `screencapture(1)` live window | WindowServer pixel readback | **④** | **no — real window** | TCC Screen Recording |

**The line is between ③ and ④, not between logic and view.** Three facts from the research nail it down, and they resolve the only real disagreement (does "pixels" require a screen?):

- **`cacheDisplay` / `dataWithPDF` / `ImageRenderer` lie about composition.** They ask each view to *redraw fresh*, re-rendering exactly the views the live compositor *skips*. So in-process raster (T2-px) is "what each view *would* draw in isolation," not "what the user sees." A green T2-px suite is **not** evidence the window isn't blank. This is precisely the trap that let the `NSRulerView` compositor bug ship behind a green suite.
- **The only stage that reflects the user's pixels is ④, and ④ is out-of-process (WindowServer).** There is no headless way to observe ④. That is an architectural fact, not a tooling gap.
- **Headless-from-a-human ≠ no-display-server.** T5 needs a *display server* (a real login GUI session — the VM), not a *human watching*. `screencapture -l<id>` + variance-sampling is fully automated and capturable to a file. So T5 is still "automatic and headless" in the sense the owner cares about; it just isn't "no compositor."

Same-process raster (T2-px) needs **no** Screen Recording permission; only cross-process ④ capture (T5) hits the TCC wall — and on macOS 15 the grant must go to the `xctest` binary too and resets on every ad-hoc rebuild.

### 1.2 TUI (Rust ratatui, later) — the line is far to the right

```
 state ─update─▶ Model ─render─▶ Cell-grid Buffer ─Backend─▶ bytes ─▶ PTY ─▶ emulator ─▶ pixels
 └────────── pure, deterministic ──────────┘   └──── device/env-dependent ────┘
```

ratatui's `Backend` trait is **cell-oriented, not byte-oriented** (`draw(I: Iterator<Item=(u16,u16,&Cell)>)`), which is *why* `TestBackend` can hold the grid in memory losslessly — styling is structured data, not a parsed escape sequence.

| Layer | Mechanism | Verifies | Real TTY? |
|---|---|---|---|
| L1 logic | call `update(msg)` | state machine, command emission | no |
| L2 **buffer** | `TestBackend` / render to raw `Buffer` | layout, glyphs, **style** (`cell.fg`/`modifier`), cursor, scrollback | no |
| L3 snapshot | `insta` on buffer | visual regression — **but glyph snapshots drop style silently** | no |
| L5 PTY+emulator | `portable-pty` + `vt100` parser | escape emission, `isatty`, termios, SIGWINCH, mouse/paste/kitty, exit-restore | **yes** |

The "real screen" line for TUI sits between L2/L3 and L5. **~90% of TUI correctness is a pure `state → cell grid` function** — test it at the `Buffer` layer where it's deterministic, TTY-free, and *style-inspectable*. The irreducible-TTY residue: `isatty()`-gated behavior, termios raw mode, SIGWINCH, protocol handshakes (mouse/bracketed-paste/kitty), and terminal-state restoration on exit. The one thing *no* automated layer nails: per-emulator grapheme width (wezterm caps at 2 cells; xterm/kitty use `wcwidth` → 4 for ZWJ emoji). Cell tests verify *intent*, not the user's actual column placement.

### 1.3 Vanilla-JS web (later) — a hard cliff, not a gradient

```
 JS ─▶ [1] logic (any JS engine, no DOM)
 HTML ─▶ [2] DOM structure (jsdom — real parser+selectors, NO layout)
 ──────────────── CLIFF ────────────────
 CSS/layout ─▶ [3] computed style + geometry  ┐
 events ─────▶ [4] trusted input + hit-test   ├─ real engine only (headless browser OK)
 raster ─────▶ [5] pixels                      ┘
```

The cliff is **brutal and non-negotiable: layers 1–2 run faithfully in a JS-only runtime; 3–5 require a real engine's cascade/layout/raster.** jsdom does **no layout** — `getBoundingClientRect()` is all zeros, `getComputedStyle` returns *declared* not *resolved* values. Any pixel/geometry assertion in jsdom is testing a lie (happy-dom is *more* dangerous — it invents plausible-looking fake numbers). Two non-obvious correctness footguns:
- **"Headless" is not one thing.** Old pre-2023 headless Chrome was a separate code path that rendered differently; `--headless=new` runs the same browser code. Verify which mode before trusting any headless layout/visual result.
- **Trusted vs synthetic events.** jsdom `dispatchEvent` is `isTrusted:false` — no default actions, no real focus/`:focus-visible`, no hit-testing. Layout-coupled interaction bugs (an invisible overlay eating clicks, `pointer-events:none`, z-index stacking) are **only** caught by real-browser input doing real hit-testing. That's the strongest argument for a small Playwright lane even for a "simple" vanilla UI.

---

## 2. The target pyramid + tooling

### SwiftUI/AppKit (the app today)

```
   ████████████████████████  T1  pure logic/value      host, µs    ~50–60% of regressions
   ██████████████            T1m model/coordinator      host, ms    ~20%  ← THE leverage tier
   ████████                  T2' in-proc NSHostingView   host, ms*   ~10%  (*#192-isolated)
   ███                       T2-px in-proc raster        host, ms    contrast/zero-size/AppKit-chrome only
   ─────────────────────────────────────────────────────────────────────
   ██                        T4 real .app --script       VM, s       launch+wiring+cross-proc-persist smoke
   ▌                         T5 screencapture live        VM, s       ONE ruler-compositor bug class
```

The counterintuitive truth this repo already proves: **the most valuable UI tests are the headless ones.** The `RepublishInvariant` suites pin observability fan-out (the republish-storm perf-bug class — real ~5MB/s leaks, quadratic re-renders) that "drive the app and look at it" is *structurally blind to*. T1m catches bugs T5 cannot.

**Tooling decisions:**
- **ViewInspector — adopt, narrowly.** Now acceptable. Use it for the one thing T1m can't see and T2' is too heavy/poisoned for: *declared* view-tree shape and which conditional branch a state produces (e.g. "rendered mode declares the WebView branch"). Hard limits to respect: it reads *declared* not *resolved* attributes (sees `.foregroundColor(.red)`, can't confirm the glyph rasterized red), breaks per-Xcode against private layout, and needs `sheet2`/`alert2` production shims. Treat it as a **structural assertion** tool, not a visual or layout one — don't let it pull assertions *up* from T1m.
- **No `swift-snapshot-testing`.** It inherits T2-px's compositor blindness entirely (renders off-screen) and carries the bless-the-wrong-baseline maintenance tax. The repo's deferral was correct.
- **Keep `DiagnosticDump` as the T2' engine** — it already serializes alpha/opacity/hidden-ancestor/zero-size/contrast/glyph-status for the whole tree in-process. It's an underused superpower; most T4 assertions could read this JSON from an in-process `NSHostingView`.

### TUI (Rust)
- **L2 `Buffer` assertions as the mass tier**, plus the underused **`vt100`-as-oracle in unit tests**: render to a byte-emitting backend into a `Vec<u8>`, feed `vt100::Parser`, assert `cell.fgcolor()`. This recovers the **style fidelity that glyph snapshots silently drop** without spawning a process — the missing middle between style-blind `insta` and flaky PTY.
- `insta` for layout-at-a-glance only; **assert style at L2** alongside it (belt-and-suspenders, since `.snap` is style-blind).
- Property-based testing on the `update` reducer (random key sequences, assert invariants) — composes beautifully because L2 render is pure.

### Vanilla web
- **Functional-core / DOM-projection architecture**: `reducer`/`viewModel` pure (L1, the mass), one `render(root, vm)` file touches `document.*`. Weaponize the seam frameworks hide.
- jsdom for structure (real parser/selectors — fast, many). **Never assert px in jsdom.**
- **Computed-style assertions** in a `--headless=new` Playwright lane *before* pixel snapshots — real-engine, localizable, low-flake. **DOM+computed-style snapshots** over pixel snapshots for "did output change."
- Pixel snapshots only in a **pinned-render container** (fixed fonts + software raster), small regions.

### The reusable-core consequence (Rust core, per MEMORY)
The architecture *forces* the pyramid the right way: domain/state logic moves into the Rust core, tested at L0/L1 in Rust (`cargo test`, no UI, no FFI) — this becomes the broad base shared by **all three** front-ends. Each front-end then only needs to test its *projection* of core state (T1m/L2/jsdom-L2) plus its thin irreducible-display residue. The core's binary-RPC boundary is itself a contract-test seam: fake the *other end* (the `MDVFakeLSPServer` pattern) to test each side headlessly.

---

## 3. Migration plan (from the audit)

### 3.1 The keystone refactor (unblocks everything else)

**Lift `ScriptRunner.runScriptStep`'s verb `switch` into a free function** `apply(_ verb: String, to model: DocumentModel, sessions: SessionsAppCoordinator)`. Today the verbs (`toggleViewMode`, `zoomIn`, `openPath`, `session-open-new`, `goto-commit`…) are plain method calls coupled to `AppDelegate.self.window/.sessions`. Two callers of the one function:
1. `AppDelegate.runScriptStep` (VM path, kept for true OS-integration smoke).
2. A new **`HeadlessHarness`** that constructs a hermetic `DocumentModel` (DI seam already exists), applies the same verbs, and emits the dump dict in-memory via the existing `automationCurrentState()` — feeding the **existing Page Objects unchanged** (they already consume a `[String:Any]`, indifferent to whether a spawned app wrote it to `/var/folders` or it came from memory).

This single refactor demotes the bulk of the heavy suites from spawn-seconds to in-process-microseconds. The JSON *file round-trip is pure ceremony* — it exists only because producer and consumer were different processes.

### 3.2 The move-down list (concrete, from both audit halves)

| Suite(s) | Now | → Target | Mechanism / why safe |
|---|---|---|---|
| `InteractionScriptTests` (tab/zoom asserts) | T4 | **T1m** | all assertions read `model.tabCount/.zoom/.currentViewMode` — set directly by methods |
| `InteractionScriptTests` `assertHasWebView` | T4 | **T2'** | WKWebView realization already proven in-process by `ContentViewHostingTests` |
| `GoToPathUITests` | T4 | **T1m** | drives `model.commitGoToPath(_:)` + reads `lastGoToError` — pure model, no process |
| `ScenarioTests` (zoom/mode/title) | T4 | **T1m** | `DocumentModel` sequence; only `assertHasWebView` → T2' |
| `Sessions/SessionsKeyboardUITests` | T4 | **T1m** | header *admits* it skips key dispatch; tests pure `sessions.nextSession()/activate(index:)` routing — duplicate of `SessionTabPersistenceTests` at L2 |
| `Sessions/SessionTabBarUITests` | T4 | **T1m** | reads `dump.model.sessions/.activeSessionID` = pure coordinator state; the `+`-button a11y check is already a no-op — delete it |
| `InteractionDeepTests` (tab-cycle/palette/sidebar) | T4 | **T1m** | model-dict reads |
| `LongFlowTests` (per-step invariants) | T4 | **T1m** | title/zoom/frame-present are model reads |
| `FindBarTests`, `FormatToggleTests` | T2'(gated) | **T1m**, **ungated** | carry `renderHost`/`hostedViews` plumbing **no test calls** — dead code; every test is model-level. Delete plumbing, drop the `#192` gate |
| `ComponentVisualTests` (4 tests), `MermaidHostingTests` (HTML/cache tests) | T2'(gated) | **T1m**, ungated | `modeBar`/`palette`/`hex`/`error` and `renderedHTML`/cache are pure model/string asserts paying the WebView-gate tax |
| `RenderedFindBarTests` (3 model tests) | T2'(gated) | **T1m**, ungated | split out of the gate to shrink `#192` blast radius |
| `MarkdownRenderedViewTests` | (mislabeled) | rename → `MarkdownLinkPolicyTests` | already optimal T1 (pure static link-scheme security fn); name oversells — it hosts nothing |
| `LargeFileOpenTests` pattern | T2 | (keep) propagate | watermark-injection (shrink threshold, not the fixture) — apply to any "huge file/many tabs" temptation |

### 3.3 Harness/seam work to make headless the *default*

1. **Per-tier base classes** (`HeadlessUITestCase` / `LiveAppTestCase` / `PixelTestCase`) so tier is in the *type*, and CI selects "headless-safe" without a hand-maintained `--filter`. Today tiering is implicit in target + filename + scattered env-gate (`#192`, `MDV_RUN_LSP_SMOKE`) — there is no machine-checkable assertion that a "headless" test didn't spawn the app. This is what lets `CLAUDE.md` drop the blunt "no `--filter` sweep" rule.
2. **`HeadlessHarness`** (§3.1) producing the dump dict in-memory.
3. **Default graph-quiesce `tearDown`** for any T2' hosting test: flush pending `ViewGraphRootValueUpdater` renders (the `WebViewTestTeardown` pattern) *before* releasing every host — partial mitigation for `#192`.
4. **Narrow the reactivity probe**: host *only the leaf* (`MarkdownRenderedView` alone) not the whole `ContentView`, to minimize `#192`-exposed graph state. The DESIGN.md Tier-2 sketch (`TabBar(model:).frame(...)`) — never built — is exactly this.
5. **Exploit T2-px for AppKit-drawn chrome** (the unclaimed fidelity-per-dollar): off-screen `cacheDisplay` snapshots of *non-WebView* surfaces (tab/mode/status strips, NSTextView source, contrast via the fields `DiagnosticDump` already computes) need no permission and no foreground — a middle tier the repo doesn't use. **Never** for WebView content (WebContent process backing-store is blank off-screen) or the compositor bug (T2-px is structurally blind to it).

### 3.4 The genuine real-screen-only residue (small — named exhaustively)

- **`SourceViewVisualRegressionTests` (T5).** The *only* irreducibly-real-screen suite. Guards exactly **one** bug class — `NSRulerView`-in-`tile()`-in-SwiftUI-commit sibling-blank compositing — observable *only* at ④ via `screencapture(1)`. Cannot demote: T2-px would render the strips correctly while the live window is blank (false green). Already meta-tested (`MDV_ENABLE_BROKEN_RULER=1` proves the variance check has teeth) — the gold standard. **Keep, but make the structural prohibition the primary defense**: "never attach `NSRulerView`, never subclass `NSLayoutManager` in the source view." The rule is cheaper and stronger than the test; T5 is belt-and-suspenders nightly/VM.
- **A single T4 launch-smoke scenario**: app launches, opens a file, dispatches a representative verb, doesn't crash — verifies the AppDelegate↔coordinator *wiring* that only exists in a real process.
- **`InteractionDeepTests.test_resize_changesWindowGeometry` (T4)**: reads back real `NSWindow.frame` after `setFrame`, including OS clamping — no in-process equivalent.
- **`LongFlowTests` zoom-across-relaunch (T4)**: cross-*process* `PreferencesStore` persistence — needs a real second launch.
- **True OS-integration** (not yet automated, stays manual/VM): Services menu, drag-from-Finder, Launch Services, the actual `NSEvent`→menu-selector key-dispatch chain (every "UI" test today enters at the *action method*, never verifying the SwiftUI control→action binding — the honest coverage gap).

Everything else — the entire `RepublishInvariant` family, coordinator suites, cache/leak guards, parsers — is already at its faithful floor (T1/T1m) and **must not be "upgraded" to UI tests.**

---

## 4. Why we kept over-placing — and the guardrail

**Five systemic causes** (root, not symptom):

1. **`xctest` is Xcode-only on macOS**, and the VM is the only host with both Xcode *and* a GUI session. This *deployment* constraint ("where can xctest run") fused in the team's mental model with *necessity* ("needs a window") and *artifact* ("needs the bundle"). Three different things became one.
2. **The compositor bug over-generalized into a prior.** It taught a true, narrow lesson (the view tree and `cacheDisplay` both lie about ④) that calcified into a broad reflex ("to be safe, drive the real app"). Outside that one ruler chain, the tree does *not* lie about what the heavy tests actually assert.
3. **The `--script` runner predates the coordinator extraction.** It was the only way to reach `@MainActor` state when written; the demotions were simply never done after `DocumentModel` became cleanly constructable.
4. **The artifact and the assertion are decoupled in the wrong direction**: a heavy producer (spawned app + blank PNG + tree JSON) feeds a light consumer (model scalars). `MDV_BACKGROUND=1` even proves the heavy tier *can't* produce truthful pixels on the host anyway — you pay process-spawn cost for strictly-not-more signal.
5. **Tier was never a first-class, machine-checkable property** — only target + filename + ad-hoc env gate — so nothing *stopped* a test from sitting too high.

**The guardrail (convention to prevent recurrence):**

> **A test may sit at tier N+1 only if it asserts on an observable that tier N cannot faithfully produce. The PR must name that observable.**

Made enforceable, not aspirational:
- **Tier is the base class** (§3.3.1). A `LiveAppTestCase`/`PixelTestCase` subclass requires a one-line `// TIER-JUSTIFY:` comment naming the ④/cross-process/OS-integration observable that forces it. Default base is headless; you must *opt up*.
- **CI runs the headless tiers as the gating sweep**; T4/T5 are a separate VM lane (nightly + pre-release). Headless is the default *because it's what the merge gate runs*.
- **Code-review checklist line**: "Does this UI test read `model.*` scalars? → it's T1m. Does it read the realized tree only for shape? → T2'. Does it need WindowServer pixels / a real process boundary? → only then T4/T5, and say which."
- The rule cuts *down*: any pressure to push validation *up* into live-window driving is a signal a seam is missing one layer down — build the seam instead.

---

## 5. Sequenced next steps (max regression-catching per unit effort)

1. **Land the keystone refactor** (§3.1): lift `runScriptStep` → free `apply(verb:to:sessions:)`, build `HeadlessHarness` emitting the dump dict in-memory to the existing Page Objects. *Unblocks every T4 demotion; highest leverage single change.*
2. **Add the three per-tier base classes + the `TIER-JUSTIFY` convention** (§3.3.1, §4). *Cheap, makes the new default enforceable before you migrate — so migrations land at the right tier and can't regress.*
3. **Quick wins — delete dead weight**: ungate `FindBarTests`/`FormatToggleTests` and delete their unused `renderHost`/`hostedViews` plumbing; rename `MarkdownRenderedViewTests`→`MarkdownLinkPolicyTests`; delete the no-op `+`-button check. *Hours of work, immediately shrinks the gated/heavy surface and the `#192` blast radius.*
4. **Migrate the T4→T1m bulk** (`InteractionScriptTests`, `GoToPathUITests`, `ScenarioTests`, both Sessions UITests, `InteractionDeepTests`, `LongFlowTests`) — assert `model.*` directly. *Reclaims the VM round-trip for the whole cluster; ~nothing lost (assertions are already state-only).*
5. **Split T2'-gated suites**: demote the model-only tests to ungated T1m; keep a *small* isolated T2' set (with the default graph-quiesce `tearDown`) for the handful of "view layer actually minted a WKWebView" reactivity checks. *Stops `#192` poisoning the main sweep.*
6. **Carve the residue** (§3.4): one T4 launch-smoke + the resize + the relaunch-persistence specials; write the "never attach `NSRulerView`" structural rule into `LESSONS.md` as the primary compositor-bug defense, T5 as belt-and-suspenders. *Locks the heavy tier to its irreducible minimum.*
7. **(When the Rust core lands)** Move domain/state logic into the core, test at L1 in `cargo test` as the shared base; stand up the per-front-end projection tiers (TUI `Buffer`+`vt100`-oracle; web jsdom-L2 + `--headless=new` computed-style lane); fake the binary-RPC other-end per front-end. *Pays the pyramid forward to all three UIs at once.*

**Adopt ViewInspector** at step 5 only, scoped to declared-tree/branch assertions — not as a layout or visual tool.

Relevant files: `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/MarkdownViewer/ScriptRunner.swift`, `/Users/me/Documents/workspaces/claude/markdown_viewer/Tests/ViewerUITests/AppLauncher.swift`, `/Users/me/Documents/workspaces/claude/markdown_viewer/Tests/ViewerUITests/Harness/WebViewTestTeardown.swift`, `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/Automation/DocumentModel+AutomationHost.swift`, `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/DiagnosticDump.swift`, `/Users/me/Documents/workspaces/claude/markdown_viewer/Tests/ViewerUITests/TabRepublishInvariantTests.swift`, `/Users/me/Documents/workspaces/claude/markdown_viewer/Tests/ViewerUITests/SourceViewVisualRegressionTests.swift`, `/Users/me/Documents/workspaces/claude/markdown_viewer/DESIGN.md`, `/Users/me/Documents/workspaces/claude/markdown_viewer/LESSONS.md`.