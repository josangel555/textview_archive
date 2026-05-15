# Investigation: source-view invisible content

Status: **fixed (commit 73baa53)**. Replaced `NSScrollView.verticalRulerView`
with a sibling `GutterScrollContainerView` that lays out a custom
`LineNumberGutterView` next to the `NSScrollView`. User confirmed the
text is now visible.

## Symptom

When `TextDisplayView` (NSScrollView + NSTextView + LineNumberRulerView) is
rendered as part of the SwiftUI tree, **only the LineNumberRulerView draws**.
Everything else in the window — TabBar, ModeBar, NSTextView text glyphs,
file-name label, sidebar — is invisible. The window shows white background.

The user has reported this consistently. Confirmed via in-app self-snapshot
(`CGWindowListCreateImage`, no Screen Recording permission needed).

## What renders vs what doesn't

| Element | Status when TextDisplayView present | Notes |
| --- | --- | --- |
| Title bar | ✓ Visible | WindowServer-drawn |
| LineNumberRulerView | ✓ Visible | Traditional NSView `drawHashMarksAndLabels` |
| NSTextView background fill | ✓ Visible (white) | `drawsBackground=true` |
| NSTextView text glyphs | ✗ Invisible | Despite glyphs generated, layoutManager populated |
| TabBar (SwiftUI) | ✗ Invisible | SwiftUI hosting layer empty |
| ModeBar (SwiftUI) | ✗ Invisible | SwiftUI hosting layer empty |
| Sidebar (if visible) | ✗ Invisible | SwiftUI hosting layer empty |

| Scenario | Result |
| --- | --- |
| Launch with no file (empty state) | ✓ Everything renders |
| Launch with `.md`, default rendered mode (WKWebView) | ✓ Everything renders |
| Launch with `.md`, toggled to source | ✗ Only ruler visible |
| Launch with `.xml` (always source) | ✗ Only ruler visible |

## Diagnostic dump confirms

- Window: occlusionState_visible=True, isKey=True, isMain=True
- NSHostingView<ContentView>: 1500x1068, alpha=1, hidden=false
- TabBar's PlatformContainer: 1468x28, but **layer.hasContents=False**
- ModeBar's segmented control host: layer.hasContents=False
- AppKitPlatformViewHost<TextDisplayView>: 1500x1002, layer.hasContents=False
- NSScrollView: 1500x1002, layer.hasContents=False
- NSClipView: 1500x985, layer.hasContents=False
- **NSTextView: 1500x985, layer.hasContents=True ←** but glyphs invisible
- NSTextView.textColor: black sRGB (0,0,0,1), background: white (1,1,1,1), contrast distance 1.73
- NSTextView.numberOfGlyphs: 102 (for 102-char file)
- NSTextView.glyph_boundingRect: (0,0 1475x176) — laid out correctly
- LineNumberRulerView: 40x1002, **layer.hasContents=True** (the only SwiftUI-tree-sibling with contents)

## What's been ruled out

- ❌ Zero-sized views — all sizes match parents
- ❌ Alpha/hidden — all alphaValue=1, isHidden=false
- ❌ Color contrast — text and bg are max-contrast
- ❌ TextKit 2 — switched to explicit TextKit 1 stack, no change
- ❌ `_NSScrollViewContentBackgroundView` (visual effect bg) — set
   `scrollView.drawsBackground=false` to suppress, no change
- ❌ Window occlusion — `tell application activate` confirms occlusion=visible
- ❌ Pre-rasterization race — 5s delays don't help, state is persistent

## Strong leads

1. **The bug propagates upward**: when TextDisplayView appears,
   *every* SwiftUI hosting layer in the window becomes empty
   (TabBar, ModeBar, etc.). Whatever the NSScrollView/NSTextView setup is
   doing, it's breaking the *parent* NSHostingView's compositing.

2. **AppKit drawing paths still work**: LineNumberRulerView (an NSRulerView
   subclass with traditional `drawHashMarksAndLabels`) draws. NSTextView's
   background fill draws. So the window IS receiving display passes. The
   compositor isn't entirely dead.

