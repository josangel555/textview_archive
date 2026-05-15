# LESSONS.md — hard-won knowledge for this codebase

Workspace-scoped memory. Read this when you're about to do something
adjacent to the items below. The mistakes that produced these entries
each cost real hours; the entries exist so they don't cost the next
hours.

## The SwiftUI / NSTextView compositor bug

### Symptom
On macOS 14 / 15 / 26, when an `NSTextView` lives inside an SwiftUI
view hierarchy (via `NSViewRepresentable` or `NSViewControllerRepresentable`),
sibling SwiftUI views laid out **before** it in the parent stack stop
compositing — they appear blank. The NSTextView's documentView often
ALSO renders blank. SwiftUI siblings laid out **after** the source
view (e.g. the bottom status bar) render correctly. The view tree
exists (`NSView.recursiveDescription` shows the expected
HostingViews), the model has the data (status bar reports the line
count) — only WindowServer composition skips them.

### Root cause
Attaching an `NSRulerView` subclass (we had `LineNumberRulerView`) to
the source `NSScrollView`'s `verticalRulerView`. That ruler's
`drawHashMarksAndLabels` calls into `NSLayoutManager.glyphRange(...)`
and `glyphIndexForCharacter`, which force layout. The ruler is drawn
during `NSScrollView.tile()`, which `NSScrollView` calls *inside*
SwiftUI's commit phase. The forced-layout call inside `tile` inside
commit prints this runtime warning (visible in Console.app or stderr
if you watch for it):

> `NSHostingView is being laid out reentrantly while rendering its
> SwiftUI content. This is not supported and the current layout pass
> will be skipped.`

The skipped pass means the SwiftUI siblings ABOVE the source view
never get their layer contents committed for that frame. Subsequent
frames don't invalidate them so they stay blank.

### What does NOT fix it
- `wantsLayer = true` on the scroll view / text view
- `canDrawSubviewsIntoLayer = true`
- `NSTextView.scrollableTextView()` factory defaults vs. custom container
- Switching `NSViewRepresentable` → `NSViewControllerRepresentable`
  (community recommends it; necessary but not sufficient for us)
- Wrapping the scroll view in an extra container `NSView`
- Calling `needsDisplay = true` after content load

### What DOES fix it
Remove the `NSRulerView` from the scroll view entirely. Don't set
`verticalRulerView` and don't enable `hasVerticalRuler`. The bug is
specifically in the ruler-tile-layout chain — without that chain,
`NSTextView` hosted via `NSViewControllerRepresentable` composes
correctly, sibling SwiftUI views render fine, drag-select / Find /
services menu all work.

The proper alternative for line numbers is a **separate SwiftUI gutter
column** synced to the textView's `clipView.boundsDidChangeNotification`.
That path computes line positions in a notification handler — outside
any `tile()` call — so calling `NSLayoutManager` from there is safe.

### How to test for regressions of this bug class
`xctest` cannot observe this bug. The view tree walks correctly; the
test sees the right number of `NSTextView` / `HostingView` instances.
`NSView.cacheDisplay(in:to:)` cannot observe it either — it walks the
hierarchy and asks each view to draw fresh, bypassing the WindowServer
compositor.

**The only path that observes the bug is `screencapture(1)` on the
live window.** That goes through WindowServer and shows actual
composited pixels.

See `Tests/ViewerUITests/SourceViewVisualRegressionTests.swift`:
- Launches the .app pointing at a real source file
- App writes its `NSWindow.windowNumber` to a known path on launch
  (see main.swift right after `showWindow(window)`)
- Test reads the windowNumber, runs `screencapture -l<id> -x`,
  decodes the PNG, samples per-region pixel variance with a dense
  64×16 grid quantized to 4 bits per channel
- Each region (TabBar / ModeBar / StatusBar) must have ≥3 distinct
  quantized colors
- A meta-test (`test_meta_brokenRulerIsDetectedAsRegression`) sets
  `MDV_ENABLE_BROKEN_RULER=1`, launches with the broken ruler, and
  asserts the variance check DETECTS the regression. This proves
  the test isn't a no-op.
