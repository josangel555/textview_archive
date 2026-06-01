I now have a thorough, evidence-grounded understanding. Here is my analysis.

---

# Test-tier topology of `markdown_viewer` — why tests sit heavy, what seams already exist, and what's missing to make headless the default

## 0. The empirical lay of the land (so the rest is grounded, not asserted)

Counts as of this read:

| Target | Test methods | UI/display dependence |
|---|---|---|
| `ViewerKitTests` | 97 | none (Foundation value types) |
| `ViewerCoreTests` | 1808 | none (logic/parsers/git/sqlite/LSP-via-fake-server) |
| `ViewerUITests` | 793 | mixed — **76 of 101 files** `@testable import ViewerUI` and drive the model in-process |

Of the 101 `ViewerUITests` files, only **~12** are genuinely "heavy":

- **Real-app spawn** (`MultiScenarioTestCase` / `AppLauncher` / `LaunchHarness`): `InteractionScriptTests`, `InteractionDeepTests`, `LongFlowTests`, `ScenarioTests`, `GoToPathUITests`, `Editor/EditorMultiScenarioTests`, `Editor/EditorPhase4ScenarioTests`, `Sessions/{OpenInNewSession,SessionsKeyboard,SessionTabBar}UITests`.
- **In-process live-`WKWebView` host** (`#192`-gated): `ContentViewHostingTests`, `MermaidHostingTests`, `DiagnosticDumpTests`, `ComponentVisualTests`, `RenderedFindBarTests`, `FindBarTests`, `FormatToggleTests`.
- **Real pixels via screencapture**: `SourceViewVisualRegressionTests` only (plus `DiagnosticDumpTests` exercising the `cacheDisplay` path).

So the heavy tier is already a thin minority. The interesting question isn't "why is everything heavy" — it's "why do the heavy ones that *don't need* to be heavy still pay full freight," and what's structurally blocking the obvious demotions.

There are effectively **five tiers in practice** (the DESIGN.md Tier 1/1m/2/3/4 taxonomy is partly aspirational — Tier 2 snapshot and Tier 3 ViewInspector were *deferred*, never adopted; no `ViewInspector`/`SnapshotTesting` dep exists, consistent with the minimal-deps rule):

```
T1   ViewerKit/ViewerCore unit            no display, no AppKit-window  ← 1905 methods, instant
T1m  DocumentModel/coordinator unit       @MainActor, NSApplication.shared touched but no window
     + RepublishInvariant                 (this is where the real leverage already lives)
T2'  in-process NSHostingView + layout    real NSView tree, NO NSApp.run, walks subviews
     (ContentViewHostingTests etc.)        ← mints live WKWebView ⇒ #192 abort ⇒ gated out of sweep
T4   real .app via --script               spawn dist/TextView.app, JSON file round-trip, poll exit
T5   screencapture on live window         WindowServer pixels (only tier that sees the compositor bug)
```

---

## 1. The systemic reasons tests landed heavy

These are *causes*, ordered by how much they actually forced heaviness — not the usual "UI is hard to test" platitude.

### 1.1 `xctest` is Xcode-only on macOS, so the cheap headless tier is itself fragile to host

`LESSONS.md` ("VM smoke testing") documents that the swift.org toolchain on a Xcode-less Mac has **no `XCTest.framework`** — `swift test` fails with `no such module 'XCTest'`. This is the foundational constraint that pushes the *whole* program toward the VM: the VM is the only place that has both Xcode (hence xctest) *and* a real GUI session. That coupling is why `CLAUDE.md` says "UI tests belong on the VM" — but note it's a *deployment* constraint (where xctest can run), not a per-test *necessity*. It bleeds into the mental model so that "needs a window" and "needs the VM" got conflated with "needs the real `.app`."

### 1.2 The compositor bug taught the team that the view tree lies — and they over-generalized the lesson

