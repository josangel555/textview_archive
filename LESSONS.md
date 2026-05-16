# LESSONS.md — hard-won knowledge for this codebase

Workspace-scoped memory. Read this when you're about to do something
adjacent to the items below. The mistakes that produced these entries
each cost real hours; the entries exist so they don't cost the next
hours.

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
