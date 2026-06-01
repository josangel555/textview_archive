I have everything I need — the project's real techniques across the full spectrum, plus the broader landscape and the mechanism-level details. Let me write the comprehensive answer.

---

# Testing SwiftUI (and AppKit-hosted SwiftUI on macOS): The Full Landscape

This maps every technique by the **mechanism it actually exercises**, not by tool name. The single most important axis — the one almost every blog post gets wrong — is **where in the rendering pipeline a technique taps in**, because that determines what it can and cannot observe. I'll establish that pipeline first, then walk each technique against it.

The codebase at `/Users/me/Documents/workspaces/claude/markdown_viewer` is an unusually disciplined real-world example: it runs five distinct tiers and documents *exactly* which bug class each tier is blind to. I draw on it throughout because it demonstrates the limits empirically (it shipped a compositor bug behind a 100%-green suite — see below).

---

## 0. The rendering pipeline — the axis everything hangs on

```
  SwiftUI View struct (value type, your code)
        │  ① body evaluation / diffing  ──────────── pure value computation
        ▼
  SwiftUI's internal attribute graph (AGGraph)
        │  ② layout pass (sizeThatFits / placement)
        ▼
  Realized backing tree
   • on macOS via NSHostingView → NSView / CALayer subtree
   • leaves: NSTextView, WKWebView, MTKView, custom NSViewRepresentable
        │  ③ draw(_:) / display → CALayer.contents (bitmaps, glyphs)
        ▼
  ───────────── PROCESS BOUNDARY ─────────────
        │  ④ WindowServer composition (out-of-process, GPU)
        ▼
  Physical framebuffer → pixels the human sees
```

Every technique listens at exactly one of these stages. **The further down you tap, the more real the signal — and the more setup, permission, and flakiness you pay.** The critical and counterintuitive fact: **stages ① ② ③ all run inside your process and can be driven fully headless; stage ④ runs in another process (`WindowServer`) and is the *only* stage that reflects what the user actually sees.** A whole class of bugs lives exclusively at ④ and is structurally invisible to everything above it. This codebase learned that the hard way.

---

## 1. Pure logic / view-model testing (stage ① inputs, never enters SwiftUI)

**Mechanism:** Don't test the `View` at all. Push all decisions into plain value types and `@MainActor` observable models, then test those directly with XCTest / Swift Testing. No `NSHostingView`, no AppKit, no run loop.

This is the dominant strategy in the codebase: ~200 `ViewerCore`/`ViewerKit` cases plus ~40 `ViewerUI` model cases, all host-runnable per `CLAUDE.md`. Look at `Tests/ViewerCoreTests/TabsStateTests.swift`, `PanelVisibilityResolverTests.swift`, `SidebarSectionPlannerTests.swift` — every one is a pure reducer/resolver extracted *specifically so it never needs a view*.

| Can observe | Cannot observe |
|---|---|
| Business logic, state machines, reducers | Anything visual — it never realizes a view |
| `@Published` / `@Observable` state transitions | Layout, sizing |
| Computed view inputs (what a row *would* show) | View-tree structure |
| Derived layout *intent* (`computeWidths`, `filesystemRows`) | Whether the view even compiles into a body |

**Runs:** fully headless / in-memory. No window, no NSApplication, no permissions.

**Non-obvious angle — this is testability architecture, not a test technique.** The reason this tier carries the load is that the team aggressively moved logic *out* of `body`. `TESTING.md` even documents a bug where `SidebarModel.children(of:)` wrote to a cache *from inside `body`* — caught by pivoting the model's contract to a pure function. The lesson: **the cheapest, most reliable SwiftUI test is the one that doesn't touch SwiftUI.** If you find yourself needing ViewInspector to assert behavior, that's often a smell that a decision is trapped inside `body` that should be hoisted into a testable model. Most "SwiftUI is untestable" complaints are really "I put my logic in the wrong layer."

---

## 2. Headless reflection introspection — ViewInspector (stage ① body output)

