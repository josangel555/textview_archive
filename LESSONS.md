# LESSONS.md — hard-won knowledge for this codebase

Workspace-scoped memory. Read this when you're about to do something
adjacent to the items below. The mistakes that produced these entries
each cost real hours; the entries exist so they don't cost the next
hours.

## UTM VM: "flaky ssh" is memory-pressure bufferbloat, and NEVER `rm -rf .build` on it (2026-06-09)
- **Diagnosis of the recurring "VM ssh keeps timing out".** The VM is **8 vCPU / 4 GiB RAM**. A Swift build
  (TreeSitter grammars have high peak RSS) + the ~4000-test suite pushes 4 GiB into heavy swap/compression
  (`vm_stat`: 100k+ swapouts, 190k+ compressor pages). When it swaps, processes block on page-in and the
  **virtio-net queue stalls** → `ping` shows **0 % loss but multi-second RTT, draining ~1 s/step** (textbook
  CPU/mem-starved-guest bufferbloat). SSH "Operation timed out" is just the handshake missing its window during
  a stall. So the VM is fine when idle and "vanishes" exactly when a build/test hammers it. The cure is owner-side:
  **bump RAM 4→8 GiB in UTM**. Mitigation: `~/.ssh/config` `macOS15` now has `ServerAliveInterval 15` /
  `ServerAliveCountMax 8` / `ConnectTimeout 30` / `TCPKeepAlive yes` so sessions ride out the stalls.
- **The VM is an OFFLINE rsync mirror — NEVER `rm -rf .build` on it.** SwiftPM deps (the tree-sitter grammars,
  swift-cmark) live in `.build/{checkouts,repositories}` (~1 GB). The standard sync EXCLUDES `.build/`, so once
  wiped the VM cannot repopulate them — a clean `swift build` tries to refetch from github and dies with
  `Could not resolve host` (the VM has no/limited internet; e.g. when the host VPN is down). Restore path if it
  ever gets wiped: `rsync -az .build/checkouts .build/repositories Package.resolved macOS15:markdown_viewer/.build/`
  from the host (arch-independent git content), then `swift package resolve` re-creates the working copies offline.
  `test-in-vm.sh` / `vm-smoke.sh` do NOT wipe `.build` — only an agent doing `rm -rf .build` does. Don't.