- Both tests `XCTSkip` cleanly when:
  - the .app isn't built yet
  - the runner lacks Screen Recording permission (TCC)
  - `MDV_SKIP_VISUAL` is set

### Before touching `TextDisplayView` / source view containment
1. Run the visual regression: `swift test --filter SourceViewVisualRegressionTests`
2. Manually eyeball with `bash scripts/visual-smoke.sh` — confirms
   TabBar / ModeBar / Sidebar / StatusBar all show pixels alongside
   the source content
3. If you add anything that touches `NSScrollView.verticalRulerView`,
   `hasVerticalRuler`, or any `NSRulerView` subclass: STOP. Use the
   SwiftUI gutter overlay pattern instead.

## Tests need to match the bug class

The compositor bug ships behind a green test suite because the test we
had only walked the view tree and counted instances. Visual rendering
state is fundamentally out of `xctest`'s observability when running
headless. **If a bug class is visible-pixels-only, the test must be
pixel-level too**, and that means either:
- `screencapture(1)` against a live window (our approach), or
- ScreenCaptureKit (more APIs, same root)

`NSView.cacheDisplay(in:to:)` and `NSWindow.dataWithPDF(inside:)`
both bypass WindowServer and lie about composition state.

## TCC on ad-hoc-signed builds

The .app gets a new code-directory hash on every rebuild because the
binary changes. macOS treats consecutive rebuilds as different apps
for permission gating, so Full Disk Access / Screen Recording / etc.
re-prompts roll back. Mitigations:
- `scripts/install-app.sh` copies to `/Applications/MarkdownViewer.app`
  (stable path); the FDA grant there *mostly* survives rebuilds
  because TCC keys on the bundle identifier we hold stable via
  `codesign --identifier`
- Real fix is a Developer ID cert (Phase 9, out of scope today)

## SwiftUI child-ObservableObject changes don't propagate

`ContentView` observes `DocumentModel`. `model.sidebar` is a child
`SidebarModel` (also `ObservableObject`). Changing
`model.sidebar.isVisible` triggers `sidebar.objectWillChange` — but
NOT `model.objectWillChange`. `ContentView` sees no signal and
doesn't re-render. We fix this by manually piping
`sidebar.objectWillChange` → `model.objectWillChange.send()` in
`DocumentModel.init`. Same fix needed for any other child OOs we add.

## File-path stable cache keys vs content-hash

Earlier `highlightCache` and `renderedHTMLCache` used
`text.hashValue` as the key. For a multi-MB file `text.hashValue` is
O(N) per call, computed on every SwiftUI body re-eval. Fix: key on
`(URL, content.length)`. Length acts as a coarse change detector
that file-watcher reload triggers automatically. Same lesson applies
to any future cache: don't put the full payload in the key.

## Test-suite hygiene around the live app

`AppLauncher.runScript` sets `MDV_BACKGROUND=1` and skips the
`osascript activate` so test runs don't steal keyboard focus from the
user. If you add a new test that spawns the .app, do the same unless
you specifically need a focused window (e.g. the visual regression
test, which DOES need it for screencapture to see current pixels).

## `swift build` lock contention piles up silently

Running multiple `swift build` invocations back-to-back (especially
when an earlier one didn't print to stdout fast enough and seemed
"stuck") leaves zombies. They hold the SwiftPM `.build/` lock and the
next build serializes behind them. Symptoms: a fresh build takes 100s+
instead of <5s; tests show wall-clock that's way bigger than they
should be (saw 124s on a test that should be <5s).

Fix: `ps aux | grep "swift build" | grep -v grep` to list them, then
`kill <pid> <pid> …` (do NOT `pkill -f "swift build"` — broad pkill
is blocked by the auto-mode classifier). Investigate before killing
if you're not sure they're yours.

Prevention: don't fire a new `swift build` until the previous
finished. If a build seems hung, look at the bg task output file —
"no output" usually means it's blocked on the lock, not actually
compiling. Cancel it before starting another.

## When in doubt about an end-to-end change

The chain that catches the most stuff: build → install → run from
`/Applications/MarkdownViewer.app` → `bash scripts/visual-smoke.sh`.
If something looks wrong, run with `MDV_ENABLE_BROKEN_RULER=1` to
confirm the test would have caught it.