**Mechanism:** ViewInspector uses Swift's `Mirror` reflection to crack open the opaque `some View` tree *after* `body` evaluates but *before* layout. It walks the value-type composition (`VStack { Text… }`) and lets you find descendants by type, read declared attributes (the `Text`'s string, a declared `.foregroundColor`, `.font`), and fire built-in callbacks (`button.tap()`, `.callOnAppear()`).

| Can observe | Cannot observe |
|---|---|
| View-tree **structure** as declared (`find(ViewType.Text.self)`) | **Layout / sizing** — no layout pass runs; no frames exist |
| Declared modifiers' parameters (color, font, padding *values*) | **Rendered pixels** — nothing is drawn |
| State changes via triggered callbacks (`tap`, `onAppear`) | Whether a modifier *visually took effect* (only that it's attached) |
| Conditional branches (which subview a state produces) | Animations (no timeline, no compositor) |
| `@Binding`/`@State`/`@ObservedObject`-driven output | Gestures through the real event system (only the declared closure) |

**Runs:** fully headless / in-memory. This is its single biggest selling point — no window, fast, deterministic.

**Real limits (be candid):**
- **It reads *declared* attributes, not *resolved* ones.** It sees that you wrote `.foregroundColor(.red)`; it does **not** confirm the glyph rasterized red. A `.foregroundColor` overridden by an ancestor, defeated by `.tint`, or invisible due to a same-color background → all pass.
- **Reflection is fragile against the SwiftUI internals.** Apple changes the private struct layout freely; ViewInspector breaks per Xcode release and chases it. Sheets/alerts/popovers historically can't be inspected as-written — you must swap in `alert2`/`sheet2` wrapper modifiers, i.e. **you modify production code to make it testable**, which is a real cost.
- **Nested `@EnvironmentObject` is unsupported** — you can inspect a child in isolation but not within its parent hierarchy.
- It's a third-party dependency that lives or dies on one maintainer keeping pace with private API churn — relevant given this project's stated minimal-dependency posture. The team **deferred** it (`TESTING.md` Tier 3, "⏸ deferred") for exactly this reason.

---

## 3. In-process backing-tree walk — `NSHostingView` + subtree introspection (stage ② ③ structure)

This is the project's signature technique and the most underused-in-the-wild approach worth highlighting. **No third-party dependency, no window, no permissions — yet it reaches a full layout pass.**

**Mechanism** (see `Tests/ViewerUITests/ContentViewHostingTests.swift:77`):
```swift
_ = NSApplication.shared                 // touch NSApp so NSView lifecycle is sane
let host = NSHostingView(rootView: view) // realizes SwiftUI → real NSView/CALayer tree
host.frame = NSRect(origin: .zero, size: size)
host.layoutSubtreeIfNeeded()             // ← forces a REAL layout pass at a chosen size
// then recursively walk host.subviews and assert on the realized NSView tree
```

`NSHostingView` is the AppKit bridge that turns a SwiftUI tree into a concrete `NSView`/`CALayer` hierarchy. Crucially `layoutSubtreeIfNeeded()` runs **stage ②** — real geometry, real frames, real leaf views (`WKWebView`, `NSScrollView`, `NSTextView`) get instantiated. You then walk `subviews` recursively and assert.

The same harness covers `NSViewRepresentable` / `NSViewControllerRepresentable` leaves transparently, because hosting realizes them into the tree. `MermaidHostingTests.swift:154` asserts a `.mmd` file produces a real `WKWebView` in the subtree (`NSClassFromString("WKWebView")`); `ContentViewHostingTests.swift:160` does the same for rendered markdown. That's how you test a representable: **host it, then look for its backing view by class.**

The codebase's `DiagnosticDump.swift` is the most sophisticated form — it serializes the *entire* realized tree to JSON capturing every visibility-determining property: `frame`, `bounds`, `visibleRect`, `alphaValue`, `isHidden`, `isHiddenOrHasHiddenAncestor`, `layer.opacity`, `layer.hasContents`, and — the standout — **computed foreground/background color contrast distance in sRGB** (`DiagnosticDump.swift:196`) plus **glyph generation status from the `NSLayoutManager`** (`:213`, `glyphRange`, `numberOfGlyphs`, `boundingRect`). It even flags zero-sized views explicitly (`zeroSize`) — "the silent killers" (`:123`).

| Can observe | Cannot observe |
|---|---|
| **Layout / sizing** — real frames after a real layout pass | **Rendered pixels** as composited — does NOT go through WindowServer |
| View-tree **structure** of the *realized backing tree* (the NSView/CALayer side) | The **stage-④ compositor bug class** (see §6 — this is the headline limit) |
| Presence/class of representable leaves (`WKWebView`, `NSTextView`, `MTKView`) | True gesture/event dispatch through the responder chain |
| Zero-size / collapsed / hidden / transparent views | Animation *frames* (can read final layer state, not the in-flight timeline) |
| `NSTextView` glyph generation, color contrast, layout-manager state | Anything SwiftUI bakes into `layer.contents` as an opaque bitmap (see gotcha) |

**Runs:** fully headless / in-memory. **No window, no NSApplication event loop, no TCC permission.** This is the sweet spot the project leans on hardest because it's both deep (real layout) and cheap (host-runnable, fast, hermetic).

**Two non-obvious gotchas this code paid for:**
1. **SwiftUI flattens primitives into layer contents.** `Text`, `Image`, `Label` often do *not* appear as distinct `NSView` subclasses — they're rasterized into the hosting layer's `contents`. So `ComponentVisualTests.swift:119` can't find a label by walking for an `NSTextField`; it falls back to KVC-probing `stringValue`/`accessibilityValue` on every node, then to model state. **You cannot assume every visible element is a separately-walkable NSView.** This silently caps what tree-walking can assert about leaf text.
2. **KVC probes can crash the whole test process, uncatchably.** `value(forKey: "stringValue")` on a node that isn't KVC-compliant throws an ObjC `NSUnknownKeyException` → `SIGABRT` that Swift `try`/`catch` cannot intercept. The code guards every probe with `responds(to:)` (`ComponentVisualTests.swift:140`, `DiagnosticDump.swift:82` for the private `recursiveDescription` selector). A subtle, real production-test hazard.

---

## 4. In-process rasterization — `ImageRenderer` / `cacheDisplay` / `dataWithPDF` (stage ③ pixels, but NOT ④)

**Mechanism:** Force the realized views to *draw themselves* into an off-screen bitmap, then sample pixels. Three variants, all in-process:
- **`SwiftUI.ImageRenderer`** — renders a SwiftUI view to a `CGImage`/`NSImage` off-screen. `TESTING.md` lists a `ContentViewPixelTests` tier "✅ XCTest + `SwiftUI.ImageRenderer`, sample pixels" — though note that file no longer exists in the tree (the doc is stale; the tier was real at some point).
- **`NSView.cacheDisplay(in:to:)`** → `bitmapImageRepForCachingDisplay` — what `DiagnosticDump.captureWindowToPNG` (`:263`) and `automationSnapshotPNG` (`DocumentModel+AutomationHost.swift:122`) use.
- **`NSWindow.dataWithPDF(inside:)`** — vector variant.

| Can observe | Cannot observe |
|---|---|
| **Rendered pixels** of each view's own `draw(_:)` | **WindowServer composition** — the bug class at §6 |
| Color/contrast/transparency *as each view draws fresh* | Inherited environment by default (see below) |
| "View is structurally present but visually empty/transparent" | Inter-view occlusion / blending the compositor would do |
| Final visual state, sampled deterministically | Off-screen-vs-on-screen layout divergence (GeometryReader/`Spacer`) |

**Runs:** fully headless / in-memory, **no permission**. Same-process bitmap capture never needs Screen Recording — that TCC gate is only for capturing *other* processes' windows (`DiagnosticDump.swift:256`).

**The dangerous, load-bearing caveat — these methods *lie* about composition.** Per `LESSONS.md:156`: *"`NSView.cacheDisplay(in:to:)` and `NSWindow.dataWithPDF(inside:)` both bypass WindowServer and lie about composition state."* They walk the hierarchy and ask **each view to draw fresh** — which *re-renders* views the compositor would have skipped. So a pixel test built on `cacheDisplay` will show a view as correctly drawn even when the live window shows it blank. **In-process rasterization captures "what each view *would* draw," not "what the user *does* see."** That's the trap that let the compositor bug ship green.

**`ImageRenderer`-specific limits** (independent of the above): an off-screen view is **not anchored to the app's environment** — Dark/Light mode, Locale, Dynamic Type, custom `@Environment` values all reset to system defaults unless you inject them explicitly. Views depending on parent geometry (`GeometryReader`, infinite `Spacer`) render at wrong/unexpected sizes. So pixel output off-screen can legitimately differ from on-screen *even when nothing is broken* — a false-positive source for golden tests. `@MainActor`-only.

---

## 5. PNG golden snapshot testing — `swift-snapshot-testing` (stage ③, persisted + diffed)

**Mechanism:** Same in-process rasterization as §4 (it renders SwiftUI/UIKit/AppKit views to images), but adds the missing half: **persist a baseline image, diff future renders against it, surface a visual diff on mismatch.** First run records; subsequent runs compare. Also supports non-image "snapshots" — recording a value/struct/JSON as text and diffing that.

| Can observe | Cannot observe |
|---|---|
| **Visual regressions on a fixed layout** (the headline use) | WindowServer composition (inherits §4's blind spot) |
| Pixel-level diffs across the whole view at once | *Why* it changed — a diff says "different," not "wrong" |
| Catches drift no assertion was written for | Interaction, gestures, animation timelines |

**Runs:** headless / in-memory.

**Real limits / why this project deferred it** (`TESTING.md` Tier 2, "⏸ deferred"):
- **Brittleness & maintenance tax.** Snapshots break on OS version, font rendering, Retina scale, antialiasing, locale. A team is one Xcode bump away from a wall of red diffs that are all "correct." Animations must be disabled or they produce non-deterministic captures.
- **The "blessed wrong baseline" failure mode.** When a diff appears, the path of least resistance is to re-record. Teams routinely bless a regression because eyeballing 40 diffs is tedious — the test then locks in the bug.
- **It inherits §4's compositor blindness entirely** — it renders off-screen, so it cannot see the one bug class this project most needed to catch. Snapshot testing is great for "did this button's padding change," useless for "does this view composite at all in a live window."

---

## 6. WindowServer pixel capture on a *live* window — `screencapture(1)` / ScreenCaptureKit (stage ④, THE real one)

**This is the only technique in the entire list that observes what the user actually sees**, and the project built it specifically because everything above is blind to a real bug it shipped.

**The bug** (`LESSONS.md:55`): on macOS 14/15/26, an `NSTextView` hosted in SwiftUy via a representable, combined with an `NSRulerView` subclass, caused **sibling SwiftUI views laid out before it to stop compositing** — they go blank in the live window. Root cause (`:68`): the ruler's `drawHashMarksAndLabels` forces `NSLayoutManager` layout *during* `NSScrollView.tile()`, which runs *inside* SwiftUI's commit phase, triggering the runtime warning *"NSHostingView is being laid out reentrantly while rendering its SwiftUI content… the current layout pass will be skipped."* The skipped pass means siblings never commit their layer contents for that frame, and nothing re-invalidates them.

**Why every in-process tier missed it** (`:108`): the view tree walks perfectly (§3 sees all the right NSViews), layout frames are correct, the model has the data, and `cacheDisplay` re-draws the "blank" views fresh so they look fine (§4/§5). *"The only path that observes the bug is `screencapture(1)` on the live window."*

**Mechanism** (`SourceViewVisualRegressionTests.swift`):
1. `swift build` the `.app`, launch it via `Process` pointed at a real source file.
2. The app writes its `NSWindow.windowNumber` to a known tmp path on launch (the test polls for it — `waitForWindowID`, `:317`).
3. Foreground via `osascript … to activate` (occluded windows have **stale framebuffers** — AppKit suspends drawing for occluded windows, so this step is mandatory).
4. `screencapture -l<windowID> -x -o out.png` — `-l<id>` captures one window **through WindowServer**.
5. Decode PNG, sample per-region pixel **variance** on a dense 64×16 grid quantized to 4 bits/channel; assert each UI strip (TabBar/ModeBar/StatusBar) shows ≥3 distinct colors → proves it composited (`regionHasVariety`, `:278`).
6. **A meta-test** (`test_meta_brokenRulerIsDetectedAsRegression`, `:50`) launches with `MDV_ENABLE_BROKEN_RULER=1` and asserts the variance check *detects* the break — proving the test isn't a no-op. (Testing your test. Worth copying.)

| Can observe | Cannot observe |
|---|---|
| **What the user actually sees** — true composited pixels | Cheap/fast feedback — it's slow (launch + foreground + 1.5s settle) |
| The compositor-skip / sibling-blank bug class | Hermeticity — needs a real GUI session, TCC grant |
| Occlusion, blending, real GPU composition | Determinism — timing-sensitive; must `XCTSkip` constantly |
| Off-screen-vs-on-screen divergence | Semantic *meaning* of pixels (variance ≠ correctness) |

**Runs:** **requires a real on-screen window** and a real login GUI session. Per project's `CLAUDE.md`, this is **VM-only** (UTM macOS VM), never on the host — it grabs focus and is privacy-sensitive.

**Hard real-world constraints:**
- **TCC Screen Recording permission** is mandatory and brutal on macOS 15+: you must grant it to **both** the launching terminal **AND** `/Applications/Xcode.app/Contents/Developer/usr/bin/xctest` (`:103`). On ad-hoc-signed builds, every rebuild changes the code-directory hash → TCC re-prompts (`LESSONS.md:159`), mitigated only by holding the bundle ID stable via `codesign --identifier` and installing to a stable path.
- **`CGWindowListCreateImage` was removed (obsoleted) in macOS 15.0** — the old in-process-ish capture API is gone (`DiagnosticDump.swift:266`). The modern replacement is **ScreenCaptureKit** (`SCScreenshotManager`), which is async, requires the same TCC grant, and is more API surface for the same result — which is why this project shells out to the `screencapture(1)` binary instead (it encapsulates the SCK plumbing). The macOS-15.1 `CGPreflightScreenCaptureAccess` deprecation churn makes permission *detection* itself a moving target.
- **Focus stealing & occlusion** is the silent killer of headless-ish runs: a window launched via `Process` from a foregrounded terminal stays occluded → empty framebuffer → blank capture even though nothing is broken (`AppLauncher.swift:25`). Hence the VM-only rule.

---

## 7. Real UI automation — XCUITest / AX (stage ④ + real event dispatch)

**Mechanism:** `XCUIApplication` launches the real `.app` in a separate process and drives it through the **Accessibility (AX) tree** — synthesizing real taps/keystrokes via the HID/event system and querying elements by `accessibilityIdentifier`. This is the only technique that exercises the *full* responder chain and event loop.

| Can observe | Cannot observe |
|---|---|
| Real gestures, clicks, keystrokes through the event system | Internal view state directly (only what's surfaced to AX) |
| End-to-end flows, menu/window wiring, launch behavior | Pixels (AX is semantic, not visual — pair with §6 for that) |
| Focus / responder chain, keyboard shortcuts | Anything not exposed to accessibility |
| AppDelegate sequencing (argv, `application(_:open:)`) | Fast feedback — slowest tier, flakiest |

**Runs:** **real on-screen window required**, separate GUI session, accessibility permission. The project lists this as Tier 4 VM (XCUITest in tart/UTM VM), nightly-only, deferred.

**The project's pragmatic substitute is worth highlighting as a genuinely underused pattern.** Rather than synthesize real key events (which `Process`-launched apps can't receive — `SessionsKeyboardUITests.swift:5`), they built an **in-app `--script` command runner**: the app accepts `--script path` + a file arg, executes verbs (`toggle-view`, `new-tab`, `zoom-in`, `session-next`), and writes a **JSON `DiagnosticDump` between each step** to `mdv-step-NN.json` (`AppLauncher.swift`, `InteractionScriptTests.swift`). Tests launch the real `.app` headless (`MDV_BACKGROUND=1`, no focus theft), run the script, and assert on the per-step dumps via Page Objects (`Tests/ViewerUITests/PageObjects/`). And the model state is made authoritative in the dump via an `AutomationHost` protocol (`DocumentModel+AutomationHost.swift`) — `InteractionScriptTests.swift:74` deliberately trusts `model.tabCount` over the NSView count because *SwiftUI AX identifiers don't reliably propagate to the realized NSView* (a real limit of AX-based assertions on hosted SwiftUI).

This gives ~80% of XCUITest's "real app, real launch, state-change-propagates-to-view-tree" coverage **without** the AX-permission, focus, and flakiness tax — by substituting a scripted command channel + JSON introspection for synthesized HID events. The candid limit (`SessionsKeyboardUITests.swift:19`): it does **not** test the actual `NSEvent`-monitor → menu-action-selector key dispatch chain — that's verified manually until the VM gains real key support.

---

## Consolidated matrix

| Technique | Pipeline stage | Logic | Tree structure | Layout/size | Pixels (drawn) | Pixels (composited) | Gestures/events | State changes | Animations | Headless? | Permission? |
|---|---|---|---|---|---|---|---|---|---|---|---|
| **1. Model / pure logic** | ① inputs | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ | ❌ | ✅ fully | none |
| **2. ViewInspector** | ① body output | ⚠️ via callbacks | ✅ declared | ❌ | ❌ | ❌ | ⚠️ declared closure | ✅ | ❌ | ✅ fully | none |
| **3. NSHostingView walk** | ② ③ structure | ❌ | ✅ realized | ✅ | ❌ | ❌ | ❌ | ⚠️ via model | ⚠️ final layer only | ✅ fully | none |
| **4. ImageRenderer / cacheDisplay** | ③ pixels | ❌ | ⚠️ | ✅ | ✅ | ❌ **(lies)** | ❌ | ❌ | ⚠️ final frame | ✅ fully | none |
| **5. Snapshot (golden)** | ③ persisted | ❌ | ⚠️ | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ | ✅ fully | none |
| **6. screencapture / SCK live** | ④ composited | ❌ | ❌ | ⚠️ | ✅ | ✅ **only one** | ❌ | ❌ | ⚠️ frame grabs | ❌ window | TCC Screen Rec. |
| **7. XCUITest / AX** | ④ + events | ❌ | ⚠️ via AX | ⚠️ | ❌ | ✅ (if paired) | ✅ **only one** | ⚠️ via AX | ⚠️ | ❌ window | Accessibility |

`✅` strong / `⚠️` partial-or-indirect / `❌` blind. "Headless?" = needs no on-screen window. **Stages ①②③ = in-process, headless-capable. Stage ④ = out-of-process WindowServer, needs a real window.**

---

## Non-obvious / counterintuitive takeaways

1. **The deepest "headless" tier you can reach is layout, not pixels-as-seen.** `NSHostingView` + `layoutSubtreeIfNeeded()` (§3) runs a *real* layout pass with no window — that surprises people who think any geometry needs a screen. But the moment you ask "does the user *see* it," you've crossed the process boundary into WindowServer and lost headlessness entirely. There is no headless way to observe stage ④. That's a hard architectural fact, not a tooling gap.

2. **Three different APIs render "to an image," and two of them lie.** `ImageRenderer`, `cacheDisplay`, `dataWithPDF` all produce pixels — by asking each view to *redraw fresh*. The live compositor *skips* views under certain conditions. So in-process rasterization is strictly "what each view would draw in isolation," which can diverge from the composited reality. A green pixel/snapshot suite is not evidence the window isn't blank.

3. **Same-process capture is permission-free; cross-process capture is the TCC wall.** Capturing *your own* window via `cacheDisplay` needs nothing. Capturing it via `screencapture`/SCK (through WindowServer) needs Screen Recording — and on macOS 15 you must grant it to the `xctest` binary too, and it resets on every ad-hoc rebuild. The permission gate is fundamentally about *which process owns the framebuffer you're reading*, not about screenshots per se.

4. **Test your visual test.** The meta-test pattern (`MDV_ENABLE_BROKEN_RULER=1` deliberately reproduces the bug and asserts the check catches it) is rare and valuable. Pixel-variance assertions are exactly the kind of test that silently rots into a no-op (a flat region that always passes); a meta-test that injects the known-broken state is the only way to keep it honest.

5. **The best SwiftUI test is architectural, not a tool.** This codebase's heaviest, most reliable tier is "don't render anything" — because they extracted every decision into pure reducers and `@MainActor` models. ViewInspector/snapshots being "deferred" isn't laziness; it's recognizing those tiers are brittle (reflection chasing private API; goldens chasing OS rendering) and reserving them for the narrow band they uniquely catch (declared-attribute behavior; fixed-layout drift).

6. **AX identifiers don't reliably survive the SwiftUI → NSView realization.** A subtle trap for both §3 (counting NSViews) and §7 (querying by identifier): SwiftUI doesn't always propagate `accessibilityIdentifier` to the backing NSView, so element counts can come back spuriously zero. The robust move is to surface authoritative state through a dedicated automation channel (the `AutomationHost`/`--script`/JSON-dump pattern) rather than trusting the realized AX tree.

7. **The in-app script runner + JSON dump is an underrated alternative to XCUITest** for testing that *state changes propagate to the view layer* on a real launched app — without paying XCUITest's permission/focus/flakiness cost. It can't synthesize real HID events (so the key-dispatch chain stays manual), but for "toggle this verb, did the realized tree change correctly," it's faster, more hermetic, and more debuggable than driving the AX tree.

---

### Most-relevant files in this repo
- `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/DiagnosticDump.swift` — the in-process introspection + capture engine; read `:256–283` for the in-process-vs-WindowServer permission distinction.
- `/Users/me/Documents/workspaces/claude/markdown_viewer/Tests/ViewerUITests/ContentViewHostingTests.swift` and `ComponentVisualTests.swift` — the headless `NSHostingView` tree-walk pattern (incl. the layer-flattening and KVC-crash gotchas).
- `/Users/me/Documents/workspaces/claude/markdown_viewer/Tests/ViewerUITests/MermaidHostingTests.swift` — how `NSViewRepresentable`/`WKWebView` leaves get tested (host, then find by class).
- `/Users/me/Documents/workspaces/claude/markdown_viewer/Tests/ViewerUITests/SourceViewVisualRegressionTests.swift` — the live-window WindowServer pixel-variance test + meta-test.
- `/Users/me/Documents/workspaces/claude/markdown_viewer/Tests/ViewerUITests/AppLauncher.swift`, `InteractionScriptTests.swift`, `Sessions/SessionsKeyboardUITests.swift` — the `--script` + JSON-dump substitute for XCUITest.
- `/Users/me/Documents/workspaces/claude/markdown_viewer/LESSONS.md:55–158` — the compositor bug write-up; the single best in-repo statement of *why* most techniques are blind to stage ④.
- `/Users/me/Documents/workspaces/claude/markdown_viewer/TESTING.md:8–37` — the tier table mapping each technique to the bug class it catches (note: `ContentViewPixelTests` referenced there no longer exists — doc is stale on that one).

### External sources
- [How ViewInspector Unlocks SwiftUI Testing — Quality Coding](https://qualitycoding.org/viewinspector-swiftui-testing/)
- [nalexn/ViewInspector — GitHub](https://github.com/nalexn/ViewInspector) and [Who said we cannot unit test SwiftUI views? — Alexey Naumov](https://nalexn.github.io/swiftui-unit-testing/)
- [Snapshot testing in SwiftUI without launching the app — DevelopersIO](https://dev.classmethod.jp/en/articles/swift-snapshot-testing/)
- [ImageRenderer — Apple Developer Documentation](https://developer.apple.com/documentation/swiftui/imagerenderer) and [SwiftUI Renderers and Their Tricks — The SwiftUI Lab](https://swiftui-lab.com/swiftui-renders/)
- [ScreenCaptureKit — Apple Developer Documentation](https://developer.apple.com/documentation/screencapturekit/) and [CGWindowListCreateImage obsoleted in macOS 15 — MacPorts #71136](https://trac.macports.org/ticket/71136)