3. **SwiftUI's bitmap commits go silent**: the SwiftUI-managed layers all
   report `layer.contents == nil`. Something is causing SwiftUI to stop
   committing its rasterized output.

## Resolution

After removing `LineNumberRulerView` from the `scrollView.verticalRulerView`
slot, the entire window rendered correctly — TabBar, ModeBar, NSTextView
glyphs, all visible. The culprit was confirmed to be NSScrollView's
ruler installation path, which inserts a `_NSScrollViewContentBackgroundView`
(NSVisualEffectView) that breaks the parent SwiftUI compositor's
layer-content commits.

**Fix**: introduce `GutterScrollContainerView` (Sources/ViewerUI/GutterScrollView.swift):
- An NSView container with two children laid out horizontally:
  `LineNumberGutterView` on the left (40pt wide) and the `NSScrollView`
  on the right
- The gutter observes the scroll view's `NSClipView`
  `boundsDidChangeNotification` to redraw aligned with the visible
  glyph range
- Same line-number behavior as before, but as a *sibling* NSView
  rather than NSScrollView's installed ruler. No NSVisualEffectView
  side-effect → SwiftUI compositor stays healthy.

## Files touched

- `Sources/ViewerUI/DiagnosticDump.swift` — view-tree introspection
- `Sources/MarkdownViewer/main.swift` — `--diagnose`, `--auto-snapshot`,
  `--script` flags + SIGUSR1 handler
- `Sources/ViewerUI/TextDisplayView.swift` — explicit TextKit 1 stack
  + delegates ruler layout to GutterScrollContainerView
- `Sources/ViewerUI/GutterScrollView.swift` — new container + gutter
- `Sources/ViewerUI/DocumentModel.swift` — skip restoring TCC-protected
  folders on launch (Documents/Desktop/Downloads/Pictures/iCloud)

## Regression tests

- `DiagnosticDumpTests.test_sourceView_nsScrollViewDoesNotHaveVerticalRulerView`
  asserts no `NSScrollView` in the realized tree has both
  `hasVerticalRuler` and a non-nil `verticalRulerView` (the bug pattern).
- `DiagnosticDumpTests.test_sourceView_gutterPresent_and_distinctFromTextScrollView`
  asserts the gutter and scroll view are siblings inside
  `GutterScrollContainerView`.
- `InteractionScriptTests.test_toggleView_swapsRenderedAndSourceViews`
  exercises the live `.app` toggling rendered ↔ source.

## Known test-harness limitation

When the test runner spawns the app from a non-foreground bash session,
the window's `occlusionState.visible` is False and AppKit suspends
drawing — `CGWindowListCreateImage` then returns a blank backing store
even though the view tree is correct. This is *not* a user bug
(LaunchServices-launched apps from Finder or `open -a` get proper
focus). For automated tests, we assert on the DiagnosticDump JSON
which is layer-state-independent. PNG snapshots remain useful for
manual / human visual inspection when run with the app foregrounded.

### Mitigation attempted (and the reason it doesn't fully work)

- We tried `osascript "tell application X to activate"` from the
  launcher after spawning. macOS 14+ rate-limits / restricts
  programmatic foregrounding when the caller isn't itself frontmost.
  The window's `isKeyWindow` / `isMainWindow` / `occlusionState`
  remain False, so PNG snapshots are still blank.
- We tried `/usr/bin/open -n -a APP --args ...` (LaunchServices). On
  this macOS, `open` silently drops args that start with `--`, so the
  app launches but never sees `--script`.
- Direct `Process` exec preserves argv exactly. We use that for
  reliable script delivery and accept the occlusion as a documented
  test-harness limitation. Tests assert on JSON dumps.

For true visual review, run a UTM VM with auto-login, no terminal in
front, and let the test suite spawn MarkdownViewer there — its window
becomes frontmost by default, and PNG snapshots populate correctly.
The `scripts/test-in-vm.sh` runner is designed for that case.