- **Reap hung `xctest` orphans.** `test-in-vm.sh` can leave a child `xctest` alive after it writes `/tmp/vmtest.done`
  — seen lingering 2.5 h, leaking RAM on the 4 GiB box and compounding the pressure above. Targeted `kill <pid>`
  of the `xctest` runner is safe (NOT `killall` — that family reaps the owner's app per CLAUDE.md).

## `FileWatcherTests.test_deletedThenRecreated_watcherReattaches` is a load-flaky FSEvents test (2026-06-09)
- The headless gate (`swift test --parallel`, ~4400 tests) intermittently RED-HERRINGS on this one test:
  `Asynchronous wait failed: Exceeded timeout of 2 seconds, with unfulfilled expectations: "post-recreate
  write event"`. It is an FSEvents async-DELIVERY timing issue: under the parallel gate's machine load the
  coalesced delete→recreate→write event can land after the 2 s `XCTestExpectation` deadline. Re-run it
  ISOLATED (`swift test --filter ViewerCoreTests.FileWatcherTests/test_deletedThenRecreated_watcherReattaches`)
  — it passes in ~0.1 s. It is NOT in the perf-bench flake family the CLAUDE.md note covers, so it's easy to
  mistake for a real regression. Before chasing a gate RED, confirm the failing test(s) aren't just this one +
  re-run isolated. (A durable fix would bump the expectation timeout / poll for the event; low priority.)
- Tripwire reminder: `bash gate.sh > log 2>&1; echo "EXIT=$?" >> log` MASKS the gate's real exit — the wrapper
  exits 0 because `echo` succeeded. Trust the in-log `==> headless gate PASSED/FAILED` marker, not the
  background-task "exit code 0". Same exit-0-masking family as #311/#162.

## Terminal "typing is slow": a purely trailing-edge render throttle (2026-06-06)

**Symptom.** Owner: "Terminal is very slow — typing, pressing Enter."
Echo appears a beat after each keystroke even on an idle prompt.

**Cause.** `TerminalModel.scheduleBump()` was a **trailing-edge** throttle:
every PTY-output chunk (including each keystroke echo) spawned a
`Task { @MainActor }` that `await Task.sleep`'d a full frame (`1/60s`,
and more under the cooperative executor's imprecision) **before** bumping
`version`. So the view never repainted until a frame *after* the shell
echoed — even when the terminal had been idle and there was nothing to
coalesce. At human typing speed (keystrokes >16ms apart) EVERY echo ate
the full delay → "slow."

**Fix (`d8141c5`).** Leading-edge throttle (new pure
`ViewerCore/Terminal/FrameThrottle.swift`): the first event after an idle
gap emits **immediately**, then a `coalesceInterval` cooldown coalesces
the following burst with a single trailing flush. Decision logic is pure
+ headlessly tested (`FrameThrottleTests`); the `Task.sleep` plumbing
stays in `TerminalModel`. General rule: throttles on the *interactive
input→echo* path must be leading-edge; trailing-edge is for pure
output-rate limiting where first-paint latency doesn't matter.

**Also fixed same commit:** `TerminalPalette.nsColor` allocated a fresh
`NSColor` per attribute-run per frame — a coloured prompt has dozens of
runs, so 256/truecolor turned the draw path into per-frame allocation
churn. Memoized the 256 ansi/indexed entries into a shared precomputed
table (truecolor `.rgb` still allocates, but it's rare).

## by-exec-name kill in TEST TEAR-DOWN nukes the owner's prod app — "self-skip" doesn't cover setUp/tearDown (2026-06-06)

**Symptom.** Owner: "Why is the headless test STILL nuking
`/Applications/TextView`? It should only care about the build version,
not the prod install." (A second occurrence after the `install-app.sh`
killall was removed.)

**Cause.** `LaunchHarness.cleanup()` did
`AppLauncher.currentPID(of: "MarkdownViewer").map { kill($0, SIGTERM) }`.
`currentPID` is a raw `pgrep -x`-by-exec-name lookup; the prod app and
test spawns share the exec name `MarkdownViewer`, so the SIGTERM also hit
the owner's running `/Applications` app. Two non-obvious traps: (1) the
footgun is **not only `killall`** — any by-exec-name kill (`pgrep -x` /
`currentPID` + `kill`) is equally unsafe; (2) "heavy tiers self-skip in
the gate" protects the test *body* but **not `setUp`/tearDown** — XCTest
still runs them around a skipped body, and `cleanup()` runs there, so the
window-free headless gate WAS terminating the owner's app.

**Fix (`f6499fe`).** Route `cleanup()` through
`AppLauncher.killTestInstances(named:)`, which only SIGTERMs PIDs whose
`ps eww` env shows `MDV_TEST_INSTANCE=1` (set by `AppLauncher.runScript`).
See memory `[[feedback-killall-footgun]]`.

## TCC re-prompt-on-every-rebuild: ad-hoc signing is keyed on cdhash

**Symptom.** macOS keeps showing the "MarkdownViewer reads files from
your Documents folder" prompt on every rebuild, even after the user
clicks Allow. Same for Downloads, Desktop, removable volumes.

**Cause.** Ad-hoc signing (`codesign --sign -`) gives the binary a
fresh code-directory hash on every build. macOS TCC keys ad-hoc grants
on `cdhash` — there's no signing identity to fall back to. So every
rebuild is, from TCC's POV, a brand-new app, and grants don't migrate.

**Non-fixes that look like fixes.** A stable `--identifier` doesn't
help (TCC ignores it for ad-hoc grants). Granting Full Disk Access in
System Settings *does* survive rebuilds, but only because FDA is the
nuclear escape hatch — the per-folder prompts still fire if FDA isn't
enabled. `--preserve-metadata=identifier` doesn't help either.

**Fix.** Sign with a real signing identity. Even a self-signed cert
generated locally and stored in the login keychain works — TCC keys
the grant on `(identifier, cert-leaf-hash)` for properly-signed apps,
and both stay stable across rebuilds. `scripts/setup-signing.sh`
generates and imports the cert; `scripts/build-app.sh` picks it up
automatically.

**Gotcha 1: PKCS#12 export.** Use system `/usr/bin/openssl` (LibreSSL).
Homebrew OpenSSL 3.x produces PKCS#12 bundles that macOS rejects with
"MAC verification failed" even with `-legacy`. Use a non-empty
passphrase — `security import` interprets empty `-P ""` as wrong
password and refuses the import.

**Gotcha 2: `find-identity -p codesigning` lies.** It runs strict trust
evaluation against the cert chain; self-signed certs fail that and
get filtered out, returning "0 valid identities." But `codesign`
itself happily uses the cert. Verify by probing with codesign on a
throwaway file, not by parsing find-identity output.

**Gotcha 3: `xattr -cr` before `codesign --options runtime`.** Resource
bundles from SwiftPM ship with extended attributes and read-only
permissions. Runtime hardening refuses any xattr; you also need a
`chmod -R u+w` first so xattr can clear them.

**One-time cost.** Switching from ad-hoc to a real identity changes
the (identifier, cert-leaf-hash) pair, so TCC re-prompts ONCE on the
first launch after switching. Approve those prompts. After that, all
future rebuilds preserve the grant indefinitely (cert is good for
10 years; renew when you remember).

## The SwiftUI / NSTextView compositor bug

### The structural prohibition (PRIMARY defense — read this first)

> **Never attach an `NSRulerView` (or any `NSRulerView` subclass) to the
> source-view `NSScrollView`, and never subclass `NSLayoutManager` for the
> source view.** Don't set `verticalRulerView`, don't enable
> `hasVerticalRuler`. Line numbers come from a separate SwiftUI gutter
> column (see "What DOES fix it" below), never from a ruler.

This rule — not a test — is the load-bearing defense against the
compositor bug. The bug is *visible-pixels-only*: it lives at WindowServer
composition (stage ④), which no headless layer can observe (`xctest` tree
walks pass, `cacheDisplay` / `dataWithPDF` redraw fresh and lie about
composition — see "How to test" below). The only automated detector is
`screencapture(1)` on a live window, which needs the VM + a TCC Screen-
Recording grant and runs nightly/pre-release, not on the merge gate. So a
regression that slips past the structural rule could ship behind a green
host sweep until the next VM run.

The rule is **cheaper and stronger than the test**: it's a code-review
line anyone can check statically (grep for `NSRulerView` /
`hasVerticalRuler` / `verticalRulerView` / `: NSLayoutManager` in the
source-view code), it has no false-greens, and it costs nothing to enforce.
Treat `SourceViewVisualRegressionTests` (T5) as **belt-and-suspenders**: it
exists to catch a *violation of this rule* if one ever lands, and its
meta-test (`MDV_ENABLE_BROKEN_RULER=1`) proves the variance check still has
teeth — but the rule is what keeps the bug from being introduced in the
first place. (Testing-pyramid migration §3.4: `SourceViewVisualRegression`
is the sole irreducibly-real-screen suite; the structural prohibition is
its primary backstop.)

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

## `@Published` setters are value-blind — dedupe at the publish site

A `@Published` property's setter triggers `objectWillChange` on
every assignment, regardless of whether the new value equals the
old. If a SwiftUI view re-renders because of that signal AND its
render path writes back to the same `@Published`, you have an
infinite publish loop.

Symptom we hit: source-view RSS grew ~5 MB/sec at idle. Looked
like a heap leak; was actually an apply→publish→re-render→apply
runaway. Each cycle allocated transient SwiftUI / Foundation
state; ARC reclaimed eventually but the in-between allocations
piled up faster.

Pattern: dedupe at the callback site BEFORE invoking the
@Published setter:

```swift
private var lastPublishedX: X?
private func publishX() {
    let new = compute()
    if new == lastPublishedX { return }   // <-- the fix
    lastPublishedX = new
    onChange?(new)                          // → model.x = new
}
```

Where the loop existed in our code:
- `SourceTextController.publishSelection()` → `model.sourceSelection`
- `SourceTextController.applyFindHighlights()` → `model.sourceFindMatchSummary`

Both were re-publishing identical values on every `apply()`.

Two related rules:
- Equatable conformance is required on the published payload.
- The dedupe state must live on a long-lived object (the
  controller), not in a SwiftUI view's `@State` — those get
  recreated.

## `ForEach(stride(...).map)` in SwiftUI bodies = memory leak

SwiftUI `body` runs frequently. Anything you allocate inside body
gets reallocated each time. For collection-shaped UI, this matters:

```swift
// BAD: materializes a [Int] every body re-eval.
private func rowOffsets() -> [Int] {
    stride(from: 0, to: file.byteCount, by: bytesPerRow).map { $0 }
}
ForEach(rowOffsets(), id: \.self) { ... }
```

For a 4 MB hex file at bytesPerRow=16, that's a 2 MB Int array
*per body call*. Scroll fires many body calls. ARC eventually
catches up but in the meantime the process RSS climbs steadily
and the UI beachballs.

Fix: use `Range<Int>` directly. It's a `RandomAccessCollection`,
no materialization, LazyVStack realizes only visible rows.

```swift
// GOOD:
private var rowCount: Int { … }
ForEach(0..<rowCount, id: \.self) { row in
    HexRow(offset: row * bytesPerRow, ...)
}
```

`HexViewSizingTests.swift` pins the rowCount math so a regression
trips before shipping.

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

## Things to NOT do (each one would regress something specific)

These aren't style preferences — each is the postscript of a real
bug we hit. Re-introducing any of them re-creates the same bug.

- **Don't subclass `NSLayoutManager`.** Has historically triggered
  the compositor bug. The "invisibles too grey" issue is open
  precisely because the fix needs a subclass and we're trading
  off contrast against compositor stability.
- **Don't attach `NSRulerView`** to the source-view scrollView.
  That's *the* compositor-bug trigger. Line numbers come from a
  separate SwiftUI `Canvas` (`SourceGutterView`) synced via
  `clipView.boundsDidChangeNotification`.
- **Don't `cd && command`** in shell invocations. Use `git -C` or
  absolute paths. Compound commands defeat per-command permission
  allowlists.
- **Don't bulk-strip the bundle** without `ditto --noextattr` +
  recursive `xattr -dr com.apple.FinderInfo` afterwards. `strip(1)`
  re-applies FinderInfo to the Mach-O; codesign with
  `--options runtime` refuses bundles with any of it. `xargs +
  xattr -d` silently fails on the bundle root (xargs quoting) —
  use `xattr -dr` instead.
- **Don't change `CFBundleIdentifier`.** TCC grants are keyed on
  `(identifier, cert-leaf-hash)`. Changing it forces re-prompts for
  Documents / Downloads / Desktop / etc. Display name renames are
  fine; identifier renames are not.
- **Don't iterate Swift's `String.Character`** for line scanning of
  CRLF-bearing input. `\r\n` is a single grapheme cluster, so a
  Character iterator sees it as one unit and the LF-test never
  matches. Iterate `unicodeScalars` instead. CSV and diff parsers
  both burned a test cycle to learn this.
- **Don't use `iconutil -c icns`** if you want oxipng output
  preserved. It re-encodes the PNGs with default ImageIO settings,
  bypassing any compression you did upstream. Use
  `scripts/pack-icns.swift` to hand-pack the container instead;
  it preserves bytes verbatim.
- **Don't import `SwiftUI` into `ViewerKit` or `ViewerCore`.** The
  module boundary is what keeps Tier 1 unit tests UI-free and
  fast. If you need a value type with a Color, the Color lives in
  the SwiftUI extension in ViewerUI, not in the type definition.
- **Don't write to `~/Documents`, `~/Desktop`, `~/Downloads`** from
  any automated / restore path. TCC will prompt on first access,
  and ad-hoc grants don't survive rebuilds. `DocumentModel.isUnderTCCProtectedRoot`
  exists to skip these on workspace restore.
- **Don't use `--no-verify`** on commits or `--no-gpg-sign` on
  anything. If a hook fails, fix it, don't bypass it.

## The request-nonce pattern (transport, not state)

SwiftUI views can't imperatively command an `NSViewRepresentable`
(call a method on it the way you'd call a method on an NSView).
Two ways out: KVO-style observation, or a request-nonce.

We use request-nonces everywhere — find next/prev, find focus,
scroll-to-line. Shape:

```swift
@Published public var sourceFindNextRequest: Int = 0
public func sourceFindNext() { sourceFindNextRequest &+= 1 }
```

The view representable holds a `lastNextNonce: Int` and only acts
when the incoming nonce differs. The nonce is monotonic via `&+=`
(wrapping add) so overflow after 2³¹ requests doesn't crash. The
nonce value itself is semantically meaningless — only the change
matters.

**Don't break this pattern.** It's how the source view stays
decoupled from SwiftUI body re-evaluations. If you replace a nonce
with a "do you want me to scroll?" boolean, every body re-render
will re-trigger the scroll because the bool is still `true`.

## Internal-for-testing surfaces (don't make private again)

We've elevated several helpers from `private` to `internal` so
`@testable import` can reach them. The elevation is intentional
and documented at each call site. When refactoring, check whether
the symbol has a test or comment naming a test file — if so,
keep its access level.

Current list:
- `SourceTextController.findRanges(...)` — `TextSearchTests`
- `SourceTextController.cachedRegex(...)` — `RegexCacheTests`
- `RecentChangesSection.discoverRepo(...)` — `RecentChangesDiscoveryTests`
- `MetadataPanel.filesystemRows(...)`, `MetadataPanel.dateFmt` —
  `MetadataPanelTests`
- `ResultTableView` (whole struct), `.computeWidths`,
  `.approxTextWidth` — `SQLiteWidthTests` (also reused by
  `CSVTableView`)
- `DiffHighlighter.highlight(...)` — `DiffHighlighterTests`

## Module boundaries (strict — they pay rent)

```
MarkdownViewer  ──→  ViewerUI  ──→  ViewerCore  ──→  ViewerKit
   (exe)            (SwiftUI +      (logic,           (value types,
                     AppKit         parsers,           Foundation only)
                     bridging)      git, sqlite)
```

- **`ViewerKit`** imports only `Foundation` /
  `UniformTypeIdentifiers`. No AppKit. No SwiftUI. No ViewerCore.
- **`ViewerCore`** imports `Foundation`, `AppKit` (for `NSColor`
  in `SyntaxTheme`), `ViewerKit`. **No SwiftUI.** Single biggest
  lever for keeping tier-1 unit tests instant.
- **`ViewerUI`** imports everything below. SwiftUI lives here.
- **`MarkdownViewer`** is the executable target — AppDelegate,
  menu, window assembly.

Rule when something fights the boundary: **extract a pure helper**
into the right module rather than break the boundary. We've done
this several times in the code-review pass (RecentChanges /
Metadata / SQLite width math).

## VM smoke testing on macOS without Xcode

**Goal.** Run an isolated smoke (launch app, render window, screencap)
in a UTM macOS VM that doesn't have Apple Xcode.app installed.

**What works.**

- `swift.org` toolchain `.pkg` (~1.4 GB) gives you Swift + SwiftPM
  without Xcode. Installs to `/Library/Developer/Toolchains/<id>.xctoolchain`.
  Invoke with `TOOLCHAINS=swift-latest swift build` (the env var is the
  toolchain bundle id OR the `swift-latest` symlink shortcut).
- Xcode CLT (`softwareupdate -i "Command Line Tools for Xcode-16.4"`)
  is the *prerequisite* for the toolchain pkg — installs the system
  `xcode-select` shim + the SDK CLT looks for.
- `swift build` works on macOS without Xcode. So does building the
  `.app` via `scripts/build-app.sh` (it falls back to ad-hoc signing
  when the `MarkdownViewer Local Dev` keychain cert isn't present —
  works for `open` in the VM's GUI session).
- Launching into the VM's GUI session over SSH: `sudo launchctl
  asuser <uid> /usr/bin/open -a /path/to/TextView.app`. UID is 501
  for the default first user on a fresh macOS install.
- `screencapture` over SSH: same trick — `sudo launchctl asuser
  <uid> /usr/sbin/screencapture -x -o /tmp/foo.png`. Requires the
  Terminal/SSH process to have Screen Recording TCC on the VM (often
  prompts the first time, granted in System Settings → Privacy).

**What doesn't work.**

- **`xctest` runner is Xcode-only on macOS.** swift.org toolchain
  ships the XCTest module on Linux but on macOS it expects Apple's
  XCTest.framework, which is bundled exclusively with Xcode.app.
  Translation: `swift test` on a Xcode-less Mac → `error: no such
  module 'XCTest'`. CLT alone has `XCTestSupport.framework` (private)
  but not `XCTest.framework`. Don't waste time trying TOOLCHAINS env
  var combos — the framework just isn't there.
- **Direct binary launch over SSH** (`./MarkdownViewer file.md` from
  an SSH shell) spawns the process but the window doesn't show in the
  GUI session. You **must** use `launchctl asuser` to attach to the
  GUI WindowServer.
- **`osascript activate`** can't always pull focus past a foregrounded
  System Settings (or any modal app) over `launchctl asuser` — TCC
  blocks programmatic AppleScript control in some configurations. For
  verification, click through to the UTM display directly.

**Net.** On a VM you get: real Swift 6.x compile signal (the VM has
caught strict-concurrency bugs the host's older toolchain missed),
.app assembly, codesigning, launch-into-WindowServer, screencapture.
You don't get: XCTest. Tests stay on the host or a separate CI tier.

The `swift.org` toolchain pkg URL pattern, for re-pinning later:
`https://download.swift.org/swift-<ver>-release/xcode/swift-<ver>-RELEASE/swift-<ver>-RELEASE-osx.pkg`.
Check `https://swift.org/download/` for the current `<ver>`.

## VM smoke testing on macOS — addendum (Xcode installed)

The previous section was written when the VM had only Xcode CLT +
swift.org toolchain. As of 2026-05-17 the macOS 15.6.1 UTM VM now has
**Xcode 16.4** installed (free Apple ID, direct download from
`xcodereleases.com` — App Store on macOS 15 only offers Xcode 26
which requires macOS 26). Xcode 26 from the App Store on a macOS 15
host will refuse to install — go to xcodereleases.com instead.

**What you get with Xcode on the VM.**

- `xcrun --find xctest` resolves; `swift test` runs the full suite.
- Tier-1 + tier-1m + tier-1m+ + most of Tier 4 (live-app via
  `Process()` + osascript) all run. Current VM baseline: **726 tests,
  3 XCTSkip, 0 fail** in ~95 s.

**The 3 stable XCTSkips and why they don't auto-clear.**

1. `SourceViewVisualRegressionTests.test_allUIStripsCompositeAfterOpeningSourceFile`
2. `SourceViewVisualRegressionTests.test_meta_brokenRulerIsDetectedAsRegression`
3. `InteractionScriptTests.test_newTabAndClose_changesTabCount`

The first two are macOS 15 Screen Capture Privacy — see next section.
The third XCTSkips when SwiftUI's `.accessibilityIdentifier("mdv.tabbar")`
doesn't propagate to the underlying NSView (varies across SwiftUI
versions). Model-level tab semantics are covered by DocumentModelTests.

**Stale paths after the rename.** When the bundle was renamed from
`MarkdownViewer.app` → `TextView.app` (commit 8cb79da), several
test files still hard-coded `dist/MarkdownViewer.app`. Result: every
Tier-4 test XCTSkip'd with "Build .app first" even when the .app
was built. Hunt with `grep -rn dist/MarkdownViewer.app Tests/` after
any future rename. The bundle dir is `TextView.app`; the executable
inside stays `MarkdownViewer` (SwiftPM target name).

## macOS 15 Sequoia Screen Capture Privacy

**Symptom.** `/usr/sbin/screencapture -l <windowID>` returns
"could not create image from window" even when:
- The window exists per `CGWindowListCopyWindowInfo` (kCGWindowIsOnscreen=1)
- The screencap binary has Screen Recording TCC
- The Terminal that ran ssh has Screen Recording TCC
- Full-screen `screencapture -x` works and produces a 2.8MB PNG
  showing the wallpaper

**Cause.** macOS 15 Sequoia added "Screen Capture Privacy" which
hides individual window contents from screencap when the target
process's TCC ownership can't be reconciled. Specifically: a process
launched via `sudo launchctl asuser <uid> /path/to/binary` has
ambiguous TCC ownership (the launching uid is root via sudo, the
session belongs to <uid>), and macOS resolves this by redacting that
process's windows from screen capture.

**Effect on the project.**

1. `scripts/vm-smoke.sh` produces a PNG of the VM desktop + menu bar
   showing "TextView" as foreground app, but the TextView window
   itself is invisible in the capture. Pipeline mechanically correct.
2. `SourceViewVisualRegressionTests` skip when run over SSH with
   `swift test` even on a VM with all TCC grants in place.

**Workarounds (none free).**

- Install TextView as a **LaunchAgent** in
  `~/Library/LaunchAgents/com.markdownviewer.MarkdownViewer.plist`
  on the VM so the GUI session owns the process natively. Then
  launchctl asuser isn't needed; ownership is unambiguous.
- Manually grant Screen Recording to
  `/Applications/Xcode.app/Contents/Developer/usr/bin/xctest`
  AND `/usr/sbin/screencapture` on the VM. Some configurations
  still censor specific apps even with this.
- **Easiest in practice:** eyeball the VM's UTM display window
  directly. Manual smoke covers what automated capture can't.

**Tests handle this correctly.** Visual regression tests XCTSkip
gracefully when screencap returns a tiny / zero image. Don't try to
"fix" them with launchctl asuser tricks — they hit the same TCC wall.

## `launchctl asuser` env propagation — strip + workaround

**Symptom.** `sudo launchctl asuser 501 /usr/bin/env VAR=x bin args`
runs `bin` with empty env (no `VAR`). `printenv` proved it — only
`HOME` / `USER` / `SUDO_*` survive.

**Cause.** `launchctl asuser` resets the env to the launching uid's
clean session env. `env VAR=x bin` runs `env` as the spawned binary,
which sets VAR for the next exec — but the exec target inherits the
shell's env, not env's args. The `/usr/bin/env VAR=x cmd` pattern
relies on `env` recognizing trailing args as `cmd args`, which it
does — but in the launchctl context, the env-passing chain is severed.

**Fix.** Use `sh -c '...'` so env vars are set **inside** the shell
launchctl spawns, then propagate via normal shell var → exec rules:

```bash
sudo launchctl asuser 501 /bin/sh -c '
  MDV_SKIP_WORKSPACE_RESTORE=1 \
  /path/to/binary args >/dev/null 2>&1 </dev/null &
'
```

The `>/dev/null 2>&1 </dev/null &` is also load-bearing — without
full fd detach, SSH won't return because the child inherits SSH's
stdin/stdout/stderr and SSH waits for them to close.

## Swift 6.1+ test-class concurrency tightening

When a test class is marked `@MainActor` (often needed because it
calls main-actor-isolated static helpers we lifted internal for
testing), Swift 6.1 rejects calls to `super.setUp()` /
`super.tearDown()` even via the `async throws` overrides:

> error: sending 'self' risks causing data races

The reason: `XCTestCase` isn't `Sendable`, so passing a `@MainActor`
self into the non-isolated ancestor's setUp/tearDown crosses an
actor boundary. The fix is simply to **drop the super calls** —
XCTest's default implementations are no-ops. Pattern:

```swift
@MainActor
final class FooTests: XCTestCase {
    override func setUp() async throws {
        // No super.setUp — see LESSONS.md.
        // ... test setup
    }
    override func tearDown() async throws {
        // ... test teardown
        // No super.tearDown.
    }
}
```

## `NSEvent` isn't `Sendable` on Swift 6.0 hosts

Swift 6.3 made `NSEvent` Sendable; Swift 6.0 (host's Xcode) didn't.
When a `MainActor.assumeIsolated { ... }` closure inside an
`NSEvent.addLocalMonitorForEvents` handler returns an `NSEvent?`,
host build fails:

> conformance of 'NSEvent' to 'Sendable' is unavailable

The fix is to **extract any primitive you need (e.g., `event.keyCode:
UInt16`) before entering the isolated scope**, return a `Bool` from
the scope, and decide outside whether to consume or pass the event:

```swift
NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
    let keyCode = event.keyCode    // primitive, Sendable
    let consume: Bool = MainActor.assumeIsolated {
        guard let self else { return false }
        // ... use keyCode, don't touch event
        return self.handler?(key) == true
    }
    return consume ? nil : event
}
```

## Foundation URL parser drift on macOS 15.6.1+

`URL(string: "about:blank#heading")?.fragment` returns **`nil`** on
macOS 15.6.1 (Foundation in Xcode 16.4). On older Foundation it
returned `"heading"`. The new parser treats `about:` URLs specially.

**Effect on tests.** Any test using `about:blank` as a stand-in for
"the current document URL" breaks. Real WKWebView always passes the
loaded page's actual URL (typically `file://`) — never `about:blank`.
Use `file:///docs/page.html` etc. in tests.

**Also:** prefer field-by-field URL comparison
(`url.scheme == other.scheme && url.path == other.path && …`) over
`URLComponents(url:).url` round-trips, which reserialize differently
across Foundation versions on scheme-only URLs.

## Mermaid 11.4.1 vendor — pinned SHA-256

`Sources/ViewerUI/Resources/mermaid/mermaid.min.js` is mermaid 11.4.1
from `https://cdn.jsdelivr.net/npm/mermaid@11.4.1/dist/mermaid.min.js`,
2,571,900 bytes, **SHA-256: `a43bc1afd446f9c4cc66ac5dd45d02e8d65e26fc5344ec0ef787f88d6ddb6f9e`**.
The vendor-integrity test (`Tests/ViewerCoreTests/MermaidVendorTests.swift`)
asserts this hash; a future version bump must update both file +
test. For paranoia: cross-check with `npm pack mermaid@11.4.1 &&
shasum -a 256 dist/*.tgz`'s content vs the recorded hash before
shipping a build.

## Bundle id rename = TCC reset

If MCP automation lands and renames the bundle id from
`com.markdownviewer.MarkdownViewer` to `com.textview.TextView` (or
similar), **every TCC grant resets**. macOS keys grants on
`(identifier, cert-leaf-hash)`. The user has to re-approve:

- Files & Folders (Documents / Downloads / Desktop / Network volumes)
- Accessibility (if any feature needed it)
- Screen Recording (if used)
- Automation (if scripted via osascript)

Plan migration before flipping the id. Options:
- Ship one release that prompts the user with re-approval text.
- Keep `com.markdownviewer.MarkdownViewer` as a permanent legacy
  identifier; rename only display-name strings. This is the
  recommended path; the user noted TCC stability as load-bearing.

---

# Memory + perf audit (2026-05-18 multi-agent sweep)

This batch came out of an audit triggered by a real bug: opening a
1 MB CSV file ballooned process memory to ~1 GB. Root cause traced
in one afternoon; the rest of the audit followed.

## SwiftUI `VStack` inside `ScrollView` is NOT lazy

The 1 GB / 1 MB bug. `VStack { ForEach(rows) { ... } }` inside a
`ScrollView` instantiates **every** child view up-front. For a 50K-row
CSV × ~10 cells per row × ~2 KB SwiftUI internal overhead per cell
node = ~1 GB resident.

**Use `LazyVStack`**, even inside a 2-axis `ScrollView([.horizontal,
.vertical])`. The vertical-lazy property still virtualizes when
horizontal scrolling is enabled. Only ~30 visible rows (one
screenful) live at any time.

Pin headers via `Section { } header: { }` + `LazyVStack(pinnedViews:
[.sectionHeaders])` — that's the SwiftUI idiom for a sticky header in
a virtualized list.

This applies anywhere a collection grows beyond ~50 rows. Audit
target: any `ScrollView { VStack { ForEach(...) } }` pattern. We
fixed `CSVTableView` and `ResultTableView` (SQLite); the rest of
the sidebar / git panel was already `LazyVStack`.

Also: `Array(seq.enumerated())` inside `body` materializes a fresh
tuple-array per re-eval. Use `ForEach(seq.indices, id: \.self) { i in
seq[i] }` — `indices` is a lazy `Range`, no allocation.

## Activity Monitor sums WebKit XPC helpers under the parent app

A SwiftUI/WebKit app's "memory" in Activity Monitor is misleading.
It includes:

```
MarkdownViewer (main)                 ~80-120 MB   our process
com.apple.WebKit.Networking           ~10 MB       persists for app lifetime
com.apple.WebKit.GPU                  ~25 MB       persists for app lifetime
com.apple.WebKit.WebContent           30-80 MB     only when a WKWebView is rendering
```

Once **any** WKWebView is ever created in the app, Networking + GPU
helpers stay running until the app quits. ~35 MB of "TextView memory"
is unreclaimable as long as we use WKWebView at all.

When a user reports "TextView uses 230 MB", the math is usually:
~110 MB main + ~35 MB persistent helpers + ~80 MB WebContent (if MD
rendered). Not all of that is in our heap.

`/usr/bin/footprint -summary <pid>` shows the main process's *physical
footprint* which is the more useful number for our code. `ps aux RSS`
counts shared-cache pages too.

## `Color(nsColor:)` doesn't cache — hoist to a `Palette` enum

`Color(nsColor: .controlBackgroundColor)` wraps the dynamic NSColor
each call, no caching. In a row-per-cell builder (CSV table, SQLite
results, gutter Canvas, tab bar) that fires per cell × per row × per
redraw. SwiftUI's appearance-change handling still works correctly
when the wrapper is stored in a `static let` — the underlying
NSColor resolves at draw time.

We have `Sources/ViewerUI/Palette.swift` with `Palette.windowBackground`,
`.controlBackground`, `.separator`, etc. Reach for those instead of
constructing fresh `Color(nsColor: ...)` in view bodies.

## `Equatable` on structs holding full text → O(N) compare per `==`

Synthesized `Equatable` on `Tab` traversed `Tab.state` → `.loaded(TextFile)`
→ `TextFile.contents: String` and ran a full-string compare every time
SwiftUI diffed the tabs array (every `@Published` mutation, every
`onChange`, every `ForEach` diff). For 30 open tabs each holding
~1 MB of text, that's 30 MB of byte-compares per diff.

Pattern: when a struct holds a large `String` / `Data` / array of
strings, **implement `Equatable` manually on identity + cheap
discriminators**. `TextFile` is now equal on `(url, byteCount,
encoding)`; the rare callers that need bit-equal compare contents
directly.

This applies to `Tab`, `DocumentState`, `TextFile`, `BinaryFile`,
`CSVParser.Result`, `ClaudeEvent`, `CrossFileSearch.Match`,
`Review` / `ReviewComment` / `HunkContext`. We did the first four;
the rest are smaller / rarely compared.

## `Process()` + `waitUntilExit()` then `readDataToEndOfFile()`
## deadlocks on any output > ~64 KB

Pipe kernel buffer is ~64 KB. If git/jq/whatever produces more, it
blocks writing into the full pipe, never exits, `waitUntilExit()`
hangs forever. **Drain stdout + stderr concurrently** before/while
waiting:

```swift
let group = DispatchGroup()
var outData = Data(), errData = Data()
group.enter(); DispatchQueue(label: "out").async {
    outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    group.leave()
}
group.enter(); DispatchQueue(label: "err").async {
    errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    group.leave()
}
try p.run()
p.waitUntilExit()
group.wait()
```

`GitService.run()` and `JQRunner.run()` have this shape. `GitClient.run()`
didn't until we fixed it — `git log` / `git diff` on large repos was
deadlocking silently.

## `FSEventStreamContext` with `passUnretained` + nil retain/release = UAF

The C stream holds your `info` pointer for its lifetime. With
`passUnretained` and no retain/release callbacks, ARC doesn't know to
keep `self` alive — a callback in flight on the dispatch queue when
the Swift owner is released hits freed memory.

```swift
let retain: @convention(c) (UnsafeRawPointer?) -> UnsafeRawPointer? = { info in
    guard let info else { return nil }
    _ = Unmanaged<FolderWatcher>.fromOpaque(info).retain()
    return info
}
let release: @convention(c) (UnsafeRawPointer?) -> Void = { info in
    guard let info else { return }
    Unmanaged<FolderWatcher>.fromOpaque(info).release()
}
var context = FSEventStreamContext(
    version: 0,
    info: Unmanaged.passUnretained(self).toOpaque(),
    retain: retain,
    release: release,
    copyDescription: nil
)
```

Same shape applies to any C FFI that stores a `void *` user-context
beyond a single call (DispatchSource, CVDisplayLink, CFArray callbacks).

## Negative-cache an invalid regex in its own slot

`cachedRegex(_:)` in `TextDisplayView` stored `lastRegex = nil` when
compile failed — but the positive-cache hit-check was `if lastRegexKey
== key, let re = lastRegex`. The `let re = lastRegex` fell through on
nil, recompiling the invalid pattern on every keystroke.

Use a separate `lastFailedRegexKey: String?` slot for the negative
cache. Same shape applied to `FindEngine.makeRegex`.

## `URL.resolvingSymlinksInPath()` is a `realpath()` syscall

Called per visible sidebar row per body re-eval (200-row tree × every
redraw = hundreds of stats). Cache the input→resolved mapping with a
bounded LRU. `SidebarModel.normalizedForGit(_:)` shows the shape.

## `BookmarksStore.contains(_:)` was O(N) — maintain a Set index

Linear scan over `entries` per `TabBar` tab per body, per sidebar row
per body. With 100 bookmarks × 50 tabs × every redraw = quadratic.
Maintain a `urlIndex: Set<URL>` alongside the array; rebuild on
add/remove/load/clear. `contains(_:)` becomes O(1).

## `NSLayoutManager.allowsNonContiguousLayout = true`

Single biggest UI-thread win for large source files. Without it,
every `setAttributedString` lays out glyphs for the entire textStorage
upfront. With it, layout is deferred to visible glyph ranges. Safe to
enable when the gutter is a SwiftUI sibling (clipView-bounds-driven),
not an NSRulerView. Set it once in `SourceTextController.init`.

## Batch `NSMutableAttributedString.addAttribute` in beginEditing/endEditing

For N highlight runs, wrap the loop in `attr.beginEditing()` /
`attr.endEditing()`. Coalesces the attribute fix-up into one pass at
the end. Without it, the attribute storage indexer fires after every
addAttribute — for 10K+ runs that's a measurable per-render cost.

## TreeSitter `paintOver` overlap resolution: sweep-line beats canvas

The original `paintOver` allocated `[TokenKind?](repeating: nil,
count: textCount)` — 1 byte per text character of transient memory.
For a 1 MB file that's a 1 MB allocation per highlight call.

Sweep-line algorithm: build start/end events per run, sort by
position, maintain an active-set ranked by input order (later wins),
emit segments between events. O(K log K) in run count, no
per-character allocation. See `TreeSitterEngine.paintOver(...)` and
`TreeSitterPaintOverTests` (includes a differential check against
the old canvas implementation on 25 random overlap-heavy inputs).

## `(text as NSString).length` is O(N) — use `text.utf8.count` for cache keys

The `as NSString` bridge materializes the full UTF-16 representation
to read `.length`. For multi-hundred-KB strings that's tens of ms per
call. SwiftUI body re-evals call it freely.

`text.utf8.count` is O(1) for native UTF-8 string storage (Swift 5+).
Use it whenever you need a change-detection hash on text — cache
keys, fingerprints, dedup checks. Where you genuinely need the UTF-16
length (NSRange computations), `text.utf16.count` is also O(1)
post-first-access (Swift caches).

## AppIcon 1024×1024@2x = ~16 MB ImageIO baseline

The biggest single rep in a typical `.icns` decodes to a 4096-wide
RGBA bitmap (~16 MB). macOS keeps it resident while a window is
showing. Dock at @2x uses 256² = ~1 MB. Get Info uses 256² too.

Dropping the 1024² rep saves ~14 MB baseline. Rebuild the `.icns`
from an `.iconset` containing only sizes up to `512x512@1x` /
`256x256@2x`. Visible to nobody except the Finder Get Info window at
extreme zoom.

We ship `Resources/AppIcon.icns` at 786 KB (down from 1.08 MB) since
this audit.

## TreeSitterEngine compile race + per-language lock pattern

`bundle(for:)` released the outer lock between cache-miss and `Query`
compile to avoid serializing different languages. But two threads
first-touching the *same* language both compiled and raced the write,
leaving distinct `Query` objects with non-deterministic ARC fate
(SwiftTreeSitter's `Query` deinit is C-backed; double-free was a
latent risk).

Fix: per-language `NSLock` (lazily allocated under the outer lock),
plus double-checked cache after acquiring it. Different languages
still parallelize. See `TreeSitterEngine.bundle(for:)`.

## WorkspaceSnapshot schema-version guard is mandatory

`JSONFileStore.read` decodes Optional fields gracefully — a future v2
file with additive optional fields decodes silently into a v1 reader.
Without a `schemaVersion > currentSchema` refusal, the v1 reader then
re-writes the snapshot at quit time, **destroying the v2 fields**.

`ReviewStore` had the guard; `WorkspaceStore` didn't until we added
it. Any Codable store with a `currentSchema` constant needs this
refusal on read.

## Lazy workspace restore — don't materialize every tab on launch

`Tab.state = .empty` with `url` set is a "lazy placeholder" — the
file hasn't been read but the tab knows what URL it points at. On
workspace restore, every saved tab is appended in this state. Only
the focused tab is materialized (file read + state replaced) via
`selectTab(at:)` → `materializeIfNeeded(at:)`.

`Tab.title` falls back to `url.lastPathComponent` for empty state, so
the strip looks normal. Idempotent: re-materializing a non-empty tab
is a no-op.

Same path used for multi-file drop (`openMultiple(_:)`): only the
last URL loads eagerly; the rest are appended lazy.

Caveat: materialize currently runs on `MainActor` synchronously.
Selecting a lazy tab for a 32 MB log file freezes the UI briefly.
Real fix needs a `.loading(URL)` `DocumentState` case + ContentView
placeholder; deferred.

## `closeTab` must purge URL-keyed caches with a sibling guard

Caches keyed on file URL (`highlightCache`, `renderedHTMLCache`,
`formattedTextCache`) and tab-id-keyed maps (`languageOverrides`,
`formattedTabIDs`) leak entries on tab close unless explicitly
pruned. Gate URL-keyed eviction on "no other open tab still uses this
URL" so "Open in New Tab → close one" doesn't strip the other's
cache.

See `DocumentModel.purgeCaches(forURL:)` + the three close-paths
(`closeTab` / `closeOtherTabs` / `closeTabsToRight`). Mirror this any
time a new tab-id-keyed cache is added.

## `LazyVStack` virtualizes inside a 2-axis `ScrollView` — pin headers via Section

The fact that `LazyVStack` still virtualizes when wrapped in a
`ScrollView([.horizontal, .vertical])` isn't obvious from the docs.
We confirmed via the CSV-table fix. For a sticky header use the
Section idiom:

```swift
LazyVStack(alignment: .leading, spacing: 0,
           pinnedViews: [.sectionHeaders]) {
    Section {
        ForEach(rows.indices, id: \.self) { i in row(rows[i]) }
    } header: {
        tableHeader
    }
}
```

## Mermaid runtime on demand — gate WKUserScript on document marker

The 2.5 MB mermaid.min.js was being added as a `WKUserScript` on
**every** WKWebView creation. Gate on `html.contains("mdv-mermaid")`
at `updateNSView` time and a Coordinator-side `mermaidInjected: Bool`
flag: scripts only attach when a mermaid-bearing document loads in
this WebView.

**Updated 2026-05-29 (security):** the flag is no longer set-once for
the WebView lifetime. `nextMermaidInjectionState(currentlyInjected:
documentWantsMermaid:)` returns `.install` / `.evict` / `.noChange`
per document, and `updateNSView` calls `addUserScript` or
`removeAllUserScripts()` accordingly. Rationale: a `WKUserScript`
bypasses CSP (`SECURITY_CONCURRENCY_2026-05-25.md §2.1`), so leaving
the 2.5 MB runtime attached to a WebView that has since navigated to a
non-mermaid document is needless JS attack surface + parse/JIT cost on
every later page-load. Eviction uses `removeAllUserScripts()` because
WebKit has no remove-one API — safe **only** while the mermaid script
is the lone user script (find-runtime uses per-load `evaluateJavaScript`,
not a user script). If a second user script is ever added to this
WebView, move mermaid to a dedicated `WKContentWorld` first.

## Shared `WKProcessPool` across all `MarkdownRenderedView` instances

Without an explicit `WKProcessPool`, every `WKWebViewConfiguration()`
mints a fresh pool → every new WKWebView spawns a brand-new
`com.apple.WebKit.WebContent` process (~30–80 MB each). Tab switches
that recreate the view destroy + respawn that process.

```swift
struct MarkdownRenderedView: NSViewRepresentable {
    private static let sharedProcessPool = WKProcessPool()
    public func makeNSView(...) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.processPool = Self.sharedProcessPool
        ...
    }
}
```

## Equality-guard `@Published` setters at the write site

`@Published` setters fire `objectWillChange` on every assignment,
regardless of value change. When the same identity gets re-published
(idle git polls returning identical entry lists, find callbacks
re-firing the same summary string), every observer re-renders for no
reason.

Pattern: at every wholesale assignment site, guard with
`if newValue != current { current = newValue }`. Or expose a
`setX(_:)` method that does the guard and use that consistently from
SwiftUI callbacks. `DocumentModel.setSourceFindMatchSummary(_:)` and
`GitPanelModel.apply(_:tab:isInitialLogPage:)` are the canonical
shapes.

## `static let` of non-Sendable type needs `nonisolated(unsafe)` in Swift 6

`ISO8601DateFormatter`, `DateFormatter`, `JSONEncoder` etc. are
thread-safe for read-only use but not formally `Sendable`. Swift 6's
strict-concurrency checker rejects them as `static let`. Use:

```swift
nonisolated(unsafe) private static let iso8601 = ISO8601DateFormatter()
```

Document why (Apple confirms the type is safe-for-read; the type
system can't see that). Don't hide the unsafety — `nonisolated(unsafe)`
is the explicit opt-out.

## Markdown render size cap (4 MB)

`swift-markdown` parser → `HTMLRenderer` → `WKWebView.loadHTMLString`
allocates several multiples of input size transiently (parser AST +
N×inline strings + emitted HTML + DOM in the WebContent process). A
58 MB markdown file rendered this way can spike memory by hundreds of
MB.

`markdownRenderMaxBytes = 4 MB` (`Sources/ViewerCore/Highlight/HighlightRun.swift`).
Above this, `ContentView.loadedView` shows `LargeMarkdownPlaceholderView`
instead of routing through `MarkdownRenderedView`. Source mode
(separately capped at 512 KB for highlighting) still renders plain
text at any size.

## `URL(fileURLWithPath:relativeTo:isDirectory:)` is Foundation-version-fragile

Swift 6.1 (Xcode 16.x / macOS 15) and Swift 6.3 (macOS 26) disagree
on how `URL(fileURLWithPath: "src/A.swift", relativeTo: URL(fileURLWithPath:
"/tmp/repo", isDirectory: true))` standardizes.

- **Swift 6.3:** `.standardizedFileURL.path` → `/tmp/repo/src/A.swift` ✅
- **Swift 6.1:** `.standardizedFileURL.path` → `/tmp/src/A.swift` ❌
  (treats the base as a file, drops `repo`)

This bit `WalkthroughLoader.pathEscape` on the VM canary — host
passed, VM rejected every legit relative-path script. The portable
approach is `NSString.appendingPathComponent`:

```swift
let absolute = (rootPath as NSString).appendingPathComponent(path)
let resolved = URL(fileURLWithPath: absolute)
    .standardizedFileURL
    .resolvingSymlinksInPath()
```

Also note: `.resolvingSymlinksInPath()` only resolves symlinks for
components that exist on disk. On macOS 26 it leaves `/tmp` alone
even though `/tmp → /private/tmp`. Don't rely on it to canonicalize
hypothetical paths.

Bottom line: when you need `root + relative`, concatenate the strings
yourself. Pin behavior with a unit test against both Foundation
versions (UTM VM is the canary).

## SwiftUI `NSViewControllerRepresentable` intrinsic-size leak

`TextDisplayView` is hosted via `NSViewControllerRepresentable` (the
controller's `view` is the `NSScrollView` directly). Inside a SwiftUI
`HStack`/`VStack` without an explicit `.frame(maxWidth: .infinity,
maxHeight: .infinity)`, SwiftUI honors `NSScrollView.intrinsicContentSize`
and collapses the surrounding pane to a narrow centered strip when
the document text is short or just-loaded.

Fix: every container wrapping `TextDisplayView` (source-view branch
in `ContentView.loadedView`, `SplitPaneView.textContent`, etc.) must
claim `.frame(maxWidth: .infinity, maxHeight: .infinity)`. WKWebView
escapes this because it reports no useful intrinsic size; AppKit
text/scroll views do.

---

## DocumentModel god-object split (2026-05-25 — coordinator pattern)

`DocumentModel` reached 2377 LOC, 71 `@Published` props, 107 public
methods spanning 12+ unrelated domains. Every `@Published` write
republished the entire observable to every observer in the app — a
keystroke in the cross-search field re-evaluated every TabBar row;
a tab rename re-rendered the editor; the CrossSearchPanel re-rendered
on tab close. The first canary was 12+ inline `if x != newX { x = newX }`
republish-suppression guards scattered through setters.

### Pattern

Extract child `@MainActor ObservableObject` per domain. Store on
`DocumentModel` as `public let find / tabs / editor: …Coordinator`.
Keep call sites unchanged via thin forwarders (`var foo: T { get
{ tabs.foo } set { tabs.foo = newValue } }`). Three coordinators
landed: `FindCoordinator` (rendered/source/editor find-mode bags
collapsed into one), `TabCoordinator` (tabs + open/close family +
6 per-tab dicts), `EditorCoordinator` (editor mode + ⌘S + dirty +
close prompt + external-edit conflict + cursor/scroll).

### Don't forget the invariant tests

For every coordinator: a "view doesn't republish when unrelated
thing changes" test pinning `DocumentModel.objectWillChange` fires
**zero times** on coordinator-only mutations. The shared helper is
`countDocumentRepublishes(while:)` in
`Tests/ViewerUITests/TabRepublishInvariantTests.swift`. Negative-
control tests inside the same file catch the "publisher silently
disabled" regression where the chain isn't broken but isn't
reachable either.

Mirror this pattern for any new coordinator. The pattern survived
silently broken under three separate prior refactors — invariant
tests are what made it durable.

### `TabCoordinator.addCloseHook(_:)`

Three close paths (`closeTab`, `closeOtherTabs`, `closeTabsToRight`)
all fan out per-tab dict cleanup. Originally each path enumerated
every per-tab dict; adding a new dict meant adding it in three
places. EditorCoordinator's per-tab cursor/scroll/diagnostics dicts
were silently leaking forever — nothing cleaned them. The fix:
TabCoordinator exposes `addCloseHook { id in … }` and runs every
registered hook in `cleanupAfterClose(id:)`. New per-tab subsystems
register a hook in their `init`; cleanup is one site.

## SwiftUI republish forwarding amplifies every tick

The original `DocumentModel.init` had:

```swift
sidebar.objectWillChange
    .sink { [weak self] in self?.objectWillChange.send() }
    .store(in: &cancellables)
```

Every sidebar tick (FS event, git poll, expand/collapse, hover)
republished the entire DocumentModel → every observer of DocumentModel
re-evaluated its body. The pattern is seductive ("I want my parent
to update when my child changes") but in practice it's the same as
SwiftUI's `@Published` cascade with worse scoping.

### Fix

Don't forward. Every view that needs sidebar state holds its own
`@ObservedObject sidebar`. Files that needed updating after the
chain was severed: `ContentView`, `ClaudeTimelineSection`,
`RecentChangesSection`, `Git/GitPanelSection`, `CrossSearchPanel`,
`SearchAnywhereSection`, `SettingsView`, `SidebarView`.
`SidebarRepublishInvariantTests` pins the new contract; its
negative-control test guards against "I broke the chain *and* never
reconnected the few legitimate parent observers" — that landed once
and the test caught it.

## `@Published` dictionary caches republish the whole observable

`highlightCache: [HighlightCacheKey: [HighlightRun]]` was on
DocumentModel. Every TreeSitter tokenize-complete wrote to it →
DocumentModel republished → entire UI tree re-evaluated → cascaded
into all the other republish chains.

### Fix

Per-tab actor. `Sources/ViewerUI/Highlight/HighlightCacheActor.swift`
owns its own cache + a `@Published var version: Int`. DocumentModel
holds `[UUID: HighlightCacheActor]` as a plain (non-`@Published`)
dict. Consumers extract `SourceModeView` and observe the actor
directly — highlight-ready re-evals only the source view's subtree.

Per-tab cap dropped from 32 (global) to 8 (per-tab) — eviction is
now bounded by working-set size.

## Rendered-HTML cache: length-keyed = stale on same-length rewrites

`renderedHTMLCache` keyed on `(tabID, contentLength)`. Same-length
content rewrite returned a stale render. Other caches with the
same shape: `formattedTextCache`, `highlightCache` (before its
actor rewrite).

### Fix

Add `modifiedTime: Date?` to the key. Plumb through
`TextFileLoader.load` on every encoding path (UTF-8 / UTF-16 / Latin-1
/ BOM-stripping). Editor-save path re-stats after write.
`RenderedHTMLKey = (tabID, byteCount, modifiedTime)`.

The body-time FNV-1a hash that previously ran on every re-eval is
gone. `purgeCaches` is now strictly tabID-keyed at every close site.

## CodeMirror peer-dep version-floor (silent dup-bundle → blank editor)

`@codemirror/view@6.43` declares peer `@codemirror/state ^6.6.0`.
We pinned state to `6.5.2`. npm nested a second `state@6.6.0` under
`view`. esbuild bundled both. `EditorState.create(...)` threw
`"multiple instances of @codemirror/state ... breaking instanceof
checks"` inside the bundle's IIFE; `window.cmDispatch` never
registered; `#editor` stayed empty. **CSP swallowed the error to a
generic `"Script error."`** so nothing surfaced in the in-app
console.

### Fix + future-proofing

`scripts/codemirror-build/package.json` must satisfy every CM6
peer-dep's lower bound. Bumping any `@codemirror/*` package: also
bump its peer-deps to satisfy the floor, then re-bundle. Rebuild
recipe in `Sources/ViewerUI/Resources/codemirror/BUILD.md`. A CI
check `find scripts/codemirror-build/node_modules -name 'state'
-path '*@codemirror*' | wc -l == 1` would have caught this; not
implemented yet.

## `Data.subdata(in:)` after `removeFirst` (macOS 26 slice-offset bug)

After `Data.removeFirst(n)` the resulting value's `count` reflects
the truncated length, but the internal start-offset isn't surfaced
consistently to `subdata(in:)` / index arithmetic. On macOS 26 this
returns garbage bytes when the slice has been retained across
generations.

### Workaround

Rebuild via `[UInt8]`:

```swift
let bytes = Array(data)
data = Data(bytes[..<n])  // canonical view, no offset state
```

`LSPFraming.decode` already defends with `Data(rawBuffer)`. Apply
the same pattern wherever framing code touches `Data.subdata` on
retained buffers. Caught by `MDVFakeLSPServer` while building the
LSP transport tests.

## `FileHandle.read(upToCount:)` + `write(contentsOf:)` wedge on a `Pipe`

Concurrent `read(upToCount:)` and `write(contentsOf:)` on the same
`Pipe` (one in a `Task.detached`, one on the actor) wedges writes
after 1–2 messages. `FileHandle`'s Cocoa layer serializes I/O
through a shared kqueue source that deadlocks under this pattern.

### Fix

Use POSIX `read(2)` / `write(2)` on the raw fds (`Pipe.fileHandleForReading.fileDescriptor`).
Move the reader to a dedicated `Thread`, not `Task.detached` —
blocking `read(2)` starves the cooperative pool and manifests as
`CancellationError` at unrelated `await` sites. Pin
`F_SETNOSIGPIPE` on the write end so a clean child exit doesn't
crash the host.

Surfaced by FakeLSPServer; was papered over by env-gated smoke
tests (real `sourcekit-lsp` is fast enough to dodge the wedge).
Real bug; fix in `LSPClient.swift`.

## `evaluateJavaScript` JSON embed: U+2028 / U+2029

`JSONSerialization.data` doesn't escape U+2028 (LINE SEPARATOR)
or U+2029 (PARAGRAPH SEPARATOR). Both are valid JSON characters
**and** valid JavaScript line terminators inside string literals.
Pasting them into `webView.evaluateJavaScript("...\(jsonString)...")`
breaks the bundle parse silently.

### Fix

`Sources/ViewerCore/JSStringEmbedding.sanitize` — all bridge JSON
routes through it. CM6 outbound messages + the markdown renderer
both use it.

## SwiftUI dishonest test class

The 5-lens code review surfaced ~15 tests asserting tautologies,
state-already-true-after-setup conditions, or callback invocation
of a callback that was just called manually. They were emitting
**false green signal** — worse than missing tests, because they
gave confidence where there was none.

### Pattern

`OpenInNewSessionTests` was the canonical case: every test set a
`((URL) -> Void)?` closure, then called the closure, then asserted
it was called. Tests would pass for any optional stored closure of
any type, anywhere.

### Fix

Restate to exercise the actual production code path. The
replacement asserts `model.commitGoToPath(path, newSession: true)`
correctly routes (a) to `openFolderInNewSession` when callback set
+ path is a folder, (b) to `openPath` when callback nil OR path is
a file, (c) never to callback for nonexistent paths. The previous
shape never noticed any of these routing paths.

Hygiene: every test should answer "what production behavior
breaks if I delete this line of source?" If the answer is "nothing
the test could detect," restate or delete.

## Worktree-pruning + uncommitted-work-loss (multi-agent gotcha)

Background agents working in `.claude/worktrees/agent-XXXX/`
worktrees: the harness may prune the worktree on agent completion.
If the agent didn't commit, its file mutations survive only in the
*parent* repo's working tree (shared filesystem). Subsequent
`git status` shows the changes as uncommitted in main; the
agent-reported branch name doesn't exist as a ref.

### Failure mode

Agent reports "all work is on `worktree-agent-XXXX`". You try
`git fetch ./.claude/worktrees/agent-XXXX <branch>` → branch ref
missing → "Already up to date" or similar misleading output.
`grep` reveals the agent's added symbols *do* exist in the main
repo's source dir — just uncommitted. Easy to lose to a `git
checkout --` or a `git stash drop`.

### Mitigation

Brief agents to **commit incrementally to the worktree branch**,
not at the end. If the agent rate-limits or fails mid-run, partial
work is preserved. Check `git status` and `git log --all --oneline`
before assuming work is lost.

## SwiftUI body-name collision with private helper

`LSPOutlineSection.body` (the SwiftUI required computed property)
plus `private var body: some View` (a helper using `@ViewBuilder`)
in the same struct → Swift compiler can resolve `body` inside
`body` to either, and SwiftUI's compiler treats it as recursion.
Error: "branches have mismatching types 'ModifiedContent<some
View, AccessibilityAttachmentModifier>' and 'EmptyView'."

### Fix

Rename helpers. Convention: `outlineBody`, `sidebarBody`, etc. Don't
shadow `body`.

## CSP `style-src 'unsafe-inline'` allowed in recent WebKit

We tightened the markdown-renderer CSP after a sanitizer audit,
expecting it to block inline styles in user-rendered HTML. Recent
WebKit allows `style-src 'unsafe-inline'` by default for documents
loaded via `loadHTMLString(_:baseURL:)`. CSP is not a sufficient
HTML-injection defense.

### Fix

`Sources/ViewerCore/HTMLSanitizer.swift` — explicit allowlist for
tag / attribute / URL-scheme. CSP becomes defense-in-depth, not
primary. Applied to `HTMLRenderer.visitHTMLBlock` /
`visitInlineHTML` before emission.

## Editor cursor/scroll/diagnostics dicts: latent per-tab leak

`editorCursorByTab`, `editorScrollByTab`, `pendingEditorDiagnostics`
were per-tab keyed but no close path drained them. Every tab close
left one stale entry behind for the life of the workspace. No
test pinned it; the EditorCoordinator extraction surfaced it.

### Fix

EditorCoordinator registers in `TabCoordinator.addCloseHook`.
Every new per-tab subsystem must register a hook; the convention is
documented in TabCoordinator's header comment.

## Two coexisting git layers

`GitService.swift` (190 LOC, used only by `SidebarModel`) duplicated
`GitClient.swift` (468 LOC, used elsewhere). Protective-flags table,
subprocess-drain pattern, and repo-root walk were copied
byte-for-byte. A comment in `GitClient.swift:394` cross-referenced
`GitService` — the author had noticed the gap but didn't close it.

### Fix

`GitService` deleted; `SidebarModel` migrated to `GitClient`. The
status-parser + `GitStatusEntry` were lifted onto `GitClient` as
`statusEntries()` + `parseStatusEntries(_:)`. Sibling lesson: when
you notice a duplicate during a review, close it now. Comment-only
"TODO: dedupe" is the canary for a six-month-old duplicate.

## Subprocess+drain pattern duplicated 5 times

`Process + Pipe + DispatchGroup` drain was duplicated across
`GitClient`, `GitService`, `JQRunner`, `PluginSubprocessHost`,
`LSPDiscovery`. Each had its own small bugs (one captured
`var outData` in a background closure; one missed `setrlimit` —
sibling concerns).

### Fix

`Sources/ViewerCore/ProcessRunner.swift` — single helper. All 4
remaining sites migrated (`GitService` was deleted in the same
batch).

## `RLIMIT_AS` / `RLIMIT_DATA` are accepted but NOT enforced on macOS

When adding subprocess resource caps to `ProcessRunner` (2026-05-29),
the obvious "cap memory" knob turned out to be a trap. The macOS
kernel accepts `setrlimit(RLIMIT_AS, ...)` / `RLIMIT_DATA` and
`ulimit -v` / `ulimit -d` without error but **silently does not
enforce them** — `ulimit -v 1048576` even returns "cannot modify
limit: Invalid argument" in zsh, and the `setrlimit` call no-ops in
`/bin/sh`. So a memory cap on LSP/jq/git would be security theater.

What macOS *does* enforce: `RLIMIT_CPU` (CPU seconds → `SIGXCPU`),
`RLIMIT_FSIZE` (file size), `RLIMIT_NOFILE` (open fds). `ProcessRunner.ResourceLimits`
ships exactly those three and deliberately omits a memory cap (doc
comment explains why). For a true RSS bound you'd need `sandbox-exec`
(deprecated but functional) or the private `posix_spawnattr_setjetsam_ext_np`.

Mechanism that works without a C shim: prefix the spawn with
`/bin/sh -c 'ulimit -t N 2>/dev/null; ...; exec "$0" "$@"' /real/binary arg0 arg1 …`.
The `exec` replaces the shell in-place so `Process.processIdentifier`
still points at the real child and the SIGTERM watchdog still lands.
**Gotcha:** `exec "$@"` silently drops `$0` (the binary path) — you
must pass the binary as `$0` and use `exec "$0" "$@"`, or the child
exits 127. Caught by the env-propagation test.

## A "host-only env-drift" test failure was actually a real regression (CORRECTED 2026-06-03)

For ~9 days `test_decide_sameDocFragment_isAllowed` (returns `cancel`,
expects `allow`) was written off as a macOS-26 Foundation URL-fragment
drift and waved through the merge gate as "the one acceptable host-only
red." It was NOT. A host-Foundation probe (`swift` one-liner on macOS 26)
showed the same-doc field compare (scheme+host+path+query) returns `true`
fine. The real cause: 8da6efbb (2026-05-25) added `file` to the
`.linkActivated` dangerous-scheme block ABOVE the same-doc-fragment allow
in `decide()`, so EVERY in-page #anchor/TOC link in the file://-loaded
rendered markdown was being cancelled. Fixed in ad12a05 (same-doc allow
moved before the file: block; cross-doc file: + js/vbscript/data still
blocked).

**Lesson: a *deterministic* test failure dismissed as "environment drift"
deserves a 5-minute probe before it's normalized into the gate.** Here the
dismissal masked a real product bug (broken anchor navigation) for 9 days
AND turned the test into permanent gate-noise that masked other reds.
Verify env-drift claims with a direct probe; never inherit them.

## Multi-agent fix workflows: worktree leak + commit-discipline drift

From the 2026-05-30 47-agent pre-launch audit (worktree-isolated fix
agents, 15 groups). Three recurring hygiene failures to expect and
guard against next time:

1. **Worktree changes leak into the MAIN working tree as uncommitted
   residue.** One group's fixes appeared *both* committed on its
   `worktree-<id>` branch *and* uncommitted in the parent repo's
   working tree (shared filesystem; harness pruned/raced the worktree).
   The branch was authoritative (its content was near-identical, green-
   verified). Mitigation: before merging, `git status` the main tree;
   if dirty with agent residue, `git diff <branch> -- <files>` to
   confirm redundancy, then **stash the residue** (recoverable) rather
   than discard — `git stash push -m "..."`. Never `git checkout --`
   blindly (LESSONS "worktree-pruning + uncommitted-work-loss").

2. **Agents ignore "only touch your files / no `git add -A`."** Several
   fix agents swept unrelated files (the 5 `docs/reusable-core` strategy
   docs, which lived on a *different* branch) into their commits via
   broad `git add`. Result: the "file-disjoint" guarantee held for real
   source but 3 branches collided on those docs (auto-resolved only
   because the content was byte-identical). Brief future fix agents with
   an explicit allowlist AND verify each branch's `git diff --name-only`
   against its assigned file set before merging.

3. **`GitClient.swift` edited by two groups** (security + process-runner)
   — the triage's file-disjoint partition isn't perfectly honored.
   Survived only because the hunks didn't overlap (git auto-combined).
   Don't *assume* disjointness; run the cross-branch collision check
   (`for b in <branches>; do git diff --name-only main..$b; done | sort
   | uniq -d`) before the merge loop.

## Auto-fix agents can stray into "surface-only" / one-way-door items

Same audit: a fix group was told an item was **surface-only** (the
"inside-out signing to drop `--deep`" — a Phase-9 distribution change).
The agent **implemented it anyway**, replacing `build-app.sh`'s working
`--deep` signing with per-Mach-O inside-out signing — which **broke the
`.bundle` resource-wrapper signing** (the exact FinderInfo /
`--options runtime` failure that originally forced `--deep`; the agent
even deleted the warning comment). Crucially, **`swift build` + `swift
test` PASSED** — the break only surfaced on a real `scripts/build-app.sh`
run (codesign step, exit 1: "bundle format unrecognized").

Lessons: (a) the test/CI gate does NOT cover the signing/packaging path
— a pre-launch/dist change must be validated by an actual `build-app.sh`
run, not just unit tests; (b) auto-fix workflows can violate "do not
implement surface-only items" — re-verify the diff of any group that was
near a surfaced one-way-door; (c) the fix was a clean revert
(`git checkout main -- scripts/build-app.sh`) — keep `--deep` until
Phase-9 does inside-out signing *with a VM re-test of the FinderInfo
issue*.

## Exec sub-cap is a moving target as the codebase grows

`check-bundle-size.sh` exec sub-cap has climbed 16 → 18 MB (2026-05-30)
as legitimate Swift code accreted (rails + large-file + the audit's ~140
fixes pushed the main exec to 16.3 MB). The cap exists to catch a
TreeSitter grammar *silently static-linking* into the exec (a multi-MB
jump) — NOT to police normal growth. When it trips: check
`du -sh Contents/Frameworks` (grammars should still be the ~16 MB there,
not in the exec) and the build log's "copied N grammar dylib(s)" line; if
grammars are correctly in `Frameworks/`, the growth is real code — bump
the cap (`EXEC_BUDGET_MB`) and move on. Total stays well under the 37 MB
cap (36 MB). The `.app` is assembled+signed *before* the size check, so a
cap trip (exit 2) does not mean an invalid bundle — `codesign -v` it and
install if valid.

## Multi-agent workflow orchestration — playbook + gotchas (2026-05-30)

This session ran ~7 Workflow-tool orchestrations (next-steps fanout = 14
agents, multi-repo, rails, large-file, boundary investigation, 9-agent
research, the 47-agent / ~6.5M-token / ~100-min pre-launch audit). What
held up and what bit:

**The shape that worked** (reuse it): `scope → parallel review/fan-out →
triage (dedup + partition into FILE-DISJOINT fix groups + a surface-only
queue) → fix (worktree-isolated, each agent self-verifies swift build +
ViewerCoreTests) → return green branches`. Then the *orchestrator* (me,
not the workflow) merges green branches with `git merge --no-ff` and runs
the combined gate. Design phases used a judge-panel (N angled proposals →
1 synthesis). Read-only investigations returned MD bodies I wrote to disk.

**Gotcha — advisory `blockers` ≠ "red".** My workflow guards logged
"phase blocked/red" whenever a fix/impl agent returned a non-empty
`blockers[]` — but agents routinely put *advisory* notes there ("VM-only
verification deferred", "not a code blocker"). This misfired 3×. Gate the
decision on `build_clean && host_tests_pass`; treat `blockers[]` as
informational unless an entry literally says the code is broken. (Fixing
the guard semantics is a TODO if these scripts are reused.)

**Gotcha — `git merge` loop in zsh.** `for n in $order; do ...` does NOT
word-split an unquoted scalar in zsh (unlike bash) — the whole string
arrives as one token and every merge fails with "not something we can
merge". Use a real array: `order=(33 34 35 …)` (or `${=order}`). Cost me
one failed loop.

**Gotcha — triage's "file-disjoint" guarantee is not guaranteed.** Two
audit groups independently edited `GitClient.swift` (survived only because
hunks didn't overlap → git auto-combined). ALWAYS run the collision check
before the merge loop:
`for b in <branches>; do git diff --name-only main..$b; done | sort | uniq -d`.
See also the worktree-leak lesson above — fix agents leak into the main
tree and sweep unrelated files via broad `git add`.

**Technique — resume-to-extend a running workflow.** To add agents
mid-run: `TaskStop <task>` → edit the persisted script (the tool prints
its path) to add to the `parallel(...)` array → re-invoke
`Workflow({scriptPath, resumeFromRunId})`. Completed agents return cached
(matched by prompt+opts); new agents run live; dependent phases (verify,
synthesis) re-run because their prompt changed. Used to add the
IntelliJ + general-exploration research agents without losing the 5
already done. Web-research agents need `agentType: 'general-purpose'`
(for WebSearch/WebFetch).

**Technique — two workflows concurrently is fine.** The 47-agent audit
(CPU-bound build/test) and the 9-agent web research (I/O-bound) ran
together without much contention. Each Workflow has its own concurrency
cap (~min(16, cores-2)).

**Gotcha — don't gate a TORN tree (2026-06-05 perf wave).** A worktree
mid-run is a moving target: sequential edit-only agents write
incrementally, so `git diff`/`git status` taken before the workflow's
completion notification can show only a *prefix* of the final change. The
perf wave bit this — I inspected `mdv-perf` (4 files, `filter.rs` +120, no
`wire.rs`), ran all three gates on that snapshot, then `git add -A`
committed a tree that had since grown (`wire.rs` +109, `filter.rs` +250
after two more agents finished). The gate never saw the committed code; I
only noticed because the `git merge --ff-only` diff-stat listed `wire.rs`.
**Rule: gate the COMMITTED commit, not a live worktree snapshot.** Either
wait for the `<task-notification … completed>` before gating, or — safest —
commit first and re-run the full gate against that exact tree. Re-gating a
committed artifact is cheap insurance; a half-gated commit on `main` is not.

**Scale note.** The audit was ~6.5M output tokens. Justified for a real
pre-launch audit; do NOT reach for a 47-agent fan-out for routine work.

**Process debt this created — BRANCH SOUP.** Running many fix-workflows
produced **6+ feature branches off `main`, none merged** (see
`HANDOFF_2026-05-30.md` §0). Consolidation is owed and is itself a careful
job (several branches overlap on `DocumentModel`/`ContentView`). Lesson:
when running back-to-back fix-workflows, either merge to `main` between
runs (when verified) or accept that a consolidation/merge-ordering pass is
deferred — and write it down so it isn't lost.

## Branch consolidation merge campaign (2026-05-31)

The deferred consolidation was executed: `main` fast-forwarded to
`audit/pre-launch` (141 audit fixes + docs), then 4 feature branches were
squash-merged in (image-scroll-zoom, media-preview-bugs, multi-repo-git,
session-ui). Hard-won knowledge:

**Squash-merge, not per-commit rebase, for divergent branches.** Each landed
via `git merge --squash <branch>` → resolve conflicts ONCE against the final
tree → one clean commit → linear trunk. Per-commit rebase re-conflicts at
every commit. (Matches the git-workflow "squash recommended" rule.)

**`swift build` does NOT compile tests** — a merge can be build-green yet
test-compile-broken. After any merge that removes/renames API, run
`swift test --filter <target>`. Two hits this session: (a) `SidebarModelTests`
had git tests OUTSIDE the conflict region — the branch's own test-removal
only knew its own tests, not ones `main` added after the branch forked →
surfaced as `error: fatalError` at test-compile, not in `swift build`;
(b) `TextFileLoaderTests` had a stale `0xC3 0x28 → .isoLatin1` expectation
that `main`'s audited CP1252-before-Latin1 ladder (I18N-01) decodes as CP1252.

**Cascading conflicts — merge ORDER matters.** Landing `integration/session-ui`
first (it rewrote `main.swift`'s rails/sessions region) ballooned
`feat/unified-search-panel`'s `main.swift` conflict to ~305 lines. Sequence
overlapping-file branches cheapest-first, or accept the later one grows.

**Key reconciliation decisions (so a future reader doesn't "fix" them back):**
- `GitClient`: `run()` delegates to `runResult()`; ONE
  `ProcessRunner.run(p, timeout: statusTimeout, limits:, maxOutputBytes: 512MiB)`
  carries BOTH the audit's SCALE-2 byte-cap AND the multi-repo wall-clock
  timeout. Kept `Self.resolvedGitBinary` (the branch had regressed to a
  hardcoded `/usr/bin/git`).
- `SidebarModel`: git status was DELIBERATELY moved OUT into the registry
  (`TrackedReposChannel`/`Store`/`RepoFocusTracker`). The old SidebarModel git
  API (`gitStatus`/`gitStatuses`/`gitRepoRoot`/`gitRootOverride`/
  `refreshGitStatus`/`fnv1a`) is GONE; the SCALE-3 string-keyed optimization is
  moot (git no longer lives there). Views read git via
  `model.trackedRepos.status(for:)` / `.trackedRoots`. Kept integration's new
  `claudeHasTranscripts` flag; dropped the resurrected `gitRootOverride`.
- `TextFileLoader`: kept `main`'s `TextDecoder.decode -> Decoded` ladder
  (shared with CrossFileSearch); took integration's two-tier cap
  (`readableMaxBytes` 512 MiB hard / `softWarnBytes` 64 MiB watermark) +
  back-compat `maxBytes` alias; `isLargeReadOnly` grafted onto the `.text`
  TextFile construction.
- `DocumentModel.displayedText`: large-file short-circuit
  (`if file.isLargeReadOnly { return raw DisplayedText }`, skip the O(N)
  formatter) grafted onto `main`'s `DisplayedText`-returning API.
- `SidebarView`/`ContentView`/`ShoulderRailView`: panel-presence `hasRepo` now
  reads `model.trackedRepos.trackedRoots.isEmpty == false` (was the removed
  `sidebar.gitRepoRoot`). Both `trackedRepos` (registry) + `panelLayout`
  (rails) observed directly.

**Still VM-unverified** (build + host-unit verified only): multi-repo git
badges/picker, session-ui rails/large-file-render/view-mode-picker. See BACKLOG.


## Session 2026-06-02 — perf cascade, the live-app test gap, profiling tooling
(Full detail: `docs/HANDOFF_2026-06-02.md` §6.)
- **SwiftUI OVER-OBSERVATION is the dominant perf trap here.** A view holding `@ObservedObject var model: DocumentModel` re-bodies on EVERY model republish; `sourceScrollState`/`sourceSelection` fire per scroll-tick/caret → the always-on-screen `SidebarView` re-bodied on every interaction (caret = 13 ms / 249× baseline). Fix = narrow-channel ObservableObjects (`SourceViewChannel`, like `FindCoordinator`/`PanelLayoutStore`). When "laggy on every interaction," suspect over-broad observation first.
- **Never do filesystem I/O in a SwiftUI `body` getter** — `GitClient.discoverRoot` walked ~64 `fileExists` toward `/` per sidebar pass. Cache it; recompute only on the triggering event.
- **TEST GAP that shipped a broken build** (`fd11e61` couldn't load files live): the headless gate (T1/T1m/T2') never launches the app to open a file (that's T4 `LiveAppTestCase`, self-skips on host, VM-only, VM not run) AND `build-app.sh` runs ZERO tests before install. Fix in flight = a host-runnable live-app smoke (open each file type + cycle every view mode + assert content) wired into `build-app.sh` as a PRE-INSTALL gate. **A green headless gate does NOT mean the live app works.**
- **"IOSurface 70 MB" was a transient compositing peak, not a leak/the cost** — re-measure showed base 36 MB / 2-source 84 MB. Corroborate a single heap-dump moment before acting on it.
- **A layout-driving GeometryReader that writes `@State` it then re-reads = a per-frame layout-pass MULTIPLIER** (live-only; a one-pass headless harness can't see it). Use a non-layout `.background(GeometryReader)` + epsilon-guard the `@State` height writes.
- **Editor was broken by a CM6 `WidgetType` bootstrap `ReferenceError`** (`codemirror.html` missing it from the `window.CM` destructure) — latent since CM6 Phase 4; one-line fix.
- **Recurring hazard:** `Workflow` `isolation:'worktree'` agents leak their named branch into the MAIN checkout + land the real work on a sibling superset branch (`X-work`/`worktree-<runid>`). Harvest the superset (`git log main..<branch>`), ff `main`, `git switch main` in the checkout, reap extra worktrees + delete leaked branches.
- **Native profiling cheat-sheet:** `footprint` / `vmmap --summary` / `heap <pid>` / `sample`→`scripts/lib/sample_flamegraph.py`. Tools: `scripts/{mem-profile,heap-dump,flamegraph}.sh` + `Tests/ViewerUITests/InteractionProfileHarness.swift` (`MDV_PROFILE=1`). `mem-profile` skill at `.claude/skills/` (gitignored, local-only).

## Session 2026-06-03 — Giga UAT, workflow recovery, repo reconciliation

**1. Workflow/agent self-reports lie — reconcile against git/disk ground truth.**
The Giga UAT's report claimed "0 fixes landed on main" (git showed **2** real
commits) and "32 fixed, staged on branches" (in fact **~27 were UNCOMMITTED in
their worktree dirs**, not committed to branches). Never act on a workflow
agent's summary for landing/reaping — check `git log main..`, `git status` per
worktree, and tree-diffs yourself first.

**2. A schema-bound `agent()` awaited *bare* aborts the whole workflow.**
A heavy live-app subagent that ends without calling `StructuredOutput` (after 2
nudges) throws; a bare `await agent(...)` in a loop propagates that into a total
run failure (lost ~90 min / 37 agents once). Fix pattern: wrap each schema
agent in `try/catch` (record a sentinel + continue), and in the prompt mandate
"your LAST action MUST be StructuredOutput, even for empty results" + a scope
guard ("compile the suite ONCE; run a representative subset rather than
exhausting context"). The hardened resume then completed.

**3. The pre-install smoke RUNNER must compile in DEBUG, never `-c $CONFIG`.**
`build-app.sh`'s gate ran `swift test -c release`, but the test target is
**uncompilable in release**: `#if DEBUG` test-support hooks (e.g.
`TreeSitterEngine._jsonLanguagePointerForTesting`) vanish, and `GrammarLoaderTests`
references them unguarded. The runner only spawns the *already-release-built*
`dist/` app as an external process, so its own optimization level is irrelevant.
Run it debug. (Fixed: 798b7ee.)

**4. Multi-agent fix fleets leave fixes UNCOMMITTED in worktree dirs + tangle one
shared stash stack.** 33 fixer worktrees (= 55 GB) shared a single object DB →
cross-worktree `git stash` mis-pops left `RECOVERED-*-belongs-to-sibling`
entries, and most fixes sat uncommitted in the worktree (not on the branch).
Harvest procedure: `git add -A && commit` each worktree to its branch FIRST
(verify `commits>0, dirty=0`), THEN `git worktree remove`. `remove --force` can
fail on a transient lock yet `prune` still clears the admin record — leaving an
orphaned dir to `rm -rf` (safe once committed).

**5. Before any mass branch/worktree cleanup: bundle EVERYTHING first.**
`git bundle create bk.bundle --all` (capture stashes as temp `zzstash/N`
branches beforehand so they're included), then `git bundle verify`. One file =
total recoverability → every subsequent delete is zero-risk. Restore via
`git fetch bk.bundle 'refs/heads/*:refs/heads/restored/*'`.

**6. `ahead=N` (rev-list main..branch), not tree-diff, is the merged signal.**
Once main moves far ahead, *every* stale branch's tree differs from main (pure
noise). Only `ahead>0` branches carry unique commits — and even those are
usually superseded (pre-rename test files, refactored-away `GitService`/
`WorkspaceStore`, throwaway `poc/` dirs, old dated docs). Confirm with
`comm -23 <(git ls-tree -r --name-only $b|sort) <(git ls-tree -r --name-only main|sort)`
to see files-unique-to-branch before deciding land-vs-delete.

**7. `swift test … | tail -N` HIDES the gate verdict — a heavy-tier sentinel red
read as green for 13 commits.** The Giga UAT commit `98ded71` added a T4 scenario
(`PMA06`) that drives `PluginSubprocessHost` *directly* — so it calls neither
`skipIfNotBuilt()` nor `runScenarios()` (the two skip paths) and runs its body in
the headless gate, tripping `TierGateObserver`. The 3394-test SUITE was always
green; only the **tier-policy sentinel** failed — and `MDV_HEADLESS_GATE=1 swift
test | tail -60` clips the `HEADLESS GATE FAILED` banner (it prints AFTER the last
per-test line), so every per-item "gate-green" check on top of it missed it.
Lessons: (a) trust the gate's **own exit code**, not piped/tailed stdout —
`bash scripts/test-headless-gate.sh; echo $?` or grep for `HEADLESS GATE FAILED`;
(b) any new T4 test that bypasses `runScenarios()` needs an explicit
`try skipIfNotBuilt()` or it silently runs in the gate; (c) the suite passing ≠
the gate passing — the sentinel is a separate signal. (Fixed: PMA06 guard added.)

## Session 2026-06-04 — Rust-core migration, three front-ends, security audit

Big session: drove the Rust-core migration deep, built two new front-ends, ran a
516-agent audit. Durable learnings:

### The Type-1 stateless FFI slice — the repeatable migration template
Every pure ViewerCore unit ported to Rust this session (diff parse + gutter
marks, hex render, hex search, indent detect) followed ONE shape, and it's the
template for the rest:
1. **core fn** in `rust-core/crates/core/src/<slice>.rs` — pure, sans-IO, faithful
   port; `cargo test` parity cases incl. the hazards (UTF-16/astral, CRLF, OOB).
2. **wire seam** (when the result is structured): a `*_wire(frame) -> frame` fn
   using `wire::{decode_frame, encode_frame}` (u32-LE prefix + rmp `to_vec_named`).
3. **FFI shim** in `crates/ffi` — mirror `mdvcore_cm_apply`: `ffi_guard!`, out-`MdvBuf`,
   `MdvStatus`. cbindgen regenerates the header on `scripts/build-rust-core.sh`.
4. **Swift bridge** in `RustCore/CoreClient.swift` — build the request via the
   hand-rolled `MsgPackValue` encoder, call, decode via `MsgPackReader`.
5. **ViewerCore adapter** behind `RustCoreFallback.run(.<cap>, rust:, swift:)` —
   default-OFF gate, falls back to Swift on any bridge fault. Never delete the
   Swift path until the slice has soaked ON.
6. **A/B parity test** in `RustCoreTests` (imports RustCore + ViewerCore): force
   the rust path, assert byte-equal to the Swift incumbent over a hazard corpus.

**Wire vs raw-bytes-out:** structured results (diff files, search offsets) ride a
MessagePack frame. But a BIG single string (hex dump: 4 MB file → ~18 MB text)
goes back as **raw UTF-8 in the MdvBuf**, not a frame — wrapping+re-decoding it
would double the cost for nothing. Inputs that are large (hex bytes) cross as a
raw pointer+len (like `mdvcore_session_open`), not embedded in a frame.

### A configured lint that nothing runs is NOT enforced
The workspace `[workspace.lints]` *denied* `indexing_slicing`/`panic`/`unwrap_used`
(the sans-panic core policy) — but CI only ran `cargo build` on the core, never
`cargo clippy` or `cargo test`. So the denies were **dead letters**: two
`indexing_slicing` panic sites shipped in `cm_edit.rs` (`0cead3c`) and the 80+
pure cargo tests never gated a merge. Fix: `scripts/rust-core-gate.sh` (clippy
deny-enforce + cargo test) wired into `pr.yml`. **Lesson:** verify the lint/test
config is actually *invoked* by a gate, not just present in the manifest.

### "One core, three front-ends" + structural parity
`mdvcore-core` now backs the SwiftUI app (FFI), a ratatui TUI (`crates/tui`,
`mdv-tui`), and a std-only HTTP web server (`crates/web`, `mdv-web`). The
front-ends were kept at parity MANUALLY at first, then made parity STRUCTURAL via
`core::view` — a render-agnostic view-model (`build(bytes,name,mode) -> {Text|Hex|
Table} + indent + modes`). Both front-ends are thin renderers over it, so they
can't drift. **`default-members = ["crates/core","crates/ffi"]`** in the workspace
keeps the front-end bins (ratatui/crossterm dep tree) OUT of the merge gate and
the macOS app's 16 MB exec budget — they build only via `cargo run -p`.
**Headless validation patterns that work with no GUI:** ratatui `TestBackend`
(render a frame to an in-memory buffer + substring-assert) and a `--snapshot`
flag that prints one rendered frame; for the web server, pure render-fn unit
tests + a `127.0.0.1:0` socket round-trip + a `curl` smoke.

### Grapheme (Swift) vs scalar (Rust) index domains — a porting hazard
Swift `String` indexes **grapheme clusters** (`Array(Character)`); Rust `str`
iterates **Unicode scalars** (`char`). Any code whose OUTPUT is character indices
into the string (e.g. `FuzzyMatcher.matchedIndices`, used to bold matched glyphs)
will DIVERGE between Swift and Rust on combining-mark / ZWJ-emoji input — and
Rust std has no grapheme segmentation (needs the `unicode-segmentation` crate).
**Lesson:** don't port index-emitting string code claiming byte-exact parity
without a grapheme dep; for ASCII/single-scalar inputs it matches, but the A/B
test can't honestly cover the hazard. (FuzzyMatcher #6 was deferred for this.)

### Filesystem-containment security patterns (from the audit)
- **Anchor temp-dir prefix checks.** `FileManager.temporaryDirectory.path` is
  `/var/folders/<rand>/T` with **no trailing slash**. A bare `path.hasPrefix(temp)`
  therefore admits a user-writable SIBLING like `/var/folders/<rand>/T-attacker/`,
  escaping the jail. Always `== temp || hasPrefix(temp + "/")`. (Bit BOTH
  `URLSchemePolicy` and `MCPToolCatalog` — the same flaw, drift between two
  copies of a boundary; factor a shared `isContained(_:in:)`.)
- **Check containment BEFORE existence.** Throwing `notFound` before
  `permissionDenied` leaks an existence oracle for out-of-jail paths.
- **Binding 127.0.0.1 does NOT make a local HTTP server safe.** A browser the
  user is already running can **DNS-rebind** an attacker hostname to 127.0.0.1
  and issue same-origin requests. A loopback file-browser needs: a **Host-header
  allowlist** (refuse any Host that isn't localhost/127.0.0.1 — browsers always
  send Host, so a foreign one is the attack), reject non-GET, and a real
  **path jail** (canonicalize + `starts_with(root)` on every served path).
  `mdv-web` shipped with all three missing → arbitrary file read; fixed `c0bc6dc`.

### Redaction must sit in front of the *surfacing* path, not just the detail view
`ClaudeLogParser.parse` does NOT redact. The monitor's transcript detail redacts
manually before display, but `ClaudeTranscriptSearch` matched + snippeted RAW
events — so its (planned) use in the monitor would have leaked `signature`/
`headers`/image-blob content the detail view hides. Added `parseRedacted` /
`redactedEvents(from:)` and routed search through them. **Lesson:** put the
redaction barrier on EVERY consumer that surfaces content, not just the obvious
one; a shared "redacted events" entry point prevents the gap.

### Parallel test fixtures keyed only by PID race each other
Temp fixtures named `…-{process::id()}` are shared by ALL tests in the binary;
parallel tests then `remove_dir_all` each other's dir mid-run → flaky failures
that look like logic bugs. Key by **pid + an `AtomicU64` counter** so each call
is unique. (Bit both the tui and web test fixtures.)

### Multi-agent audit (deep-audit) + the spend ceiling
The `deep-audit` workflow (`.claude/workflows/deep-audit.js`) — subsystem ×
dimension reviewers → adversarial perspective-diverse verification (default-refute,
majority-confirm) → completeness critic → ranked report — found 80 verified
findings incl. a real S1 in code written the same session. The adversarial-verify
stage is what makes the output high-signal (it kills the false positives that
plague mega-reviews). **Operational fact:** one `deep` run = ~516 agents / ~26M
subagent tokens and **tripped the account monthly spend limit**. Large fan-out
workflows are not free — gate them; solo work continues fine.

### Trust fresh state over the tracker docs
`AUTONOMOUS_PROGRESS.md` said the agent-monitor PoC "UI not built" — it had been
built (a 460-line view) in a prior session and the doc was stale. Checking the
actual files first (per the "fetch fresh state" rule) avoided rebuilding it.
**Lesson:** when a tracker/doc claims something is missing, verify against the
code before acting — docs drift, code is ground truth.

## Session 2026-06-05 PM — in-file find (TUI+web), SwiftUI polish, branch reconciliation

### "One core, three front-ends" pays off twice: build the primitive once, wire each tier
In-file find (TSK-197 TUI + TSK-198 web) shipped from a single new `core::find` module
(`find_matches(text,query,Case)` + `first_from`/`next_index`/`prev_index`, 17 tests). The TUI
got a `/` overlay with n/N nav; the web got `?find=&fmatch=` — each front-end wiring was small
because the matching logic + cursor math lived in the tested core. **Lesson:** when a feature is
"port the same behavior to TUI + web", write/extend a `mdvcore_core` primitive with exhaustive
unit tests first, then the front-ends are thin shells. Validate with `cargo test --workspace`
(TUI/web are OUT of `default-members`; the `rust-core-gate` only covers core+ffi).

### Swift: adding a defaulted parameter to a public fn breaks stale callers at LINK time
Adding `isRenderableText: Bool? = nil` to `ViewModeOptions.availableModes` is source-compatible,
but it changes the function's MANGLED symbol. SwiftPM's incremental compiler did NOT recompile
caller files that omit the new arg, so their cached `.o` referenced the old symbol → "Undefined
symbols … availableModes(for:forcedCategory:)" at link, even after a full `swift build`/gate run.
**Fix:** `grep -rl "availableModes(" Sources Tests | xargs touch` to force-recompile callers (or
a clean build). **Lesson:** after adding a defaulted param to a widely-called public func, touch
its callers — don't trust incremental to invalidate them.

### Web text-highlight: reuse the line-anchor machinery, don't inject marks mid-line
The web tier escapes every content byte through `esc()`. To "highlight find matches" the naive
path is wrapping matched byte-ranges in `<mark>` inside the escaped line — fiddly + an injection
risk. Instead the find steered the EXISTING go-to-line machinery: set the current match's line as
the `gutter_html` `target`, which already emits `id="L<n>"` + a `.cur` highlight and a `#L<n>`
fragment the browser scrolls to. **Zero escaping surgery, correct by construction.** **Lesson:**
before adding HTML-generation, check whether an existing anchored/targeted render path already
does what you need with a different input.

### The ratatui TUI is headless-testable — use `render(app)` + `on_key`
`App::snapshot(w,h)` renders one frame to an in-memory `TestBackend` string; tests drive
`app.on_key(KeyCode::…)` then assert on the rendered text + `app` state. This gave real coverage
for the `/` find overlay (open → type → ↵ → n/N → Esc) with no terminal. **Lesson:** TUI features
are NOT "live only" — assert behavior through the snapshot harness.

### `App.status` (TUI) is write-only — surface state in the help bar instead
The TUI `App.status` field is set in ~10 places (`opened X`, `no matches`, prompt hints) but
NEVER rendered. The find feature put its `i of n` count in the bottom help-bar branch instead.
**Lesson / latent task:** wiring `App.status` into the status line would make all those messages
visible (overlaps the [PORT][TUI] status-bar task).

### View-mode resolution is URL-only and regression-prone (still)
`ViewModeOptions.{defaultMode,availableModes}` resolve purely from the URL/extension; the LOADED
state (e.g. an unknown-extension file the loader decoded as text) is never fed back, so such a
file opens HEX-only. TSK-332's pure layer (an additive `isRenderableText` hint on BOTH functions,
kept in lockstep so a hinted `.source` default is always in `availableModes`) is done + tested,
but the loader→picker threading is deferred: it lands in the carry-mode/picker-desync zone that
produced #212/#217/#219 (all LIVE-only bugs). **Lesson:** changes to view-mode resolution need a
live smoke (`build-app.sh debug` → ViewModeMatrix T4), not just the headless gate.

### Reconciling stale scratch branches: grep each piece against main before merging
Two `worktree-wf_*` branches were **163 commits behind** main. Naively merging would have
re-introduced a competing design (one re-broadened a `setCurrentViewMode` guard that main had
deliberately scoped narrow) and conflicted on already-landed code (the other's `wireLifecycle`
was already on main). **Lesson:** for a branch far behind main, `git diff branch...main` per file
+ `grep` each key symbol in main to classify every hunk as already-landed / superseded /
genuinely-missing; salvage only the genuinely-missing, non-contradictory pieces (here: one
`SessionStore` env-override). Don't blanket-merge or blanket-drop.

### Board reconciliation is real work: verify-and-close already-done tasks with evidence
~8 `[PORT][W1]` board tasks (line-number gutter, sort modes, hidden toggle, go-to-line) were
fully implemented in code but left `reported`. Closing them to `fixed` with file-cited evidence
(the TSK-402 reconcile chore) is legitimate Validation-lane progress, no code change. **Lesson:**
before building a "missing" feature, grep the code — it may already exist and just need closing.

## Session 2026-06-05 (later) — .tsx grammar (TSK-195) + a buried highlighter bug

### `.tsx` already had everything but the wiring — and the tsx grammar ships in the TS dylib
`tree-sitter-typescript` exports BOTH `tree_sitter_typescript` and `tree_sitter_tsx` from one
package/product. The lazy wrapper (`TreeSitterLazyWrappers/TreeSitterTypeScriptLazy/wrapper.c`)
already kept a `tree_sitter_tsx` keepalive and the `TreeSitterTypeScript_TreeSitterTSX.bundle`
already shipped in `dist/`. So TSK-195 was *pure wiring*, no new dependency / dylib / product:
add `HighlightLanguage.tsx` + `GrammarLoader.Grammar.tsx` (cSymbol `tree_sitter_tsx`,
**dylibBasename = the SAME `libTreeSitterTypeScriptLazy`** — both grammars live in one dylib),
route `.tsx` extension → `.tsx`, reuse the TS highlights/folds queries (every TS node type exists
in the superset TSX grammar). **Lesson:** before treating "add a grammar" as a heavy dep task,
check whether the grammar's C symbol is already exported by an existing dylib (`nm -gU`).

### THE engine doesn't evaluate tree-sitter query predicates — identifiers mis-color (TSK-410)
Landing `.tsx` surfaced a real, broad bug. `TreeSitterEngine.tokenize` iterates
`bundle.query.execute(...)` matches directly and **never evaluates `#match?` / `#eq?` /
`#is-not?` predicates**. So predicate-gated captures fire unconditionally. Concrete repro:
`tokenize("const myThing = 5;", language: .typescript)` → `myThing` is `.type` (purple), because
`((identifier) @type (#match? @type "^[A-Z]"))` fires for the lowercase name and `@type` is the
last-emitted capture. **Resolution model:** `paintOver` = *last input index wins*; the cursor
yields matches ordered by the pattern root node's start byte (a `jsx_opening_element`-rooted
`@tag` capture emits BEFORE the inner identifier's captures, so it LOSES). That's why a dedicated
tsx-highlights `@tag`/`@attribute` query did NOT win — so I dropped it and `.tsx` reuses
`typescript-highlights`; the grammar swap alone is the real fix (JSX now parses instead of
ERROR-polluting the tree). **Filed TSK-410** (predicate eval). It's risky to fix headless-only:
changes highlighting across all languages, and `#is-not? local` needs a locals query the engine
lacks — so it needs a live source-view smoke, not just the headless gate. **Lesson:** the
syntax highlighter is predicate-blind; capture file-order + last-wins is the *only* disambiguator
today. Tuning a query = ordering captures so the desired one is emitted last for each node.

### Diagnosing "is the grammar actually being used?" — dump the s-expression, don't infer from colors
When tsx highlighting looked like TypeScript output, the decisive probe was
`Parser().parse(src)?.rootNode?.sExpressionString` for each grammar: typescript → `(ERROR ...
type_arguments ...)`, tsx → `(jsx_element ...)`. That instantly separated "wrong grammar" from
"right grammar, wrong query/precedence" (it was the latter). **Lesson:** for highlighter bugs,
get the parse tree's s-expr first; token *colors* are three layers downstream (grammar → query →
captures → paintOver) and conflate independent failures.

## Session 2026-06-06 — perf Fix#1 (pane retention), tab-strip UX cluster, VM build, the killall footgun

### The test harness was killing the developer's OWN running app (`killall` by shared exec name)
The owner asked, mid-session: *"why would a headless test run kill my running instance of /Applications?"*
Root cause: several test/harness paths called **`killall MarkdownViewer`** to reap a leaked prior
test spawn — but the installed app and the test-spawned app **share the executable name**
`MarkdownViewer`, so `killall` SIGTERMed whatever the user had open. The most frequent trigger was
`scripts/build-app.sh debug` → the pre-install `ViewModeMatrixSmokeTests` T4 gate → `AppLauncher`.
**Fix (committed `ca67005`):** mark every test spawn with `env["MDV_TEST_INSTANCE"] = "1"` and
replace the blanket `killall` with `AppLauncher.killTestInstances(named:)` — it `pgrep -x`'s
candidate PIDs, reads each one's environment via `ps eww -p <pid>`, and SIGTERMs **only** the PIDs
whose env contains the `MDV_TEST_INSTANCE=1` marker. The Finder/LaunchServices-launched app (no
marker) is never touched. **Remaining bare-`killall` sites to migrate the same way** (follow-up):
`SourceViewVisualRegressionTests`, `WalkthroughAndCodeReviewUATTests`, and `LaunchHarness` (~:104).
**Lesson:** never `killall` by a name your shipping app also uses. Tag test-spawned processes and
reap by tag (env marker via `ps eww`), or track the `Process` PID you launched and kill only that.

### The UTM test VM CAN build now (TSK-401) — Swift 6.1.2 is stricter than the host on actor isolation
Stale memory said the VM couldn't build (no Rust toolchain etc.). Reality at this session: the VM
(`macOS15` / `vm-tester`, **Swift 6.1.2**) builds fine once 4 strict-concurrency sites that the host
toolchain waved through were fixed. The host and VM differ on **default-actor-isolation** strictness
("skew"), so code that compiles on the host can fail on the VM. Fix patterns that worked:
- `nonisolated(unsafe) private static let coalesceLock = NSLock()` for a global lock that's logically
  thread-safe but trips isolation inference (`ReviewSession`).
- For a `Task.detached` / `DispatchQueue.main.sync` body that the VM flags as "sending `self`":
  capture **`nonisolated(unsafe) let strongSelf = self`** (NOT `[weak self]` — the weak capture is
  *also* flagged), then run the main-thread body inside **`MainActor.assumeIsolated { strongSelf.… }`**
  / `MainActor.run { strongSelf.… }` (`HexView`). `MainActor.assumeIsolated` **alone** did not clear
  "sending self"; the `nonisolated(unsafe) let` capture is the part that does. Rebinding
  `let self = strongSelf` inside is rejected — use `strongSelf` directly.
**Lesson:** the VM is a *stricter* compiler, not a broken one — treat its errors as real
forward-compatibility signals. Update memory `reference_vm_no_rust_toolchain`: VM builds are no
longer blocked (host still ships the Rust staticlib; VM compiles the Swift tree).

### perf Fix#1: keep inactive tab panes mounted at `opacity:0`, never `.hidden()`
The dominant tab-switch freeze is view-side — switching tabs tore down and reloaded the inactive
pane's `WKWebView`. Fix (TSK-108): retain inactive panes mounted via a `MountedPanesLRU` (cap 4) in a
`ZStack`, the inactive ones at **`.opacity(0)` + `.allowsHitTesting(false)` + `accessibilityHidden`**
— **not** `.hidden()`. `.hidden()` removes the view from the hierarchy enough that WebKit fires a
`visibilitychange` and self-reloads the page (the cmux #1228 pathology), which defeats the whole
retention. Validate the *absence of remount* with a `#if DEBUG` `MountProbe` that counts
`makeNSView`/`dismantleNSView` on the web views: A→B→A must be **0** new mounts; evicting past the LRU
cap is exactly **1** dismantle. **Lesson:** "hide a WebView but keep it alive" = opacity/offscreen,
never `.hidden()`/removal — and assert the no-remount invariant with a make/dismantle probe, because
it regresses silently (you just get the slow path back).

### A flaky parallel headless-gate failure looks like a real failure — re-run before chasing it
`scripts/test-headless-gate.sh` failed once with exit 1, **no assertion text**, and "tier enforcement
OK" — i.e. a test body errored under `--parallel` with no diagnostic. A direct
`swift test --parallel` then exited 0 and the gate re-run passed on the same commit. **Lesson:** a
gate failure with no assertion message + a clean tier-enforcement line is the signature of a flaky
parallel test, not the change under test. Re-run once (and/or a `--filter` of the suspect suite)
before assuming the diff broke something.

### Board-id `TSK-NNN` ≠ audit `#N` (the Claude-TaskList numbers) — they collide and mislead
The `tasked` board's `TSK-401` (the VM-build fix) is a *different* item from Claude-TaskList `#401`
(`[PORT][WEB] Persistent front-end session state`). The two numbering spaces overlap numerically but
are unrelated systems; the Claude TaskList is a stale redundant mirror — the **board is the system of
record**. **Lesson:** always say/track `TSK-` ids for board work; never reconcile a board task against
a same-numbered Claude-TaskList entry. And per the shared-board caveat, grep this repo before acting
on any board task (TSK-101..106 are a *different* project's `agent:forge` tasks).

## Session 2026-06-06 (PM) — session-tab clobber, File→Reset, no-host-UI-tests, VM 6.3 toolchain

### Session tabs vanished = `index.json` clobbered to empty while snapshots survived
Owner's session tabs disappeared. Root cause: `~/Library/Application Support/MarkdownViewer/Sessions/index.json`
was `{"sessions":[]}` next to ~40 intact `<uuid>.json` snapshots — the coordinator persisted an empty
index (the saveSync-races-enqueueSave clobber, #330) and restore read it as "no sessions." **Fixes
(both shipped):** (1) `SessionStore` now REFUSES to persist an empty index while `liveSnapshotIDs()` is
non-empty (a genuinely-closed session has its snapshot `moveToTrash`'d first, so an empty index is only
legit when no snapshots remain); (2) `SessionsCoordinator.restore()` self-heals — empty/absent/corrupt
index + substantial live snapshots (root exists + ≥1 open tab, deduped by root) → rebuild the index from
them. **Lesson:** treat a derived index as reconstructible from its source-of-truth files; guard against
writing an empty aggregate over surviving members, and self-heal on read. Persisted state lives under
`Application Support/MarkdownViewer/` (NO bundle-id prefix); the bundle-id dir holds Plugins/Walkthroughs/
jdtls-data only — the CLAUDE.md path was wrong and cost a detour.

### `build-app.sh` writes `dist/` but the user runs `/Applications/` — "rebuild didn't show my change"
A rebuilt feature (File→Reset) "didn't appear" because the running app was `/Applications/TextView.app`
(installed Jun-4) while `build-app.sh debug` only updates `dist/TextView.app`. **Lesson:** after
`build-app.sh`, run `scripts/install-app.sh` (now chainable via the new `build-app.sh … --install` flag)
to push the bundle to `/Applications`. Confirm which bundle is running with
`ps -axo pid,command | grep TextView` + `strings <exe> | grep <new-feature-string>` before assuming a
build is stale.

### Owner directive: NO UI tests on the Mac — UTM only
T4/T5/WebView suites + the `build-app.sh` pre-install ViewModeMatrix smoke all spawn the app / open a
window on the host. Owner forbids that on their machine. **The pre-install smoke is now opt-in
(`MDV_RUN_SMOKE_GATE=1`)** so the default build/install never opens a window. Host validation = `swift
build` + `test-headless-gate.sh` (window-free) only; UI/live validation goes to the UTM VM. See memory
`feedback-no-ui-tests-on-mac`.

### The UTM VM already had a Swift 6.3 toolchain installed — just not selected
The VM's default `swift` is 6.1.2 (Xcode 16.4), which is STRICTER than the host on region-isolation
(`try await super.setUp()` in `@MainActor` test classes = "sending non-Sendable self" → the whole test
target fails to compile, blocking `swift test` entirely — TSK-439). But
`/Library/Developer/Toolchains/` already contained `swift-6.3-RELEASE.xctoolchain` +
`swift-latest.xctoolchain`. **Lesson:** before downloading/installing a toolchain, `ls
/Library/Developer/Toolchains/` — a newer one may already be there; select it with
`TOOLCHAINS=$(plutil -extract CFBundleIdentifier raw <tc>/Info.plist) swift build` (or
`TOOLCHAINS=swift` for swift-latest). **Compiling on the VM is NOT a UI test** — it's allowed under the
no-host-UI-tests rule; only spawning the app/window is forbidden.

### Settings sub-pages: detached NSWindows give no "back" — use a NavigationStack
Settings opened Plugins/LSP as separate `NSWindow`s (only a red close button, no back). Wrapping Settings
in a `NavigationStack` and making those `NavigationLink`s pushes them in-place with a native back button.
Also: an `NSHostingController`-hosted Settings window needs `.resizable` in its `styleMask` AND a flexible
`.frame(min/ideal/max…)` (not a hard fixed frame) or content clips with no way to grow.

### Sidebar tool-window resize model (root cause for the "can't resize / non-uniform" reports)
FILES is a SPECIAL flex-fill panel (tier 1, `maxHeight:.infinity`) ABOVE the accordion (tier 2). Accordion
tool-windows have ABSOLUTE `@AppStorage` heights; `SidebarSectionPlanner` draws a divider only BETWEEN
adjacent visible tool-windows (none below the last, none between FILES and the first); each
`ResizableSectionDivider` resizes only the panel ABOVE it (FILES absorbs slack). So: 1 tool-window → 0
dividers (can't drag); 2 → divider only between the two tools, above-only resize (erratic); lone FILES can
leave a gap. **A "uniform/proportional resize incl. FILES" rework (TSK-440) is a layout-model change in a
regression-prone zone (#100/#133/#211/#215/ChromeLayoutGate) — needs the live/VM verify loop, not a blind
edit.**

## Session 2026-06-06 (later) — terminal Enter, iCloud build-detritus race, VM live lane

### Embedded terminal: Return is eaten as a key-equivalent BEFORE keyDown (TSK-448)
Owner: "Terminal — I can't press enter or execute commands" (typing echoed fine, only Enter was dead). A
custom input `NSView` (the terminal grid) handles Return in `keyDown` (keyCode 36/76 → CR `0x0D`), and that
code was correct — but **Return never reached `keyDown`**. AppKit dispatches Return through the window
**key-equivalent / default-button** path FIRST (`performKeyEquivalent` walks the tree, then the window's
default button cell). SwiftUI installs a window default button whenever ANY `.keyboardShortcut(.defaultAction)`
/ `.return` button exists in the chrome — so Return fired that button and the terminal's `keyDown` was never
called. Plain letters aren't key-equivalents, so they skip that path and hit `keyDown` directly → "typing works
but Enter doesn't" is the exact signature. **Fix (`c3a7b83`):** override `performKeyEquivalent(with:)` on the
terminal view to claim Return/keypad-Enter (keyCode 36/76) **only while `window?.firstResponder === self`** and
**only when `.command` is absent** (so ⌘C/⌘V/menu shortcuts still resolve), routing them back through the
existing `keyDown`. **Lesson:** for any embedded AppKit view that must receive Return/Tab/Esc (terminals, custom
editors), `keyDown` alone is insufficient — those keys are claimed by the default-button/focus machinery first;
intercept them in `performKeyEquivalent` gated on first-responder. This is **live-only** (no headless test can
synthesize the window default-button race); verify by relaunching the installed app or on the VM.

### `build-app.sh` codesign intermittently fails on iCloud xattr re-stamping (TSK-449)
`build-app.sh` failed at `codesign --options runtime` with "resource fork, Finder information, or similar
detritus not allowed" — but had succeeded twice minutes earlier with the SAME code. Root cause: the repo lives
under `~/Documents`, which is **iCloud-synced**, and the iCloud **file provider re-stamps** `com.apple.FinderInfo`
+ `com.apple.fileprovider.fpfs#P` onto the TreeSitter resource bundles *in real time*. `build-app.sh` does
`ditto --noextattr` + `xattr -dr com.apple.FinderInfo` before signing, but iCloud re-adds the xattrs in the
window between the clean and the sign — a **race** the build usually wins but sometimes loses. **Deterministic
workaround (used to ship c3a7b83):** `ditto --norsrc --noextattr --noacl --noqtn dist/TextView.app
/tmp/X.app` → `xattr -cr /tmp/X.app` → `codesign --force --deep --sign 'MarkdownViewer Local Dev'
--options runtime --timestamp=none /tmp/X.app` → `codesign --verify --deep --strict` → `ditto /tmp/X.app
/Applications/TextView.app`. `/private/tmp` and `/Applications` are NOT file-provider-synced, so xattrs aren't
re-stamped there and the signature holds. **Proper fix (filed):** make `build-app.sh` do its clean+sign step in
a `TMPDIR` outside iCloud, then move the signed bundle into `dist/`. **Lesson:** a codesign "detritus" failure
that is *intermittent* on an unchanged tree = something is re-adding xattrs out of band; on an iCloud/Dropbox-
synced working copy that's the file provider. Sign outside the synced tree.

## Session 2026-06-06 (evening) — owner UI-bug batch (terminal Enter real cause, killall, Settings back, palette hover, status bar)

### An app-wide `NSEvent` local key monitor pre-empts BOTH the responder chain AND performKeyEquivalent
Owner: "Terminal — Enter does nothing; the file nav is eating the keystroke" (typing echoed, only Return dead).
The terminal's `keyDown`/`performKeyEquivalent` were correct — but `SidebarKeyMonitor` installs
`NSEvent.addLocalMonitorForEvents(matching: .keyDown)` that consumes Return/arrows app-wide and only yielded
when `NSApp.keyWindow?.firstResponder is NSText`. The terminal is a custom `NSView` (not `NSText`), so the
monitor swallowed Return and returned `nil` (consumed) BEFORE it reached the terminal — a local monitor runs
ahead of key-equivalent + responder dispatch entirely. **Fix (`8b8a547`):** a `SidebarKeyMonitorExempt` marker
protocol; the monitor yields to any first responder conforming to it; `TerminalNSView` conforms. **Lesson:**
when a custom focusable NSView "doesn't get keys," look for app-wide local `NSEvent` monitors FIRST (they win
over the responder chain). Two layers had to be fixed for the terminal: the monitor (this) AND
`performKeyEquivalent` for the window default-button (`c3a7b83`) — both pre-empt `keyDown` for Return.

### `killall MarkdownViewer` in install-app.sh killed the owner's running app on every `--install`
The owner's `/Applications` app "kept getting closed." `scripts/install-app.sh` ran `killall MarkdownViewer`
before copying — and the installed app + freshly-built bundle share the exec name `MarkdownViewer`, so every
`build-app.sh --install` (which the autonomous loop runs) SIGTERMed the owner's running app. Same killall-footgun
class as the earlier `AppLauncher` fix; install-app.sh was the remaining LIVE site on the normal dev loop. **Fix
(`e5ffa08`):** removed it — macOS replaces a running `.app` fine (live process holds the old inode; new code on
next manual relaunch). **Lesson:** NEVER `killall <shipping-exec-name>` in any script/test; when the owner says
"something keeps closing my app," grep `killall` across scripts/ + Tests/ first. The headless gate never killed
it (heavy tiers self-skip) — only the install path did.

### macOS `NavigationStack` back chevron needs a window toolbar — a hosted Settings window has none
Settings → Plugins/LSP pushed via `NavigationStack`+`NavigationLink` but showed NO back button (user stuck): on
macOS the automatic chevron renders in the window TOOLBAR, and the `NSHostingController`-hosted Settings window
has none. **Fix (`e3cd4a2`):** wrap sub-pages in a `SettingsSubPage` with an explicit "‹ Settings" Button
calling `@Environment(\.dismiss)`. **Lesson:** don't rely on NavigationStack's auto back button in a
toolbar-less hosted window — provide an explicit dismiss control.

### SwiftUI list "scrolls on mouse-over": hover-set selection + scroll-on-selection-change
Command palette re-centered as the pointer moved over rows: `onHoverChanged → selectedIndex`, and
`.onChange(of: selectedIndex){ proxy.scrollTo(.center) }` fired for hover too. **Fix (`65b2b32`):** a
`scrollOnSelectionChange` flag set ONLY by keyboard `moveSelection`; the `onChange` scrolls only when set.
Hover still moves selection (Return opens the hovered row) but never scrolls.

### Verifying a "live-only" UI bug headlessly: prove the data source + wiring, isolate the re-render
Owner pushed: "can't you verify [status-bar-on-tab-change] headlessly?" Yes — the bar reads `currentState`/
`currentURL` (computed from `tabs.selected`) + observes `model.tabCoordinator`. Headless test
`test_selectTab_statusBarDataSourceTracksSelectedFile` (`1615b98`) opens 2 files, switches tabs, asserts the
data source tracks the selected file — PASSES. So model+wiring are provably correct; only the SwiftUI re-body
(AttributeGraph) is live-only. The one headless-identifiable blank (selecting a `.empty→.loading` tab →
`currentMetrics` nil) was fixed to show Size + "loading…". **Lesson:** a "live-only" UI bug usually has a
headless-testable data/wiring layer underneath — prove that first + fix any headless-visible cause, narrowing
the live surface to the genuine re-render rather than guessing.

## Session 2026-06-06 (terminal copy/paste/select/color — TSK-456)

- **`TERM=xterm-256color` makes 256/truecolor the DOMINANT colour path, not an edge case.** The terminal
  advertised `xterm-256color` but `TerminalColor` was a flat 16-case enum and the ANSI parser
  *parsed-then-DROPPED* `38;5;n` (256) and `38;2;r;g;b` (truecolor) — so modern tools (ls --color, git,
  starship/p10k prompts, eza, bat) which emit those forms rendered **monochrome** despite "16-colour
  support." Owner's "support color" was really "the dominant colour path is silently discarded." Fix:
  `TerminalColor` → `.default/.ansi(0...15)/.indexed(0...255)/.rgb`; parser applies them; `TerminalPalette`
  resolves the xterm 6×6×6 cube + 24-step greyscale ramp + rgb. Lesson: if you advertise a terminal
  capability via `TERM`, you must actually render it — advertising 256-colour then dropping it is worse
  than advertising `xterm` (16).
- **Keep the named colours as `static let` aliases onto the new associated-value cases** (`.red = .ansi(1)`)
  so every existing call site + test vector (`XCTAssertEqual(..., .brightGreen)`) keeps compiling through an
  enum-shape change. Only the two places that *pattern-matched* named cases (bold→bright promotion;
  palette switch) needed rewriting (`if case let .ansi(n) = base, n < 8`).
- **AppKit selector gotchas when adding Edit-menu actions to a custom NSView:** `selectAll(_:)` IS declared
  on `NSResponder` → needs `override`; `copy(_:)`/`paste(_:)` are NOT → plain `@objc func`;
  `validateMenuItem(_:)` is from `NSMenuItemValidation` (conform to it) and is NOT on NSView → no `override`,
  no `super` call. The app's Edit menu uses nil-target `copy:`/`paste:`/`selectAll:`, so implementing those
  selectors on the focused view wires ⌘C/⌘V/⌘A for free — no `performKeyEquivalent` hijack needed. Ctrl-C
  (SIGINT) is the `.control` chord in `keyDown`, untouched by ⌘C.
- **Pure selection model belongs in ViewerCore.** `TerminalSelection` (anchor/head, ordered, columnRange,
  selectedText, word/line/all) is AppKit-free → 17 headless tests cover geometry + extraction + word/line.
  The NSView only does mouse→cell mapping + drag tracking + the translucent highlight draw. Same
  prove-it-headlessly discipline as the status-bar work.

## Session 2026-06-07 (terminal tabs, CM6 editor features, tasked-MCP migration)

- **CM6 editor props were plumbed-but-never-passed.** `foldingRanges`, `indentGuides`, and an
  insert-at-cursor path were fully built in `CodeMirrorEditorView` + `codemirror.html` (real
  `foldService`/`applySetFoldingRanges`, `IndentGuideWidget`/`applySetIndentGuides`) but the only call
  site (`ContentView.swift:~570`) passed none of them, so the features were dark. LESSON: before
  assuming a feature is unbuilt, grep the **call site** — the view/JS layer may already support it and
  only the wiring is missing. (Folds=TSK-466, indent guides=TSK-487.)
- **`Tab` is NOT `Codable`.** Session persistence serializes a separate `TabSnapshot` DTO
  (`Sources/ViewerCore/Tab.swift` is `Sendable, Identifiable` only). So a new in-memory-only `Tab`
  field (e.g. `isPreview`, TSK-306) is non-persisted *for free* — the snapshot just won't carry it.
  Add it to `Tab`'s custom `Equatable` if a visual depends on it (the SwiftUI tab-strip diffs on it).
- **Terminal scroll reset on tab switch = view-local state + `.id` remount.** `scrollOffset` lived on
  `TerminalNSView`, and `TerminalPaneView` puts `.id(selectedTabID)` on the single representable, so
  AppKit destroys+recreates the NSView every tab switch → offset reset to 0 (broke scrolled-up history
  + felt like it disrupted `top`). Fix (TSK-489): lift per-tab render state onto the per-tab
  `TerminalModel`; the recreated view seeds from it + writes back. GENERAL: any view-local state on a
  `.id`-keyed terminal/editor tab view is lost on switch — store it on the per-tab model.
- **Terminal lacks the alternate-screen buffer** (`TerminalScreen.swift:~22` "out of scope"). Full-
  screen TUIs (`top`/`vim`/`less`) therefore write into the normal grid+scrollback. If `top` renders
  wrong, THIS is the root cause, not scroll — it's a separate parser feature (host-testable w/ golden
  tests). Don't blind-fix it as a "scroll" issue.
- **`tasked` board is now first-class MCP tools** (`mcp__tasked__*`); the old `python3 /tmp/board.py`
  HTTP shim is RETIRED (owner, 2026-06-07). `task_advance{to,understanding,note,summary}` auto-walks
  reported→…→fixed in ONE call. `task_park{kind,question,context}` is the owner-decision gate (pings).
  `task_record` needs `summary` (and `commits` to link SHAs; `task_advance` does NOT take commits).
- **Agent self-validation policy (owner, 2026-06-07):** agents MAY `task_validate` to validated/done,
  but ONLY with a `checks` artifact = an *automated test exercising the actual behaviour*. WebView/
  AppKit-RENDERED behaviour (CM6 pixels, fold gutter, indent guides, caret insert, terminal strip
  placement/scroll) has NO host coverage → cannot self-validate on host; leave at `fixed` for owner/VM
  or add a VM UI test first. Full rule in `CLAUDE.md` (Automated runs SOP).
### Terminal tabs invisible — compositor occlusion + ImageRenderer false-green (TSK-488, 2026-06-07)

The "I see a gap before the terminal but no tabs" report. Took FOUR wrong fixes before the real cause,
because every diagnosis used a tool structurally blind to the actual bug. Full detail so we never burn
this many rounds again.

- **Root cause = opaque layer-backed `NSViewRepresentable` occludes a SwiftUI sibling drawn before it.**
  `TerminalPaneView` is a SwiftUI `HStack`/`VStack` whose siblings are (a) the SwiftUI-drawn tab strip
  (chips) and (b) `terminalSurface`, an `NSViewRepresentable` wrapping the opaque, layer-backed
  `TerminalNSView`. On macOS SwiftUI hosts a representable as a REAL AppKit subview backed by its own
  `CALayer`. That opaque layer composites OVER any SwiftUI sibling **painted before it**, even when the
  two are geometrically adjacent in a stack (NOT overlapping). So it is **paint-order / position
  dependent**: strip drawn BEFORE the surface (`.left`/`.top` — strip is the first child) → surface's
  layer covers the chips → blank rail (the "gap"); strip drawn AFTER (`.right` — strip is the last
  child) → strip wins → visible. That asymmetry is the tell: the owner on the default LEFT saw nothing
  while RIGHT would have worked. Same family as the documented `NSRulerView`-in-`tile()` sibling-blank.
- **FIX:** give each SwiftUI sibling its own compositing layer with an explicit z-order above the
  surface — `strip.compositingGroup().zIndex(1)` vs `terminalSurface.zIndex(0)` — in EVERY layout
  branch, so visibility no longer depends on child order.
  (`Sources/ViewerUI/Terminal/TerminalView.swift`, commit 1dd0483.)
- **Why it survived 4 rounds — the false-green tool matrix.** What each "test" actually sees:
  | Tool | Sees SwiftUI draw? | Sees the opaque AppKit layer? | Verdict for this bug |
  | --- | --- | --- | --- |
  | NSView frame-walk / `DiagnosticDump` | layout only | no paint | useless ("rail has size") |
  | `ImageRenderer` | yes, in ISOLATION | NO — draws a placeholder for the representable | **FALSE GREEN** |
  | `cacheDisplay` | no (SwiftUI CA layers → black) | partial | useless |
  | `screencapture -l<windowID>` (stage ④) | yes | YES — real composite | **the only authority** |
  The four discarded fixes (ScrollView removal, widen rail, accent colour vs muted
  `selectedContentBackgroundColor`, frame-size asserts) were all chasing what those blind tools showed.
- **The guard that works:** `TerminalTabStripVisualRegressionTests` (T5 `PixelTestCase`) — launches the
  app via `MDV_UI_SCENE=terminal-{left,top,right}`, captures the real window with `screencapture`, and
  asserts a dense accent-chip block in the configured rail band. Harness: `scripts/ui-snapshot.sh`.
- **ALWAYS demonstrate teeth on a real-UI test.** A green never shown to go red is not a guard. I
  reverted the fix, rebuilt, confirmed the test FAILS for left+top (passes for right — correct, since
  right was never occluded), then restored. Make this a habit for any T5 pixel test.
- Codified as a preventive rule in `CLAUDE.md` (Testing rules → "Compositor occlusion + the
  ImageRenderer false-green trap").

### Recursive-descent parsers in `mdvcore-core` need an explicit depth cap (TSK-217, 2026-06-07)

Shipped `format::pretty_json` (the JSON Formatted-mode reformatter) as a recursive
descent — `value()` → `object()`/`array()` → `value()` — and forgot to bound the
recursion. A balanced deeply-nested document (`[[[[…]]]]`, ~100k deep) overflows the
stack and **aborts the whole process** (release profile is `panic = "abort"`, so it's
not even a catchable panic). Because the core is shared by all three front-ends, that's
a one-file-opens crash/DoS reachable from any untrusted `.json`.

- This is the **same class** as the audited cmark deep-nesting SIGSEGV (TSK-126) — any
  parser that recurses on attacker-supplied structure must cap depth, not just guard the
  visitor/output stage.
- Fix pattern: thread a `depth` counter (we already had one for indentation) and bail at
  the top of the recursive fn — `if depth > MAX_DEPTH { return None; }` — so it degrades
  to the raw-text fallback instead of crashing. `MAX_DEPTH = 128` matches `serde_json`'s
  default; real documents never nest that deep. (commit f47c7d3)
- **Teeth:** test on *balanced, valid* deep input (only the cap can reject it) and prove
  it — neuter the cap and confirm the test aborts with SIGABRT, then restore. An
  unbalanced deep string is a weaker test (it'd return None as malformed anyway).
- Checklist for any new core module: does it recurse on input? cap it. Does it index a
  slice? use `.get(..)?`. Does it allocate from an untrusted count/size? cap it. (The
  ffi no-panic clippy gate catches the unwrap/index class but NOT unbounded recursion.)

### Adding a `ViewMode`/`FileKind` variant breaks every front-end's exhaustive match (TSK-217, 2026-06-07)

`mdvcore_core::view::ViewMode` (and `FileKind`) are matched **exhaustively** in all three
front-ends — the TUI status-label match (`crates/tui/src/main.rs`), the web `mode_str` +
`parse_mode` (`crates/web/src/main.rs`), and any FFI mapping. Adding a variant
(`ViewMode::Formatted`, `FileKind::Structured`) compiles in `core` but breaks the others
with `E0004 non-exhaustive`. After adding a core enum variant, **`cargo build --workspace`**
and fix each match. (web `parse_mode` had a `_` fallback so only needed the offer arm;
TUI label + web `mode_str` were exhaustive and each needed the new arm.)

- **Stale-incremental-build false success:** during this I hit a `cargo build` that printed
  `Finished … 0.13s` and looked green while a downstream crate actually had an E0004 — the
  earlier failed build left stale artifacts and the no-op rebuild didn't recompile the
  broken bin. `touch <file> && cargo build -p <crate>` (or `cargo build --workspace`) to
  force a real recompile and see the true error. Don't trust a suspiciously-fast "Finished".

### "One core, three front-ends" features land in layers — wire the switcher generically (TSK-217/218)

Adding a view mode end-to-end = (1) core: the transform (`format::pretty_json`) + the
`ViewMode` + `available_modes()`/`default_mode()`/`classify()` entry + a `view::build` arm
(reuse an existing `ViewBody` where the render shape matches — `Formatted` reuses
`ViewBody::Text`, so renderers need NO new body type); (2) each front-end just handles the
new variant in its label/parse matches — both the TUI (`x`/cycle) and web (mode links from
`available_modes`) pick it up *by construction* because they iterate `available_modes`
rather than hard-coding the set. Classify conservatively: `.json`→Structured now, `.xml`
left `Plain` until the XML formatter lands (TSK-496) so no no-op Formatted is ever offered.

### Front-end-owned IO + core-owned parse keeps `mdvcore-core` sans-IO while still sharing logic (TSK-251/252, 2026-06-08)

Git status and recents both needed something the pure core forbids (process spawn / time).
The pattern that keeps the `#![forbid(unsafe_code)]` + no-IO + no-panic core intact AND
still shares the real logic across front-ends: **the front-end does the IO, the core does
the parse/transform.**
- `git`: TUI/web spawn `git --no-optional-locks status --porcelain=v1 --branch` (IO), then
  hand the stdout to `git::parse_status(&str) -> RepoStatus` (pure, host-tested with 8 cases
  incl all 7 unmerged XY codes + fresh-repo `No commits yet` + detached HEAD). Non-repo /
  git-absent → the front-end maps the non-zero exit / spawn error to `None`, no panic.
- `history`: the front-end owns the `Vec<PathBuf>` + when to record; `history::push<T>` does
  the MRU semantics (dedupe + front-insert + cap; cap=0 edge).
The merge-gate teeth live on the pure half (runs in the host gate); the IO half gets one
end-to-end test that stands up a *real* throwaway artifact (a `git init` temp repo) so the
spawn→parse→render wiring is exercised, not mocked. Temp repos go under
`std::env::temp_dir()` (NOT inside the working tree — else `git status` reports THIS repo).

### TUI status-line additions clip in the 35%-wide files pane — make the composition testable, not the clipped snapshot (TSK-251)

The files pane is `Constraint::Percentage(35)` of the terminal; a bordered-block title longer
than ~33 cols is truncated on screen, so a `render()` snapshot at 100 cols can't prove a new
title segment is visible. Fix: extract the title into a method (`files_title()`) and assert on
THAT string (width-independent), keeping the snapshot assertion for things that live on the
full-width status row (e.g. the find minimap, which is short + near the front so it survives).
Pane-title clipping eats the TAIL first — so a segment you must keep visible goes at the front.

### The autonomous progress log flipped from prepend-top to append-bottom around tick +59 (2026-06-08)

`docs/AUTONOMOUS_PROGRESS.md` has TWO numbering schemes that coexist: the OLD blocks near the
top use `## LOG 2026-06-07 (latest+NN)` DESCENDING (newest-on-top, tops out at +58); the
NEWER blocks are APPENDED AT THE BOTTOM as `## LOG +NN (date — …)` ASCENDING (+75, +76, …).
The "latest+N" and the commit-message "tick +N" are different counters. To find the real
latest entry, read the BOTTOM of the file, not the top. New entries append at the bottom.

### The VM UI/pixel lane is finally complete: ulimit (TSK-500) + launchctl-asuser (TSK-501), 2026-06-08

Two independent things made `ssh macOS15 'swift test'` look catastrophically red while `main` was
healthy, and BOTH are now fixed in `scripts/test-in-vm.sh`:
- **fd exhaustion (TSK-500):** the soft `ulimit -n` over a non-login ssh session is **256**; the full
  single-process `swift test` (4220 tests) leaks fds past it → EMFILE "could not open temp file" →
  ~158 false failures. Fix: `ulimit -n 8192` before `swift test` (hard limit is unlimited).
- **heavy-tier occlusion (TSK-501):** `ssh … swift test` runs OUTSIDE the console Aqua session, so
  T4/T5/UAT/VisualRegression windows never realize → occlusion failures. Fix: an additive
  `MDV_VM_GUI_SESSION=1` path that wraps `swift test` in
  `sudo -S launchctl asuser $(stat -f %u /dev/console) /bin/bash -lc "<cmd>"`, with cwd/ulimit/
  `TOOLCHAINS` exported INSIDE the spawned shell (asuser strips env passed via /usr/bin/env — same
  trick as vm-smoke.sh). Default-off so the headless `test` path is unchanged. Needs `MDV_VM_SUDO_PASS`.
  PROOF it works: PreviewsUATTests.PV_07 ran 10.3s / SessionsUATTests.SESS01 ran 6.6s (windows realized)
  vs fast occlusion-fail over plain ssh.
- **GOTCHA — the captured ssh stdout is summary-only.** The background job's returned stdout had only
  the per-suite "Executed N tests" lines, NOT the per-test-case "Test Case … failed" lines, and NO
  `[GUI session]` banner. The authoritative full log is **`/tmp/mdv-test-output.txt` on the VM** (the
  script `tee`s there). Always pull THAT to identify which tests failed; don't trust the thin host capture.

### Whole-window `recursiveDescription` + retained-pane LRU = stale "no X view mounted" assertions (TSK-504)

`DocumentModel.mountedPanes = MountedPanesLRU(capacity: 4)` keeps up to 4 panes alive simultaneously in
the ContentView ZStack at `opacity:0` (intentional — keeps inactive WKWebViews from firing
`visibilitychange`). The diagnostic dump (`DiagnosticDump.swift:60/67`) is the WHOLE window
(`window.contentView` + `recursiveDescription`). So a UAT assertion like `assertNoHexView` doing a
whole-window `hasViewClass("Hex")` is WRONG whenever ≤4 tabs are open and ANY retained (inactive) pane
is legitimately a HexView — e.g. PreviewsUATTests.PV_07 opens data.bin (HEX) + empty.bin (HEX) + code.txt,
all retained, so the assertion is structurally guaranteed to trip on the retained binary panes even when
the ACTIVE pane is Source. The model state (`currentViewMode`/`currentStateKind`) is correct; only the
assertion's scope is wrong. RULE: "no <kind> view present" assertions in the retained-pane world MUST be
scoped to the ACTIVE pane subtree (opacity==1 / hit-testable / URL-matched), never the whole window.
Audit siblings: `LSPUATTests.assertNoHexView` likely shares the hazard.

## VM pixel lane: TCC screencapture is attributed to xctest, NOT /bin/bash (2026-06-08, TSK-502)

Two durable VM gotchas found finishing the T5/VisualRegression pixel lane:

- **A prior `sudo` build poisons `.build` with root-owned files → `ModuleCache ...Operation not
  permitted` (EPERM) on the next `vm-tester` build.** A one-off `sudo swift build` (or any root-context
  compile) left ~1000 root-owned files in `~/markdown_viewer/.build` on the VM; the normal
  `build-app.sh` run as vm-tester then can't overwrite the CMdvCore `.pcm` and fails. FIX (fast, keeps
  the build cache): `echo <pass> | sudo -S chown -R vm-tester:staff .build` then rebuild as vm-tester.
  rsync excludes `.build`, so it's VM-local — chown is safe. Prefer chown over `rm -rf .build` (a full
  wipe forces a from-scratch recompile + SwiftPM re-resolve). Never run the VM build/test under `sudo`
  directly — the GUI-session path is `sudo -S launchctl asuser 501 …` which DROPS to uid 501 (vm-tester),
  so artifacts stay vm-tester-owned and consistent.
- **Granting Screen Recording to `/bin/bash` + `Terminal` does NOT let the T5 tests capture.** The T5
  PixelTestCase/VisualRegression suites spawn `/usr/sbin/screencapture -l<windowID>` from *inside* the
  `xctest` process (Foundation `Process`). macOS attributes the `kTCCServiceScreenCapture` check to the
  **responsible process = xctest**, not the `/bin/bash` ancestor — so even with `/bin/bash` granted
  (auth_value=2, client_type=1 in the SIP-protected system TCC.db), the per-window capture is denied and
  every pixel test self-skips ("Screen Recording denied"). A *direct* full-screen `screencapture -x` run
  as a bash-chain child DOES capture (proves the /bin/bash grant is real) — the difference is purely the
  responsible-process attribution of the xctest-spawned child. The grant must be on the **swiftpm xctest
  runner** specifically (the tests' own skip message says so). An agent CANNOT add it: the system TCC.db
  is SIP-protected, no `sqlite`/`tccutil` INSERT works without disabling SIP — it needs the owner's GUI
  grant or an MDM PPPC profile. Candidate code workaround (unverified): route the test's screencapture
  through `/bin/bash -c "screencapture …"` so the responsible process becomes the granted /bin/bash.
  Also recall the standing vm-smoke caveat: macOS 15 "Screen Capture Privacy" can redact windows of
  `launchctl asuser`-bridged processes regardless of grant; the durable fix may be running the app as a
  GUI-session-owned LaunchAgent. Parked as TSK-502 (decision).

## Session 2026-06-09 — rust-core production audit, Phase-0 fixes, VM GUI-lane forensics

- **`git checkout -- <file>` during a teeth check WIPES uncommitted work.** Demonstrating
  test teeth means mutating the code under test (revert the fix), watching the test go red,
  then restoring. If the fix itself is still uncommitted, `git checkout` restores the
  *committed* state and destroys the fix AND the new test. Undo deliberate teeth-check
  mutations with the inverse Edit, never with git, until the work is committed.
- **Bumping `rust-version` re-arms MSRV-aware clippy lints.** Raising `rust-version`
  1.85→1.88 made `collapsible_if` (deny via workspace lints) fire on 10 pre-existing
  nested-if sites, because let-chains became suggestible at 1.88. The gate goes red on a
  "comment-only" manifest change. Fix is mechanical:
  `cargo clippy --fix -p <crate> --all-targets --allow-dirty`.
- **`sudo launchctl asuser <uid> bash -lc` runs the payload as ROOT, not the uid's user.**
  `asuser` only adopts the *bootstrap namespace*; uid/euid stay root. Consequences on the VM
  GUI lane: xctest and every spawned app run as root, `FileManager.temporaryDirectory`
  resolves to root's `/var/folders/zz/...`, so windowid handshake files are invisible to
  non-sudo `find`s and TCC grants must attach to the right responsible process. The T5
  windowid timeout (2.5s) is also too short there — apps DO publish (window 1588 proven),
  just slowly; bump `waitForWindowID(timeout:)` for VM runs.
- **`MDV_VM_GUI_SESSION=1 scripts/test-in-vm.sh` silently no-ops without `MDV_VM_SUDO_PASS`.**
  The sudo wrapper prints "a password is required" into the log and the sweep "passes"
  having run nothing. Always pass `MDV_VM_SUDO_PASS=<vm-sudo-password>` with the GUI lane.
- **A bare `cargo` run inside the repo grew a 2.8 GB `rust-core/target` in the iCloud-synced
  tree** (sync thrash + xattr re-stamping — same class as the codesign breakage). Now
  self-enforcing: `rust-core/.cargo/config.toml` pins `target-dir = /private/tmp/mdv-rust-target`
  for every cargo invocation at or below `rust-core/`; `CARGO_TARGET_DIR` still overrides.
- **iCloud can make `rm -rf` fail with "Directory not empty"** mid-walk (file provider
  re-materializes entries). Just run it a second time.
- **Workflow verdict salvage:** when a multi-agent run dies at a usage limit, verdict-null
  entries are *unprocessed*, not refuted — distinguish by the missing `reasoning` field
  before counting. Resume with `resumeFromRunId` to reuse the cached prefix.

## Session 2026-06-10 — Phase-0 fixes: three distinct staleness traps + flake pattern

- **Cargo config discovery walks up from CWD, not `--manifest-path`.** The
  `rust-core/.cargo/config.toml` target-dir redirect silently did NOT apply to
  `cargo --manifest-path rust-core/Cargo.toml …` run from the repo root — a
  246 MB `rust-core/target` regrew in the iCloud tree within hours of the
  "fix". Cure: a second `.cargo/config.toml` at the REPO root (commit 2d4f7dd).
- **SwiftPM does NOT track the prebuilt `libmdvcore_ffi.a` as a build input.**
  Rebuilding the staticlib alone does not relink already-built test bundles —
  the A/B parity suite ran STALE Rust against new Swift and failed with a
  one-side-fixed signature (caught live in 730fc65). `build-rust-core.sh` now
  `touch`es `Sources/RustCore/*.swift` after staging so the next SwiftPM build
  relinks. If an A/B test fails right after a Rust change, suspect the link
  before the code.
- **SwiftPM stale incremental compile on enum case-add = cross-module case-tag
  skew.** Adding `case tooLarge` before `.panic` in the public Equatable
  `CoreError` left ViewerCore compiled against the OLD tag order:
  `.panic == .panic` evaluated FALSE across modules (escalation test red, fix
  invisible). `touch` the dependent source to force recompile. Same family as
  the untracked-.a hole — SwiftPM trusts its incremental state too much.
- **Host-gate flake pattern under build load:** PTY lifecycle + LSPPool tests
  use 2.5–8 s waits that time out while cargo/swiftc saturate the machine;
  isolated re-run passes in <100 ms. Triage rule: re-run the failing suite
  ALONE before chasing it. (Candidate hardening: load-tolerant deadlines +
  retry-once-in-gate for the known-flaky suites — offered to owner 2026-06-10.)

### 2026-06-10 (later) — profiling-harness session
- **The PerfSignpost capture recipe was silently broken.** The doc's TL;DR ran
  `xctrace record --template 'Time Profiler'` WITHOUT `--instrument
  'os_signpost'` — the stock template records ONLY Apple's PointsOfInterest
  lane, so every `com.markdownviewer.*` interval was absent from the trace
  while looking like a clean capture. The flag is load-bearing; doc fixed
  (1668d68). Companion trap: `OSSignposter` intervals are NOT persisted to
  the unified log store — `log show --signpost` returns NOTHING for them, so
  it is not a fallback. The trace is the only record.
- **Two more root-poisoning sites in the VM GUI lane (TSK-502 class):** the
  sudo'd `launchctl asuser` xctrace writes its `.trace` root-owned → (a) the
  vm-tester `scp` pull gets per-file Permission denied, (b) the NEXT run's plain
  `rm -rf` of the old trace fails. `vm-profile.sh` self-heals both (in-sudo
  `chown -R vm-tester` after recording + sudo'd pre-clean). Pattern: anything a
  sudo'd bridge WRITES needs an in-bridge chown before unprivileged access.
- **Ad-hoc inline sudo-password heredocs over ssh get denied by the action
  classifier; committed, reviewable harness scripts (the vm-smoke.sh shape)
  are the sanctioned route.** That pressure produced `scripts/vm-profile.sh` —
  the better artifact anyway (repeatable, self-documenting, owner-auditable).
- **Stripped release bundle ⇒ unsymbolicated Time Profiler samples.** Release
  is the honest config for signpost TIMINGS, but stack ATTRIBUTION needs the
  debug build (`vm-profile.sh … debug`). Choose per question.
- **Measured (not guessed): rendered-MD open = 94% WebKit.** VM capture of
  LESSONS.md (147KB, no mermaid): app-side pipeline ~230ms cold / ~80ms warm
  (renderPage 203ms incl. 149ms one-time query-compile) vs
  `WKWebView.loadToFinish` 3457ms. The lag lives in the WebKit page build —
  and is RE-PAID on every tab revisit because the single mounted WKWebView is
  torn down per switch (MountedPanesLRU is the data-justified fix).
- **Inert-control bug class: "visible" ≠ "revealed".** Shoulder buttons 4/5/6
  toggled fine at the model layer; the sections mounted COLLAPSED (Claude's
  disclosure was transient `@State false`, reset every remount), so the click
  read as dead. When a toggle shows a container with its own disclosure
  state, the toggle must also expand it (reveal-on-toggle-on, c82498f).
- **Close-path lazy-survivor class:** any flow that changes the SELECTION as
  a side effect (close auto-selecting a neighbor) must run the same
  incoming-tab duties as an explicit select (`materializeIfNeeded` +
  staleness refresh) or lazy tabs sit blank (5336262).

- **2026-06-10 (TSK-592 system-scope capture):** Two WebKit perf intuitions refuted by
  measurement. (1) **WebContent does NOT relayout per resize frame** — during a 4s
  setFrame sweep (~30Hz) over a rendered-MD tab, the WebContent process logged ~1-2
  samples/s (idle); WebKit throttles/coalesces resize repaints. Don't attribute resize
  jank to the web view without sampling it. (2) **`WKWebView.loadToFinish` (3.4s VM) is
  latency, not CPU** — system-wide sampling shows only ~0.11 core·s of WebContent work
  building the whole LESSONS.md page; the wall-clock is IPC/first-paint scheduling.
  CPU-side optimizations can't shrink it; only avoiding the reload (MountedPanesLRU)
  can. Recipe: `bash scripts/vm-profile.sh <file> 30 resize release system` → per-process
  aggregation, sweep window anchored by the app's own sample density (no signposts in
  system scope).

## 2026-06-10 (autonomous run, later)
- **Never run teeth mutations while a background `build-app.sh` is in flight on the same
  tree.** SwiftPM hard-fails with "input file ... was modified during the build" — the
  TSK-314 install raced a teeth mutate/restore cycle on `DocumentModel.swift` and died with
  exit 1 (build correctness is preserved; only the run is lost). Order per item: teeth →
  restore → commit → gate → THEN kick the install. If the install must overlap other work,
  only overlap it with non-mutating steps (board updates, docs, trace parsing).

## 2026-06-10 (VM live-app validation traps — TSK-617)
- **`test-in-vm.sh test` does NOT rebuild `dist/` and `dist/` is rsync-excluded** — after
  landing a fix, a VM T4/UAT rerun spawns the PRE-FIX `dist/TextView.app` and fails
  identically, masquerading as "fix didn't work". Always check the dist binary's mtime
  against the fix and rebuild on the VM (`ssh macOS15 'cd markdown_viewer && bash
  scripts/build-app.sh debug'`) before any live-app rerun.
- **VM dist build (default Swift 6.1.2) and test build (script-selected 6.3) share
  `.build/arm64-apple-macosx/debug` and clobber each other** — the next `swift test` dies
  with "module compiled with Swift 6.1.2 cannot be imported by the Swift 6.3 compiler".
  Cure: `rm -rf .build/arm64-apple-macosx/debug` ONLY (never `.build/checkouts` /
  `.build/repositories` — the VM is an offline rsync mirror and cannot re-fetch).
- **Empty files defeat NUL-byte binary sniffing** — 0 bytes decode as valid empty UTF-8,
  so content-based binary detection passes them to the text path. Any "unknown type →
  HEX" contract needs an explicit size==0 route (`DocumentController.open`, c3e6e5b).

## 2026-06-10 (TextKit 2 large-document traps — TSK-267)
- **A self-sizing (`isVerticallyResizable`) NSTextView defeats TK2 viewport layout**: any
  height query (`textContainerOrigin`, triggered by `layoutViewport` and `renewGState`)
  runs `ensureLayoutForRange` over the WHOLE document. For uniform grids, pin the frame
  arithmetically (engine-measured line height × rows) and override `textContainerOrigin`
  to return the inset. Measure line height from a tiny NSTextLayoutManager sample, never
  font metrics — and pin formula == `usageBoundsForTextContainer` in a host test so an OS
  metrics change goes red (HexGridGeometryTK2Tests).
- **Do NOT bound the NSTextContainer to make height queries cheap** — a finite container
  makes TK2 lay out in-bounds content EAGERLY (measured: chunked build blew up). Keep the
  container unbounded; fix the frame and the origin instead.
- **`ssh vm 'build | tail -N'` masks build failures** (exit code is tail's) → the harness
  profiles/tests a STALE binary and "refutes" a fix that was never in the build. Always
  propagate the remote build's exit code (vm-profile.sh fixed, b1849c4). Symptom checklist
  before trusting any VM artifact: binary mtime vs fix time, `nm` for a new symbol, build
  log exit marker.

## 2026-06-10 (in-process event synthesis — TSK-620 half B, the five constraints)
Empirically mapped while building `ui-click`/`ui-double-click` (UIEventSynth). Each one
cost an iteration; together they bound what an IN-PROCESS click harness can ever do:
- **(1) `sendEvent` down/up pairs cannot satisfy NSControl tracking loops** — an
  `NSButton.mouseDown` runs a modal tracking loop that pulls its mouse-up from the EVENT
  QUEUE via `nextEvent`; a directly-sent up never arrives there. Queue-post
  (`NSApp.postEvent`) for AppKit controls.
- **(2) Queued events cannot route to an un-ordered window** — a window that was never
  ordered in has no window device (`windowNumber <= 0`); posted events are dropped on
  dequeue. End-to-end delivery is only observable in a live ordered window (VM lane);
  headless tests pin everything up to delivery (`UIEventSynth.events`).
- **(3) A click on a non-key window is swallowed as the activating click** — under
  `MDV_BACKGROUND` the window is never key; SwiftUI views default
  `acceptsFirstMouse == false`, so the first click activates and is consumed. The verb
  must `NSApp.activate` + `makeKeyAndOrderFront` first (e692846).
- **(4) SwiftUI controls inside an NSHostingView are NOT NSViews** — their
  `.accessibilityIdentifier(_:)` never lands on any NSView; an NSView-tree walk cannot
  find them. Ids appear on hosting NSViews only at hosting BOUNDARIES (which is why
  DiagnosticDump works).
- **(5) The in-process accessibility tree is EMPTY** — `contentView.accessibilityChildren()`
  returns 0 children at the root (proven live: `axRootChildren=0`). SwiftUI materializes
  AX elements lazily for EXTERNAL AX clients only, and AX TCC for xctest is owner-only
  (SIP blocks agent INSERT). An in-process AX walk is a dead end, period.
  ⇒ Consequence: clicking arbitrary SwiftUI controls in-process requires the controls to
  PUBLISH their own frames (a `.uiClickTarget("id")` modifier → ClickTargetRegistry), or
  an external XCUITest runner (testmanagerd synthesizes entitled real events). Design on
  TSK-620.
- **Versioned NOT-FOUND traces pay for themselves**: tagging the failure trace with a
  resolver version (`click[v4](…): NOT FOUND; axRootChildren=…`) plus an AX-id sample
  distinguishes "stale binary" / "AX tree empty" / "ids live elsewhere" in ONE VM run
  instead of three.

## 2026-06-10 (VM + commit hygiene, recurring)
- **chown `.build` EVERY VM cycle, not once** — every sudo'd asuser GUI test run
  re-poisons `.build` with root-owned files; the NEXT build fails "Operation not
  permitted". Make `sudo chown -R vm-tester .build` an unconditional step of the cycle
  (rsync → chown → build → test), not a one-time repair (TSK-502 class).
- **Never `;`-chain `git commit` after a remote/long build** — `ssh vm build; git commit`
  commits even when the build FAILED (af8bd21 landed non-compiling code). Gate with `&&`
  on the build's REAL exit, or run the steps as separate sequential calls and read the
  exit first.

## 2026-06-10 (in-process event synthesis — TSK-620 endgame, constraints 6–8: the matrix is CLOSED)
Continuation of "the five constraints" above; these three close every remaining channel.
- **(6) WindowServer refuses activation/key status to a root-uid app in a user's GUI
  session** — even `.regular` policy + `NSApp.activate` + run-loop pumping never lands
  key. Cure for the harness: spawn the app AS the console user (`sudo -n -u vm-tester`)
  from the root xctest (AppLauncher does this whenever `geteuid()==0`); root's per-user
  tmpdir is 700, so the cross-user hand-off moves script/arg/artifacts to a 0777 /tmp dir.
- **(7) A fork/exec'd app on macOS 14+ can NEVER self-activate** (cooperative activation)
  — correct uid does not help. The ONLY route to genuine activation is a LaunchServices
  launch: `open -n -W --env K=V … -a App` (`--env` exists and works; LS drops
  `--`-prefixed argv, so `--script`/file ride in env vars `MDV_SCRIPT_PATH` /
  `MDV_OPEN_FILE`, read back in main.swift). AppLauncher `viaOpen:` mode; PROVEN: the
  trace flipped to `active=true` + key window. Also disproven en route: FAKING
  `isKeyWindow` (window subclass) changes nothing — `sendEvent`'s non-key suppression is
  not keyed on the overridable property (a probed plain-AppKit subview's `mouseDown`
  never arrived either), so don't try that again.
- **(8) Synthesized NSEvents do not drive SwiftUI gestures EVEN on a genuinely key +
  active window** (iteration 10: LS-launched, `via=sendEvent active=true`, action never
  fired; SwiftUI attaches zero public NSGestureRecognizers and ignores direct responder
  dispatch). SwiftUI's gesture pipeline evidently requires WindowServer-backed (CGEvent)
  input — which requires the owner-only AX TCC grant. ⇒ In-process real-event synthesis
  for SwiftUI controls is IMPOSSIBLE, full stop.
- **The sanctioned endgame**: the testing mandate's own fallback — "exercise the exact
  action closure the control is wired to" — as a script verb in the LIVE app, asserting
  the cross-process outcome incl. RENDERED text via the `nsTextField` dump channel
  (`session-open-home`, `session-new-via-goto`; InteractionUATTests green 2/2 on the VM
  after 5 demonstrably-red iterations). The only residue this leaves uncovered is literal
  pixel hit-area routing — entitled synthesis (XCUITest L4 / owner AX grant) territory.
  Don't spend VM iterations rediscovering this: for any future SwiftUI-interaction
  ticket, go STRAIGHT to exact-closure verbs + rendered-outcome dump assertions.

## 2026-06-10 (Git-panel harness bindings — TSK-522/523 VM scenarios)
- **`GitPanelModel` focus-follow does NOT bind in a harness launch** — opening a repo
  folder + `show-git-panel` leaves `panel.repoRoot` nil (trace: "NO repoRoot"). Scenarios
  must pin the root via the header picker's exact closure (`git-panel-root` verb →
  `pickRepoRoot`, defaulting to the opened sidebar root since the launcher rewrites
  paths for the cross-user hand-off).
- **The panel boots on the Status tab and `refreshCurrent` loads only the VISIBLE tab** —
  `logEntries` stays empty (cumulative-diff range = nil) until the Log tab is selected
  (`git-panel-tab log`, the segmented control's `selectTab` closure) + a settle.
- **Cross-user git fixtures need a chown**: git ≥2.35 refuses root-owned repos ("dubious
  ownership") when the console-user app shells git against the /tmp copy — AppLauncher
  chowns the run dir to the spawn user; folder args get 0755 (a blanket 0644 kills
  directory traversal).
- **Self-describing action traces pay for themselves AGAIN**: `GitLogDiffActions.lastTrace`
  (root → range → git body bytes → cache write → tab count) named the exact broken link
  ("NO repoRoot") in ONE run — the same pattern as the ui-click v4 trace. Give every
  multi-link harness action a trace channel up front.

## 2026-06-10 (later still) — gated suites must be IN a lane list, and caches that views read-only are lifecycle-coupled

- **A gated test suite that is in NO lane's filter list runs NOWHERE — and its
  green history means nothing.** `PaneRetentionMountProbeTests` self-gates on
  `MDV_RUN_WEBVIEW_TESTS` but was never added to `test-in-vm.sh
  run_webview_tests` or `nightly-vm.yml`, so TSK-611 broke the pane-retention
  contract it guards (3 dismantles on LRU overflow instead of 1) and nothing
  went red for days. When adding an env-gated suite, wiring it into the lane
  list IS part of the change (same class as #312). Corollary: when validating
  an old `fixed` ticket, RE-RUN its evidence fresh — this exact re-run is what
  caught the regression.
- **A cache that a SwiftUI body reads READ-ONLY becomes part of the view
  lifecycle: evicting an entry is equivalent to tearing the view down.** After
  TSK-611, `renderedHTMLIfCached` nil → spinner branch → the retained
  WKWebView pane is dismantled. So the rendered-HTML cache eviction must be
  MOUNTED-AWARE (never evict a `MountedPanesLRU` member's entry), and
  drop-to-⅔ hysteresis on such a cache amplifies one eviction into several
  teardowns. General rule: any cache consulted in `body` to DECIDE WHETHER A
  SUBTREE EXISTS must align its eviction policy with the retention policy of
  that subtree (TSK-621, af5e6dd).