The single most expensive bug in `LESSONS.md` (the `NSRulerView`-in-`tile()`-in-SwiftUI-commit compositor skip) has a brutal property: **every cheaper observation mechanism reports green while the screen is blank.** `recursiveDescription` is correct, instance counts are correct, and crucially `NSView.cacheDisplay(in:to:)` / `dataWithPDF` *also* lie — they re-draw fresh, bypassing WindowServer. Only `screencapture(1)` on a live window sees it.

That's a real, correctly-identified limit (T5 exists for a genuine reason). But its *side effect* is a cultural prior: "the view tree can lie, so to be safe, drive the real app." That prior is over-broad. The compositor bug is a **single, known, structural** failure mode (ruler attachment), now guarded by a dedicated meta-tested T5 test *and* a "don't attach `NSRulerView`" hard rule. Outside that one chain, the view tree does *not* lie about the things the heavy tests actually assert (mode, tab count, zoom, WKWebView presence). The heaviness is partly an emotional residue of one bug.

### 1.3 The `--script` runner predates the coordinator extraction — it was the *only* way to reach `@MainActor` state when it was written

`ScriptRunner.swift` is "pure code-motion out of `main.swift` (2026-05-25)" and the verb dispatcher reaches directly into `AppDelegate.model` / `.sessions` / `.window`. It was built as a VM driver before `DocumentModel` was a cleanly-constructable, dependency-injected object. Look at what the verbs actually *are*: `model.toggleViewMode()`, `model.zoomIn()`, `model.openPath(...)`, `sessions.openFolder(...)`. **Every verb is a plain method call on an object a test can construct directly** (`DocumentModel(controller:history:sidebar:preferences:)`). The script runner is a string-keyed indirection layer over method calls that are now reachable in-process. It survived because it works and the demotions were never done — not because the indirection is needed.

### 1.4 The assertions and the harness are decoupled in the wrong direction

`InteractionScriptTests` is the tell. Its assertions are almost entirely on **model state lifted into the JSON dump** — `dumps[i].model.tabCount`, `.zoom`, `.currentViewMode`, `.sidebar.rootURL`. The test comments explicitly say so: *"Prefer model state over the realised NSView tab count — SwiftUI accessibility identifiers don't always propagate."* So the test already distrusts the view tree and reads the model. But to get that model state it pays for: `killall`, `Process.run`, two `Thread.sleep`s, exit-polling, and a JSON-file round-trip through `/var/folders`. The harness produces a heavy artifact (real-app + PNG + view-tree JSON) when the assertion consumes a light one (model scalars). The only verbs whose assertions *truly* need the realized tree are `assertHasWebView`/`assertNoWebView` (WKWebView presence) — and even that is reproducible in T2' in-process hosting (`ContentViewHostingTests.test_openMarkdown_hostedView_containsWebView` does exactly this without the `.app`).

### 1.5 SwiftUI's process-global view graph poisons the cheap-but-not-cheapest tier (`#192`)

This is the most non-obvious and the most important real limit. `WebViewTestTeardown` documents it precisely: the in-process `NSHostingView` suites don't just leak WebContent processes — they leave a **deferred `ViewGraphRootValueUpdater` render scheduled on the main dispatch queue**, and hundreds of tests later, *any* test that spins the main runloop (e.g. `PluginSubprocessHost.call` → `Process.waitUntilExit()`) drains that stale render against a now-freed AttributeGraph node and `abort()`s the **single shared xctest process** with `AG::precondition_failure`, truncating the alphabetical M→Z tail.

This is the systemic killer of "host in-process as the default": SwiftUI hosting state is **process-global and not reset between tests**, and xctest runs all of a target's tests in one process. So a T2' test is not hermetic the way a T1 test is — it mutates a shared graph that a much-later unrelated test can trip over. The team's response (gate the WebView suites out of the bare sweep behind `MDV_RUN_WEBVIEW_TESTS=1`, same pattern as `MDV_RUN_LSP_SMOKE`) is a *process-isolation* workaround, not a fix. This is the real reason in-process hosting isn't already the default tier: it's cheap per-test but corrupts the shared process for everyone downstream.

### 1.6 Focus/occlusion economics make the real-app path produce *blank* artifacts anyway

`AppLauncher` and the `LESSONS` "test-suite hygiene" note: macOS 14+ blocks `NSApp.activate` from a non-frontmost spawner, so the spawned window is occluded, AppKit suspends drawing for occluded windows, and PNG snapshots come back blank. The harness sets `MDV_BACKGROUND=1` (accessory policy, no activate) precisely *so it doesn't steal the user's keyboard* — which means the heavy real-app path **cannot produce truthful pixels on the host at all**. So you pay full real-app cost for an artifact (JSON view tree + a blank PNG) that the in-process host could produce equivalently and faster. The pixel-truth you actually wanted requires a *foreground GUI session* (the VM), and even there macOS 15 "Screen Capture Privacy" redacts `launchctl asuser`-spawned windows. The heavy tier's marquee capability (real pixels) is the one thing it mostly can't deliver outside a hand-held VM session.

### 1.7 Per-tier discovery: there is no test-level tier tagging, only target-level + filename convention

Tiering is encoded three ways, none of them first-class: by **target** (`ViewerCoreTests` vs `ViewerUITests`), by **file naming** (`*UITests`, `*ScenarioTests`), and by **env-var gate at `setUp`** (`#192`, LSP smoke). There's no per-method trait that says "I am headless-safe." So `swift test --filter ViewerUITests` sweeps pure-model `RepublishInvariant` tests, in-process hosts, and real-app spawns indiscriminately — which is exactly why `CLAUDE.md` has to say "no filter sweeps L4/L5, run UI on the VM." The blunt target boundary forces the conservative blanket rule.

---

## 2. Reusable seams that already exist (the demotion is mostly *available*, not blocked)

The codebase is, ironically, in excellent shape for headless. The seams are real and load-bearing:

- **`DocumentModel` is fully dependency-injected.** `init(controller:history:goToPathHistory:bookmarks:sidebar:preferences:)` — every store takes a `storeURL`/`UserDefaults(suiteName:)`, so a test gets a hermetic model with zero global state. `RepublishInvariant` + `DocumentModelTests` already exploit this. This is the single biggest lever and it's already built.

- **The module boundary is the headless guarantee, enforced by a hard rule.** `ViewerKit` = Foundation only; `ViewerCore` = + AppKit (`NSColor`) + ViewerKit, **no SwiftUI**; SwiftUI is quarantined to `ViewerUI`. The `LESSONS` "Don't import SwiftUI into ViewerKit/ViewerCore" rule is *why* 1905 of ~2700 test methods need no display. Every "extract a pure helper into the right module" refactor (RecentChanges, Metadata, SQLite width) is a deliberate seam-cut to keep logic in the headless tier.

- **The `AutomationHost` protocol is a clean, AppKit-free verb surface over the model.** `DocumentModel+AutomationHost.swift` already re-exposes open/select/setViewMode/find/state/bookmark as protocol methods that "`MCPServer` can call without importing AppKit/SwiftUI." This is the headless command surface the `--script` runner *should* be calling. `automationCurrentState()` returns an `AutomationState` value type — that's the in-memory equivalent of the JSON dump, with no file round-trip.

- **The coordinator + `*RepublishInvariant` pattern is the gold standard already in place.** `FindCoordinator`/`TabCoordinator`/`EditorCoordinator` are `@MainActor ObservableObject`s constructed standalone; `countDocumentRepublishes(while:)` (in `TabRepublishInvariantTests`) sinks `objectWillChange` and counts. These tests assert *observability semantics* — "a CSV-filter edit fires zero `DocumentModel.objectWillChange`" — which is **the single most valuable UI behavior to pin** (the republish-storm class of perf bug) and they do it with *no view at all*. Each file has a negative-control test ("publisher still fires on its own mutation") so the invariant can't silently rot. This pattern caught a class of bug that "drive the real app and look" never would, and it's 100% headless.

- **`EditorCoordinator`'s closure-injected side effects are explicitly headless seams.** DESIGN.md: *"`onReloadFromDisk`, etc. keep the coordinator headless-testable."* Disk I/O, file-watcher pause/resume, tab replacement — all injected as closures the test can stub. `EditorCoordinatorDiskRoundtripTests` does a real disk save without the app.

- **`MDVFakeLSPServer` is the template for "fake the subprocess, not the integration."** A host-runnable executable speaking LSP framing on stdio with env-var-driven canned responses. It lets `LSPClient`/`LSPPool` be exercised end-to-end **with no sourcekit-lsp and no app** — and `ViewerCoreTests` has ~25 LSP test files riding on it. This is the proof that even subprocess/IPC behavior demotes to T1 with the right fake.

- **Page Objects already abstract the assertion from the artifact source.** `DumpPage`/`ModeBarPage`/etc. read a `[String: Any]` dump. Nothing about them requires the dump to come from a *file written by a spawned app* — the same dict could be produced in-process from `automationCurrentState()` or `DiagnosticDump.dump(window:)`. The seam to swap the artifact *producer* under a fixed *consumer* is already there.

- **`DiagnosticDump.dump(window:)` works on any `NSWindow`**, including one built in-process via `NSHostingController` (no `NSApp.run`). `ContentViewHostingTests` proves you can host `ContentView`, force layout, and walk the tree without launching the bundle.

---

## 3. What's missing to make headless the default

Concrete, codebase-specific gaps — these are the *actual* blockers, not "write more tests."

### 3.1 No in-process headless harness that produces the dump dict (the #1 missing piece)

The `--script` verbs and the JSON-dump shape are the contract. What's missing is a `HeadlessHarness` that:
1. constructs a hermetic `DocumentModel` (the seam exists),
2. interprets the *same verb vocabulary* as `ScriptRunner.runScriptStep` against that model (the verbs are already plain method calls),
3. produces an `AutomationState`/dump dict in memory (the seam exists via `automationCurrentState()`),
4. feeds it to the **existing Page Objects** unchanged.

This collapses `InteractionScriptTests`, `EditorMultiScenarioTests`, the Sessions UI tests, and `GoToPathUITests` from T4 (spawn + sleep + poll + file I/O, ~seconds each) to T1m (microseconds, hermetic). The verb-dispatch logic currently lives in an `AppDelegate` extension coupled to `self.window`/`self.sessions` — **the missing refactor is to lift the `switch cmd` into a free function `func apply(_ verb: String, to model: DocumentModel, sessions: SessionsAppCoordinator)`** that both `AppDelegate.runScriptStep` (VM path, kept for true OS-integration smoke) and the new headless harness call. Single source of truth for the verb semantics, two front-ends.

### 3.2 No per-method tier trait — tiering can't be expressed, only filtered by target/filename

Missing: a lightweight tagging mechanism so `swift test` can select "headless-safe only" without a hand-maintained `--filter` list. Options that respect the minimal-deps rule (all stdlib/XCTest):
- An `XCTestCase` base subclass per tier (`HeadlessUITestCase` vs `LiveAppTestCase` vs `PixelTestCase`), so the tier is in the type, and a CI invocation targets a base class.
- Or an env-gate convention generalized from `#192`/LSP-smoke into one documented set: `MDV_TIER=headless|live|pixel`.

Right now the tier is *implicit in where the file imports from* — there's no machine-checkable assertion that a "headless" test didn't accidentally spawn the app.

### 3.3 The `#192` AttributeGraph corruption has no per-test reset, so T2' can't be the default

This is the genuine technical blocker for "host in-process everywhere." Until there's a way to **drain/reset SwiftUI's process-global view graph between tests** (the `WebViewTestTeardown.pumpMainQueue()` flush is a partial mitigation but the comment is explicit it *can't reach* the process-global corruption), in-process hosting must stay process-isolated. The missing piece is either:
- a reliable per-test graph-quiesce (flush all pending `ViewGraphRootValueUpdater` renders in `tearDown` *before* releasing every host — `WebViewTestTeardown` does this for WebView suites; it would need to be the default `tearDown` for *all* hosting tests), or
- running hosting tests in **forked/isolated processes** (xctest doesn't fork per-test; would need a custom runner or splitting hosting suites into their own target).
Candid limit: **this may be unfixable from the test side** — it's SwiftUI internal state. The pragmatic answer is to *avoid* T2' wherever T1m suffices (most cases — assert model state, not view tree) and keep T2' as a small, isolated, opt-in suite for the handful of "did the view layer actually mint a WKWebView" checks.

### 3.4 No headless equivalent for the one assertion T1m can't make: "view layer reacted to model"

`assertHasWebView` is the canonical "the SwiftUI body actually swapped views when the model changed" check. T1m can't see this (no view). T2' can but is `#192`-poisoned. Missing: a **narrower, cheaper reactivity probe** than hosting the whole `ContentView`. Two underused options:
- Host *only the leaf view under test* (`MarkdownRenderedView` alone, not the full `ContentView` tree) in an `NSHostingView` — far less graph state, less `#192` exposure. The DESIGN.md Tier-2 sketch (`TabBar(model:).frame(...)`) is exactly this and was never built.
- Assert the **derived published property** instead of the rendered view: if `model.currentViewMode == .rendered` *deterministically implies* a WKWebView (it does — `ContentView.loadedView` branches on it), then pinning the branch *condition* in T1m plus one T2' smoke that the branch *wires* a WKWebView gives you the coverage without hosting on every test.

### 3.5 The pixel tier (T5) has no host story and is effectively manual-only

Candid limit, documented thoroughly in `LESSONS`: the compositor bug is screencapture-only; `cacheDisplay`/`dataWithPDF` lie; the host can't foreground the spawned app (occlusion → blank); the VM redacts `launchctl asuser` windows (macOS 15 Screen Capture Privacy). **There is no headless path to T5 and there probably can't be** — observing WindowServer composition *requires* WindowServer composition. The realistic move is to **shrink T5 to its irreducible core**: it exists to guard exactly one bug class (ruler-tile-layout), it's already meta-tested (`MDV_ENABLE_BROKEN_RULER=1` proves it detects the regression), and it's gated to skip cleanly when capture is unavailable. Don't try to demote it; instead lean on the *structural* rule ("never attach `NSRulerView`, never subclass `NSLayoutManager`") as the primary defense and treat T5 as a belt-and-suspenders nightly/VM check. The structural prohibition is cheaper and stronger than any test.

---

## 4. Non-obvious / counterintuitive angles

- **The most valuable UI tests in this repo are the *headless* ones.** The `RepublishInvariant` suite pins observability fan-out (the republish-storm perf-bug class) — a property that's *invisible* to "drive the app and look at it" and that caused real ~5 MB/s leaks and quadratic re-renders. Counterintuitively, the cheapest tier catches the bugs the expensive tier structurally can't. The instinct "important UI behavior needs a real window" is backwards here.

- **The JSON file round-trip is pure ceremony.** The dump is `[String: Any]` serialized to `/var/folders` and re-parsed. In-process, `automationCurrentState()` *is* that dict already. The file exists only because the producer (spawned app) and consumer (test process) are different processes — an artifact of the `--script` architecture, not a requirement. Same Page Objects, in-memory dict, zero I/O.

- **`MDV_BACKGROUND=1` quietly proves the real-app tier can't do its headline job.** It's set so tests don't steal keystrokes — but accessory + no-activate means the window is occluded and PNGs are blank. So the heavy tier produces the *same* truthful artifact (view-tree JSON) as in-process hosting plus a *useless* blank PNG. You pay process-spawn cost for strictly-not-more signal.

- **The fake-subprocess pattern (`MDVFakeLSPServer`) generalizes to MCP and plugins.** The MCP server and `PluginSubprocessHost` are already tested in `ViewerCoreTests/Automation` and `Plugins` — i.e. the project already knows how to test IPC headlessly by faking the *other end*. The same discipline applied to the app-driving layer (fake the *frontend* = construct the model directly, skip the process) is the demotion of §3.1.

- **Counterintuitive limit: more in-process hosting is *not* strictly better.** Because SwiftUI's graph is process-global and xctest doesn't isolate per-test (`#192`), naively converting T4 tests to "host `ContentView` in-process" would *spread* the AttributeGraph-abort blast radius into the main sweep. The right move is T1m (model only, no host) for the 90% case and a *small, isolated* T2' for the reactivity 10% — not "host everything."

- **`NSWindow.windowNumber`-to-file is a neat WindowServer seam** (lets `screencapture -l<id>` target the exact window without private `CGWindowList` enumeration) — worth preserving for the irreducible T5, and a good example of the codebase already minimizing the heavy tier's footprint.

## 5. Bottom line

The heaviness is **mostly historical, not necessary.** The seams for headless are already built and load-bearing — DI'd `DocumentModel`, the SwiftUI-free module boundary, the `AutomationHost` value-surface, the coordinator/`RepublishInvariant` pattern, Page Objects decoupled from artifact source, and `MDVFakeLSPServer` as the fake-the-other-end template. The real-app `--script` tier persists because (a) it predates the coordinator extraction, (b) its verbs were never refactored into a model-callable free function, and (c) `xctest`-on-VM coupling fused "needs a window" with "needs the bundle" in the team's mental model.

Three genuine limits remain, in descending tractability:
1. **`#192` SwiftUI process-global graph corruption** — keeps in-process hosting opt-in; likely unfixable from the test side, so route around it (prefer model-state T1m, isolate T2').
2. **T5 pixel observation requires WindowServer** — irreducible; shrink T5 to the one ruler bug class and lean on structural prohibitions.
3. **`swift test` needs Xcode's xctest** — a deployment constraint that should *not* dictate per-test tiering once §3.1/§3.2 land.

The highest-leverage missing piece is one refactor: **lift `runScriptStep`'s verb `switch` into a free `apply(verb:to:sessions:)` function**, build a `HeadlessHarness` that runs the same verbs against a hermetically-constructed `DocumentModel` and emits the dump dict in-process for the existing Page Objects, and add a per-tier base class so CI can select "headless-safe" without a hand-maintained filter list. That alone demotes the bulk of `InteractionScriptTests` / `EditorMultiScenarioTests` / Sessions-UI / `GoToPathUITests` from spawn-the-app seconds to in-process microseconds, leaving only true OS-integration smoke (Services, drag-from-Finder, Launch Services, gatekeeper) and the single ruler-compositor pixel guard genuinely heavy.

Relevant files: `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/MarkdownViewer/ScriptRunner.swift`, `/Users/me/Documents/workspaces/claude/markdown_viewer/Tests/ViewerUITests/AppLauncher.swift`, `/Users/me/Documents/workspaces/claude/markdown_viewer/Tests/ViewerUITests/Harness/WebViewTestTeardown.swift`, `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/Automation/DocumentModel+AutomationHost.swift`, `/Users/me/Documents/workspaces/claude/markdown_viewer/Tests/ViewerUITests/TabRepublishInvariantTests.swift`, `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/DocumentModel.swift:239`, `/Users/me/Documents/workspaces/claude/markdown_viewer/DESIGN.md:374`.